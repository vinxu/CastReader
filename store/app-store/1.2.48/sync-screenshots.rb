#!/usr/bin/env ruby
# Upload this release's five reviewed genuine captures per device and locale.
# Old assets remain until all five replacements are COMPLETE. Resumable by ID/hash.
require 'json'
require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'
require 'optparse'
require File.expand_path('~/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client.rb')
options = { execute: false, profiles: %w[iphone ipad] }
OptionParser.new do |p|
  p.on('--execute') { options[:execute] = true }
  p.on('--profile NAME') { |v| options[:profiles] = [v] }
  p.on('--locales LIST') { |v| options[:locales] = v.split(',') }
end.parse!
abort 'Unknown profile' unless (options[:profiles] - %w[iphone ipad]).empty?
root = File.expand_path('../../..', __dir__)
report = File.join(root, 'reports/ios-release-1.2.48')
metadata = JSON.parse(File.read(File.join(__dir__, 'asc-metadata.json')))
abort 'Expected 29 supported ASC locales' unless metadata.size == 29
selected = options[:locales] || metadata.keys
abort 'Unknown locale' unless (selected - metadata.keys).empty?
version_id = '968ba86c-0722-43fa-b55c-ff0425533966'
client = ASCClient.new
version = client.request('GET', "/v1/appStoreVersions/#{version_id}").fetch('data')
abort 'Unexpected version or state' unless version.dig('attributes', 'versionString') == '1.2.48' && version.dig('attributes', 'platform') == 'IOS' && version.dig('attributes', 'appStoreState') == 'PREPARE_FOR_SUBMISSION'
versions = client.get_all('/v1/apps/6757636395/appStoreVersions?filter%5Bplatform%5D=IOS&limit=200')
abort 'Wrong app' unless versions.any? { |v| v['id'] == version_id }
localizations = client.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=200")
resource = ->(type, attrs, rel = nil, id = nil) { { data: { type: type, attributes: attrs, relationships: rel, id: id }.compact } }
selected.each do |locale|
  target = localizations.find { |l| l.dig('attributes', 'locale') == locale } or abort "Missing locale #{locale}"
  language = metadata.fetch(locale).fetch('appLanguage')
  language = 'es' if locale == 'es-MX'
  language = 'zh-Hans' if locale == 'zh-Hant'
  options[:profiles].each do |profile|
    display = profile == 'iphone' ? 'APP_IPHONE_67' : 'APP_IPAD_PRO_3GEN_129'
    dimensions = profile == 'iphone' ? [1320, 2868] : [2732, 2048]
    folder = File.join(report, 'screenshots', profile, language)
    files = (1..5).map { |i| File.join(folder, '%02d.png' % i) }
    images = files.map do |path|
      abort "Missing reviewed image #{path}" unless File.file?(path)
      header = File.binread(path, 26)
      abort "Invalid PNG #{path}" unless header.start_with?("\x89PNG\r\n\x1a\n".b) && header[16,8].unpack('NN') == dimensions && [0,2,3].include?(header.getbyte(25))
      sha = Digest::SHA256.file(path).hexdigest
      { 'path' => path, 'name' => "1.2.48-#{profile}-#{File.basename(path, '.png')}-#{sha[0,16]}.png", 'sha256' => sha, 'md5' => Digest::MD5.file(path).hexdigest, 'size' => File.size(path) }
    end
    sets = client.get_all("/v1/appStoreVersionLocalizations/#{target.fetch('id')}/appScreenshotSets?limit=50").select { |s| s.dig('attributes','screenshotDisplayType') == display }
    abort "Ambiguous set #{locale}/#{profile}" if sets.size > 1
    set = sets.first
    items = set ? client.get_all("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots?limit=50") : []
    desired_names = images.map { |i| i['name'] }
    abort 'Duplicate remote names' unless items.map { |i| i.dig('attributes','fileName') }.uniq.size == items.size
    abort 'Replacement exceeds Apple 10-image staging capacity' if items.size + images.count { |i| items.none? { |r| r.dig('attributes','fileName') == i['name'] } } > 10
    unless options[:execute]
      puts JSON.generate(locale: locale, profile: profile, oldCount: items.size, files: desired_names, writes: false)
      next
    end
    journal_path = File.join(report, 'screenshot-journals', "#{locale}-#{profile}.json")
    journal = File.exist?(journal_path) ? JSON.parse(File.read(journal_path)) : { 'versionID' => version_id, 'locale' => locale, 'profile' => profile, 'images' => {}, 'originals' => items }
    abort 'Journal target mismatch' unless journal.values_at('versionID','locale','profile') == [version_id,locale,profile]
    save = lambda do
      FileUtils.mkdir_p(File.dirname(journal_path))
      File.write(journal_path + '.tmp', JSON.pretty_generate(journal) + "\n", perm: 0o600)
      File.rename(journal_path + '.tmp', journal_path)
    end
    unless set
      abort 'Ambiguous earlier set reservation; inspect target before retrying' if journal['setReservation']
      journal['setReservation'] = true; save.call
      set = client.request('POST','/v1/appScreenshotSets',resource.call('appScreenshotSets',{screenshotDisplayType: display},{appStoreVersionLocalization:{data:{type:'appStoreVersionLocalizations',id:target.fetch('id')}}})).fetch('data')
    end
    journal['setID'] = set.fetch('id'); save.call
    puts "Uploading #{locale}/#{profile}"; $stdout.flush
    images.each do |file|
      item = items.find { |i| i.dig('attributes','fileName') == file['name'] }
      unless item
        abort "Ambiguous earlier reservation #{file['name']}" if journal['images'][file['name']]
        journal['images'][file['name']] = { 'state' => 'reserving', 'sha256' => file['sha256'] }; save.call
        item = client.request('POST','/v1/appScreenshots',resource.call('appScreenshots',{fileName:file['name'],fileSize:file['size']},{appScreenshotSet:{data:{type:'appScreenshotSets',id:set.fetch('id')}}})).fetch('data')
      end
      id = item.fetch('id')
      journal['images'][file['name']] = {'id'=>id,'sha256'=>file['sha256']}; save.call
      state = item.dig('attributes','assetDeliveryState','state')
      abort "Apple rejected screenshot #{id}" if state == 'FAILED'
      if state == 'AWAITING_UPLOAD'
        operations = item.dig('attributes','uploadOperations')
        abort "Missing upload operations #{id}" if !operations || operations.empty?
        File.open(file['path'],'rb') do |input|
          operations.each do |operation|
            uri = URI(operation.fetch('url')); abort 'Non-HTTPS upload' unless uri.scheme == 'https'
            input.seek(operation.fetch('offset')); bytes = input.read(operation.fetch('length'))
            abort 'Truncated chunk' unless bytes&.bytesize == operation.fetch('length')
            req = Net::HTTP.const_get(operation.fetch('method').capitalize).new(uri)
            operation.fetch('requestHeaders',[]).each { |h| req[h.fetch('name')] = h.fetch('value') }; req.body = bytes
            response = Net::HTTP.start(uri.hostname,uri.port,use_ssl:true,open_timeout:20,read_timeout:60) { |http| http.request(req) }
            abort "Upload #{id}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
          end
        end
        client.request('PATCH',"/v1/appScreenshots/#{id}",resource.call('appScreenshots',{uploaded:true,sourceFileChecksum:file['md5']},nil,id))
      end
    end
    complete = false
    12.times do
      items = client.get_all("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots?limit=50")
      wanted = images.map { |file| items.find { |i| i['id'] == journal['images'].fetch(file['name']).fetch('id') } }
      abort 'Reserved asset disappeared' if wanted.any?(&:nil?)
      abort 'Apple screenshot processing failed' if wanted.any? { |i| i.dig('attributes','assetDeliveryState','state') == 'FAILED' }
      images.zip(wanted).each do |file,item|
        state = item.dig('attributes','assetDeliveryState','state')
        journal['images'][file['name']]['state'] = state
        if state == 'COMPLETE' && item.dig('attributes','sourceFileChecksum') != file['md5']
          # The set listing can briefly report COMPLETE before its checksum.
          # Confirm the exact asset instead of trusting a stale list response.
          exact = client.request('GET',"/v1/appScreenshots/#{item.fetch('id')}").fetch('data')
          item.replace(exact)
          checksum = item.dig('attributes','sourceFileChecksum')
          abort "Checksum mismatch #{item['id']}" if checksum && checksum != file['md5']
        end
      end
      save.call
      complete = images.zip(wanted).all? { |file,i| i.dig('attributes','assetDeliveryState','state') == 'COMPLETE' && i.dig('attributes','sourceFileChecksum') == file['md5'] }
      break if complete
      sleep 10
    end
    abort 'Processing pending; resume this same journal' unless complete
    ids = images.map { |i| journal['images'].fetch(i['name']).fetch('id') }
    old = items.reject { |i| ids.include?(i['id']) }
    original_ids = journal.fetch('originals').map { |i| i['id'] }
    abort 'Unexpected concurrent asset; preserve and inspect' unless (old.map { |i| i['id'] } - original_ids).empty?
    old.each { |i| client.request('DELETE',"/v1/appScreenshots/#{i.fetch('id')}") }
    client.request('PATCH',"/v1/appScreenshotSets/#{set.fetch('id')}/relationships/appScreenshots",{data:ids.map { |id| {type:'appScreenshots',id:id} }})
    order = client.get_all("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots?limit=50")
    abort 'Final order/readback mismatch' unless order.map { |i| i['id'] } == ids && order.all? { |i| i.dig('attributes','assetDeliveryState','state') == 'COMPLETE' }
    journal['complete'] = true; save.call
    puts "Verified #{locale}/#{profile}: five COMPLETE assets"; $stdout.flush
  end
end
