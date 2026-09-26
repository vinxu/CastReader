#!/usr/bin/env ruby
# Packaging checks only. Live playback acceptance is a separate release gate.
require 'xcodeproj'
require 'json'
require 'digest'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'CastReader.xcodeproj'))
names = ['CastReader', 'CastReader Share Extension', 'CastReader Widget', 'CastReader Safari Extension']
targets = names.map { |name| project.targets.find { |t| t.name == name } || abort("Missing target #{name}") }
versions = targets.flat_map do |target|
  target.build_configurations.map do |config|
    settings = config.build_settings
    abort "#{target.name}/#{config.name} must support iPhone and iPad" unless
      settings['TARGETED_DEVICE_FAMILY'].to_s.split(',').map(&:strip).sort == ['1', '2']
    [settings['MARKETING_VERSION'], settings['CURRENT_PROJECT_VERSION']]
  end
end.uniq
abort 'App and all extensions must share version/build' unless versions.length == 1
app = targets.first
safari = targets.last
abort 'Missing Safari target dependency' unless app.dependencies.any? { |d| d.target == safari }
abort 'Safari is not embedded in PlugIns' unless app.copy_files_build_phases.any? do |phase|
  phase.dst_subfolder_spec == '13' && phase.files.any? { |f| f.file_ref == safari.product_reference }
end
safari.build_configurations.each do |config|
  settings = config.build_settings
  abort 'Unexpected Safari bundle identity' unless settings['PRODUCT_BUNDLE_IDENTIFIER'] == 'com.same.castreader.SafariExtension'
  abort 'Safari must use extension-safe APIs' unless settings['APPLICATION_EXTENSION_API_ONLY'] == 'YES'
  abort 'Safari must support iOS devices' unless settings['SUPPORTED_PLATFORMS'].to_s.split.include?('iphoneos')
end
extension_root = File.join(root, 'CastReader Safari Extension')
info = Xcodeproj::Plist.read_from_path(File.join(extension_root, 'Info.plist'))
abort 'Incorrect Safari extension point' unless info.dig('NSExtension', 'NSExtensionPointIdentifier') == 'com.apple.Safari.web-extension'
['CastReader/CastReader.entitlements', 'CastReader Safari Extension/CastReaderSafariExtension.entitlements'].each do |path|
  ent = Xcodeproj::Plist.read_from_path(File.join(root, path))
  abort "Missing shared app group in #{path}" unless ent.fetch('com.apple.security.application-groups').include?('group.com.same.castreader')
  abort "Missing isolated Safari keychain in #{path}" unless ent.fetch('keychain-access-groups').include?('$(AppIdentifierPrefix)com.same.castreader.safari')
end
resources = File.join(extension_root, 'Resources')
manifest = JSON.parse(File.read(File.join(resources, 'manifest.json')))
abort 'Native account bridge permission missing' unless manifest.fetch('permissions').include?('nativeMessaging')
abort 'Manifest/app version mismatch' unless manifest['version'] == versions.first.first
%w[en zh_CN ja es fr de pt_BR it hi].each do |locale|
  abort "Missing Safari locale #{locale}" unless File.file?(File.join(resources, '_locales', locale, 'messages.json'))
end
script = File.join(resources, 'content-scripts', 'content.js')
abort 'Temporary acceptance probe in production resources' if File.read(script).include?('castreader-qa-probe')
puts JSON.pretty_generate(version: versions.first.first, build: versions.first.last,
  deviceFamilies: [1, 2], extensionPoint: info.dig('NSExtension', 'NSExtensionPointIdentifier'),
  contentSHA256: Digest::SHA256.file(script).hexdigest, status: 'PASS')
