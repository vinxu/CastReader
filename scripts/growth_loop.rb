#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8

# US / GB Apple Ads 增长闭环快报。
#
# 默认只拉 2026-08-24 关键词路由调整后的首个完整自然日起的 US / GB，结束日为昨天：
#   ruby scripts/growth_loop.rb
#
# 指定窗口：
#   ruby scripts/growth_loop.rb --from 2026-08-24 --to 2026-08-24
#
# 周度完整对账（增加 ASC 首次下载与订阅事件）：
#   ruby scripts/growth_loop.rb --full
#
# 本脚本绝不修改广告。ASC 数据没有 Campaign 维度，只做国家大盘对账；
# 真实广告 CAC 必须用 production mobile_ad_attributions 连正价 Apple 交易。

require "csv"
require "date"
require "json"
require "net/http"
require "open3"
require "optparse"
require "stringio"
require "tempfile"
require "uri"
require "zlib"

APP_ID = 6_757_636_395
ROUTING_CHANGE_AT = "2026-08-23T03:52Z"
CUTOVER_DATE = Date.iso8601("2026-08-24")
FX_RMB_PER_USD = 7.15
US_FIRST_YEAR_LTV_RMB = (46 * FX_RMB_PER_USD).round(2)
US_TWO_YEAR_LTV_LOW_RMB = (54 * FX_RMB_PER_USD).round(2)
US_TWO_YEAR_LTV_HIGH_RMB = (65 * FX_RMB_PER_USD).round(2)

TARGET_CPT_RMB = 8.0
TARGET_TAP_TO_INSTALL = 0.35
TARGET_INSTALL_CPA_RMB = 23.0
TARGET_INSTALL_TO_TRIAL = 0.20
TARGET_TRIAL_TO_PAID = 0.35

CAMPAIGNS = {
  "US" => {
    id: 2_144_343_127,
    name: "CR_US_Search_Discovery_2026Q3",
    price: "v2",
    product_ids: %w[ai.castreader.pro.monthly.v2 ai.castreader.pro.yearly.v2]
  },
  "GB" => {
    id: 2_144_503_591,
    name: "CR_GB_Search_Discovery_2026Q3",
    price: "v1",
    product_ids: %w[ai.castreader.pro.monthly ai.castreader.pro.yearly]
  }
}.freeze

SCRIPT_DIR = File.expand_path(__dir__)
SEARCHADS_CLI = File.join(SCRIPT_DIR, "searchads_api.rb")

class PullError < StandardError; end

def money(value)
  raw = value.is_a?(Hash) ? value["amount"] : value
  Float(raw || 0)
rescue ArgumentError, TypeError
  0.0
end

def integer(value)
  Integer(value || 0)
rescue ArgumentError, TypeError
  0
end

def pct(numerator, denominator)
  denominator.to_f.positive? ? numerator.to_f / denominator.to_f : nil
end

def format_pct(value)
  value ? format("%.1f%%", value * 100) : "—"
end

def pass_mark(value, target, direction)
  return "—" if value.nil?

  passed = direction == :lower ? value <= target : value >= target
  passed ? "✅" : "❌"
end

def searchads_json(method, path, payload = nil)
  args = ["ruby", SEARCHADS_CLI, method, path]
  stdout = nil
  stderr = nil
  status = nil

  if payload
    Tempfile.create(["castreader-us-gb-asa", ".json"]) do |file|
      file.write(JSON.generate(payload))
      file.flush
      stdout, stderr, status = Open3.capture3(*args, file.path)
    end
  else
    stdout, stderr, status = Open3.capture3(*args)
  end

  raise PullError, "Apple Ads #{method} #{path} 失败：#{stderr.to_s.strip}" unless status.success?

  parsed = JSON.parse(stdout)
  raise PullError, "Apple Ads #{method} #{path} 返回错误：#{parsed['error']}" if parsed["error"]

  parsed
rescue JSON::ParserError => e
  raise PullError, "Apple Ads #{method} #{path} 返回非 JSON：#{e.message}"
end

def report_payload(start_date, end_date, order_by: "localSpend", limit: 1_000)
  {
    startTime: start_date.iso8601,
    endTime: end_date.iso8601,
    timeZone: "ORTZ",
    returnRecordsWithNoMetrics: false,
    returnRowTotals: true,
    returnGrandTotals: true,
    selector: {
      orderBy: [{field: order_by, sortOrder: "DESCENDING"}],
      pagination: {offset: 0, limit: limit}
    }
  }
end

def reporting_rows(path, start_date, end_date, order_by: "localSpend")
  parsed = searchads_json(
    "POST",
    path,
    report_payload(start_date, end_date, order_by: order_by)
  )
  Array(parsed.dig("data", "reportingDataResponse", "row"))
end

def campaign_metrics(start_date, end_date)
  by_name = CAMPAIGNS.values.to_h { |spec| [spec.fetch(:name), spec] }
  result = CAMPAIGNS.transform_values do |_spec|
    {impressions: 0, taps: 0, installs: 0, spend: 0.0}
  end

  reporting_rows("/api/v5/reports/campaigns", start_date, end_date).each do |row|
    metadata = row["metadata"] || {}
    spec = by_name[metadata["campaignName"]]
    next unless spec

    country = CAMPAIGNS.key(spec)
    total = row["total"] || {}
    result.fetch(country)[:impressions] += integer(total["impressions"])
    result.fetch(country)[:taps] += integer(total["taps"])
    result.fetch(country)[:installs] += integer(
      total["totalInstalls"] || total["tapInstalls"] || total["installs"]
    )
    result.fetch(country)[:spend] += money(total["localSpend"])
  end

  result.each_value { |metrics| metrics[:spend] = metrics[:spend].round(2) }
  result
end

def campaign_statuses
  parsed = searchads_json("GET", "/api/v5/campaigns?limit=1000")
  targets = CAMPAIGNS.values.to_h { |spec| [spec.fetch(:id), spec] }
  Array(parsed["data"]).each_with_object([]) do |campaign, rows|
    spec = targets[campaign["id"].to_i]
    next unless spec

    rows << {
      country: CAMPAIGNS.key(spec),
      status: campaign["status"],
      serving: campaign["servingStatus"],
      budget: money(campaign["dailyBudgetAmount"]),
      modification_time: campaign["modificationTime"],
      end_time: campaign["endTime"]
    }
  end.sort_by { |row| row.fetch(:country) }
end

def normalize_detail_row(row)
  metadata = row["metadata"] || {}
  total = row["total"] || {}
  spend = money(total["localSpend"])
  installs = integer(total["totalInstalls"] || total["tapInstalls"] || total["installs"])
  {
    keyword: metadata["keyword"],
    search_term: metadata["searchTermText"],
    match_type: metadata["matchType"],
    impressions: integer(total["impressions"]),
    taps: integer(total["taps"]),
    installs: installs,
    spend: spend.round(2),
    cpa: installs.positive? ? (spend / installs).round(2) : nil
  }
end

def detail_reports(start_date, end_date)
  result = {}
  CAMPAIGNS.each do |country, spec|
    result[country] = {}
    {keywords: "keywords", search_terms: "searchterms"}.each do |key, endpoint|
      order_by = endpoint == "searchterms" ? "impressions" : "localSpend"
      path = "/api/v5/reports/campaigns/#{spec.fetch(:id)}/#{endpoint}"
      rows = reporting_rows(path, start_date, end_date, order_by: order_by)
        .map { |row| normalize_detail_row(row) }
        .select { |row| row[:spend].positive? || row[:installs].positive? }
        .sort_by { |row| [-row.fetch(:spend), -row.fetch(:installs)] }
      result.fetch(country)[key] = rows.first(10)
    end
  end
  result
end

def print_statuses(statuses)
  puts "\n当前投放状态"
  puts format("%-3s %-9s %-12s %9s %-23s %s", "国", "status", "serving", "日预算", "modificationTime", "endTime")
  statuses.each do |row|
    puts format(
      "%-3s %-9s %-12s %8.2f¥ %-23s %s",
      row.fetch(:country), row.fetch(:status), row.fetch(:serving), row.fetch(:budget),
      row.fetch(:modification_time).to_s, row.fetch(:end_time) || "未设置"
    )
  end
end

def print_window(label, start_date, end_date, metrics)
  puts "\n#{label}  #{start_date} → #{end_date}"
  puts format(
    "%-3s %8s %6s %6s %7s %9s %7s %8s %9s %10s",
    "国", "花费", "展示", "点击", "CPT", "tap→install", "安装", "安装CPA", "所需付费率", "所需试用率"
  )

  CAMPAIGNS.each_key do |country|
    row = metrics.fetch(country)
    cpt = row[:taps].positive? ? row[:spend] / row[:taps] : nil
    tap_to_install = pct(row[:installs], row[:taps])
    cpa = row[:installs].positive? ? row[:spend] / row[:installs] : nil
    required_paid = country == "US" && cpa ? cpa / US_FIRST_YEAR_LTV_RMB : nil
    required_trial = required_paid ? required_paid / TARGET_TRIAL_TO_PAID : nil
    puts format(
      "%-3s %7.2f¥ %6d %6d %6s %8s%s %7d %7s%s %9s %10s",
      country,
      row[:spend],
      row[:impressions],
      row[:taps],
      cpt ? format("¥%.2f", cpt) : "—",
      format_pct(tap_to_install),
      pass_mark(tap_to_install, TARGET_TAP_TO_INSTALL, :higher),
      row[:installs],
      cpa ? format("¥%.2f", cpa) : "—",
      pass_mark(cpa, TARGET_INSTALL_CPA_RMB, :lower),
      format_pct(required_paid),
      format_pct(required_trial)
    )
  end
end

def print_details(details)
  details.each do |country, groups|
    puts "\n#{country} 切点后高花费关键词"
    puts format("%-30s %-7s %6s %5s %5s %8s %8s", "keyword", "match", "展示", "点击", "安装", "花费", "CPA")
    groups.fetch(:keywords).each do |row|
      puts format(
        "%-30s %-7s %6d %5d %5d %7.2f¥ %8s",
        row[:keyword].to_s[0, 30], row[:match_type].to_s, row[:impressions], row[:taps],
        row[:installs], row[:spend], row[:cpa] ? format("¥%.2f", row[:cpa]) : "—"
      )
    end

    puts "#{country} 切点后高花费搜索词"
    puts format("%-30s %-25s %5s %5s %8s %8s", "searchTerm", "sourceKeyword", "点击", "安装", "花费", "CPA")
    groups.fetch(:search_terms).each do |row|
      term = row[:search_term].to_s.empty? ? "(隐藏/Auto)" : row[:search_term]
      puts format(
        "%-30s %-25s %5d %5d %7.2f¥ %8s",
        term.to_s[0, 30], row[:keyword].to_s[0, 25], row[:taps], row[:installs],
        row[:spend], row[:cpa] ? format("¥%.2f", row[:cpa]) : "—"
      )
    end
  end
end

def asc_api_json(path)
  require_relative "app_store_connect_api"
  response = asc_request("GET", path)
  raise PullError, "ASC #{path} → HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end

def download_gzip(url, attempts: 3)
  attempt = 0
  begin
    attempt += 1
    uri = URI(url)
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 90
    response = http.start { |client| client.request(Net::HTTP::Get.new(uri)) }
    raise PullError, "ASC 分片下载 HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    Zlib::GzipReader.new(StringIO.new(response.body)).read
  rescue StandardError
    raise if attempt >= attempts

    sleep(2)
    retry
  end
end

def asc_report_rows(report_name, from_date, to_date)
  requests = asc_api_json("/v1/apps/#{APP_ID}/analyticsReportRequests?limit=20").fetch("data")
  request = requests.find { |row| row.dig("attributes", "accessType") == "ONGOING" } || requests.first
  raise PullError, "ASC 没有可用的 analyticsReportRequest" unless request

  reports = asc_api_json("/v1/analyticsReportRequests/#{request.fetch('id')}/reports?limit=200").fetch("data")
  report = reports.find { |row| row.dig("attributes", "name") == report_name }
  return [] unless report

  processing_from = (from_date - 5).iso8601
  processing_to = (to_date + 5).iso8601
  instances = asc_api_json("/v1/analyticsReports/#{report.fetch('id')}/instances?limit=200").fetch("data")
    .select do |instance|
      date = instance.dig("attributes", "processingDate")
      date && date >= processing_from && date <= processing_to
    end

  instances.flat_map do |instance|
    segments = asc_api_json("/v1/analyticsReportInstances/#{instance.fetch('id')}/segments").fetch("data")
    segments.flat_map do |segment|
      CSV.parse(download_gzip(segment.dig("attributes", "url")), headers: true, col_sep: "\t").map(&:to_h)
    end
  rescue StandardError => e
    warn "ASC #{report_name} #{instance.dig('attributes', 'processingDate')} 失败：#{e.message}"
    []
  end
end

def print_asc_auxiliary(from_date, to_date)
  downloads = asc_report_rows("App Downloads Standard", from_date, to_date)
  subscriptions = asc_report_rows("App Store Subscription Event Report Standard", from_date, to_date)

  first_downloads = Hash.new(0)
  downloads.each do |row|
    date = row["Date"].to_s
    country = row["Territory"].to_s
    next unless CAMPAIGNS.key?(country)
    next unless date >= from_date.iso8601 && date <= to_date.iso8601
    next unless row["Download Type"].to_s.match?(/first[- ]time/i)

    first_downloads[country] += integer(row["Counts"])
  end

  events = CAMPAIGNS.transform_values do |_spec|
    {trial_starts: 0, paid_from_trial: 0, direct_paid: 0, churn_from_trial: 0}
  end
  subscriptions.each do |row|
    date = row["Event Date"].to_s
    country = row["Territory"].to_s
    spec = CAMPAIGNS[country]
    next unless spec
    next unless date >= from_date.iso8601 && date <= to_date.iso8601
    next unless spec.fetch(:product_ids).include?(row["Subscription Identifier"].to_s)

    count = integer(row["Counts"])
    case row["Event Name"].to_s
    when /free trial start/i then events.fetch(country)[:trial_starts] += count
    when /full price from free trial/i then events.fetch(country)[:paid_from_trial] += count
    when /full price subscription start/i then events.fetch(country)[:direct_paid] += count
    when /churn from free trial/i then events.fetch(country)[:churn_from_trial] += count
    end
  end

  puts "\nASC 全渠道辅助对账（非广告 cohort，不得用于计算广告 CAC）"
  puts format("%-3s %9s %9s %14s %9s %11s %s", "国", "首次下载", "试用开始", "试用转正价", "直接付费", "试用期流失", "价格口径")
  CAMPAIGNS.each do |country, spec|
    row = events.fetch(country)
    puts format(
      "%-3s %9d %9d %14d %9d %11d %s",
      country, first_downloads[country], row[:trial_starts], row[:paid_from_trial],
      row[:direct_paid], row[:churn_from_trial], spec.fetch(:price)
    )
  end
  puts "注：同窗的试用开始与转正价来自不同 cohort，不输出伪 trial→paid 比率。"
end

options = {
  from: CUTOVER_DATE,
  to: Date.today - 1,
  full: false,
  details: true
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/growth_loop.rb [options]"
  opts.on("--from DATE", "起始日，不得早于 2026-08-24") { |value| options[:from] = Date.iso8601(value) }
  opts.on("--to DATE", "结束结算日，默认昨天") { |value| options[:to] = Date.iso8601(value) }
  opts.on("--full", "增加 ASC 全渠道首次下载/订阅事件对账") { options[:full] = true }
  opts.on("--no-details", "不拉关键词与搜索词，用于快速健康检查") { options[:details] = false }
  opts.on("-h", "--help", "显示帮助") do
    puts opts
    exit 0
  end
end

begin
  parser.parse!(ARGV)
  raise ArgumentError, "不支持的参数：#{ARGV.join(' ')}" if ARGV.any?
  if options[:to] < CUTOVER_DATE
    puts "关键词路由变更于 #{ROUTING_CHANGE_AT} 完成；2026-08-23 是混合日，不进入本轮判断。"
    puts "首个完整自然日是 #{CUTOVER_DATE}，结算后再拉取当前策略数据。"
    exit 0
  end
  raise ArgumentError, "--from 不得早于 #{CUTOVER_DATE}" if options[:from] < CUTOVER_DATE
  raise ArgumentError, "--to 不得早于 --from" if options[:to] < options[:from]
  raise ArgumentError, "--to 不得晚于昨天，当日 Apple Ads 尚未结算" if options[:to] >= Date.today
rescue OptionParser::ParseError, ArgumentError => e
  warn e.message
  warn parser
  exit 2
end

begin
  puts "US / GB Apple Ads 增长闭环快报"
  puts "切点 #{CUTOVER_DATE} · 报表窗口 #{options[:from]} → #{options[:to]} · 只读"
  puts format(
    "US v2 净 LTV：首年 ¥%.0f；两年 ¥%.0f–%.0f；运营目标 CPT≤¥%.0f / tap→install≥35%% / 安装CPA≤¥%.0f",
    US_FIRST_YEAR_LTV_RMB, US_TWO_YEAR_LTV_LOW_RMB, US_TWO_YEAR_LTV_HIGH_RMB,
    TARGET_CPT_RMB, TARGET_INSTALL_CPA_RMB
  )

  print_statuses(campaign_statuses)

  yesterday = options[:to]
  last_three_start = [options[:from], options[:to] - 2].max
  windows = [
    ["昨日", yesterday, yesterday],
    ["近 3 个结算日", last_three_start, options[:to]],
    ["切点后累计", options[:from], options[:to]]
  ].uniq { |_label, start_date, end_date| [start_date, end_date] }
  windows.each do |label, start_date, end_date|
    print_window(label, start_date, end_date, campaign_metrics(start_date, end_date))
  end

  print_details(detail_reports(options[:from], options[:to])) if options[:details]
  print_asc_auxiliary(options[:from], options[:to]) if options[:full]

  puts "\n闭环硬门：本报告不用全渠道付费冒充广告付费。"
  puts "只有 production attributed 广告设备连到 Apple 正价交易后，才能宣布 CAC < LTV。"
  puts "GB 当前仍是 v1 价格，在 GBR 开放 v2 且核定当地净 LTV 前，不宣布“新价闭环跑通”。"
rescue PullError, JSON::ParserError, KeyError, Errno::ENOENT => e
  warn "增长闭环拉数失败：#{e.message}"
  exit 1
end
