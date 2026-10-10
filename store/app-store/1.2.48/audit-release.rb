#!/usr/bin/env ruby
# Version-scoped audit for the user's 28-language campaign: 27 ASC languages
# plus preserved es-MX/zh-Hant. App Info is shared with the Mac review and is
# read-only; its existing 11 localized names/subtitles must remain unchanged.
require 'json'
require 'digest'
require 'optparse'
require File.expand_path('~/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client.rb')
options = {}
OptionParser.new { |p| p.on('--build-id ID') { |v| options[:build] = v } }.parse!
abort '--build-id is required' unless options[:build]
root = File.expand_path('../../..', __dir__)
report = File.join(root, 'reports/ios-release-1.2.48')
expected = JSON.parse(File.read(File.join(__dir__, 'asc-metadata.json')))
client = ASCClient.new
version_id = '968ba86c-0722-43fa-b55c-ff0425533966'
errors = []
version = client.request('GET', "/v1/appStoreVersions/#{version_id}").fetch('data')
build = client.request('GET', "/v1/appStoreVersions/#{version_id}/build")['data']
errors << 'Wrong version/platform/release behavior' unless version.dig('attributes','versionString') == '1.2.48' && version.dig('attributes','platform') == 'IOS' && version.dig('attributes','releaseType') == 'AFTER_APPROVAL'
errors << 'Exact build 74 must be VALID and APP_STORE_ELIGIBLE' unless build && build['id'] == options[:build] && build.dig('attributes','version') == '74' && build.dig('attributes','processingState') == 'VALID' && build.dig('attributes','buildAudienceType') == 'APP_STORE_ELIGIBLE'
localizations = client.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=200")
errors << 'Expected exact 29-locale set' unless localizations.map { |l| l.dig('attributes','locale') }.sort == expected.keys.sort && expected.size == 29
screenshots = {}
localizations.each do |item|
  locale = item.dig('attributes','locale')
  copy = expected[locale]
  next unless copy
  %w[description keywords supportUrl marketingUrl whatsNew promotionalText].each do |field|
    errors << "#{locale}: #{field} differs" unless item.dig('attributes',field).to_s == copy[field].to_s
  end
  sets = client.get_all("/v1/appStoreVersionLocalizations/#{item.fetch('id')}/appScreenshotSets?limit=50")
  screenshots[locale] = {}
  {'iphone'=>'APP_IPHONE_67','ipad'=>'APP_IPAD_PRO_3GEN_129'}.each do |profile,display|
    matching = sets.select { |s| s.dig('attributes','screenshotDisplayType') == display }
    if matching.size != 1
      errors << "#{locale}/#{profile}: missing or ambiguous set"; next
    end
    images = client.get_all("/v1/appScreenshotSets/#{matching.first.fetch('id')}/appScreenshots?limit=50")
    journal_path = File.join(report,'screenshot-journals',"#{locale}-#{profile}.json")
    unless File.file?(journal_path)
      errors << "#{locale}/#{profile}: upload journal missing"; next
    end
    journal = JSON.parse(File.read(journal_path))
    wanted = journal.fetch('images').sort_by { |name,_| name }.map { |_,e| e.fetch('id') }
    errors << "#{locale}/#{profile}: exact ordered five COMPLETE assets required" unless journal['complete'] && wanted.size == 5 && images.map { |i| i['id'] } == wanted && images.all? { |i| i.dig('attributes','assetDeliveryState','state') == 'COMPLETE' }
    screenshots[locale][profile] = {count: images.size, states: images.map { |i| i.dig('attributes','assetDeliveryState','state') }.uniq, ids: images.map { |i| i['id'] }}
  end
end
baseline = JSON.parse(File.read(File.join(report,'asc-app-info-baseline.json')))
app_info_checks = baseline.map do |info|
  original = info.fetch('localizations')
  actual = client.get_all("/v1/appInfos/#{info.fetch('id')}/appInfoLocalizations?limit=200")
  changed = original.filter_map do |before|
    locale = before.dig('attributes','locale')
    after = actual.find { |x| x.dig('attributes','locale') == locale }
    locale if !after || %w[name subtitle privacyPolicyUrl privacyChoicesUrl privacyPolicyText].any? { |k| before.dig('attributes',k) != after.dig('attributes',k) }
  end
  errors << "Shared App Info changed: #{changed.join(',')}" unless changed.empty?
  {id:info['id'],unchanged:changed.empty?,localeCount:actual.size}
end
review = client.request('GET',"/v1/appStoreVersions/#{version_id}/appStoreReviewDetail")['data']
errors << 'Missing review details' unless review
if review && review.dig('attributes','demoAccountRequired')
  %w[demoAccountName demoAccountPassword].each { |k| errors << "Missing reviewer #{k}" if review.dig('attributes',k).to_s.empty? }
end
core_path = File.join(report,'core-gate.json')
if File.file?(core_path)
  core = JSON.parse(File.read(core_path))
  %w[cn global].each do |region|
    %w[read-regular read-community read-private explain-regular explain-community explain-private].each do |cell|
      result = core.dig('regions',region,cell)
      errors << "Core gate #{region}/#{cell} is not verified PASS" unless result && result['status'] == 'PASS' && result['evidence'].is_a?(Array) && !result['evidence'].empty? && result['evidence'].all? { |p| File.exist?(File.join(root,p)) }
    end
  end
  errors << 'Core gate source/config must match final archive' unless core['archiveSourceVerified'] == true
else
  errors << 'Core gate evidence is not complete'
end
output = {version:version.dig('attributes','versionString'),buildID:build&.fetch('id'),buildNumber:build&.dig('attributes','version'),localeCount:localizations.size,screenshots:screenshots,appInfoPreservation:app_info_checks,reviewDetailsPresent:!review.nil?,errors:errors}
File.write(File.join(report,'final-release-audit.json'),JSON.pretty_generate(output)+"\n",perm:0o600)
puts JSON.pretty_generate(output)
exit(errors.empty? ? 0 : 1)
