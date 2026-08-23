#!/usr/bin/env ruby
# frozen_string_literal: true

# 词级 CAC join（循环验证协议⑤环读数的最后一公里）。
#
# 输入：
#   1. 词级广告 cohort JSON（`keywordId` / `installs` / `fullPricePayers`）
#      （默认 /tmp/loop-keyword-installs.json；无文件时只打印 ASA 侧词表现）
#   2. Apple Ads 关键词报表（keywordId → 词文本 + 展示/点击/花费）
# 输出：每词一行——词文本 | 展示 | 点击 | 花费 | 归因装机 | 正价付费 | 安装 CPA | 付费 CAC
#
# 重要：`purchase_result success` + introductory 只是试用启动，不是正价付费。
# 输入 JSON 必须显式提供 `fullPricePayers`；旧字段 `payers` 不再用于 CAC。
#
# 用法：ruby scripts/asa_keyword_cac.rb [installs.json] [start=YYYY-MM-DD] [end=YYYY-MM-DD]

require "json"
require "tempfile"
require "date"
require "time"
require "open3"

ALLOWED_CAMPAIGN_IDS = %w[2144343127 2144503591].freeze
CAMPAIGN_ID = ENV.fetch("ASA_CAMPAIGN_ID", "2144343127") # 默认 CR_US_Search_Discovery_2026Q3
abort "只允许 US/GB clean campaign：#{ALLOWED_CAMPAIGN_IDS.join(" / ")}" unless ALLOWED_CAMPAIGN_IDS.include?(CAMPAIGN_ID)

installs_path = ARGV[0] || "/tmp/loop-keyword-installs.json"
start_date = ARGV[1] || "2026-08-24"
# D+10 is exact-time maturity. Ending on D-11 keeps the whole final calendar
# day mature instead of mixing early-day mature installs with late-day ones.
end_date = ARGV[2] || (Date.today - 11).iso8601

begin
  parsed_start = Date.iso8601(start_date)
  parsed_end = Date.iso8601(end_date)
rescue Date::Error
  abort "start/end must be ISO dates"
end
abort "end must be on or after start" if parsed_end < parsed_start
if parsed_end > Date.today - 11
  abort "拒绝未成熟 CAC：end 必须不晚于 D-11（当前上限 #{(Date.today - 11).iso8601}）"
end

installs = File.exist?(installs_path) ? JSON.parse(File.read(installs_path)) : []
campaign_rows = installs.select { |row| row["campaignId"].to_s == CAMPAIGN_ID }
unless campaign_rows.empty?
  unsafe = campaign_rows.reject do |row|
    row["measurementStatus"] == "KNOWN" && row["maturityStatus"] == "MATURE"
  end
  unless unsafe.empty?
    states = unsafe.map { |row| "#{row["measurementStatus"]}/#{row["maturityStatus"]}" }.uniq
    abort "拒绝未成熟或不完整 CAC 输入：#{states.join(", ")}"
  end

  from_values = campaign_rows.map { |row| row["reportFrom"] }.compact.uniq
  to_values = campaign_rows.map { |row| row["reportToExclusive"] }.compact.uniq
  abort "可信漏斗 JSON 缺少唯一 reportFrom/reportToExclusive" unless from_values.length == 1 && to_values.length == 1
  report_from = Time.parse(from_values.first).getlocal("+08:00")
  report_to = Time.parse(to_values.first).getlocal("+08:00")
  unless report_from.hour.zero? && report_from.min.zero? && report_from.sec.zero? &&
         report_to.hour.zero? && report_to.min.zero? && report_to.sec.zero?
    abort "可信漏斗窗口必须使用 Asia/Shanghai 自然日边界"
  end
  expected_start = report_from.to_date.iso8601
  expected_end = (report_to.to_date - 1).iso8601
  unless start_date == expected_start && end_date == expected_end
    abort "ASA 与可信漏斗窗口不一致：应使用 #{expected_start} → #{expected_end}"
  end
end

installs_by_kw = campaign_rows.each_with_object(Hash.new { |h, key| h[key] = { "installs" => 0, "fullPricePayers" => 0 } }) do |row, h|
  key = row["keywordId"].to_s
  h[key]["installs"] += row["installs"].to_i
  h[key]["fullPricePayers"] += row["fullPricePayers"].to_i
end

report_request = {
  "startTime" => start_date,
  "endTime" => end_date,
  "selector" => {
    "orderBy" => [{ "field" => "localSpend", "sortOrder" => "DESCENDING" }],
    "pagination" => { "offset" => 0, "limit" => 200 },
  },
  "granularity" => "WEEKLY",
  "returnRecordsWithNoMetrics" => true,
}

rows = nil
Tempfile.create(["asa_kw_report", ".json"]) do |f|
  f.write(JSON.generate(report_request))
  f.flush
  raw, error_output, status = Open3.capture3(
    "ruby",
    File.expand_path("searchads_api.rb", __dir__),
    "POST",
    "/api/v5/reports/campaigns/#{CAMPAIGN_ID}/keywords",
    f.path
  )
  abort "Apple Ads keyword report failed: #{error_output.strip}" unless status.success?
  data = JSON.parse(raw)
  rows = data.dig("data", "reportingDataResponse", "row") || []
end

puts "词级 CAC · campaign #{CAMPAIGN_ID} · #{start_date} → #{end_date}"
puts format(
  "%-34s %6s %5s %9s %5s %5s %9s %9s",
  "keyword", "展示", "点击", "花费", "装机", "付费", "安装CPA", "付费CAC"
)

total = { imp: 0, taps: 0, spend: 0.0, installs: 0, payers: 0 }
rows.each do |row|
  meta = row["metadata"] || {}
  kw_id = meta["keywordId"].to_s
  text = meta["keyword"] || "?"
  imp = 0
  taps = 0
  spend = 0.0
  (row["granularity"] || []).each do |g|
    imp += g["impressions"].to_i
    taps += g["taps"].to_i
    spend += g.dig("localSpend", "amount").to_f
  end
  attr = installs_by_kw[kw_id] || {}
  n_installs = attr["installs"].to_i
  # 仅 Apple 订阅对账已确认的正价付费才允许进 CAC 分母。
  # 旧 loop-funnel-report 的 `payers` 实际是 purchase_result success，包含免费试用。
  n_payers = attr["fullPricePayers"].to_i
  next if imp.zero? && n_installs.zero? # 静默词不占版面

  cac = n_installs.positive? ? format("¥%.1f", spend / n_installs) : "—"
  cpp = n_payers.positive? ? format("¥%.1f", spend / n_payers) : "—"
  puts format(
    "%-34s %6d %5d %8.1f¥ %5d %5d %9s %9s",
    text[0, 34], imp, taps, spend, n_installs, n_payers, cac, cpp
  )
  total[:imp] += imp
  total[:taps] += taps
  total[:spend] += spend
  total[:installs] += n_installs
  total[:payers] += n_payers
end

puts "-" * 88
total_cac = total[:installs].positive? ? format("¥%.1f", total[:spend] / total[:installs]) : "—"
total_cpp = total[:payers].positive? ? format("¥%.1f", total[:spend] / total[:payers]) : "—"
puts format(
  "%-34s %6d %5d %8.1f¥ %5d %5d %9s %9s",
  "TOTAL", total[:imp], total[:taps], total[:spend],
  total[:installs], total[:payers], total_cac, total_cpp
)
puts "\n判定参照：US v2 首年跑通 CAC ≤¥329，可扩量 CAC ≤¥263。"
puts "GB 当前仍是 v1；未核定当地净 LTV 前不套用 US 阈值。"
