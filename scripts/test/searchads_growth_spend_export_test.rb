#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "uri"
require_relative "../searchads_growth_spend_export"

class SearchAdsGrowthSpendExportTest < Minitest::Test
  FIXTURE_PATH = File.expand_path(
    "fixtures/searchads_growth_spend/happy_path.json",
    __dir__
  )
  REPORT_DATE = Date.iso8601("2026-08-20")
  GENERATED_AT = Time.iso8601("2026-08-24T12:34:56.123Z")

  class FakeAppleClient
    attr_reader :posts

    def initialize(fixture, report_error_at: nil, declared_report_total: nil)
      @fixture = fixture
      @report_error_at = report_error_at
      @declared_report_total = declared_report_total
      @posts = []
    end

    def provider_account_id
      @fixture.fetch("org_id")
    end

    def get(path)
      uri = URI("https://fixture.invalid#{path}")
      params = URI.decode_www_form(uri.query.to_s).to_h
      page(@fixture.fetch("campaigns"), params.fetch("offset").to_i, params.fetch("limit").to_i)
    end

    def post(path, payload)
      raise "unexpected endpoint #{path}" unless path == "/api/v5/reports/campaigns"
      @posts << Marshal.load(Marshal.dump(payload))
      offset = payload.dig("selector", "pagination", "offset")
      limit = payload.dig("selector", "pagination", "limit")
      return {"error" => {"message" => "fixture API failure"}} if offset == @report_error_at

      rows = @fixture.fetch("report_rows")
      total = @declared_report_total || rows.length
      response = page(rows, offset, limit, total: total)
      response["data"] = {
        "reportingDataResponse" => {
          "row" => response.fetch("data"),
          "grandTotals" => {"other" => false, "total" => grand_totals(rows)}
        }
      }
      response
    end

    private

    def page(rows, offset, limit, total: rows.length)
      {
        "data" => rows.slice(offset, limit) || [],
        "pagination" => {
          "totalResults" => total,
          "startIndex" => offset,
          "itemsPerPage" => [limit, [total - offset, 0].max].min
        }
      }
    end

    def grand_totals(rows)
      amount = rows.reduce(BigDecimal("0")) do |sum, row|
        sum + BigDecimal(row.dig("total", "localSpend", "amount"))
      end
      {
        "localSpend" => {
          "amount" => amount.to_s("F"),
          "currency" => "RMB"
        },
        "impressions" => rows.sum { |row| row.dig("total", "impressions") },
        "taps" => rows.sum { |row| row.dig("total", "taps") },
        "totalInstalls" => rows.sum { |row| row.dig("total", "totalInstalls") }
      }
    end
  end

  class FakeBackend
    attr_reader :calls

    def initialize(fail_spend_at: nil)
      @fail_spend_at = fail_spend_at
      @calls = []
      @spend_calls = 0
    end

    def post(path, payload)
      @spend_calls += 1 if path == SearchAdsGrowthSpend::SPEND_PATH
      if path == SearchAdsGrowthSpend::SPEND_PATH && @spend_calls == @fail_spend_at
        raise SearchAdsGrowthSpend::BackendApiError, "fixture backend failure"
      end
      @calls << [path, payload]
      {"ok" => true}
    end
  end

  def setup
    @fixture = JSON.parse(File.read(FIXTURE_PATH))
    @tmpdir = Dir.mktmpdir("searchads-growth-test")
    @plan_path = File.join(@tmpdir, "plan.json")
    File.write(@plan_path, JSON.pretty_generate(@fixture.fetch("plan")))
  end

  def teardown
    FileUtils.remove_entry_secure(@tmpdir) if File.exist?(@tmpdir)
  end

  def exporter(fixture: @fixture, client: nil, page_size: 2, **options)
    SearchAdsGrowthSpend::Exporter.new(
      report_date: REPORT_DATE,
      source_generated_at: GENERATED_AT,
      current_time: GENERATED_AT,
      apple_client: client || FakeAppleClient.new(fixture),
      plan_path: @plan_path,
      output_dir: File.join(@tmpdir, "output"),
      page_size: page_size,
      **options
    )
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def test_complete_paginated_export_builds_reproducible_country_scopes
    client = FakeAppleClient.new(@fixture)
    pipeline = exporter(client: client)
    result = pipeline.build

    assert_equal %w[GB US], result.artifacts.map(&:country)
    assert_operator client.posts.length, :>, 1
    client.posts.each do |payload|
      assert_equal "UTC", payload.fetch("timeZone")
      assert_equal REPORT_DATE.iso8601, payload.fetch("startTime")
      assert_equal REPORT_DATE.iso8601, payload.fetch("endTime")
      assert_equal true, payload.fetch("returnRecordsWithNoMetrics")
    end

    us = result.artifacts.find { |artifact| artifact.country == "US" }
    assert_equal 1, us.spend_payload.fetch("rows").length
    assert_equal 2345, us.coverage_payload.fetch("amount_cny_fen")
    assert_equal 1, us.coverage_payload.fetch("fact_row_count")
    assert_equal "2144343127", us.coverage_payload.fetch("campaign_id")
    assert_equal "2026-08-20T00:00:00.000Z", us.coverage_payload.fetch("coverage_start")
    assert_equal "2026-08-21T00:00:00.000Z", us.coverage_payload.fetch("coverage_end")
    assert_equal "complete_authoritative_export", us.coverage_payload.fetch("attestation")

    us.spend_payload.fetch("rows").each do |row|
      assert_equal "apple_ads", row.fetch("provider")
      assert_equal "987654321", row.fetch("provider_account_id")
      assert_match(/\A\d+\z/, row.fetch("campaign_id"))
      assert_equal "CNY", row.fetch("currency")
      assert_equal 2, row.fetch("currency_minor_exponent")
      assert_equal row.fetch("spend_minor"), row.fetch("spend_cny_fen")
      assert_equal 1_000_000, row.fetch("fx_rate_micros")
      assert_equal 5, row.fetch("installs")
    end
    assert_equal [234], us.spend_payload.fetch("rows").map { |row| row.fetch("clicks") }
    us_source = JSON.parse(us.source_contents)
    assert_equal 5, us_source.fetch("rows").sum { |row| row.fetch("apple_total_installs") }

    gb = result.artifacts.find { |artifact| artifact.country == "GB" }
    assert_equal 1, gb.coverage_payload.fetch("fact_row_count")
    assert_equal 1112, gb.coverage_payload.fetch("amount_cny_fen")
    assert_equal 3, gb.spend_payload.fetch("rows").first.fetch("installs")
    assert_equal "2144503591", gb.coverage_payload.fetch("campaign_id")

    run_dir = pipeline.write(result)
    result.artifacts.each do |artifact|
      source_path = File.join(run_dir, artifact.source_file_name)
      assert_equal artifact.source_sha256, Digest::SHA256.file(source_path).hexdigest
      assert_equal artifact.source_sha256, artifact.spend_payload.fetch("source_file_sha256")
      assert_equal artifact.source_sha256, artifact.coverage_payload.fetch("source_file_sha256")
    end
    manifest = JSON.parse(File.read(File.join(run_dir, "manifest.json")))
    assert_equal 72, manifest.dig("completeness_policy", "minimum_lag_after_utc_day_end_hours")
    assert_equal "operational_campaign_report_not_financial_settlement",
                 manifest.dig("completeness_policy", "source_kind")
    assert_equal "half_up_per_campaign_row",
                 manifest.dig("normalization", "sub_fen_rounding")
  end

  def test_source_hash_is_stable_across_api_row_and_page_order
    first = exporter(page_size: 2).build
    reversed = deep_copy(@fixture)
    reversed["campaigns"].reverse!
    reversed["report_rows"].reverse!
    second = exporter(fixture: reversed, page_size: 3).build

    first_hashes = first.artifacts.to_h { |artifact| [artifact.country, artifact.source_sha256] }
    second_hashes = second.artifacts.to_h { |artifact| [artifact.country, artifact.source_sha256] }
    assert_equal first_hashes, second_hashes
  end

  def test_report_api_or_incomplete_pagination_fails_before_coverage_files
    failing_clients = [
      FakeAppleClient.new(@fixture, report_error_at: 2),
      FakeAppleClient.new(@fixture, declared_report_total: @fixture.fetch("report_rows").length + 1)
    ]
    failing_clients.each do |client|
      assert_raises(SearchAdsGrowthSpend::AppleApiError) do
        exporter(client: client).build
      end
    end
    assert_empty Dir.glob(File.join(@tmpdir, "**", "*.coverage.json"))
  end

  def test_zero_row_response_is_not_attested_as_zero_spend_coverage
    empty = deep_copy(@fixture)
    empty["report_rows"] = []
    error = assert_raises(SearchAdsGrowthSpend::ExportError) do
      exporter(fixture: empty).build
    end
    assert_match(/omitted planned campaignId/, error.message)
    assert_empty Dir.glob(File.join(@tmpdir, "**", "*.coverage.json"))
  end

  def test_unplanned_castreader_campaign_is_ignored_outside_the_explicit_scope
    unplanned = deep_copy(@fixture)
    extra = deep_copy(unplanned.fetch("campaigns").first)
    extra["id"] = 2144503999
    extra["name"] = "CR_US_Unplanned"
    unplanned.fetch("campaigns") << extra
    assert_equal %w[GB US], exporter(fixture: unplanned).build.artifacts.map(&:country)
  end

  def test_wrong_country_currency_or_duplicate_dimension_fails_closed
    cases = []

    wrong_country = deep_copy(@fixture)
    wrong_country.fetch("campaigns").first["countriesOrRegions"] = ["GB"]
    cases << wrong_country

    wrong_currency = deep_copy(@fixture)
    wrong_currency.fetch("report_rows").first.dig("total", "localSpend")["currency"] = "USD"
    cases << wrong_currency

    duplicate = deep_copy(@fixture)
    duplicate.fetch("report_rows") << deep_copy(duplicate.fetch("report_rows").first)
    cases << duplicate

    cases.each do |fixture|
      assert_raises(SearchAdsGrowthSpend::ExportError) do
        exporter(fixture: fixture).build
      end
    end
    assert_empty Dir.glob(File.join(@tmpdir, "**", "*.coverage.json"))
  end

  def test_recent_operational_day_is_not_coverage_eligible
    error = assert_raises(SearchAdsGrowthSpend::ExportError) do
      SearchAdsGrowthSpend::Exporter.new(
        report_date: Date.iso8601("2026-08-22"),
        source_generated_at: GENERATED_AT,
        current_time: GENERATED_AT,
        apple_client: FakeAppleClient.new(@fixture),
        plan_path: @plan_path,
        output_dir: File.join(@tmpdir, "output")
      ).build
    end
    assert_match(/not coverage-eligible/, error.message)
  end

  def test_dry_run_posts_only_spend_and_commit_posts_coverage_after_all_spend
    dry_result = exporter(dry_run: true).build
    dry_backend = FakeBackend.new
    submitted = SearchAdsGrowthSpend.submit_artifacts(
      dry_result,
      backend_client: dry_backend,
      commit: false
    )
    assert_equal({spend: 2, coverage: 0}, submitted)
    assert_equal [SearchAdsGrowthSpend::SPEND_PATH] * 2, dry_backend.calls.map(&:first)
    assert dry_backend.calls.all? { |_path, payload| payload.fetch("dry_run") }

    commit_result = exporter(dry_run: false).build
    commit_backend = FakeBackend.new
    SearchAdsGrowthSpend.submit_artifacts(
      commit_result,
      backend_client: commit_backend,
      commit: true
    )
    assert_equal(
      [SearchAdsGrowthSpend::SPEND_PATH] * 2 + [SearchAdsGrowthSpend::COVERAGE_PATH] * 2,
      commit_backend.calls.map(&:first)
    )
    refute commit_backend.calls.any? { |_path, payload| payload.fetch("dry_run") }
  end

  def test_backend_spend_error_never_posts_coverage
    result = exporter(dry_run: false).build
    backend = FakeBackend.new(fail_spend_at: 2)
    assert_raises(SearchAdsGrowthSpend::BackendApiError) do
      SearchAdsGrowthSpend.submit_artifacts(
        result,
        backend_client: backend,
        commit: true
      )
    end
    refute backend.calls.any? { |path, _payload| path == SearchAdsGrowthSpend::COVERAGE_PATH }
  end
end
