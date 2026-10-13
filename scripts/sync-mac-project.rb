#!/usr/bin/env ruby
# Keep Mac Catalyst on the same application source/resource graph as iOS.
# The independent target leaves the released iOS app and extensions unchanged.
require 'xcodeproj'
require 'json'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'CastReader.xcodeproj'))
ios = project.targets.find { |target| target.name == 'CastReader' }
abort 'Missing iOS application target' unless ios
mac_release = JSON.parse(File.read(File.join(root, 'scripts/mac-release-version.json')))
mac = project.targets.find { |target| target.name == 'CastReaderMac' }
mac ||= project.new_target(:application, 'CastReaderMac', :ios, '17.6')

def mirror_phase(source, destination)
  valid = source.files.select { |file| file.file_ref || file.product_ref }
  wanted = valid.map { |file| (file.file_ref || file.product_ref).uuid }
  destination.files.to_a.each do |file|
    file.remove_from_project unless wanted.include?((file.file_ref || file.product_ref)&.uuid)
  end
  ordered = valid.map do |file|
    copy = destination.files.find { |existing| existing.file_ref == file.file_ref && existing.product_ref == file.product_ref }
    copy ||= destination.project.new(Xcodeproj::Project::Object::PBXBuildFile)
    copy.file_ref = file.file_ref if file.file_ref
    copy.product_ref = file.product_ref if file.product_ref
    copy.settings = Marshal.load(Marshal.dump(file.settings)) if file.settings
    copy
  end
  destination.files.clear
  ordered.each { |file| destination.files << file }
end

tests = project.targets.find { |target| target.name == 'CastReaderMacTests' }
tests ||= project.new_target(:unit_test_bundle, 'CastReaderMacTests', :ios, '17.6')
tests.add_dependency(mac) unless tests.dependencies.any? { |dep| dep.target == mac }
ios_tests = project.targets.find { |target| target.name == 'CastReaderTests' }
mirror_phase(ios_tests.resources_build_phase, tests.resources_build_phase)
test_group = project.main_group.find_subpath('CastReaderMacTests', true)
test_group.path = 'CastReaderMacTests'
Dir.glob(File.join(root, 'CastReaderMacTests/*.swift')).sort.each do |path|
  name = File.basename(path)
  ref = test_group.files.find { |file| file.path == name } || test_group.new_reference(name)
  tests.add_file_references([ref]) unless tests.source_build_phase.files_references.include?(ref)
end
# Compile the existing iOS account contracts without copying a second test
# implementation. The scheme selects only the applicable contracts below.
selection = File.readlines(File.join(root, 'scripts/mac-unit-test-selection.txt')).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
classes = selection.map { |line| line.split('/').first }.uniq
# A misspelled class otherwise silently omits both its source and tests.
available_test_sources = Dir.glob(File.join(root, '{CastReaderTests,CastReaderMacTests}/*.swift'))
missing_classes = classes.reject do |name|
  available_test_sources.any? { |path| File.read(path).match?(/\bclass\s+#{Regexp.escape(name)}\s*:/) }
end
abort "Unknown Mac test selections: #{missing_classes.join(', ')}" unless missing_classes.empty?
shared_sources = Dir.glob(File.join(root, 'CastReaderTests/*.swift')).select do |path|
  text = File.read(path)
  File.basename(path) == 'TestRepository.swift' || classes.any? { |name| text.match?(/\bclass\s+#{Regexp.escape(name)}\s*:/) }
end
tests.source_build_phase.files.to_a.each do |file|
  path = file.file_ref&.real_path&.to_s
  if path&.start_with?(File.join(root, 'CastReaderTests/')) && !shared_sources.include?(path)
    file.remove_from_project
  end
end
shared_sources.map { |path| path.delete_prefix(root + '/') }.each do |path|
  ref = project.files.find { |file| file.real_path.to_s == File.join(root, path) }
  unless ref
    abort "Missing shared test source #{path}" unless File.file?(File.join(root, path))
    shared_group = project.main_group.find_subpath('CastReaderTests', true)
    shared_group.path = 'CastReaderTests'
    ref = shared_group.new_reference(File.basename(path))
  end
  tests.add_file_references([ref]) unless tests.source_build_phase.files_references.include?(ref)
end
tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'SUPPORTED_PLATFORMS' => 'macosx',
    'SUPPORTS_MACCATALYST' => 'YES',
    'DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER' => 'NO',
    'SDKROOT' => 'iphoneos',
    'TARGETED_DEVICE_FAMILY' => '2,6',
    'SWIFT_VERSION' => '5.0',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_MODULE_NAME' => 'CastReaderMacTests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.same.castreader.mac-tests',
    'DEVELOPMENT_TEAM' => ios.build_configurations.first.build_settings['DEVELOPMENT_TEAM'],
    'CODE_SIGN_STYLE' => 'Automatic',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/CastReaderMac.app/Contents/MacOS/CastReaderMac',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks', '@loader_path/../Frameworks']
  })
end

mirror_phase(ios.source_build_phase, mac.source_build_phase)
mirror_phase(ios.resources_build_phase, mac.resources_build_phase)
mirror_phase(ios.frameworks_build_phase, mac.frameworks_build_phase)
mac.package_product_dependencies.clear
ios.package_product_dependencies.each { |product| mac.package_product_dependencies << product }

mac.build_configurations.each do |config|
  source = ios.build_configurations.find { |item| item.name == config.name }
  config.base_configuration_reference = source.base_configuration_reference
  config.build_settings = Marshal.load(Marshal.dump(source.build_settings))
  config.build_settings.merge!({
    'SUPPORTED_PLATFORMS' => 'macosx',
    'SUPPORTS_MACCATALYST' => 'YES',
    'DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER' => 'NO',
    'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
    'SDKROOT' => 'iphoneos',
    'PRODUCT_NAME' => 'CastReaderMac',
    'PRODUCT_MODULE_NAME' => 'CastReader',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'CastReader for Mac',
    'INFOPLIST_FILE' => 'CastReader/CastReaderMac-Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'CastReader/CastReaderMac.entitlements',
    'ENABLE_HARDENED_RUNTIME' => 'YES',
    'REGISTER_APP_GROUPS' => 'YES',
    'CASTREADER_INTERNAL_DISTRIBUTION_CONTROLS' => 'NO',
    'MARKETING_VERSION' => mac_release.fetch('version'),
    'CURRENT_PROJECT_VERSION' => mac_release.fetch('build'),
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
    'TARGETED_DEVICE_FAMILY' => '2,6'
  })
end

group = project.main_group.find_subpath('CastReader', false)
unless group.files.any? { |ref| ref.path == 'CastReaderMac.entitlements' }
  group.new_reference('CastReaderMac.entitlements')
end

# Preserve the iOS metadata and add Finder's explicit Open With association.
# Alternate rank avoids taking over the user's existing default reader.
info = Xcodeproj::Plist.read_from_path(File.join(root, 'CastReader/Info.plist'))
info['CFBundleDocumentTypes'] = [{
  'CFBundleTypeName' => 'Readable documents', 'CFBundleTypeRole' => 'Viewer',
  'LSHandlerRank' => 'Alternate', 'LSItemContentTypes' => [
    'com.adobe.pdf', 'org.idpf.epub-container',
    'org.openxmlformats.wordprocessingml.document', 'public.text', 'public.image'
  ]
}]
info['LSSupportsOpeningDocumentsInPlace'] = true
Xcodeproj::Plist.write_to_path(info, File.join(root, 'CastReader/CastReaderMac-Info.plist'))

# System share surfaces and widgets require native macOS extension targets.
# Reuse their data contracts/resources; do not embed the iOS executables.
extension_definitions = [
  ['CastReaderMacShare', 'CastReader Share Extension', 'CastReader Mac Share Extension/Info.plist', [
    'CastReader Mac Share Extension/ShareViewController.swift',
    'CastReader/Services/ShareInbox.swift', 'CastReader/Models/YouTubeTranscript.swift']],
  ['CastReaderMacWidget', 'CastReader Widget', 'CastReader Widget/Info.plist', nil]
]
embed = mac.copy_files_build_phases.find { |phase| phase.name == 'Embed Mac Extensions' }
embed ||= mac.new_copy_files_build_phase('Embed Mac Extensions')
embed.dst_subfolder_spec = '13'
extension_definitions.each do |name, source_name, plist, sources|
  original = project.targets.find { |target| target.name == source_name }
  target = project.targets.find { |item| item.name == name } || project.new_target(:app_extension, name, :osx, '14.6')
  if sources
    refs = sources.map do |path|
      project.files.find { |file| file.real_path.to_s == File.join(root, path) } || begin
        folder = File.dirname(path)
        group = project.main_group.find_subpath(folder, true)
        group.path = folder
        group.new_reference(File.basename(path))
      end
    end
    refs.each { |ref| target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref) }
  else
    mirror_phase(original.source_build_phase, target.source_build_phase)
  end
  mirror_phase(original.resources_build_phase, target.resources_build_phase)
  target.build_configurations.each do |config|
    source = original.build_configurations.find { |item| item.name == config.name }
    config.build_settings.merge!(Marshal.load(Marshal.dump(source.build_settings)))
    config.build_settings.delete('IPHONEOS_DEPLOYMENT_TARGET')
    config.build_settings.delete('TARGETED_DEVICE_FAMILY')
    config.build_settings.merge!({
      'SDKROOT' => 'macosx', 'SUPPORTED_PLATFORMS' => 'macosx', 'SUPPORTS_MACCATALYST' => 'NO',
      'MACOSX_DEPLOYMENT_TARGET' => '14.6', 'PRODUCT_NAME' => name,
      'MARKETING_VERSION' => mac_release.fetch('version'),
      'CURRENT_PROJECT_VERSION' => mac_release.fetch('build'),
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.same.castreader.#{name}",
      'INFOPLIST_FILE' => plist, 'CODE_SIGN_ENTITLEMENTS' => 'CastReader/MacExtensions.entitlements',
      'ENABLE_HARDENED_RUNTIME' => 'YES',
      'REGISTER_APP_GROUPS' => 'YES',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks']
    })
  end
  mac.add_dependency(target) unless mac.dependencies.any? { |dependency| dependency.target == target }
  unless embed.files_references.include?(target.product_reference)
    file = embed.add_file_reference(target.product_reference)
    file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  end
end

project.save
scheme_path = File.join(root, 'CastReader.xcodeproj/xcshareddata/xcschemes/CastReaderMac.xcscheme')
scheme = File.exist?(scheme_path) ? Xcodeproj::XCScheme.new(scheme_path) : Xcodeproj::XCScheme.new
unless File.exist?(scheme_path)
  scheme.add_build_target(mac)
  scheme.set_launch_target(mac)
end
scheme.add_test_target(tests) unless scheme.test_action.testables.any? { |testable| testable.buildable_references.any? { |ref| ref.target_uuid == tests.uuid } }
selection = File.readlines(File.join(root, 'scripts/mac-unit-test-selection.txt')).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
testable = scheme.test_action.testables.find { |item| item.buildable_references.any? { |ref| ref.target_uuid == tests.uuid } }
testable.use_test_selection_whitelist = true
testable.selected_tests = selection.map do |identifier|
  item = Xcodeproj::XCScheme::TestAction::TestableReference::Test.new
  item.identifier = identifier
  item
end
scheme.save_as(File.join(root, 'CastReader.xcodeproj'), 'CastReaderMac', true)
puts JSON.pretty_generate({
  target: mac.name,
  shared_sources: mac.source_build_phase.files.count,
  shared_resources: mac.resources_build_phase.files.count,
  package_products: mac.package_product_dependencies.map(&:product_name),
  embedded_extensions: mac.dependencies.map { |dependency| dependency.target.name }
})
