#!/usr/bin/env ruby
# Preserve every skill check while using the current repository's reviewed locale set.
require 'json'
require 'digest'
tool = ARGV.shift
abort 'Expected preflight.rb or release_ops.rb' unless %w[preflight.rb release_ops.rb].include?(tool)
root = File.expand_path('..', __dir__)
locales = JSON.parse(File.read(File.join(root, 'docs/aso/search-localizations.json'))).fetch('localizations').keys
abort 'Invalid locale catalog' unless locales.size == 29 && locales.uniq.size == 29
path = File.expand_path("~/.codex/skills/submit-castreader-ios-to-app-store/scripts/#{tool}")
source = File.read(path)
pattern = /^LOCALES = %w\[[^\]]+\]\.freeze$/
abort 'Skill locale declaration changed; inspect before adapting' unless source.scan(pattern).size == 1
warn "Skill #{tool} SHA256=#{Digest::SHA256.hexdigest(source)}; applying reviewed #{locales.size}-locale scope"
source.sub!(pattern, "LOCALES = #{locales.inspect}.freeze")
eval(source, TOPLEVEL_BINDING, path)
