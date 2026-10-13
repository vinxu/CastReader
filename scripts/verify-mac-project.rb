#!/usr/bin/env ruby
require 'xcodeproj'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'CastReader.xcodeproj'))
ios = project.targets.find { |target| target.name == 'CastReader' }
mac = project.targets.find { |target| target.name == 'CastReaderMac' }
abort 'Missing Mac target' unless ios && mac
def require_equal(actual, expected, label)
  abort "FAIL: #{label}" unless actual == expected
end
def entries(phase)
  phase.files.map do |file|
    ref = file.file_ref || file.product_ref
    [ref.uuid, file.settings] if ref
  end.compact
end
%i[source_build_phase resources_build_phase frameworks_build_phase].each do |phase|
  require_equal(entries(mac.send(phase)), entries(ios.send(phase)), "Shared #{phase}")
end
require_equal(mac.dependencies.map { |dependency| dependency.target.name }.sort,
              ['CastReaderMacShare', 'CastReaderMacWidget'], 'Only native Mac extensions embedded')
mac.dependencies.each do |dependency|
  dependency.target.build_configurations.each do |config|
    require_equal(config.build_settings['SDKROOT'], 'macosx', 'Native extension SDK')
    require_equal(config.build_settings['SUPPORTS_MACCATALYST'], 'NO', 'Native extension platform')
    require_equal(config.build_settings['REGISTER_APP_GROUPS'], 'YES', 'Provision native extension App Group')
  end
end
mac.build_configurations.each do |config|
  { 'SUPPORTED_PLATFORMS' => 'macosx', 'SUPPORTS_MACCATALYST' => 'YES',
    'CASTREADER_INTERNAL_DISTRIBUTION_CONTROLS' => 'NO',
    'REGISTER_APP_GROUPS' => 'YES',
    'CODE_SIGN_ENTITLEMENTS' => 'CastReader/CastReaderMac.entitlements' }.each do |key, value|
    require_equal(config.build_settings[key], value, "#{config.name} #{key}")
  end
end
# Freeze the latest integrated iOS 1.2.49 Build 84 graph, including Duo and
# locked-page continuation. Comparing to the older Build 75 graph would reject
# those additions and could encourage accidentally restoring the old target.
ios_baseline = 'a95540d4b74e1c62cc9afcc8683752a97f0e2172'
original, status = Open3.capture2('git', '-C', root, 'show', "#{ios_baseline}:CastReader.xcodeproj/project.pbxproj")
abort 'Cannot read baseline project' unless status.success?
Dir.mktmpdir('CastReaderProjectBaseline') do |temp|
  path = File.join(temp, 'CastReader.xcodeproj')
  FileUtils.mkdir_p(path)
  File.write(File.join(path, 'project.pbxproj'), original)
  baseline = Xcodeproj::Project.open(path)
  baseline.targets.each do |old|
    next if ['CastReaderMac', 'CastReaderMacTests'].include?(old.name)
    current = project.targets.find { |target| target.uuid == old.uuid }
    require_equal(current&.to_hash, old.to_hash, "Preserved target #{old.name}")
    (old.build_phases.to_a + old.build_configurations.to_a + old.dependencies.to_a).each do |object|
      actual = project.objects_by_uuid[object.uuid]&.to_hash
      if old.name == 'CastReader' && object.isa == 'PBXSourcesBuildPhase'
        # This shared adapter compiles to the original .fileImporter on iOS.
        # Permit its explicit addition, while still rejecting every removal,
        # unrelated source addition, or build-setting/extension change.
        actual = Marshal.load(Marshal.dump(actual))
        actual['files'].reject! do |id|
          ['PlatformFileImporter.swift', 'MacDocumentCameraViewController.swift'].include?(project.objects_by_uuid[id]&.file_ref&.path)
        end unless object.files.any? { |file| file.file_ref&.path == 'PlatformFileImporter.swift' }
      end
      if old.name == 'CastReaderTests' && object.isa == 'PBXResourcesBuildPhase'
        # Shared offline OCR regression uses the reported public-domain page.
        # Permit only this test fixture; app resources/settings remain identical.
        actual = Marshal.load(Marshal.dump(actual))
        actual['files'].reject! do |id|
          project.objects_by_uuid[id]&.file_ref&.path == 'kindle-offline-dual-page.png'
        end unless object.files.any? { |file| file.file_ref&.path == 'kindle-offline-dual-page.png' }
      end
      require_equal(actual, object.to_hash,
                    "Preserved #{old.name} #{object.isa}")
    end
  end
end
puts JSON.pretty_generate(status: 'PASS', shared_sources: mac.source_build_phase.files.count,
  shared_resources: mac.resources_build_phase.files.count,
  ios_baseline: ios_baseline,
  original_ios_settings_and_extensions: 'unchanged', shared_platform_adapters: ['PlatformFileImporter.swift', 'MacDocumentCameraViewController.swift'])
