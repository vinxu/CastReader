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
release = JSON.parse(File.read(File.join(root, 'scripts/mac-release-version.json')))
([mac] + mac.dependencies.map(&:target)).each do |target|
  target.build_configurations.each do |config|
    require_equal(config.build_settings.values_at('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'),
                  release.values_at('version', 'build'), "Aligned #{target.name} Mac release")
  end
end
selection = File.readlines(File.join(root, 'scripts/mac-unit-test-selection.txt')).map(&:strip)
  .reject { |line| line.empty? || line.start_with?('#') }
scheme = Xcodeproj::XCScheme.new(File.join(root, 'CastReader.xcodeproj/xcshareddata/xcschemes/CastReaderMac.xcscheme'))
tests = project.targets.find { |target| target.name == 'CastReaderMacTests' }
testable = scheme.test_action.testables.find { |item| item.buildable_references.any? { |ref| ref.target_uuid == tests&.uuid } }
abort 'FAIL: Missing Mac test selection' unless testable&.use_test_selection_whitelist?
require_equal(testable.selected_tests.map(&:identifier), selection, 'Mac test scheme matches maintained selection')
%w[SpeechGenerationControlTests ExplainGenerationControlTests ReaderPlaybackLoadingViewTests
   AudioStreamingPauseIntentTests AudioPlaybackOwnershipTests PresetTTSRequestSchedulerTests].each do |name|
  abort "FAIL: Missing playback regression #{name}" unless selection.include?(name)
end
# Freeze the validated iOS 1.2.51 Build 86 graph, including shared generation
# control and its regression suites. Mac synchronization must never roll back
# the iOS sources, release settings or extensions to an older graph.
ios_baseline = '7ba153670535ef14ca4c75d237abeced01c0f731'
original, status = Open3.capture2('git', '-C', root, 'show', "#{ios_baseline}:CastReader.xcodeproj/project.pbxproj")
abort 'Cannot read baseline project' unless status.success?
Dir.mktmpdir('CastReaderProjectBaseline') do |temp|
  path = File.join(temp, 'CastReader.xcodeproj')
  FileUtils.mkdir_p(path)
  File.write(File.join(path, 'project.pbxproj'), original)
  baseline = Xcodeproj::Project.open(path)
  baseline.targets.each do |old|
    next if old.name.start_with?('CastReaderMac')
    current = project.targets.find { |target| target.uuid == old.uuid }
    require_equal(current&.to_hash, old.to_hash, "Preserved target #{old.name}")
    (old.build_phases.to_a + old.build_configurations.to_a + old.dependencies.to_a).each do |object|
      actual = project.objects_by_uuid[object.uuid]&.to_hash
      release_targets = ['CastReader', 'CastReader Share Extension', 'CastReader Widget', 'CastReader Safari Extension']
      if release_targets.include?(old.name) && object.isa == 'XCBuildConfiguration'
        # Releases advance all four iOS components together; every other setting
        # remains frozen against the integrated baseline.
        actual = Marshal.load(Marshal.dump(actual))
        settings = actual.fetch('buildSettings')
        app_settings = ios.build_configurations.find { |c| c.name == object.name }.build_settings
        %w[MARKETING_VERSION CURRENT_PROJECT_VERSION].each do |key|
          require_equal(settings[key], app_settings[key], "Aligned #{old.name} #{key}")
        end
        abort 'FAIL: iOS build went backwards' if settings['CURRENT_PROJECT_VERSION'].to_i < object.build_settings['CURRENT_PROJECT_VERSION'].to_i
        abort 'FAIL: Invalid iOS version' unless settings['MARKETING_VERSION'].match?(/\A\d+\.\d+\.\d+\z/)
        %w[MARKETING_VERSION CURRENT_PROJECT_VERSION].each { |key| settings[key] = object.build_settings[key] }
      end
      if object.isa == 'PBXSourcesBuildPhase'
        # Additive OCR integration: keep every frozen source and its settings.
        allowed = { 'CastReader' => ['CloudOCRService.swift'], 'CastReaderTests' => ['CloudOCRTests.swift'] }.fetch(old.name, [])
        old_ids = object.files.map(&:uuid)
        added = project.objects_by_uuid[object.uuid].files.reject { |f| old_ids.include?(f.uuid) }
        require_equal(added.map { |f| f.file_ref.path }.sort, allowed.sort, "Approved #{old.name} source additions")
        added.each { |f| require_equal(f.settings, nil, "Default compilation settings for #{f.file_ref.path}") }
        actual = Marshal.load(Marshal.dump(actual))
        actual['files'] = actual['files'].reject { |id| added.any? { |f| f.uuid == id } }
      end
      require_equal(actual, object.to_hash,
                    "Preserved #{old.name} #{object.isa}")
    end
  end
end
puts JSON.pretty_generate(status: 'PASS', shared_sources: mac.source_build_phase.files.count,
  shared_resources: mac.resources_build_phase.files.count,
  ios_baseline: ios_baseline,
  original_ios_settings_and_extensions: 'unchanged except aligned release version/build',
  ios_release: ios.build_configurations.first.build_settings.values_at('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'),
  mac_release: release, mac_test_selections: selection.count)
