#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "tempfile"
require "time"
require_relative "searchads_api"

PLAN_PATH = File.expand_path("searchads_campaign_plan.json", __dir__)
APPLY = ARGV.include?("--apply")

def api_json(method, path, payload = nil)
  response =
    if payload
      Tempfile.create(["searchads", ".json"]) do |file|
        file.write(JSON.generate(payload))
        file.flush
        request(method, path, file.path)
      end
    else
      request(method, path)
    end

  parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  unless response.is_a?(Net::HTTPSuccess) && parsed["error"].nil?
    raise "Apple Ads API #{method} #{path} failed: #{response.code} #{parsed}"
  end

  parsed["data"]
end

def money(amount, currency)
  {amount: amount.to_s, currency: currency}
end

def campaign_payload(spec, plan)
  {
    orgId: org_id,
    name: spec.fetch("name"),
    billingEvent: "TAPS",
    dailyBudgetAmount: money(spec.fetch("dailyBudget"), plan.fetch("currency")),
    adamId: plan.fetch("adamId"),
    countriesOrRegions: [spec.fetch("country")],
    status: "PAUSED",
    supplySources: ["APPSTORE_SEARCH_RESULTS"],
    adChannelType: "SEARCH",
    biddingStrategy: "MANUAL_CPT"
  }
end

def ad_group_payload(spec, currency)
  {
    name: spec.fetch("adGroupName"),
    startTime: (Time.now.utc + 300).iso8601(3),
    automatedKeywordsOptIn: spec.fetch("searchMatch"),
    pricingModel: "CPC",
    defaultBidAmount: money(spec.fetch("defaultBid"), currency),
    targetingDimensions: {
      deviceClass: {
        included: ["IPHONE"]
      }
    },
    status: "PAUSED"
  }
end

def keyword_payloads(spec, currency)
  spec.fetch("keywords").map do |text|
    {
      text: text,
      matchType: spec.fetch("keywordMatchType"),
      bidAmount: money(spec.fetch("defaultBid"), currency)
    }
  end
end

def negative_payloads(spec)
  spec.fetch("campaignNegatives", []).map do |item|
    {
      text: item.fetch("text"),
      matchType: item.fetch("matchType")
    }
  end
end

def index_by_name(records)
  Array(records).to_h { |item| [item.fetch("name"), item] }
end

plan = JSON.parse(File.read(PLAN_PATH))
campaigns = index_by_name(api_json("GET", "/api/v5/campaigns?limit=1000"))

puts "Mode: #{APPLY ? 'APPLY (all resources remain PAUSED)' : 'DRY RUN'}"
puts "App: #{plan.fetch('adamId')} | Currency: #{plan.fetch('currency')} | Total daily budget: #{plan.fetch('totalDailyBudget')}"

plan.fetch("campaigns").each do |spec|
  campaign = campaigns[spec.fetch("name")]
  puts "\n#{spec.fetch('name')} | #{spec.fetch('country')} | ¥#{spec.fetch('dailyBudget')}/day"

  unless campaign
    puts "  campaign: create PAUSED"
    next unless APPLY
    campaign = api_json("POST", "/api/v5/campaigns", campaign_payload(spec, plan))
    campaigns[campaign.fetch("name")] = campaign
  else
    puts "  campaign: exists (#{campaign.fetch('id')})"
  end

  campaign_id = campaign.fetch("id")
  ad_groups = index_by_name(api_json("GET", "/api/v5/campaigns/#{campaign_id}/adgroups?limit=1000"))
  ad_group = ad_groups[spec.fetch("adGroupName")]

  unless ad_group
    puts "  ad group: create PAUSED (Search Match #{spec.fetch('searchMatch')})"
    next unless APPLY
    ad_group = api_json(
      "POST",
      "/api/v5/campaigns/#{campaign_id}/adgroups",
      ad_group_payload(spec, plan.fetch("currency"))
    )
  else
    puts "  ad group: exists (#{ad_group.fetch('id')})"
  end

  ad_group_id = ad_group.fetch("id")
  existing_keywords = Array(
    api_json(
      "GET",
      "/api/v5/campaigns/#{campaign_id}/adgroups/#{ad_group_id}/targetingkeywords?limit=1000"
    )
  )
  keyword_keys = existing_keywords.to_h { |item| [[item.fetch("text").downcase, item.fetch("matchType").upcase], true] }
  missing_keywords = keyword_payloads(spec, plan.fetch("currency")).reject do |item|
    keyword_keys[[item.fetch(:text).downcase, item.fetch(:matchType).upcase]]
  end

  puts "  keywords: #{existing_keywords.length} existing, #{missing_keywords.length} missing"
  if APPLY && missing_keywords.any?
    api_json(
      "POST",
      "/api/v5/campaigns/#{campaign_id}/adgroups/#{ad_group_id}/targetingkeywords/bulk",
      missing_keywords
    )
  end

  desired_negatives = negative_payloads(spec)
  next if desired_negatives.empty?

  existing_negatives = Array(
    api_json("GET", "/api/v5/campaigns/#{campaign_id}/negativekeywords?limit=1000")
  )
  negative_keys = existing_negatives.to_h { |item| [[item.fetch("text").downcase, item.fetch("matchType").upcase], true] }
  missing_negatives = desired_negatives.reject do |item|
    negative_keys[[item.fetch(:text).downcase, item.fetch(:matchType).upcase]]
  end

  puts "  negatives: #{existing_negatives.length} existing, #{missing_negatives.length} missing"
  if APPLY && missing_negatives.any?
    api_json(
      "POST",
      "/api/v5/campaigns/#{campaign_id}/negativekeywords/bulk",
      missing_negatives
    )
  end
end
