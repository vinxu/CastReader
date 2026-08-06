#!/usr/bin/env ruby
# frozen_string_literal: true

# ASO 关键词字段漂移检查：线上最新版本 vs docs/aso/approved-keywords.json。
#
#   ruby scripts/verify_aso_keywords.rb            # 检查最新 READY_FOR_SALE 版本
#   ruby scripts/verify_aso_keywords.rb 1.2.18     # 检查指定版本（发版前核对提交内容）
#
# 背景：1.2.16/1.2.17 提交时关键词被按旧来源重写，zh-Hans 美区扩容尾巴、ja 主力 token
# 全部丢失（详见 docs/aso/keyword-corpus.md 2026-08-06 记录）。本脚本是防线：
# 发版前后各跑一次，任何与真相源的差异都会打印出来。改词必须先改 approved-keywords.json。

require "json"
require "open3"

ROOT = File.expand_path("..", __dir__)
APPROVED = JSON.parse(File.read(File.join(ROOT, "docs/aso/approved-keywords.json")))
                .reject { |k, _| k.start_with?("_") }
APP_ID = "6757636395"
ASC = File.join(ROOT, "scripts/app_store_connect_api.rb")

def asc_get(path)
  out, _err, status = Open3.capture3("ruby", ASC, "GET", path)
  abort "ASC 请求失败: #{path}" unless status.success?
  JSON.parse(out)
end

version_filter = ARGV[0]
versions = asc_get("/v1/apps/#{APP_ID}/appStoreVersions?limit=5&fields[appStoreVersions]=versionString,appStoreState")["data"]
target = if version_filter
  versions.find { |v| v["attributes"]["versionString"] == version_filter }
else
  versions.find { |v| v["attributes"]["appStoreState"] == "READY_FOR_SALE" }
end
abort "找不到目标版本" unless target

attrs = target["attributes"]
puts "检查版本 #{attrs['versionString']}（#{attrs['appStoreState']}）"

locs = asc_get("/v1/appStoreVersions/#{target['id']}/appStoreVersionLocalizations?limit=20")["data"]
live = locs.to_h { |l| [l["attributes"]["locale"], (l["attributes"]["keywords"] || "").strip] }

drift = 0
APPROVED.sort.each do |locale, expected|
  actual = live[locale]
  if actual.nil?
    puts "  ✗ #{locale}: 线上缺少该 locale"
    drift += 1
  elsif actual == expected
    puts "  ✓ #{locale} (#{actual.length}/100)"
  else
    drift += 1
    exp_tokens = expected.split(",").map(&:strip)
    act_tokens = actual.split(",").map(&:strip)
    missing = exp_tokens - act_tokens
    extra = act_tokens - exp_tokens
    puts "  ✗ #{locale} 偏离（线上 #{actual.length} 字符 / 目标 #{expected.length}）"
    puts "      缺失: #{missing.join(', ')}" unless missing.empty?
    puts "      多出: #{extra.join(', ')}" unless extra.empty?
  end
end
(live.keys - APPROVED.keys).each { |l| puts "  ⚠ 线上存在但真相源未收录: #{l}" }

if drift.zero?
  puts "全部一致 ✓"
else
  puts "#{drift} 个 locale 偏离 —— 下个版本按 approved-keywords.json 恢复；改词先改真相源。"
  exit 1
end
