#!/usr/bin/env ruby
# frozen_string_literal: true

# 词级 CAC join（循环验证协议⑤环读数的最后一公里）。
#
# 输入：
#   1. readout-web/scripts/loop-funnel-report.mts 产出的词级装机 JSON
#      （默认 /tmp/loop-keyword-installs.json；无文件时只打印 ASA 侧词表现）
#   2. Apple Ads 关键词报表（keywordId → 词文本 + 展示/点击/花费）
# 输出：每词一行——词文本 | 展示 | 点击 | 花费 | 归因装机 | 付费 | CAC | 每付费成本
#
# 用法：ruby scripts/asa_keyword_cac.rb [installs.json] [start=YYYY-MM-DD] [end=YYYY-MM-DD]

require "json"
require "tempfile"
require "date"

CAMPAIGN_ID = "2144344391" # CR_US_Search_Exact_2026Q3

installs_path = ARGV[0] || "/tmp/loop-keyword-installs.json"
start_date = ARGV[1] || (Date.today - 30).iso8601
end_date = ARGV[2] || Date.today.iso8601

installs = File.exist?(installs_path) ? JSON.parse(File.read(installs_path)) : []
installs_by_kw = installs.each_with_object({}) { |row, h| h[row["keywordId"].to_s] = row }

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
  raw = `ruby #{File.expand_path("searchads_api.rb", __dir__)} POST /api/v5/reports/campaigns/#{CAMPAIGN_ID}/keywords #{f.path} 2>/dev/null`
  data = JSON.parse(raw)
  rows = data.dig("data", "reportingDataResponse", "row") || []
end

puts "词级 CAC · campaign #{CAMPAIGN_ID} · #{start_date} → #{end_date}"
puts format(
  "%-34s %6s %5s %9s %5s %5s %9s %9s",
  "keyword", "展示", "点击", "花费", "装机", "付费", "CAC", "每付费"
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
  n_payers = attr["payers"].to_i
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
puts "\n判定参照（§12.4）：每付费成本 ≤¥320(≈$45) 过⑤环门；展示为 0 = 相关性仍未解锁。"
