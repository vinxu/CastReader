#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only Apple Search Ads -> growth spend/coverage export for CastReader.
#
# Default behavior only reads Apple Search Ads and writes local dry-run files:
#   ruby scripts/searchads_growth_spend_export.rb --date 2026-08-20
#
# Validate spend payloads against the backend without writing facts:
#   GROWTH_ADMIN_SECRET=... ruby scripts/searchads_growth_spend_export.rb \
#     --date 2026-08-20 --post
#
# Explicitly commit facts and then their coverage attestations:
#   GROWTH_ADMIN_SECRET=... ruby scripts/searchads_growth_spend_export.rb \
#     --date 2026-08-20 --post --commit
#
# This script never creates, edits, enables, pauses, or deletes ads. The only
# Apple write-shaped request is POST /reports/campaigns, which is a read-only
# reporting endpoint.

require "bigdecimal"
require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "optparse"
require "set"
require "tempfile"
require "time"
require "tmpdir"
require "uri"
require_relative "searchads_api"

module SearchAdsGrowthSpend
  EXPECTED_ADAM_ID = 6_757_636_395
  PROVIDER = "apple_ads"
  TARGET_PLATFORM = "ios"
  REPORT_TIME_ZONE = "UTC"
  # Apple campaign performance reports are operational reports, not financial
  # settlement statements. The response has no final/closed attestation we can
  # rely on, so a UTC day must have been fully closed for another 72 hours.
  MIN_COMPLETENESS_LAG_HOURS = 72
  SOURCE_SCHEMA_VERSION = 1
  PAGE_SIZE = 1_000
  MAX_PAGES = 100
  MAX_IMPORT_ROWS = 500
  DEFAULT_PLAN_PATH = File.expand_path("searchads_growth_export_scope.json", __dir__)
  DEFAULT_OUTPUT_DIR = File.expand_path("../reports/apple-ads-growth", __dir__)
  SPEND_PATH = "/api/admin/growth/import/spend"
  COVERAGE_PATH = "/api/admin/growth/import/coverage"

  class ExportError < StandardError; end
  class AppleApiError < ExportError; end
  class BackendApiError < ExportError; end

  module_function

  def canonicalize(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
        original_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
        result[key] = canonicalize(value.fetch(original_key))
      end
    when Array
      value.map { |item| canonicalize(item) }
    else
      value
    end
  end

  def canonical_json(value, pretty: false)
    normalized = canonicalize(value)
    body = pretty ? JSON.pretty_generate(normalized) : JSON.generate(normalized)
    "#{body}\n"
  end

  def sha256(contents)
    Digest::SHA256.hexdigest(contents)
  end

  def latest_complete_report_date(now = Time.now.utc)
    (now.utc - MIN_COMPLETENESS_LAG_HOURS * 3600).to_date - 1
  end

  def safe_error(value)
    JSON.generate(value)[0, 1_000]
  rescue JSON::GeneratorError
    value.to_s[0, 1_000]
  end

  class AppleClient
    def provider_account_id
      value = config["orgId"]
      raise AppleApiError, "~/.searchads/config.json must contain an explicit orgId" if value.nil?
      value
    end

    def get(path)
      parse_response(request("GET", path), "GET #{path}")
    end

    def post(path, payload)
      Tempfile.create(["searchads-growth-report", ".json"]) do |file|
        file.write(JSON.generate(payload))
        file.flush
        return parse_response(request("POST", path, file.path), "POST #{path}")
      end
    end

    private

    def parse_response(response, label)
      parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
      unless response.is_a?(Net::HTTPSuccess) && parsed["error"].nil? && parsed["errors"].nil?
        raise AppleApiError, "#{label} failed (HTTP #{response.code}): #{SearchAdsGrowthSpend.safe_error(parsed['error'] || parsed['errors'] || parsed)}"
      end
      parsed
    rescue JSON::ParserError => e
      raise AppleApiError, "#{label} returned invalid JSON: #{e.message}"
    rescue Timeout::Error, EOFError, IOError, SocketError, SystemCallError => e
      raise AppleApiError, "#{label} failed: #{e.class}: #{e.message}"
    end
  end

  class BackendClient
    def initialize(base_url:, secret:)
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @secret = secret.to_s
      raise BackendApiError, "GROWTH_ADMIN_SECRET is required for --post" if @secret.empty?

      uri = URI(@base_url)
      unless uri.is_a?(URI::HTTP) && uri.host && (uri.scheme == "https" || %w[localhost 127.0.0.1].include?(uri.host))
        raise BackendApiError, "backend base URL must use HTTPS (localhost is allowed for tests)"
      end
    rescue URI::InvalidURIError => e
      raise BackendApiError, "invalid backend base URL: #{e.message}"
    end

    def post(path, payload)
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@secret}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(payload)

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30
      response = http.start { |client| client.request(request) }
      parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
      unless response.is_a?(Net::HTTPSuccess)
        error = parsed["error"] || parsed["code"] || "HTTP #{response.code}"
        raise BackendApiError, "POST #{path} rejected: #{error.to_s[0, 300]}"
      end
      parsed
    rescue JSON::ParserError => e
      raise BackendApiError, "POST #{path} returned invalid JSON: #{e.message}"
    rescue Timeout::Error, EOFError, IOError, SocketError, SystemCallError => e
      raise BackendApiError, "POST #{path} failed: #{e.class}: #{e.message}"
    end
  end

  Artifact = Struct.new(
    :country,
    :source_file_name,
    :source_contents,
    :source_sha256,
    :spend_file_name,
    :spend_payload,
    :coverage_file_name,
    :coverage_payload,
    keyword_init: true
  )

  BuildResult = Struct.new(
    :report_date,
    :source_generated_at,
    :dry_run,
    :artifacts,
    keyword_init: true
  )

  class Exporter
    attr_reader :output_dir

    def initialize(
      report_date:,
      apple_client: AppleClient.new,
      plan_path: DEFAULT_PLAN_PATH,
      output_dir: DEFAULT_OUTPUT_DIR,
      source_generated_at: nil,
      page_size: PAGE_SIZE,
      dry_run: true,
      current_time: Time.now.utc
    )
      @report_date = report_date.is_a?(Date) ? report_date : Date.iso8601(report_date.to_s)
      @apple_client = apple_client
      @plan_path = File.expand_path(plan_path)
      @output_dir = File.expand_path(output_dir)
      @current_time = current_time.utc
      @source_generated_at = (source_generated_at || @current_time).utc
      @page_size = Integer(page_size)
      @dry_run = dry_run
      @plan = JSON.parse(File.read(@plan_path))
    rescue ArgumentError => e
      raise ExportError, "invalid export option: #{e.message}"
    rescue Errno::ENOENT => e
      raise ExportError, "missing plan: #{e.message}"
    rescue JSON::ParserError => e
      raise ExportError, "invalid campaign plan JSON: #{e.message}"
    end

    def build
      validate_date!
      plan_specs = validate_plan!
      provider_account_id = numeric_id(@apple_client.provider_account_id, "orgId")
      campaigns = fetch_campaigns
      campaign_registry = validate_live_campaigns!(campaigns, plan_specs)
      report_rows, report_grand_totals = fetch_campaign_report
      validate_grand_totals!(report_rows, report_grand_totals)
      source_rows = validate_and_normalize_report_rows!(
        report_rows,
        campaign_registry,
        plan_specs,
        provider_account_id
      )
      artifacts = build_artifacts(provider_account_id, source_rows, plan_specs)
      BuildResult.new(
        report_date: @report_date,
        source_generated_at: @source_generated_at,
        dry_run: @dry_run,
        artifacts: artifacts
      )
    end

    def write(result)
      run_stamp = @source_generated_at.strftime("%Y%m%dT%H%M%S.%6NZ")
      final_dir = File.join(@output_dir, @report_date.iso8601, run_stamp)
      raise ExportError, "refusing to overwrite existing export directory #{final_dir}" if File.exist?(final_dir)

      FileUtils.mkdir_p(File.dirname(final_dir))
      staging = Dir.mktmpdir(".apple-ads-growth-", File.dirname(final_dir))
      begin
        result.artifacts.each do |artifact|
          write_file(staging, artifact.source_file_name, artifact.source_contents)
          written_sha = Digest::SHA256.file(File.join(staging, artifact.source_file_name)).hexdigest
          unless written_sha == artifact.source_sha256
            raise ExportError, "source checksum changed while writing #{artifact.country}"
          end
          write_file(staging, artifact.spend_file_name, SearchAdsGrowthSpend.canonical_json(artifact.spend_payload, pretty: true))
          write_file(staging, artifact.coverage_file_name, SearchAdsGrowthSpend.canonical_json(artifact.coverage_payload, pretty: true))
        end
        manifest = build_manifest(result)
        write_file(staging, "manifest.json", SearchAdsGrowthSpend.canonical_json(manifest, pretty: true))
        File.rename(staging, final_dir)
        staging = nil
      ensure
        FileUtils.remove_entry_secure(staging) if staging && File.exist?(staging)
      end
      final_dir
    rescue SystemCallError => e
      raise ExportError, "failed to write export atomically: #{e.message}"
    end

    private

    def validate_date!
      coverage_end = Time.utc(
        (@report_date + 1).year,
        (@report_date + 1).month,
        (@report_date + 1).day
      )
      if @source_generated_at < coverage_end
        raise ExportError, "source_generated_at must be at or after the UTC coverage end"
      end
      completeness_at = coverage_end + MIN_COMPLETENESS_LAG_HOURS * 3600
      if @source_generated_at < completeness_at
        raise ExportError,
              "campaign report is not coverage-eligible until #{completeness_at.iso8601} (#{MIN_COMPLETENESS_LAG_HOURS}h after UTC day end)"
      end
      if @source_generated_at > @current_time + 300
        raise ExportError, "source_generated_at must not be in the future"
      end
      unless @page_size.positive? && @page_size <= PAGE_SIZE
        raise ExportError, "page size must be between 1 and #{PAGE_SIZE}"
      end
    end

    def validate_plan!
      unless integer_value(@plan["adamId"], "plan adamId") == EXPECTED_ADAM_ID
        raise ExportError, "campaign plan adamId is not CastReader"
      end
      unless @plan["currency"] == "RMB"
        raise ExportError, "Apple account plan currency must be RMB"
      end
      raw_specs = @plan["campaigns"]
      unless raw_specs.is_a?(Array) && !raw_specs.empty?
        raise ExportError, "campaign plan must contain campaigns"
      end

      names = Set.new
      raw_specs.each_with_object({}) do |raw, specs|
        raise ExportError, "campaign plan row must be an object" unless raw.is_a?(Hash)

        name = required_string(raw["name"], "campaign name")
        country = required_string(raw["country"], "campaign country").upcase
        raise ExportError, "invalid campaign country #{country}" unless country.match?(/\A[A-Z]{2}\z/)
        raise ExportError, "duplicate campaign plan name #{name}" unless names.add?(name)

        campaign_id = numeric_id(raw["id"], "planned campaign id")
        if specs.values.any? { |spec| spec.fetch("id") == campaign_id }
          raise ExportError, "duplicate planned campaign id #{campaign_id}"
        end
        specs[name] = {"id" => campaign_id, "name" => name, "country" => country}
      end
    end

    def fetch_campaigns
      rows = []
      offset = 0
      total_results = nil
      MAX_PAGES.times do
        path = "/api/v5/campaigns?#{URI.encode_www_form(limit: @page_size, offset: offset)}"
        envelope = checked_envelope(@apple_client.get(path), "GET /api/v5/campaigns")
        page = envelope["data"]
        raise AppleApiError, "campaign list data must be an array" unless page.is_a?(Array)

        pagination = pagination_from(envelope, nil, "campaign list")
        total_results = validate_pagination!(pagination, offset, page.length, total_results, "campaign list")
        rows.concat(page)
        offset += page.length
        break if offset == total_results
      end
      if total_results.nil? || rows.length != total_results
        raise AppleApiError, "campaign list pagination did not complete"
      end
      rows
    end

    def fetch_campaign_report
      rows = []
      offset = 0
      total_results = nil
      grand_totals = nil
      completed = false

      MAX_PAGES.times do
        payload = {
          "startTime" => @report_date.iso8601,
          "endTime" => @report_date.iso8601,
          "timeZone" => REPORT_TIME_ZONE,
          "granularity" => "DAILY",
          "returnRecordsWithNoMetrics" => true,
          "returnRowTotals" => true,
          "returnGrandTotals" => true,
          "selector" => {
            "orderBy" => [{"field" => "localSpend", "sortOrder" => "DESCENDING"}],
            "pagination" => {"offset" => offset, "limit" => @page_size}
          }
        }
        envelope = checked_envelope(
          @apple_client.post("/api/v5/reports/campaigns", payload),
          "POST /api/v5/reports/campaigns"
        )
        data = envelope["data"]
        raise AppleApiError, "campaign report data must be an object" unless data.is_a?(Hash)
        response = data["reportingDataResponse"]
        raise AppleApiError, "campaign report is missing reportingDataResponse" unless response.is_a?(Hash)
        page = response["row"]
        raise AppleApiError, "campaign report row must be an array" unless page.is_a?(Array)

        page_grand_totals = response["grandTotals"]
        raise AppleApiError, "campaign report is missing grandTotals" unless page_grand_totals.is_a?(Hash)
        if grand_totals && SearchAdsGrowthSpend.canonical_json(grand_totals) != SearchAdsGrowthSpend.canonical_json(page_grand_totals)
          raise AppleApiError, "campaign report grandTotals changed between pages"
        end
        grand_totals ||= page_grand_totals

        pagination = pagination_from(envelope, data, "campaign report")
        total_results = validate_pagination!(pagination, offset, page.length, total_results, "campaign report")
        rows.concat(page)
        offset += page.length
        if offset == total_results
          completed = true
          break
        end
      end
      unless completed && rows.length == total_results
        raise AppleApiError, "campaign report pagination did not complete"
      end
      [rows, grand_totals]
    end

    def checked_envelope(value, label)
      raise AppleApiError, "#{label} response must be an object" unless value.is_a?(Hash)
      error = value["error"] || value["errors"]
      raise AppleApiError, "#{label} failed: #{SearchAdsGrowthSpend.safe_error(error)}" if error
      raise AppleApiError, "#{label} response is missing data" unless value.key?("data")

      value
    end

    def pagination_from(envelope, data, label)
      pagination = envelope["pagination"]
      pagination = data["pagination"] if !pagination.is_a?(Hash) && data.is_a?(Hash)
      raise AppleApiError, "#{label} is missing pagination" unless pagination.is_a?(Hash)

      pagination
    end

    def validate_pagination!(pagination, expected_offset, page_length, previous_total, label)
      total = nonnegative_integer(pagination["totalResults"], "#{label} totalResults")
      start = nonnegative_integer(pagination["startIndex"], "#{label} startIndex")
      items = nonnegative_integer(pagination["itemsPerPage"], "#{label} itemsPerPage")
      raise AppleApiError, "#{label} startIndex #{start} != requested #{expected_offset}" unless start == expected_offset
      raise AppleApiError, "#{label} itemsPerPage exceeds requested page size" if items > @page_size
      raise AppleApiError, "#{label} totalResults changed between pages" if previous_total && previous_total != total
      expected_length = [@page_size, total - expected_offset].min
      expected_length = 0 if expected_length.negative?
      unless page_length == expected_length
        raise AppleApiError, "#{label} page at #{expected_offset} returned #{page_length}/#{expected_length} rows"
      end
      total
    rescue ExportError => e
      raise AppleApiError, e.message
    end

    def validate_live_campaigns!(campaigns, plan_specs)
      registry = {}
      campaigns.each do |campaign|
        raise ExportError, "campaign list row must be an object" unless campaign.is_a?(Hash)
        id = numeric_id(campaign["id"], "campaign id")
        raise ExportError, "duplicate campaign id #{id}" if registry.key?(id)
        registry[id] = campaign
      end

      live_castreader = registry.values.select do |campaign|
        campaign_adam_id(campaign) == EXPECTED_ADAM_ID && campaign["deleted"] != true
      end
      live_by_name = {}
      live_castreader.each do |campaign|
        name = required_string(campaign["name"], "live campaign name")
        raise ExportError, "duplicate live CastReader campaign name #{name}" if live_by_name.key?(name)
        live_by_name[name] = campaign
      end

      missing = plan_specs.keys - live_by_name.keys
      raise ExportError, "planned CastReader campaign(s) missing: #{missing.sort.join(', ')}" unless missing.empty?

      plan_specs.each do |name, spec|
        campaign = live_by_name.fetch(name)
        live_id = numeric_id(campaign["id"], "campaign #{name} id")
        unless live_id == spec.fetch("id")
          raise ExportError, "campaign #{name} id changed: #{live_id} != #{spec.fetch('id')}"
        end
        countries = Array(campaign["countriesOrRegions"]).map { |value| value.to_s.upcase }
        unless countries == [spec.fetch("country")]
          raise ExportError, "campaign #{name} must target exactly #{spec.fetch('country')}, got #{countries.join('+')}"
        end
        currency = campaign.dig("dailyBudgetAmount", "currency")
        normalize_cny_currency(currency, "campaign #{name} budget currency")
      end
      registry
    end

    def validate_grand_totals!(rows, grand_totals)
      grand_metrics = grand_totals["total"] || grand_totals
      raise AppleApiError, "campaign report grandTotals.total must be an object" unless grand_metrics.is_a?(Hash)
      totals = rows.reduce({spend_amount: BigDecimal("0"), impressions: 0, taps: 0, installs: 0}) do |sum, row|
        metrics = report_metrics(row)
        sum[:spend_amount] += money_amount(metrics["localSpend"], "campaign report localSpend").fetch(:amount)
        sum[:impressions] += nonnegative_integer(metrics["impressions"], "campaign report impressions")
        sum[:taps] += nonnegative_integer(metrics["taps"], "campaign report taps")
        sum[:installs] += nonnegative_integer(metrics["totalInstalls"], "campaign report totalInstalls")
        sum
      end
      expected = {
        spend_amount: money_amount(grand_metrics["localSpend"], "campaign report grandTotals.localSpend").fetch(:amount),
        impressions: nonnegative_integer(grand_metrics["impressions"], "campaign report grandTotals.impressions"),
        taps: nonnegative_integer(grand_metrics["taps"], "campaign report grandTotals.taps"),
        installs: nonnegative_integer(grand_metrics["totalInstalls"], "campaign report grandTotals.totalInstalls")
      }
      unless totals == expected
        raise AppleApiError, "campaign report rows do not reconcile to grandTotals"
      end
    end

    def validate_and_normalize_report_rows!(rows, registry, plan_specs, provider_account_id)
      plan_by_id = {}
      plan_specs.each do |name, spec|
        campaign = registry.values.find do |candidate|
          candidate["deleted"] != true &&
            campaign_adam_id(candidate) == EXPECTED_ADAM_ID &&
            candidate["name"] == name
        end
        plan_by_id[numeric_id(campaign.fetch("id"), "campaign id")] = spec
      end

      seen_report_ids = Set.new
      source_rows = []
      rows.each do |row|
        raise ExportError, "campaign report row must be an object" unless row.is_a?(Hash)
        metadata = row["metadata"]
        raise ExportError, "campaign report metadata must be an object" unless metadata.is_a?(Hash)
        campaign_id = numeric_id(metadata["campaignId"], "report campaignId")
        unless seen_report_ids.add?(campaign_id)
          raise ExportError, "duplicate campaign report dimension for campaignId #{campaign_id}"
        end
        campaign = registry[campaign_id]
        raise ExportError, "report references campaign #{campaign_id} absent from complete campaign list" unless campaign

        reported_adam = optional_campaign_adam_id(metadata)
        raise ExportError, "report is missing adamId for campaign #{campaign_id}" unless reported_adam
        if reported_adam != campaign_adam_id(campaign)
          raise ExportError, "report adamId mismatch for campaign #{campaign_id}"
        end
        reported_org_id = numeric_id(metadata["orgId"], "report orgId")
        unless reported_org_id == provider_account_id
          raise ExportError, "report orgId mismatch for campaign #{campaign_id}"
        end
        reported_name = required_string(metadata["campaignName"], "report campaignName")
        if reported_name != campaign["name"]
          raise ExportError, "report campaignName mismatch for campaign #{campaign_id}"
        end

        next unless campaign_adam_id(campaign) == EXPECTED_ADAM_ID
        next unless plan_by_id.key?(campaign_id)
        raise ExportError, "planned campaign #{campaign_id} is deleted" if campaign["deleted"] == true
        spec = plan_by_id.fetch(campaign_id)
        reported_countries = Array(metadata["countriesOrRegions"]).map { |value| value.to_s.upcase }
        unless reported_countries == [spec.fetch("country")]
          raise ExportError, "report campaign #{campaign_id} must contain exactly country #{spec.fetch('country')}"
        end
        reported_country = metadata["countryOrRegion"]
        if reported_country && reported_country.to_s.upcase != spec.fetch("country")
          raise ExportError, "report country mismatch for campaign #{campaign_id}"
        end
        metrics = report_metrics(row)
        money = money_amount(metrics["localSpend"], "campaign #{campaign_id} localSpend")
        impressions = nonnegative_integer(metrics["impressions"], "campaign #{campaign_id} impressions")
        taps = nonnegative_integer(metrics["taps"], "campaign #{campaign_id} taps")
        installs = nonnegative_integer(metrics["totalInstalls"], "campaign #{campaign_id} totalInstalls")
        raise ExportError, "campaign #{campaign_id} taps exceed impressions" if taps > impressions

        source_rows << {
          "adam_id" => EXPECTED_ADAM_ID.to_s,
          "campaign_id" => campaign_id,
          "campaign_name" => campaign.fetch("name"),
          "marketing_country" => spec.fetch("country"),
          "source_currency" => money.fetch(:source_currency),
          "local_spend" => format_decimal(money.fetch(:amount)),
          "impressions" => impressions,
          "taps" => taps,
          "apple_total_installs" => installs
        }
      end

      expected_ids = plan_by_id.keys.sort
      observed_ids = source_rows.map { |row| row.fetch("campaign_id") }.sort
      unless observed_ids == expected_ids
        missing = expected_ids - observed_ids
        raise ExportError, "complete report omitted planned campaignId(s): #{missing.join(', ')}"
      end
      source_rows.sort_by { |row| [row.fetch("marketing_country"), row.fetch("campaign_id").to_i] }
    end

    def build_artifacts(provider_account_id, source_rows, plan_specs)
      countries = plan_specs.values.map { |spec| spec.fetch("country") }.uniq.sort
      countries.map do |country|
        scoped_rows = source_rows.select { |row| row.fetch("marketing_country") == country }
        if scoped_rows.empty? || scoped_rows.length > MAX_IMPORT_ROWS
          raise ExportError, "#{country} source row count must be 1-#{MAX_IMPORT_ROWS}"
        end
        campaign_ids = scoped_rows.map { |row| row.fetch("campaign_id").to_s }.uniq
        unless campaign_ids.length == 1
          raise ExportError, "#{country} coverage must contain exactly one planned campaign"
        end
        campaign_id = campaign_ids.first
        source = {
          "schema_version" => SOURCE_SCHEMA_VERSION,
          "provider" => PROVIDER,
          "provider_account_id" => provider_account_id,
          "adam_id" => EXPECTED_ADAM_ID.to_s,
          "report_request" => {
            "endpoint" => "/api/v5/reports/campaigns",
            "start_time" => @report_date.iso8601,
            "end_time_inclusive" => @report_date.iso8601,
            "time_zone" => REPORT_TIME_ZONE,
            "granularity" => "DAILY",
            "return_records_with_no_metrics" => true,
            "return_row_totals" => true,
            "return_grand_totals" => true
          },
          "completeness_policy" => {
            "source_kind" => "operational_campaign_report_not_financial_settlement",
            "provider_final_flag" => "not_available",
            "minimum_lag_after_utc_day_end_hours" => MIN_COMPLETENESS_LAG_HOURS
          },
          "scope" => {
            "target_platform" => TARGET_PLATFORM,
            "marketing_country" => country,
            "campaign_id" => campaign_id,
            "account_currency" => "RMB",
            "normalized_currency" => "CNY"
          },
          "normalization" => {
            "currency_minor_exponent" => 2,
            "cny_fx_rate_micros" => 1_000_000,
            "sub_fen_rounding" => "half_up_per_campaign_row"
          },
          "rows" => scoped_rows.sort_by { |row| row.fetch("campaign_id").to_i }
        }
        source_contents = SearchAdsGrowthSpend.canonical_json(source, pretty: true)
        source_sha256 = SearchAdsGrowthSpend.sha256(source_contents)
        spend_rows = scoped_rows.sort_by { |row| row.fetch("campaign_id").to_i }.map do |row|
          spend_minor = decimal_amount_to_minor(row.fetch("local_spend"), "source local_spend")
          {
            "provider" => PROVIDER,
            "provider_account_id" => provider_account_id,
            "spend_date" => @report_date.iso8601,
            "target_platform" => TARGET_PLATFORM,
            "marketing_country" => country,
            "campaign_id" => row.fetch("campaign_id"),
            "ad_group_id" => nil,
            "creative_id" => nil,
            "keyword_id" => nil,
            "currency" => "CNY",
            "currency_minor_exponent" => 2,
            "spend_minor" => spend_minor,
            "spend_cny_fen" => spend_minor,
            "fx_rate_date" => @report_date.iso8601,
            "fx_rate_micros" => 1_000_000,
            "fx_source" => "provider_report",
            "impressions" => row.fetch("impressions"),
            "clicks" => row.fetch("taps"),
            "installs" => row.fetch("apple_total_installs")
          }
        end
        spend_payload = {
          "dry_run" => @dry_run,
          "source_file_sha256" => source_sha256,
          "rows" => spend_rows
        }
        coverage_payload = {
          "dry_run" => @dry_run,
          "dataset" => "ad_spend",
          "provider" => PROVIDER,
          "target_platform" => TARGET_PLATFORM,
          "marketing_country" => country,
          "campaign_id" => campaign_id,
          "environment" => "production",
          "coverage_start" => "#{@report_date.iso8601}T00:00:00.000Z",
          "coverage_end" => "#{(@report_date + 1).iso8601}T00:00:00.000Z",
          "source_file_sha256" => source_sha256,
          "source_generated_at" => @source_generated_at.iso8601(3),
          "fact_row_count" => spend_rows.length,
          "amount_cny_fen" => spend_rows.sum { |row| row.fetch("spend_cny_fen") },
          "attestation" => "complete_authoritative_export"
        }
        prefix = "apple-ads-#{@report_date.iso8601}-#{country.downcase}-#{campaign_id}"
        Artifact.new(
          country: country,
          source_file_name: "#{prefix}.source.json",
          source_contents: source_contents,
          source_sha256: source_sha256,
          spend_file_name: "#{prefix}.spend.json",
          spend_payload: spend_payload,
          coverage_file_name: "#{prefix}.coverage.json",
          coverage_payload: coverage_payload
        )
      end
    end

    def build_manifest(result)
      {
        "schema_version" => 1,
        "provider" => PROVIDER,
        "report_date" => result.report_date.iso8601,
        "source_generated_at" => result.source_generated_at.iso8601(3),
        "dry_run" => result.dry_run,
        "coverage_semantics" => "UTC [coverage_start, coverage_end)",
        "completeness_policy" => {
          "source_kind" => "operational_campaign_report_not_financial_settlement",
          "provider_final_flag" => "not_available",
          "minimum_lag_after_utc_day_end_hours" => MIN_COMPLETENESS_LAG_HOURS
        },
        "normalization" => {
          "currency_minor_exponent" => 2,
          "cny_fx_rate_micros" => 1_000_000,
          "sub_fen_rounding" => "half_up_per_campaign_row"
        },
        "artifacts" => result.artifacts.map do |artifact|
          {
            "marketing_country" => artifact.country,
            "source_file" => artifact.source_file_name,
            "source_file_sha256" => artifact.source_sha256,
            "spend_file" => artifact.spend_file_name,
            "coverage_file" => artifact.coverage_file_name,
            "fact_row_count" => artifact.coverage_payload.fetch("fact_row_count"),
            "amount_cny_fen" => artifact.coverage_payload.fetch("amount_cny_fen")
          }
        end
      }
    end

    def write_file(directory, name, contents)
      path = File.join(directory, name)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(contents)
        file.flush
        file.fsync
      end
    end

    def report_metrics(row)
      raise ExportError, "campaign report row must be an object" unless row.is_a?(Hash)
      metrics = row["total"]
      raise ExportError, "campaign report row is missing total metrics" unless metrics.is_a?(Hash)
      metrics
    end

    def campaign_adam_id(campaign)
      value = campaign["adamId"] || campaign.dig("app", "adamId")
      integer_value(value, "campaign adamId")
    end

    def optional_campaign_adam_id(metadata)
      value = metadata["adamId"] || metadata.dig("app", "adamId")
      return nil if value.nil?
      integer_value(value, "report adamId")
    end

    def money_amount(value, label)
      raise ExportError, "#{label} must be an object" unless value.is_a?(Hash)
      currency = normalize_cny_currency(value["currency"], "#{label}.currency")
      amount = decimal_amount(value["amount"], "#{label}.amount")
      {amount: amount, source_currency: currency}
    end

    def normalize_cny_currency(value, label)
      currency = required_string(value, label).upcase
      unless %w[RMB CNY].include?(currency)
        raise ExportError, "#{label} must be RMB/CNY, got #{currency}"
      end
      currency
    end

    def decimal_amount_to_minor(value, label)
      decimal = decimal_amount(value, label)
      scaled = decimal * 100
      integer = scaled.round(0, BigDecimal::ROUND_HALF_UP).to_i
      raise ExportError, "#{label} exceeds supported range" if integer > 2_147_483_647
      integer
    end

    def decimal_amount(value, label)
      decimal = BigDecimal(value.to_s)
      raise ExportError, "#{label} must be nonnegative" if decimal.negative?
      decimal
    rescue ArgumentError
      raise ExportError, "#{label} is not a decimal amount"
    end

    def format_decimal(value)
      text = value.to_s("F")
      text = text.sub(/(\.\d*?)0+\z/, "\\1").sub(/\.\z/, "")
      text.empty? ? "0" : text
    end

    def numeric_id(value, label)
      integer = integer_value(value, label)
      raise ExportError, "#{label} must be positive" unless integer.positive?
      text = integer.to_s
      raise ExportError, "#{label} is too long" if text.length > 32
      text
    end

    def integer_value(value, label)
      case value
      when Integer
        value
      when String
        raise ExportError, "#{label} must be numeric" unless value.match?(/\A\d+\z/)
        Integer(value, 10)
      else
        if value.is_a?(Numeric) && value.finite? && value.to_i == value
          value.to_i
        else
          raise ExportError, "#{label} must be an integer"
        end
      end
    end

    def nonnegative_integer(value, label)
      integer = integer_value(value, label)
      raise ExportError, "#{label} must be nonnegative" if integer.negative?
      raise ExportError, "#{label} exceeds supported range" if integer > 2_147_483_647
      integer
    end

    def required_string(value, label)
      text = value.to_s
      raise ExportError, "#{label} is required" if text.empty?
      text
    end
  end

  def submit_artifacts(result, backend_client:, commit:)
    # Spend is submitted for every scope before the first coverage request. A
    # spend/API failure therefore cannot create a completeness attestation.
    result.artifacts.each do |artifact|
      backend_client.post(SPEND_PATH, artifact.spend_payload)
    end
    return {spend: result.artifacts.length, coverage: 0} unless commit

    result.artifacts.each do |artifact|
      backend_client.post(COVERAGE_PATH, artifact.coverage_payload)
    end
    {spend: result.artifacts.length, coverage: result.artifacts.length}
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    report_date: SearchAdsGrowthSpend.latest_complete_report_date,
    output_dir: SearchAdsGrowthSpend::DEFAULT_OUTPUT_DIR,
    plan_path: SearchAdsGrowthSpend::DEFAULT_PLAN_PATH,
    post: false,
    commit: false,
    backend_base_url: "https://castreader.ai"
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/searchads_growth_spend_export.rb [options]"
    opts.on("--date YYYY-MM-DD", "完整 UTC 单日且日终后已满 72h；默认最新可覆盖日期") do |value|
      options[:report_date] = Date.iso8601(value)
    end
    opts.on("--output-dir DIR", "本地审计文件根目录") do |value|
      options[:output_dir] = File.expand_path(value)
    end
    opts.on("--plan PATH", "CastReader Apple Ads read-only export scope") do |value|
      options[:plan_path] = File.expand_path(value)
    end
    opts.on("--post", "用 GROWTH_ADMIN_SECRET POST；默认仅 spend dry-run，不写事实") do
      options[:post] = true
    end
    opts.on("--commit", "与 --post 同用：先提交全部 spend，再提交 coverage") do
      options[:commit] = true
    end
    opts.on("--backend-base-url URL", "growth backend；默认 https://castreader.ai") do |value|
      options[:backend_base_url] = value
    end
    opts.on("-h", "--help", "显示帮助") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!(ARGV)
    raise SearchAdsGrowthSpend::ExportError, "--commit requires --post" if options[:commit] && !options[:post]

    exporter = SearchAdsGrowthSpend::Exporter.new(
      report_date: options[:report_date],
      output_dir: options[:output_dir],
      plan_path: options[:plan_path],
      dry_run: !options[:commit]
    )
    result = exporter.build

    if options[:post]
      backend = SearchAdsGrowthSpend::BackendClient.new(
        base_url: options[:backend_base_url],
        secret: ENV.fetch("GROWTH_ADMIN_SECRET", "")
      )
      submitted = SearchAdsGrowthSpend.submit_artifacts(
        result,
        backend_client: backend,
        commit: options[:commit]
      )
      warn "Backend accepted #{submitted.fetch(:spend)} spend payload(s) and #{submitted.fetch(:coverage)} coverage payload(s)."
      unless options[:commit]
        warn "Coverage was not POSTed: spend dry-run does not persist facts for coverage reconciliation."
      end
    end

    run_dir = exporter.write(result)
    puts "Apple Ads growth export complete: #{run_dir}"
    result.artifacts.each do |artifact|
      puts format(
        "%s rows=%d amount=¥%.2f source_sha256=%s",
        artifact.country,
        artifact.coverage_payload.fetch("fact_row_count"),
        artifact.coverage_payload.fetch("amount_cny_fen") / 100.0,
        artifact.source_sha256
      )
    end
    puts(options[:commit] ? "Mode: COMMITTED" : "Mode: DRY RUN (no growth facts written)")
    exit 0
  rescue OptionParser::ParseError, ArgumentError, SearchAdsGrowthSpend::ExportError => e
    warn "Apple Ads growth export failed closed: #{e.message}"
    exit 1
  end
end
