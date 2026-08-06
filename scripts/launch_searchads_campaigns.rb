#!/usr/bin/env ruby
# frozen_string_literal: true

# Guarded CastReader Apple Ads launch.
#
# Dry-run readiness check:
#   ruby scripts/launch_searchads_campaigns.rb
#
# Launch after every gate passes:
#   ruby scripts/launch_searchads_campaigns.rb --apply
#
# This script can only set a shared endTime and toggle the six planned ad groups
# and campaigns. It never changes budgets, bids, keywords, countries, billing,
# or App Store Connect state.

require "json"
require "open3"
require "optparse"
require "rubygems"
require "set"
require "tempfile"
require "time"
require_relative "searchads_api"

class SearchAdsLaunch
  PLAN_PATH = File.expand_path("searchads_campaign_plan.json", __dir__)
  ASC_SCRIPT = File.expand_path("app_store_connect_api.rb", __dir__)
  APP_ID = 6_757_636_395
  MINIMUM_LIVE_VERSION = Gem::Version.new("1.2.14")
  ALLOWED_COUNTRIES = Set.new(%w[US JP DE BR IT]).freeze
  DAILY_BUDGET_CAP_RMB = 200.0
  FLIGHT_SECONDS = 14 * 86_400
  END_TIME_WRITE_BUFFER_SECONDS = 5 * 60
  EXPECTED_SUPPLY_SOURCE = ["APPSTORE_SEARCH_RESULTS"].freeze
  EXPECTED_BID_STRATEGY = "MANUAL_CPT"

  EXPECTED_PAUSE_REASONS = Set.new(%w[
    PAUSED_BY_USER
    NO_AVAILABLE_AD_GROUPS
  ]).freeze
  BR_LANGUAGE_REASONS = Set.new(%w[
    NO_ELIGIBLE_COUNTRIES
  ]).freeze
  HARD_BLOCK_REASONS = Set.new(%w[
    APP_NOT_CATEGORIZED
    APP_NOT_ELIGIBLE
    APP_NOT_ELIGIBLE_SEARCHADS
    APP_NOT_ELIGIBLE_SUPPLY_SOURCE
    APP_NOT_LINKED_TO_CAMPAIGN_GROUP
    APP_NOT_PUBLISHED_YET
    APP_SENSITIVE_CONTENT
    CONTENT_PROVIDER_UNLINKED
    CREDIT_CARD_DECLINED
    INELIGIBLE_BUSINESS_LOCATION
    MISSING_BO_OR_INVOICING_FIELDS
    NO_PAYMENT_METHOD_ON_FILE
    ORG_CHARGE_BACK_DISPUTED
    ORG_PAYMENT_TYPE_CHANGED
    ORG_SUSPENDED_FRAUD
    ORG_SUSPENDED_POLICY_VIOLATION
    PAUSED_BY_SYSTEM
    TAX_VERIFICATION_PENDING
    USER_REQUESTED_ACCOUNT_SUSPENSION
  ]).freeze

  class GateError < StandardError; end
  class ApiError < StandardError; end

  def initialize(apply:, allow_current_live_version:, enable_ineligible_br:)
    @apply = apply
    @allow_current_live_version = allow_current_live_version
    @enable_ineligible_br = enable_ineligible_br
    @plan = JSON.parse(File.read(PLAN_PATH))
    @changed_campaign_ids = []
    @changed_adgroups = []
  end

  def run
    validate_plan!
    live_version = fetch_live_version!
    campaigns, adgroups = load_and_validate_resources!
    eligible, skipped = eligible_campaigns(campaigns)
    shared_end_time = choose_end_time(campaigns)

    print_summary(live_version, campaigns, eligible, skipped, shared_end_time)
    return 0 unless @apply

    raise GateError, "没有可启用的广告系列" if eligible.empty?

    # Re-read immediately before the first write to close the validation race.
    campaigns, adgroups = load_and_validate_resources!
    eligible, skipped = eligible_campaigns(campaigns)
    shared_end_time = choose_end_time(campaigns)

    begin
      set_shared_end_time!(campaigns, shared_end_time)
      enable_adgroups!(eligible, adgroups)

      refreshed = campaigns_by_name
      eligible.each do |spec|
        campaign = refreshed.fetch(spec.fetch("name"))
        allow_br_language = @enable_ineligible_br && spec.fetch("country") == "BR"
        blockers = campaign_blockers(campaign, allow_br_language: allow_br_language)
        next if blockers.empty?

        raise GateError, "#{campaign.fetch('name')} 启用广告组后仍有阻塞：#{blockers.join(', ')}"
      end

      enable_campaigns!(eligible, refreshed)
      verify_post_state!(eligible, skipped, shared_end_time)
    rescue StandardError => e
      rollback!
      raise e
    end

    puts "Launch complete. Common endTime: #{shared_end_time}"
    puts "Enabled daily budget: ¥#{format('%.2f', eligible.sum { |spec| money(spec.fetch('dailyBudget')) })}"
    puts "Skipped: #{skipped.map { |item| item.fetch(:name) }.join(', ')}" if skipped.any?
    0
  rescue GateError, ApiError, JSON::ParserError, KeyError, ArgumentError => e
    warn "Launch blocked: #{e.message}"
    2
  end

  private

  def validate_plan!
    raise GateError, "计划 App ID 不匹配" unless @plan.fetch("adamId").to_i == APP_ID
    raise GateError, "Apple Ads 账号币种必须是 RMB" unless @plan.fetch("currency") == "RMB"

    specs = @plan.fetch("campaigns")
    names = specs.map { |spec| spec.fetch("name") }
    raise GateError, "计划广告系列名称重复" unless names.uniq.length == names.length

    countries = specs.map { |spec| spec.fetch("country") }.to_set
    extra = countries - ALLOWED_COUNTRIES
    raise GateError, "计划包含未授权市场：#{extra.to_a.join(', ')}" if extra.any?

    total = specs.sum { |spec| money(spec.fetch("dailyBudget")) }
    raise GateError, "计划日预算 #{total} 超过 ¥#{DAILY_BUDGET_CAP_RMB}" if total > DAILY_BUDGET_CAP_RMB
    configured = money(@plan.fetch("totalDailyBudget"))
    raise GateError, "计划总预算字段与系列合计不一致" unless (configured - total).abs < 0.01
  end

  def fetch_live_version!
    path = "/v1/apps/#{APP_ID}/appStoreVersions?filter%5Bplatform%5D=IOS&limit=50"
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, ASC_SCRIPT, "GET", path)
    raise ApiError, "App Store Connect 版本读取失败：#{stderr.strip}" unless status.success?

    versions = JSON.parse(stdout).fetch("data")
    live = versions.select do |item|
      attributes = item.fetch("attributes")
      attributes["appStoreState"] == "READY_FOR_SALE" ||
        attributes["appVersionState"] == "READY_FOR_DISTRIBUTION"
    end.max_by { |item| Gem::Version.new(item.dig("attributes", "versionString")) }

    raise GateError, "App Store 暂无线上 iOS 版本" unless live

    version = Gem::Version.new(live.dig("attributes", "versionString"))
    if version < MINIMUM_LIVE_VERSION && !@allow_current_live_version
      pending = versions.find { |item| item.dig("attributes", "versionString") == MINIMUM_LIVE_VERSION.to_s }
      pending_state = pending&.dig("attributes", "appVersionState") || pending&.dig("attributes", "appStoreState")
      detail = pending_state ? "；1.2.14 当前为 #{pending_state}" : ""
      raise GateError, "线上仍是 #{version}，必须等 1.2.14 或更高版本上线#{detail}"
    end

    if version < MINIMUM_LIVE_VERSION
      warn "Version gate explicitly overridden: launching against live #{version}"
    end

    live
  rescue Errno::ENOENT => e
    raise ApiError, e.message
  end

  def api_json(method, path, payload = nil)
    attempts = 0
    begin
      attempts += 1
      response =
        if payload
          Tempfile.create(["searchads-launch", ".json"]) do |file|
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
      parsed["data"]
    rescue Timeout::Error, EOFError, IOError, SocketError, SystemCallError => e
      if method == "GET" && attempts <= 3
        sleep(0.5 * attempts)
        retry
      end
      raise ApiError, "#{method} #{path} -> #{e.class}: #{e.message}"
    end
  end

  def safe_error(parsed)
    JSON.generate(parsed["error"] || parsed["errors"] || parsed)[0, 1_000]
  rescue JSON::GeneratorError
    parsed.to_s[0, 1_000]
  end

  def campaigns_by_name
    records = Array(api_json("GET", "/api/v5/campaigns?limit=1000"))
    records.reject { |item| item["deleted"] }.to_h { |item| [item.fetch("name"), item] }
  end

  def load_and_validate_resources!
    all = Array(api_json("GET", "/api/v5/campaigns?limit=1000")).reject { |item| item["deleted"] }
    planned_names = @plan.fetch("campaigns").map { |spec| spec.fetch("name") }.to_set
    castreader = all.select { |item| item["adamId"].to_i == APP_ID }
    unexpected = castreader.reject { |item| planned_names.include?(item["name"]) }
    raise GateError, "发现计划外 CastReader 广告系列：#{unexpected.map { |item| item['name'] }.join(', ')}" if unexpected.any?

    by_name = castreader.to_h { |item| [item.fetch("name"), item] }
    missing = planned_names - by_name.keys.to_set
    raise GateError, "缺少计划广告系列：#{missing.to_a.join(', ')}" if missing.any?

    adgroups = {}
    @plan.fetch("campaigns").each do |spec|
      campaign = by_name.fetch(spec.fetch("name"))
      validate_campaign!(campaign, spec)

      campaign_id = campaign.fetch("id").to_i
      groups = Array(api_json("GET", "/api/v5/campaigns/#{campaign_id}/adgroups?limit=1000"))
        .reject { |item| item["deleted"] }
      expected = groups.find { |item| item["name"] == spec.fetch("adGroupName") }
      raise GateError, "#{spec.fetch('name')} 缺少广告组 #{spec.fetch('adGroupName')}" unless expected

      extras = groups.reject { |item| item["id"].to_i == expected["id"].to_i }
      raise GateError, "#{spec.fetch('name')} 存在计划外广告组" if extras.any?

      adgroups[spec.fetch("name")] = expected
    end

    [by_name, adgroups]
  end

  def validate_campaign!(campaign, spec)
    raise GateError, "#{campaign['name']} App ID 不匹配" unless campaign["adamId"].to_i == APP_ID

    countries = Array(campaign["countriesOrRegions"]).map(&:upcase)
    expected_country = spec.fetch("country")
    unless countries == [expected_country] && ALLOWED_COUNTRIES.include?(expected_country)
      raise GateError, "#{campaign['name']} 市场不匹配：#{countries.join('+')}"
    end

    amount = money(campaign["dailyBudgetAmount"])
    expected_amount = money(spec.fetch("dailyBudget"))
    currency = campaign.dig("dailyBudgetAmount", "currency")
    unless (amount - expected_amount).abs < 0.01 && currency == "RMB"
      raise GateError, "#{campaign['name']} 预算/币种不匹配"
    end
    unless Array(campaign["supplySources"]) == EXPECTED_SUPPLY_SOURCE
      raise GateError, "#{campaign['name']} 不是搜索结果广告"
    end
    unless campaign["biddingStrategy"] == EXPECTED_BID_STRATEGY
      raise GateError, "#{campaign['name']} 不是 Manual CPT"
    end
    unless %w[PAUSED ENABLED].include?(campaign["status"])
      raise GateError, "#{campaign['name']} 状态不可启动：#{campaign['status']}"
    end
  end

  def eligible_campaigns(campaigns)
    eligible = []
    skipped = []

    @plan.fetch("campaigns").each do |spec|
      campaign = campaigns.fetch(spec.fetch("name"))
      country = spec.fetch("country")
      country_reasons = Array(campaign.dig("countryOrRegionServingStateReasons", country))
      if country == "BR" && country_reasons == ["APP_LANGUAGE_INCOMPATIBLE"]
        blockers = campaign_blockers(campaign, allow_br_language: true)
        raise GateError, "#{campaign['name']} 还有其他阻塞：#{blockers.join(', ')}" if blockers.any?

        if @enable_ineligible_br
          warn "#{campaign['name']} will be enabled on hold: APP_LANGUAGE_INCOMPATIBLE"
          eligible << spec
        else
          skipped << {name: campaign.fetch("name"), reason: "APP_LANGUAGE_INCOMPATIBLE"}
        end
        next
      end
      raise GateError, "#{campaign['name']} 地区阻塞：#{country_reasons.join(', ')}" if country_reasons.any?

      blockers = campaign_blockers(campaign, allow_br_language: false)
      raise GateError, "#{campaign['name']} 有阻塞：#{blockers.join(', ')}" if blockers.any?

      eligible << spec
    end

    [eligible, skipped]
  end

  def campaign_blockers(campaign, allow_br_language:)
    reasons = Array(campaign["servingStateReasons"]).to_set
    allowed = EXPECTED_PAUSE_REASONS.dup
    allowed.merge(BR_LANGUAGE_REASONS) if allow_br_language
    blockers = reasons - allowed
    hard = reasons & HARD_BLOCK_REASONS
    (blockers | hard).to_a.sort
  end

  def choose_end_time(campaigns)
    existing = campaigns.values.map { |campaign| campaign["endTime"] }.compact
    enabled = campaigns.values.any? { |campaign| campaign["status"] == "ENABLED" }

    if enabled
      raise GateError, "已启用广告系列但缺少共同 endTime" if existing.length != campaigns.length
      parsed = existing.map { |value| parse_apple_utc_time(value) }
      if parsed.max.to_i - parsed.min.to_i > 60
        raise GateError, "已启用广告系列的 endTime 不一致"
      end
      raise GateError, "本轮 endTime 已过期" if parsed.min <= Time.now.utc

      return parsed.min.iso8601(3)
    end

    # The shared timestamp is calculated before several sequential API writes.
    # Keep a small buffer so the effective observation window remains at least
    # 14 days even when Apple normalizes response timestamps by a few seconds.
    (Time.now.utc + FLIGHT_SECONDS + END_TIME_WRITE_BUFFER_SECONDS).iso8601(3)
  rescue ArgumentError => e
    raise GateError, "endTime 无法解析：#{e.message}"
  end

  def print_summary(live_version, campaigns, eligible, skipped, end_time)
    live = live_version.fetch("attributes")
    puts "Mode: #{@apply ? 'APPLY' : 'DRY RUN'}"
    puts "Live App Store version: #{live.fetch('versionString')} (#{live['appVersionState'] || live['appStoreState']})"
    puts "Planned daily budget: ¥#{format('%.2f', @plan.fetch('campaigns').sum { |spec| money(spec.fetch('dailyBudget')) })}"
    puts "Common endTime: #{end_time}"
    puts "Eligible: #{eligible.map { |spec| spec.fetch('name') }.join(', ')}"
    puts "Skipped: #{skipped.map { |item| "#{item.fetch(:name)} (#{item.fetch(:reason)})" }.join(', ')}" if skipped.any?
    campaigns.each_value do |campaign|
      puts "  #{campaign['name']}: #{campaign['status']} / #{campaign['servingStatus']}"
    end
  end

  def set_shared_end_time!(campaigns, end_time)
    campaigns.each_value do |campaign|
      next if same_time?(campaign["endTime"], end_time)

      updated = api_json(
        "PUT",
        "/api/v5/campaigns/#{campaign.fetch('id')}",
        {campaign: {endTime: end_time}}
      )
      unless same_time?(updated["endTime"], end_time)
        raise ApiError, "#{campaign['name']} endTime 回读不一致"
      end
    end
  end

  def enable_adgroups!(eligible, adgroups)
    eligible.each do |spec|
      group = adgroups.fetch(spec.fetch("name"))
      next if group["status"] == "ENABLED"

      campaign_id = group.fetch("campaignId").to_i
      group_id = group.fetch("id").to_i
      updated = api_json(
        "PUT",
        "/api/v5/campaigns/#{campaign_id}/adgroups/#{group_id}",
        {status: "ENABLED"}
      )
      raise ApiError, "#{group['name']} 未能启用" unless updated["status"] == "ENABLED"

      @changed_adgroups << [campaign_id, group_id]
    end
  end

  def enable_campaigns!(eligible, campaigns)
    eligible.each do |spec|
      campaign = campaigns.fetch(spec.fetch("name"))
      next if campaign["status"] == "ENABLED"

      updated = api_json(
        "PUT",
        "/api/v5/campaigns/#{campaign.fetch('id')}",
        {campaign: {status: "ENABLED"}}
      )
      raise ApiError, "#{campaign['name']} 未能启用" unless updated["status"] == "ENABLED"

      @changed_campaign_ids << campaign.fetch("id").to_i
    end
  end

  def verify_post_state!(eligible, skipped, end_time)
    campaigns, adgroups = load_and_validate_resources!
    eligible.each do |spec|
      campaign = campaigns.fetch(spec.fetch("name"))
      group = adgroups.fetch(spec.fetch("name"))
      raise ApiError, "#{campaign['name']} 最终状态不是 ENABLED" unless campaign["status"] == "ENABLED"
      raise ApiError, "#{group['name']} 最终状态不是 ENABLED" unless group["status"] == "ENABLED"
      raise ApiError, "#{campaign['name']} 最终 endTime 不一致" unless same_time?(campaign["endTime"], end_time)
    end
    skipped.each do |item|
      campaign = campaigns.fetch(item.fetch(:name))
      raise ApiError, "#{campaign['name']} 应保持 PAUSED" unless campaign["status"] == "PAUSED"
    end
  end

  def rollback!
    @changed_campaign_ids.reverse_each do |campaign_id|
      api_json(
        "PUT",
        "/api/v5/campaigns/#{campaign_id}",
        {campaign: {status: "PAUSED"}}
      )
    rescue StandardError => e
      warn "Rollback warning: campaign #{campaign_id}: #{e.message}"
    end
    @changed_adgroups.reverse_each do |campaign_id, group_id|
      api_json(
        "PUT",
        "/api/v5/campaigns/#{campaign_id}/adgroups/#{group_id}",
        {status: "PAUSED"}
      )
    rescue StandardError => e
      warn "Rollback warning: ad group #{group_id}: #{e.message}"
    end
  end

  def same_time?(left, right)
    return false if left.to_s.empty? || right.to_s.empty?

    (parse_apple_utc_time(left).to_i - parse_apple_utc_time(right).to_i).abs <= 60
  rescue ArgumentError
    false
  end

  def parse_apple_utc_time(value)
    raw = value.to_s
    raw = "#{raw}Z" unless raw.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/i)
    Time.iso8601(raw).utc
  end

  def money(value)
    raw = value.is_a?(Hash) ? value["amount"] || value[:amount] : value
    Float(raw)
  rescue ArgumentError, TypeError
    0.0
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    apply: false,
    allow_current_live_version: false,
    enable_ineligible_br: false
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/launch_searchads_campaigns.rb [options]"
    opts.on("--apply", "通过全部护栏后设置 14 天 endTime 并启用合格市场") { options[:apply] = true }
    opts.on(
      "--allow-current-live-version",
      "明确忽略最低 1.2.14 版本门槛；仅在用户直接授权后使用"
    ) { options[:allow_current_live_version] = true }
    opts.on(
      "--enable-ineligible-br",
      "仅有 APP_LANGUAGE_INCOMPATIBLE 时仍启用 BR，等待 Apple 自动恢复"
    ) { options[:enable_ineligible_br] = true }
    opts.on("-h", "--help", "显示帮助") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => e
    warn e.message
    warn parser
    exit 2
  end

  exit SearchAdsLaunch.new(**options).run
end
