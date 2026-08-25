# encoding: utf-8
#
# 拉 App Store Connect Analytics 的订阅事件报表，回答 install→trial→paid 两段漏斗。
#
#   ruby scripts/asc_subscription_funnel.rb [起始日期] [结束日期]
#   默认 2026-08-06 起（ASA 投放开始日）到今天。
#
# 为什么必须走这里：trial→paid 发生在试用期结束（7 天后），用户当时多半没打开 App，
# 客户端埋点采不到；只有 Apple 的订阅事件报表有这一段。
# 注意：本报表按国家/产品维度，**不含 ASA campaign 维度**——
# 按投放渠道归因要靠自研埋点的 ad_attribution + purchase_result。
require_relative "app_store_connect_api"
require "json"
require "zlib"
require "stringio"
require "net/http"
require "csv"

APP_ID = 6757636395

def api_json(path)
  res = asc_request("GET", path)
  raise "#{path} → #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

def download_gz(url, tries: 3)
  attempt = 0
  begin
    attempt += 1
    download_gz_once(url)
  rescue StandardError => e
    raise if attempt >= tries
    sleep 2
    retry
  end
end

def download_gz_once(url)
  uri = URI(url)
  http = Net::HTTP.new(uri.hostname, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 60
  res = http.start { |c| c.request(Net::HTTP::Get.new(uri)) }
  raise "下载失败 #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  Zlib::GzipReader.new(StringIO.new(res.body)).read
end

from = ARGV[0] || "2026-08-06"
to   = ARGV[1] || Time.now.strftime("%Y-%m-%d")

# 找 ONGOING 的报表请求（持续生成，覆盖最全）
reqs = api_json("/v1/apps/#{APP_ID}/analyticsReportRequests?limit=20")["data"]
req = reqs.find { |r| r.dig("attributes", "accessType") == "ONGOING" } || reqs.first
abort "没有可用的 analyticsReportRequests" unless req

reports = api_json("/v1/analyticsReportRequests/#{req['id']}/reports?limit=200")["data"]
target = reports.find { |r| r.dig("attributes", "name") == "App Store Subscription Event Report Standard" }
abort "找不到订阅事件报表" unless target

instances = api_json("/v1/analyticsReports/#{target['id']}/instances?limit=200")["data"]
    .select { |i| d = i.dig("attributes", "processingDate"); d && d >= from && d <= to }
    .sort_by { |i| i.dig("attributes", "processingDate") }

puts "报表：#{target.dig('attributes', 'name')}"
puts "区间：#{from} → #{to}（#{instances.size} 个日实例）\n\n"

rows = []
instances.each do |inst|
  date = inst.dig("attributes", "processingDate")
  segs = api_json("/v1/analyticsReportInstances/#{inst['id']}/segments")["data"]
  segs.each do |s|
    csv = download_gz(s.dig("attributes", "url"))
    CSV.parse(csv, headers: true, col_sep: "\t").each { |r| rows << r.to_h.merge("_date" => date) }
  end
rescue StandardError => e
  warn "  #{date} 拉取失败：#{e.message}"
end

if rows.empty?
  puts "区间内没有任何订阅事件——说明这段时间一个试用/订阅都没有产生。"
  exit 0
end

puts "字段：#{rows.first.keys.reject { |k| k.start_with?('_') }.join(' | ')}\n\n"

def col(row, *names)
  names.each { |n| return row[n] if row.key?(n) && !row[n].to_s.empty? }
  nil
end

by_event = Hash.new(0)
by_country = Hash.new(0)
by_source = Hash.new(0)
by_offer = Hash.new(0)
rows.each do |r|
  ev = col(r, "Event Name") || "?"
  qty = (col(r, "Counts") || 1).to_i
  by_event[ev] += qty
  by_country["#{ev}|#{col(r, 'Territory') || '?'}"] += qty
  by_source["#{ev}|#{col(r, 'App Download Source Type') || '(未记录)'}"] += qty
  by_offer[col(r, "Offer Type") || "(无优惠)"] += qty if ev =~ /subscribe|start/i
end

puts "═══ 事件汇总 ═══"
by_event.sort_by { |_, v| -v }.each { |e, v| puts format("  %-46s %5d", e, v) }

puts "\n═══ 按国家 ═══"
by_country.sort_by { |_, v| -v }.first(14).each do |k, v|
  ev, ctry = k.split("|")
  puts format("  %-5s %-42s %4d", ctry, ev[0, 42], v)
end

puts "\n═══ 按下载来源（判断是否 ASA 带来）═══"
by_source.sort_by { |_, v| -v }.first(12).each do |k, v|
  ev, src = k.split("|")
  puts format("  %-26s %-32s %4d", src[0, 26], ev[0, 32], v)
end

puts "\n═══ 优惠类型（区分试用 vs 直接付费）═══"
by_offer.sort_by { |_, v| -v }.each { |k, v| puts format("  %-30s %4d", k, v) }

# Apple 的事件命名：试用开始 = "Free trial start activation"，
# 转付费 = "Full price from free trial"，试用期流失 = "Voluntary churn from free trial"。
starts   = by_event.select { |k, _| k =~ /free trial start/i }.values.sum
converts = by_event.select { |k, _| k =~ /full price from free trial/i }.values.sum
churn_t  = by_event.select { |k, _| k =~ /churn from free trial/i }.values.sum
churn_p  = by_event.select { |k, _| k =~ /churn from full price/i }.values.sum
puts "\n═══ 漏斗后两段 ═══"
puts "  试用开始 #{starts} · 转付费 #{converts} · 试用期流失 #{churn_t} · 付费后流失 #{churn_p}"
if starts > 0
  puts format("  trial→paid  = %.1f%%   (目标 30%%  %s)", converts * 100.0 / starts,
              converts * 100.0 / starts >= 30 ? "✅ 达标" : "❌")
  puts format("  试用期流失率 = %.1f%%", churn_t * 100.0 / starts)
end

# 按国家算 trial→paid，找出哪个市场真正在赚钱
puts "\n═══ 各国 trial→paid ═══"
ctry_start = Hash.new(0)
ctry_conv = Hash.new(0)
by_country.each do |k, v|
  ev, c = k.split("|")
  ctry_start[c] += v if ev =~ /free trial start/i
  ctry_conv[c] += v if ev =~ /full price from free trial/i
end
ctry_start.sort_by { |_, v| -v }.first(10).each do |c, st|
  cv = ctry_conv[c]
  rate = st > 0 ? cv * 100.0 / st : 0
  puts format("  %-5s 试用 %3d → 付费 %2d = %5.1f%% %s", c, st, cv, rate, rate >= 30 ? "✅" : "")
end
