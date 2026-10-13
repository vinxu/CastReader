require 'xcodeproj'
root = File.dirname(__FILE__)
project = Xcodeproj::Project.new(File.join(root, 'AO3Repro.xcodeproj'))
app = project.new_target(:application, 'AO3Repro', :ios, '17.6')
test = project.new_target(:unit_test_bundle, 'AO3ReproTests', :ios, '17.6')
test.add_dependency(app)
app.add_file_references([project.main_group.new_reference('App.swift')])
test.add_file_references([project.main_group.new_reference('AO3ReproTests.swift')])
Dir.glob(File.join(root, '*.{html,js}')).each do |file|
  test.resources_build_phase.add_file_reference(project.main_group.new_reference(File.basename(file)))
end
[app, test].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "ai.castreader.diagnostics.#{target.name}",
      'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGNING_ALLOWED' => 'NO', 'TARGETED_DEVICE_FAMILY' => '1,2',
      'IPHONEOS_DEPLOYMENT_TARGET' => '17.6',
      'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    })
  end
end
test.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/AO3Repro.app/AO3Repro'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(test)
scheme.set_launch_target(app)
scheme.save_as(project.path, 'AO3Repro', true)
