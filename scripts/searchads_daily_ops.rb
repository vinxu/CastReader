#!/usr/bin/env ruby
# frozen_string_literal: true

# CastReader Apple Ads 日常巡检与调词。
#
# 默认只读：
#   ruby scripts/searchads_daily_ops.rb
#
# 指定已结算日期：
#   ruby scripts/searchads_daily_ops.rb --as-of 2026-07-28
#
# 显式执行经过护栏校验的关键词动作：
#   ruby scripts/searchads_daily_ops.rb --apply
#
# 本脚本永远不会创建、启用、暂停、删除或修改广告系列，也不会修改国家/地区或预算。
# `--apply` 仅允许：
#   1. 恢复缺失的竞品否定词；
#   2. 将高转化搜索词添加为精确匹配，并在 Discovery 中做精确否定分流；
#   3. 将明确浪费的 Discovery 搜索词加为精确否定；
#   4. 调整已有关键词出价（单次最大 ±20%）。

require "date"
require "fileutils"
require "json"
require "optparse"
require "set"
require "tempfile"
require "time"
require_relative "searchads_api"

class SearchAdsDailyOps
  PLAN_PATH = File.expand_path("searchads_campaign_plan.json", __dir__)
  DEFAULT_OUTPUT_DIR = File.expand_path("../reports/apple-ads", __dir__)

  ALLOWED_COUNTRIES = Set.new(%w[US JP DE BR IT]).freeze
  COMPETITOR_TERMS = [
    "speechify",
    "natural reader",
    "naturalreader",
    "eleven reader",
    "voice dream reader"
  ].freeze

  BUDGET_CAP_RMB = 200.0
  FLIGHT_DAYS = 14
  FLIGHT_PLAN_CAP_RMB = 2_800.0
  MAX_BID_CHANGE = 0.20
  TARGET_CPA_RMB = 35.0
  MIN_BID_RMB = 0.50
  MAX_BID_RMB = 10.0
  LEARNING_DAYS = 3
  PAGE_SIZE = 1000
  MAX_REPORT_PAGES = 20
  TOP_ROW_LIMIT = 50
  REPORT_RETRIES = 2
  REPORT_WORKERS = [[ENV.fetch("SEARCHADS_REPORT_WORKERS", "4").to_i, 1].max, 6].min

  WINDOWS = {
    "settled_day" => 1,
    "last_3_days" => 3,
    "last_7_days" => 7
  }.freeze

  MUTATION_KINDS = Set.new(%w[
    restore_competitor_negative
    add_waste_negative
    promote_exact_keyword
    route_discovery_exact
    update_keyword_bid
  ]).freeze

  class ApiError < StandardError; end
  class SafetyError < StandardError; end

  def initialize(as_of:, apply:, output_dir:)
    @as_of = as_of
    @apply = apply
    @output_dir = output_dir
    @plan = JSON.parse(File.read(PLAN_PATH))
    @currency = @plan.fetch("currency")
    @errors = []
    @actions = []
    @applied = []
    @resource_cache = {}
    @state_path = File.join(@output_dir, "state.json")
    @launch_dates = load_launch_dates
  end

  def run
    validate_static_plan!
    load_resources!
    guardrails = validate_live_guardrails
    reports = fetch_all_reports
    update_launch_dates!(reports)
    guardrails = validate_live_guardrails
    build_actions(reports)
    validate_actions!

    if @apply
      raise SafetyError, "写入被护栏阻止：#{guardrails.fetch(:violations).join('；')}" if guardrails.fetch(:violations).any?
      raise SafetyError, "写入被报告错误阻止；请先修复 API 报告读取" if @errors.any?

      # 写入前重新读取广告系列，避免巡检和调词之间外部状态发生变化。
      load_campaigns!
      fresh_guardrails = validate_live_guardrails
      if fresh_guardrails.fetch(:violations).any?
        raise SafetyError, "写入前二次校验失败：#{fresh_guardrails.fetch(:violations).join('；')}"
      end

      apply_actions!
      guardrails = fresh_guardrails
    end

    report = build_report(guardrails, reports)
    paths = write_report(report)
    puts File.read(paths.fetch(:markdown))
    warn "JSON: #{paths.fetch(:json)}"
    warn "Markdown: #{paths.fetch(:markdown)}"
    0
  rescue ApiError, SafetyError, JSON::ParserError, KeyError, ArgumentError => e
    warn "Apple Ads 日常运营失败：#{e.message}"
    1
  end

  private

  def api_envelope(method, path, payload = nil)
    response =
      if payload
        Tempfile.create(["searchads-daily-ops", ".json"]) do |file|
          file.write(JSON.generate(payload))
          file.flush
          request(method, path, file.path)
        end
      else
        request(method, path)
      end

    parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
    unless response.is_a?(Net::HTTPSuccess) && parsed["error"].nil?
      raise ApiError, "#{method} #{path} -> HTTP #{response.code}: #{safe_error(parsed)}"
    end
    parsed
  rescue Timeout::Error, EOFError, IOError, SocketError, SystemCallError => e
    raise ApiError, "#{method} #{path} -> #{e.class}: #{e.message}"
  end

  def api_data(method, path, payload = nil)
    api_envelope(method, path, payload)["data"]
  end

  def safe_error(parsed)
    error = parsed["error"] || parsed["errors"] || parsed
    JSON.generate(error)[0, 1_000]
  rescue JSON::GeneratorError
    error.to_s[0, 1_000]
  end

  def validate_static_plan!
    raise SafetyError, "计划 adamId 与 CastReader 不一致" unless @plan.fetch("adamId").to_i == 6_757_636_395
    raise SafetyError, "账号币种必须为 RMB" unless @currency == "RMB"

    campaigns = @plan.fetch("campaigns")
    countries = campaigns.map { |spec| spec.fetch("country") }.to_set
    extra = countries - ALLOWED_COUNTRIES
    raise SafetyError, "计划包含未授权市场：#{extra.to_a.join(', ')}" if extra.any?

    planned_total = campaigns.sum { |spec| money_number(spec.fetch("dailyBudget")) }
    if planned_total > BUDGET_CAP_RMB
      raise SafetyError, format("计划日预算 %.2f RMB 超过 %.2f RMB", planned_total, BUDGET_CAP_RMB)
    end
    configured_cap = money_number(@plan.fetch("totalDailyBudget"))
    unless configured_cap <= BUDGET_CAP_RMB && (configured_cap - planned_total).abs < 0.01
      raise SafetyError, "计划总预算字段与广告系列预算合计不一致"
    end
    planned_flight_cap = planned_total * FLIGHT_DAYS
    if planned_flight_cap > FLIGHT_PLAN_CAP_RMB
      raise SafetyError, format(
        "14 天计划金额 %.2f RMB 超过 %.2f RMB",
        planned_flight_cap,
        FLIGHT_PLAN_CAP_RMB
      )
    end
  end

  def load_resources!
    load_campaigns!
    @adgroups_by_campaign = {}
    @keywords_by_campaign = {}
    @negatives_by_campaign = {}

    managed_campaigns.each do |campaign|
      campaign_id = campaign.fetch("id").to_i
      adgroups = Array(api_data("GET", "/api/v5/campaigns/#{campaign_id}/adgroups?limit=#{PAGE_SIZE}"))
      @adgroups_by_campaign[campaign_id] = adgroups

      keywords = adgroups.flat_map do |adgroup|
        adgroup_id = adgroup.fetch("id").to_i
        Array(
          api_data(
            "GET",
            "/api/v5/campaigns/#{campaign_id}/adgroups/#{adgroup_id}/targetingkeywords?limit=#{PAGE_SIZE}"
          )
        )
      end
      @keywords_by_campaign[campaign_id] = keywords
      @negatives_by_campaign[campaign_id] = Array(
        api_data("GET", "/api/v5/campaigns/#{campaign_id}/negativekeywords?limit=#{PAGE_SIZE}")
      )
    end
  end

  def load_campaigns!
    @campaigns = Array(api_data("GET", "/api/v5/campaigns?limit=#{PAGE_SIZE}"))
    @campaign_by_name = @campaigns.to_h { |campaign| [campaign.fetch("name"), campaign] }
  end

  def managed_campaigns
    names = @plan.fetch("campaigns").map { |spec| spec.fetch("name") }.to_set
    @campaigns.select { |campaign| names.include?(campaign["name"]) && !campaign["deleted"] }
  end

  def castreader_campaigns
    @campaigns.select do |campaign|
      campaign["adamId"].to_i == @plan.fetch("adamId").to_i && !campaign["deleted"]
    end
  end

  def validate_live_guardrails
    violations = []
    planned_names = @plan.fetch("campaigns").map { |spec| spec.fetch("name") }.to_set
    live_names = managed_campaigns.map { |campaign| campaign.fetch("name") }.to_set
    missing = planned_names - live_names
    violations << "缺少计划广告系列：#{missing.to_a.join(', ')}" if missing.any?

    unexpected = castreader_campaigns.reject { |campaign| planned_names.include?(campaign["name"]) }
    if unexpected.any?
      violations << "发现计划外 CastReader 广告系列：#{unexpected.map { |campaign| campaign['name'] }.join(', ')}"
    end

    bad_markets = castreader_campaigns.map do |campaign|
      countries = Array(campaign["countriesOrRegions"]).map(&:upcase)
      invalid = countries.to_set - ALLOWED_COUNTRIES
      next if invalid.empty? && countries.length == 1

      "#{campaign['name']}=#{countries.join('+')}"
    end.compact
    violations << "发现未授权或多国家广告系列：#{bad_markets.join(', ')}" if bad_markets.any?

    bad_currencies = castreader_campaigns.map do |campaign|
      currency = campaign.dig("dailyBudgetAmount", "currency")
      campaign["name"] unless currency == @currency
    end.compact
    violations << "广告系列币种不是 RMB：#{bad_currencies.join(', ')}" if bad_currencies.any?

    configured_budget = castreader_campaigns.sum { |campaign| money_number(campaign["dailyBudgetAmount"]) }
    enabled_budget = castreader_campaigns
      .select { |campaign| campaign["status"] == "ENABLED" }
      .sum { |campaign| money_number(campaign["dailyBudgetAmount"]) }
    if configured_budget > BUDGET_CAP_RMB
      violations << format("CastReader 配置日预算合计 %.2f RMB 超过 %.2f RMB", configured_budget, BUDGET_CAP_RMB)
    end
    if enabled_budget > BUDGET_CAP_RMB
      violations << format("CastReader 已启用日预算合计 %.2f RMB 超过 %.2f RMB", enabled_budget, BUDGET_CAP_RMB)
    end

    campaigns_and_ends = managed_campaigns.map do |campaign|
      [campaign, parse_time(campaign["endTime"])]
    end
    missing_schedule = campaigns_and_ends.select { |_campaign, end_at| end_at.nil? }
    if missing_schedule.any?
      violations << "14 天测试缺少 endTime：#{missing_schedule.map { |item| item[0]['name'] }.join(', ')}"
    end

    complete_schedules = campaigns_and_ends.reject { |_campaign, end_at| end_at.nil? }
    unique_end_times = complete_schedules.map { |_campaign, end_at| end_at.to_i }.uniq
    if unique_end_times.length > 1 && unique_end_times.max - unique_end_times.min > 60
      violations << "各广告系列 endTime 不一致，不能保证同时结束 14 天测试"
    end

    configured_flight_plan = configured_budget * FLIGHT_DAYS
    if configured_flight_plan > FLIGHT_PLAN_CAP_RMB
      violations << format(
        "按日预算估算的 14 天计划金额 %.2f RMB 超过 %.2f RMB",
        configured_flight_plan,
        FLIGHT_PLAN_CAP_RMB
      )
    end

    {
      currency: @currency,
      budgetCap: BUDGET_CAP_RMB,
      flightDays: FLIGHT_DAYS,
      flightPlanCap: FLIGHT_PLAN_CAP_RMB,
      configuredDailyBudget: configured_budget.round(2),
      enabledDailyBudget: enabled_budget.round(2),
      configuredFlightPlan: configured_flight_plan.round(2),
      sharedEndTime: unique_end_times.empty? ? nil : Time.at(unique_end_times.min).utc.iso8601,
      firstServingDates: launch_dates_by_campaign_name,
      budgetBehavior: "Apple 的 dailyBudget 是日均控制值，单日可能超过；统一 14 天 endTime 是测试止损护栏。",
      allowedCountries: ALLOWED_COUNTRIES.to_a.sort,
      managedCampaignCount: managed_campaigns.length,
      violations: violations
    }
  end

  def fetch_all_reports
    windows = WINDOWS.to_h do |label, days|
      start_date = @as_of - (days - 1)
      [label, {
        startDate: start_date.iso8601,
        endDate: @as_of.iso8601,
        campaigns: [],
        adgroups: [],
        keywords: [],
        searchTerms: []
      }]
    end

    tasks = []
    WINDOWS.each do |label, days|
      start_date = @as_of - (days - 1)
      tasks << {
        window: label,
        key: :campaigns,
        scope: "campaigns",
        path: "/api/v5/reports/campaigns",
        startDate: start_date,
        endDate: @as_of,
        orderBy: "localSpend"
      }
      managed_campaigns.each do |campaign|
        campaign_id = campaign.fetch("id").to_i
        {
          adgroups: "adgroups",
          keywords: "keywords",
          searchTerms: "searchterms"
        }.each do |key, endpoint|
          tasks << {
            window: label,
            key: key,
            scope: "#{campaign['name']}/#{endpoint}",
            path: "/api/v5/reports/campaigns/#{campaign_id}/#{endpoint}",
            startDate: start_date,
            endDate: @as_of,
            orderBy: endpoint == "searchterms" ? "impressions" : "localSpend"
          }
        end
      end
    end

    # 资源预取阶段已初始化凭据；这里再次显式预热，确保 worker 不会并发刷新 token。
    access_token
    org_id
    queue = Queue.new
    tasks.each { |task| queue << task }
    worker_count = [REPORT_WORKERS, tasks.length].min
    worker_count.times { queue << nil }
    result_mutex = Mutex.new
    completed = 0
    warn "Apple Ads reports: 0/#{tasks.length} (#{worker_count} workers)"

    workers = worker_count.times.map do
      Thread.new do
        loop do
          task = queue.pop
          break unless task

          rows = []
          error = nil
          begin
            rows = fetch_report_rows_with_retry(
              task.fetch(:path),
              task.fetch(:startDate),
              task.fetch(:endDate),
              order_by: task.fetch(:orderBy)
            )
          rescue ApiError, JSON::ParserError => e
            error = {
              window: task.fetch(:window),
              scope: task.fetch(:scope),
              message: e.message
            }
          rescue StandardError => e
            error = {
              window: task.fetch(:window),
              scope: task.fetch(:scope),
              message: "#{e.class}: #{e.message}"
            }
          end

          result_mutex.synchronize do
            windows.fetch(task.fetch(:window)).fetch(task.fetch(:key)).concat(rows)
            @errors << error if error
            completed += 1
            warn "Apple Ads reports: #{completed}/#{tasks.length}" if (completed % 10).zero? || completed == tasks.length
          end
        end
      end
    end
    workers.each(&:join)

    managed_ids = managed_campaigns.map { |campaign| campaign.fetch("id").to_i }.to_set
    windows.each_value do |window|
      window.each do |key, rows|
        next unless rows.is_a?(Array)

        window[key] = rows
          .map { |row| normalize_report_row(row) }
          .select { |row| row[:campaignId] && managed_ids.include?(row[:campaignId].to_i) }
      end
    end
    windows
  end

  def fetch_report_rows_with_retry(path, start_date, end_date, order_by:)
    attempts = 0

    begin
      attempts += 1
      fetch_report_rows(path, start_date, end_date, order_by: order_by)
    rescue ApiError => e
      raise unless attempts <= REPORT_RETRIES && retryable_report_error?(e)

      sleep(0.5 * attempts)
      retry
    end
  end

  def retryable_report_error?(error)
    message = error.message
    message.include?("Timeout") ||
      message.include?("EOFError") ||
      message.match?(/HTTP (429|500|502|503|504)\b/)
  end

  def fetch_report_rows(path, start_date, end_date, order_by:)
    rows = []
    offset = 0

    MAX_REPORT_PAGES.times do
      payload = {
        startTime: start_date.iso8601,
        endTime: end_date.iso8601,
        timeZone: "ORTZ",
        returnRecordsWithNoMetrics: false,
        returnRowTotals: true,
        returnGrandTotals: true,
        selector: {
          orderBy: [{field: order_by, sortOrder: "DESCENDING"}],
          pagination: {offset: offset, limit: PAGE_SIZE}
        }
      }
      data = api_data("POST", path, payload) || {}
      page = Array(data.dig("reportingDataResponse", "row") || data["row"])
      rows.concat(page)
      break if page.length < PAGE_SIZE

      offset += PAGE_SIZE
    end

    rows
  end

  def normalize_report_row(row)
    metadata = row["metadata"] || {}
    metrics = row["total"] || {}
    spend = money_number(metrics["localSpend"])
    installs = first_number(metrics, %w[totalInstalls tapInstalls installs])
    {
      campaignId: integer_or_nil(metadata["campaignId"]),
      campaignName: metadata["campaignName"],
      country: metadata["countryOrRegion"],
      adGroupId: integer_or_nil(metadata["adGroupId"]),
      adGroupName: metadata["adGroupName"],
      keywordId: integer_or_nil(metadata["keywordId"]),
      keyword: metadata["keyword"],
      searchTerm: metadata["searchTermText"],
      matchType: metadata["matchType"],
      bid: money_number(metadata["bidAmount"]),
      currency: money_currency(metrics["localSpend"]) || money_currency(metadata["bidAmount"]) || @currency,
      impressions: first_number(metrics, %w[impressions]),
      taps: first_number(metrics, %w[taps]),
      installs: installs,
      spend: spend.round(2),
      avgCpt: money_number(metrics["avgCPT"]).round(2),
      cpa: installs.positive? ? (spend / installs).round(2) : nil,
      ttr: first_number(metrics, %w[ttr]).round(4),
      installRate: first_number(metrics, %w[totalInstallRate tapInstallRate conversionRate]).round(4)
    }
  end

  def build_actions(reports)
    build_competitor_negative_actions
    last_7_days = reports.fetch("last_7_days")
    build_search_term_actions(last_7_days.fetch(:searchTerms))
    build_bid_actions(last_7_days.fetch(:keywords))
    deduplicate_actions!
  end

  def update_launch_dates!(reports)
    settled_rows = %i[campaigns adgroups keywords searchTerms].flat_map do |key|
      reports.fetch("settled_day").fetch(key)
    end
    active_campaign_ids = settled_rows.select { |row| report_row_has_activity?(row) }
      .map { |row| row[:campaignId].to_i }
      .select(&:positive?)
      .uniq

    # 若自动任务并非从首日开始运行，但近 7 天已有数据，则以“首次观察到”的
    # 日期保守起算完整 3 天学习期，避免因为创建日期较早而过早调价。
    recent_campaign_ids = %i[campaigns adgroups keywords searchTerms].flat_map do |key|
      reports.fetch("last_7_days").fetch(key)
    end.select { |row| report_row_has_activity?(row) }
      .map { |row| row[:campaignId].to_i }
      .select(&:positive?)
      .uniq
    active_campaign_ids |= recent_campaign_ids

    active_campaign_ids.each do |campaign_id|
      observed = @as_of
      existing = parse_date(@launch_dates[campaign_id.to_s])
      @launch_dates[campaign_id.to_s] = [existing, observed].compact.min.iso8601
    end
  end

  def report_row_has_activity?(row)
    row[:impressions].to_f.positive? ||
      row[:taps].to_f.positive? ||
      row[:installs].to_f.positive? ||
      row[:spend].to_f.positive?
  end

  def build_competitor_negative_actions
    @plan.fetch("campaigns").each do |spec|
      campaign = @campaign_by_name[spec.fetch("name")]
      next unless campaign

      campaign_id = campaign.fetch("id").to_i
      existing = Array(@negatives_by_campaign[campaign_id]).to_h do |item|
        [[normalize_text(item["text"]), item["matchType"].to_s.upcase], true]
      end
      required = spec.fetch("campaignNegatives", []).select { |item| competitor?(item.fetch("text")) }
      required.each do |item|
        key = [normalize_text(item.fetch("text")), item.fetch("matchType").upcase]
        next if existing[key]

        @actions << {
          kind: "restore_competitor_negative",
          campaignId: campaign_id,
          campaignName: campaign.fetch("name"),
          country: Array(campaign["countriesOrRegions"]).first,
          text: item.fetch("text"),
          matchType: item.fetch("matchType").upcase,
          reason: "计划要求的竞品否定词缺失"
        }
      end
    end
  end

  def build_search_term_actions(rows)
    rows.each do |row|
      text = row[:searchTerm].to_s.strip
      next if text.empty? || row[:campaignId].nil?
      next if row[:impressions] < 10 # Apple 不披露低于 10 次展示的具体搜索词。
      next if competitor?(text)

      campaign = campaign_by_id(row[:campaignId])
      spec = plan_spec(campaign&.fetch("name", nil))
      next unless campaign && spec
      next if campaign_in_learning?(campaign)

      installs = row[:installs]
      spend = row[:spend]
      cpa = installs.positive? ? spend / installs : nil

      if installs >= 2 && cpa && cpa <= TARGET_CPA_RMB
        add_promotion_actions(text, row, campaign, spec)
      elsif spec.fetch("searchMatch") && row[:taps] >= 8 && installs.zero? && spend >= 20
        add_negative_action(
          kind: "add_waste_negative",
          campaign: campaign,
          text: text,
          reason: format("7 天 %d taps / %.2f RMB / 0 installs", row[:taps], spend)
        )
      end
    end
  end

  def add_promotion_actions(text, row, source_campaign, source_spec)
    destination_spec =
      if source_spec.fetch("country") == "US"
        @plan.fetch("campaigns").find { |spec| spec.fetch("name") == "CR_US_Search_Exact_2026Q3" }
      else
        source_spec
      end
    return unless destination_spec

    destination_campaign = @campaign_by_name[destination_spec.fetch("name")]
    return unless destination_campaign

    destination_adgroup = Array(@adgroups_by_campaign[destination_campaign.fetch("id").to_i])
      .find { |item| item["name"] == destination_spec.fetch("adGroupName") }
    return unless destination_adgroup

    destination_keywords = Array(@keywords_by_campaign[destination_campaign.fetch("id").to_i])
    already_exact = destination_keywords.any? do |keyword|
      normalize_text(keyword["text"]) == normalize_text(text) && keyword["matchType"].to_s.upcase == "EXACT"
    end

    unless already_exact
      @actions << {
        kind: "promote_exact_keyword",
        campaignId: destination_campaign.fetch("id").to_i,
        campaignName: destination_campaign.fetch("name"),
        country: destination_spec.fetch("country"),
        adGroupId: destination_adgroup.fetch("id").to_i,
        adGroupName: destination_adgroup.fetch("name"),
        text: text,
        matchType: "EXACT",
        bid: money_number(destination_spec.fetch("defaultBid")).round(2),
        reason: format("7 天 %d installs，CPA %.2f RMB", row[:installs], row[:spend] / row[:installs])
      }
    end

    return unless source_spec.fetch("searchMatch")
    # 非美市场把 Search Match 与 Exact 放在同一广告系列；不能在同一层级
    # 给刚晋级的精确词加否定，否则会把它自己屏蔽掉。
    return if source_campaign.fetch("id").to_i == destination_campaign.fetch("id").to_i

    add_negative_action(
      kind: "route_discovery_exact",
      campaign: source_campaign,
      text: text,
      reason: "高转化搜索词已进入 Exact，Discovery 精确否定避免内耗"
    )
  end

  def add_negative_action(kind:, campaign:, text:, reason:)
    campaign_id = campaign.fetch("id").to_i
    exists = Array(@negatives_by_campaign[campaign_id]).any? do |item|
      normalize_text(item["text"]) == normalize_text(text) && item["matchType"].to_s.upcase == "EXACT"
    end
    return if exists

    @actions << {
      kind: kind,
      campaignId: campaign_id,
      campaignName: campaign.fetch("name"),
      country: Array(campaign["countriesOrRegions"]).first,
      text: text,
      matchType: "EXACT",
      reason: reason
    }
  end

  def build_bid_actions(rows)
    rows.each do |row|
      keyword_id = row[:keywordId].to_i
      next unless keyword_id.positive?

      campaign = campaign_by_id(row[:campaignId])
      next unless campaign && !campaign_in_learning?(campaign)

      resource = Array(@keywords_by_campaign[campaign.fetch("id").to_i])
        .find { |keyword| keyword["id"].to_i == keyword_id }
      next unless resource && resource["status"] == "ACTIVE"

      old_bid = money_number(resource["bidAmount"])
      next unless old_bid.positive?

      installs = row[:installs]
      spend = row[:spend]
      cpa = installs.positive? ? spend / installs : nil
      factor = nil
      reason = nil

      if installs >= 2 && cpa <= TARGET_CPA_RMB * 0.8
        factor = 1.15
        reason = format("7 天 %d installs，CPA %.2f RMB 低于目标", installs, cpa)
      elsif installs.positive? && cpa > TARGET_CPA_RMB * 1.3
        factor = 0.85
        reason = format("7 天 CPA %.2f RMB 高于目标", cpa)
      elsif installs.zero? && row[:taps] >= 8 && spend >= 20
        factor = 0.80
        reason = format("7 天 %d taps / %.2f RMB / 0 installs", row[:taps], spend)
      end
      next unless factor

      new_bid = [[old_bid * factor, MIN_BID_RMB].max, MAX_BID_RMB].min.round(2)
      next if (new_bid - old_bid).abs < 0.01

      @actions << {
        kind: "update_keyword_bid",
        campaignId: campaign.fetch("id").to_i,
        campaignName: campaign.fetch("name"),
        country: Array(campaign["countriesOrRegions"]).first,
        adGroupId: resource.fetch("adGroupId").to_i,
        keywordId: keyword_id,
        keyword: resource.fetch("text"),
        matchType: resource.fetch("matchType"),
        oldBid: old_bid.round(2),
        newBid: new_bid,
        changePct: (((new_bid / old_bid) - 1) * 100).round(1),
        reason: reason
      }
    end
  end

  def campaign_in_learning?(campaign)
    launch_date = parse_date(@launch_dates[campaign.fetch("id").to_i.to_s])
    return true unless launch_date

    (@as_of - launch_date).to_i < LEARNING_DAYS
  end

  def deduplicate_actions!
    @actions = @actions.uniq do |action|
      case action.fetch(:kind)
      when "update_keyword_bid"
        [action[:kind], action[:campaignId], action[:adGroupId], action[:keywordId]]
      when "promote_exact_keyword"
        [action[:kind], action[:campaignId], action[:adGroupId], normalize_text(action[:text])]
      else
        [action[:kind], action[:campaignId], normalize_text(action[:text]), action[:matchType]]
      end
    end
  end

  def validate_actions!
    @actions.each do |action|
      raise SafetyError, "未知写入动作 #{action[:kind]}" unless MUTATION_KINDS.include?(action[:kind])
      raise SafetyError, "动作指向未授权市场 #{action[:country]}" unless ALLOWED_COUNTRIES.include?(action[:country])
      raise SafetyError, "动作指向计划外广告系列 #{action[:campaignName]}" unless plan_spec(action[:campaignName])

      next unless action[:kind] == "update_keyword_bid"

      old_bid = action.fetch(:oldBid).to_f
      new_bid = action.fetch(:newBid).to_f
      change = (new_bid - old_bid).abs / old_bid
      if change > MAX_BID_CHANGE + 0.0001
        raise SafetyError, format("关键词 %s 单次调价 %.1f%% 超过 20%%", action[:keyword], change * 100)
      end
      unless new_bid.between?(MIN_BID_RMB, MAX_BID_RMB)
        raise SafetyError, "关键词 #{action[:keyword]} 新出价越界"
      end
    end
  end

  def apply_actions!
    exacts = @actions.select { |action| action[:kind] == "promote_exact_keyword" }
    negatives = @actions.select do |action|
      %w[restore_competitor_negative add_waste_negative route_discovery_exact].include?(action[:kind])
    end
    bids = @actions.select { |action| action[:kind] == "update_keyword_bid" }

    exacts.group_by { |action| [action[:campaignId], action[:adGroupId]] }.each do |(campaign_id, adgroup_id), actions|
      payload = actions.map do |action|
        {
          text: action.fetch(:text),
          matchType: "EXACT",
          bidAmount: {amount: format("%.2f", action.fetch(:bid)), currency: @currency}
        }
      end
      result = api_data(
        "POST",
        "/api/v5/campaigns/#{campaign_id}/adgroups/#{adgroup_id}/targetingkeywords/bulk",
        payload
      )
      assert_bulk_success!(result, "创建 Exact 关键词")
      @applied.concat(actions)
    end

    negatives.group_by { |action| action[:campaignId] }.each do |campaign_id, actions|
      payload = actions.map { |action| {text: action.fetch(:text), matchType: action.fetch(:matchType)} }
      result = api_data("POST", "/api/v5/campaigns/#{campaign_id}/negativekeywords/bulk", payload)
      assert_bulk_success!(result, "创建否定词")
      @applied.concat(actions)
    end

    bids.group_by { |action| [action[:campaignId], action[:adGroupId]] }.each do |(campaign_id, adgroup_id), actions|
      payload = actions.map do |action|
        {
          id: action.fetch(:keywordId),
          bidAmount: {amount: format("%.2f", action.fetch(:newBid)), currency: @currency}
        }
      end
      result = api_data(
        "PUT",
        "/api/v5/campaigns/#{campaign_id}/adgroups/#{adgroup_id}/targetingkeywords/bulk",
        payload
      )
      assert_bulk_success!(result, "更新关键词出价")
      @applied.concat(actions)
    end
  end

  def build_report(guardrails, reports)
    compact_windows = reports.transform_values do |window|
      {
        startDate: window.fetch(:startDate),
        endDate: window.fetch(:endDate),
        campaigns: compact_rows(window.fetch(:campaigns), TOP_ROW_LIMIT),
        adgroups: compact_rows(window.fetch(:adgroups), TOP_ROW_LIMIT),
        keywords: compact_rows(window.fetch(:keywords), TOP_ROW_LIMIT),
        searchTerms: compact_rows(window.fetch(:searchTerms), TOP_ROW_LIMIT)
      }
    end

    {
      generatedAt: Time.now.iso8601,
      mode: @apply ? "apply" : "dry-run",
      settledDate: @as_of.iso8601,
      app: {adamId: @plan.fetch("adamId"), name: "CastReader"},
      guardrails: guardrails,
      thresholds: {
        learningDays: LEARNING_DAYS,
        flightDays: FLIGHT_DAYS,
        flightPlanCapRmb: FLIGHT_PLAN_CAP_RMB,
        targetCpaRmb: TARGET_CPA_RMB,
        maxBidChangePct: (MAX_BID_CHANGE * 100).to_i,
        wasteRule: "7d taps >= 8 AND spend >= 20 RMB AND installs = 0",
        promotionRule: "7d installs >= 2 AND CPA <= 35 RMB"
      },
      launchState: {
        source: "首个出现 impressions/taps/installs/spend 的已结算日期；未捕获首日时从首次观察日起保守计算",
        firstServingDates: guardrails.fetch(:firstServingDates)
      },
      reports: compact_windows,
      recommendedActions: @actions,
      appliedActions: @applied,
      errors: @errors
    }
  end

  def compact_rows(rows, limit)
    sorted = rows.sort_by { |row| [-row.fetch(:spend, 0).to_f, -row.fetch(:installs, 0).to_i] }
    {
      rowCount: rows.length,
      totals: sum_metrics(rows),
      rows: sorted.first(limit)
    }
  end

  def sum_metrics(rows)
    spend = rows.sum { |row| row.fetch(:spend, 0).to_f }
    installs = rows.sum { |row| row.fetch(:installs, 0).to_i }
    {
      impressions: rows.sum { |row| row.fetch(:impressions, 0).to_i },
      taps: rows.sum { |row| row.fetch(:taps, 0).to_i },
      installs: installs,
      spend: spend.round(2),
      cpa: installs.positive? ? (spend / installs).round(2) : nil
    }
  end

  def write_report(report)
    FileUtils.mkdir_p(@output_dir)
    write_state
    base = File.join(@output_dir, @as_of.iso8601)
    json_path = "#{base}.json"
    markdown_path = "#{base}.md"
    File.write(json_path, "#{JSON.pretty_generate(report)}\n")
    File.write(markdown_path, markdown_report(report))
    {json: json_path, markdown: markdown_path}
  end

  def markdown_report(report)
    guardrails = report.fetch(:guardrails)
    seven_day = report.dig(:reports, "last_7_days", :campaigns, :rows) || []
    actions = report.fetch(:recommendedActions)

    lines = []
    lines << "# CastReader Apple Ads 日报 — #{@as_of.iso8601}"
    lines << ""
    lines << "- 模式：#{@apply ? 'APPLY' : 'DRY RUN（未修改线上）'}"
    lines << format(
      "- 日均计划：已配置 %.2f RMB；已启用 %.2f RMB；内部设置上限 %.2f RMB",
      guardrails.fetch(:configuredDailyBudget),
      guardrails.fetch(:enabledDailyBudget),
      guardrails.fetch(:budgetCap)
    )
    lines << format(
      "- 测试周期：%d 天；计划金额 %.2f / %.2f RMB；统一 endTime：%s",
      guardrails.fetch(:flightDays),
      guardrails.fetch(:configuredFlightPlan),
      guardrails.fetch(:flightPlanCap),
      guardrails.fetch(:sharedEndTime) || "未设置"
    )
    lines << "- 预算说明：#{guardrails.fetch(:budgetBehavior)}"
    serving_dates = guardrails.fetch(:firstServingDates)
    lines << "- 首次有效投放：#{serving_dates.empty? ? '尚未观察到已结算流量' : serving_dates.map { |name, date| "#{name}=#{date}" }.join('；')}"
    lines << "- 市场：#{guardrails.fetch(:allowedCountries).join(' / ')}"
    lines << "- 护栏：#{guardrails.fetch(:violations).empty? ? '通过' : guardrails.fetch(:violations).join('；')}"
    lines << "- 报告读取：#{@errors.empty? ? '完整' : "#{@errors.length} 个错误，禁止写入"}"
    lines << ""
    lines << "## 近 7 天广告系列"
    lines << ""
    lines << "| Campaign | Country | Spend | Taps | Installs | CPA |"
    lines << "|---|---:|---:|---:|---:|---:|"
    if seven_day.empty?
      lines << "| 暂无已结算数据 | — | 0 | 0 | 0 | — |"
    else
      seven_day.each do |row|
        lines << format(
          "| %s | %s | %.2f | %d | %d | %s |",
          row[:campaignName] || row[:campaignId],
          row[:country] || "—",
          row[:spend],
          row[:taps],
          row[:installs],
          row[:cpa] ? format("%.2f", row[:cpa]) : "—"
        )
      end
    end
    lines << ""
    lines << "## 调整建议"
    lines << ""
    if actions.empty?
      lines << "暂无满足阈值的调整；继续收集数据。"
    else
      lines << "| 动作 | Campaign | 对象 | 依据 |"
      lines << "|---|---|---|---|"
      actions.each do |action|
        object =
          if action[:kind] == "update_keyword_bid"
            "#{action[:keyword]}: #{action[:oldBid]} → #{action[:newBid]} RMB"
          else
            action[:text]
          end
        lines << "| #{action[:kind]} | #{action[:campaignName]} | #{escape_table(object)} | #{escape_table(action[:reason])} |"
      end
    end
    if @errors.any?
      lines << ""
      lines << "## API 错误"
      lines << ""
      @errors.each { |error| lines << "- #{error[:window]} / #{error[:scope]}：#{error[:message]}" }
    end
    lines << ""
    lines.join("\n")
  end

  def plan_spec(name)
    @plan.fetch("campaigns").find { |spec| spec.fetch("name") == name }
  end

  def campaign_by_id(id)
    @campaigns.find { |campaign| campaign["id"].to_i == id.to_i }
  end

  def normalize_text(text)
    text.to_s.downcase.strip.gsub(/[[:space:]]+/, " ")
  end

  def competitor?(text)
    normalized = normalize_text(text)
    COMPETITOR_TERMS.any? { |term| normalized.include?(normalize_text(term)) }
  end

  def money_number(value)
    raw = value.is_a?(Hash) ? value["amount"] || value[:amount] : value
    Float(raw || 0)
  rescue ArgumentError, TypeError
    0.0
  end

  def money_currency(value)
    value.is_a?(Hash) ? value["currency"] || value[:currency] : nil
  end

  def first_number(hash, keys)
    key = keys.find { |candidate| !hash[candidate].nil? }
    return 0 if key.nil?

    value = hash[key]
    value.is_a?(Integer) ? value : Float(value)
  rescue ArgumentError, TypeError
    0
  end

  def integer_or_nil(value)
    value.nil? ? nil : Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def parse_time(value)
    return nil if value.to_s.empty?

    raw = value.to_s
    raw = "#{raw}Z" unless raw.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/i)
    Time.iso8601(raw).utc
  rescue ArgumentError
    nil
  end

  def parse_date(value)
    return nil if value.to_s.empty?

    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def load_launch_dates
    state = JSON.parse(File.read(@state_path))
    Hash(state["launchDates"]).transform_keys(&:to_s)
  rescue Errno::ENOENT, JSON::ParserError, TypeError
    {}
  end

  def write_state
    state = {
      updatedAt: Time.now.iso8601,
      launchDates: @launch_dates.sort.to_h
    }
    File.write(@state_path, "#{JSON.pretty_generate(state)}\n")
  end

  def launch_dates_by_campaign_name
    managed_campaigns.each_with_object({}) do |campaign, result|
      date = @launch_dates[campaign.fetch("id").to_i.to_s]
      result[campaign.fetch("name")] = date if date
    end
  end

  def assert_bulk_success!(data, label)
    failures = Array(data).select do |item|
      item.is_a?(Hash) && (item["error"] || item["errors"])
    end
    return if failures.empty?

    raise ApiError, "#{label}存在逐项错误：#{safe_error('errors' => failures)}"
  end

  def escape_table(value)
    value.to_s.gsub("|", "\\|").gsub("\n", " ")
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    apply: false,
    as_of: Date.today - 1,
    output_dir: SearchAdsDailyOps::DEFAULT_OUTPUT_DIR
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/searchads_daily_ops.rb [options]"
    opts.on("--apply", "执行护栏允许的关键词/否定词写入；默认仅生成 dry-run 建议") do
      options[:apply] = true
    end
    opts.on("--as-of DATE", "最后一个已结算日期，格式 YYYY-MM-DD；默认昨天") do |value|
      options[:as_of] = Date.iso8601(value)
    end
    opts.on("--output-dir DIR", "JSON/Markdown 输出目录") do |value|
      options[:output_dir] = File.expand_path(value)
    end
    opts.on("-h", "--help", "显示帮助") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError, ArgumentError => e
    warn e.message
    warn parser
    exit 2
  end

  exit SearchAdsDailyOps.new(**options).run
end
