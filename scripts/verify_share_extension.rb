#!/usr/bin/env ruby

require "json"
require "xcodeproj"

root = File.expand_path("..", __dir__)
project = Xcodeproj::Project.open(File.join(root, "CastReader.xcodeproj"))
app = project.targets.find { |target| target.name == "CastReader" }
share = project.targets.find { |target| target.name == "CastReader Share Extension" }
abort "Missing CastReader target" unless app
abort "Missing CastReader Share Extension target" unless share

info = Xcodeproj::Plist.read_from_path(File.join(root, "CastReader Share Extension/Info.plist"))
rule = info.dig("NSExtension", "NSExtensionAttributes", "NSExtensionActivationRule")
abort "Share activation rule must be nested under NSExtensionAttributes" unless rule.is_a?(Hash)
%w[
  NSExtensionActivationSupportsFileWithMaxCount
  NSExtensionActivationSupportsImageWithMaxCount
  NSExtensionActivationSupportsText
  NSExtensionActivationSupportsWebPageWithMaxCount
  NSExtensionActivationSupportsWebURLWithMaxCount
].each do |key|
  abort "Share activation rule is missing #{key}" unless rule.key?(key)
end

app_entitlements = Xcodeproj::Plist.read_from_path(File.join(root, "CastReader/CastReader.entitlements"))
share_entitlements = Xcodeproj::Plist.read_from_path(File.join(root, "CastReader Share Extension/CastReaderShareExtension.entitlements"))
[app_entitlements, share_entitlements].each do |entitlements|
  groups = entitlements["com.apple.security.application-groups"] || []
  abort "Missing group.com.same.castreader entitlement" unless groups.include?("group.com.same.castreader")
end

abort "Share extension is not an app dependency" unless app.dependencies.any? { |dependency| dependency.target == share }
embedded = app.copy_files_build_phases.flat_map(&:files_references)
abort "Share extension is not embedded" unless embedded.include?(share.product_reference)
abort "ShareInbox.swift is missing from the app" unless app.source_build_phase.files_references.any? { |ref| ref.path == "ShareInbox.swift" }
abort "ShareInbox.swift is missing from the extension" unless share.source_build_phase.files_references.any? { |ref| ref.path == "ShareInbox.swift" }

catalog = JSON.parse(File.read(File.join(root, "CastReader Share Extension/Localizable.xcstrings")))
required_locales = %w[en zh-Hans ja es fr de pt-BR it hi]
%w[
  share_title share_detail share_document share_image share_text
  share_save share_importing share_saved share_failed share_success_title
].each do |key|
  locales = catalog.dig("strings", key, "localizations") || {}
  missing = required_locales - locales.keys
  abort "#{key} is missing locales: #{missing.join(', ')}" unless missing.empty?
end

app_catalog = JSON.parse(File.read(File.join(root, "CastReader/Localizable.xcstrings")))
%w[内容接收箱 内容暂时无法打开，请重试 接收箱是空的 从其他应用分享网页、文字、文档或图片到\ CastReader，内容会保存在这里。].each do |key|
  locales = app_catalog.dig("strings", key, "localizations") || {}
  missing = required_locales - locales.keys
  abort "#{key} is missing locales: #{missing.join(', ')}" unless missing.empty?
end

home = File.read(File.join(root, "CastReader/Views/Home/HomeView.swift"))
settings_view = File.read(File.join(root, "CastReader/Views/Settings/SettingsView.swift"))
abort "Content inbox entry must be reachable from the home settings button" unless home.include?("SettingsToolbarButton") && settings_view.include?("shareInboxRow")
abort "Content inbox entry must use a native inbox symbol" unless settings_view.include?("tray.full.fill")
abort "Content inbox badge must represent unread items" unless home.include?("shareInboxUnreadCount") && settings_view.include?("shareInboxUnreadCount")

main_tab = File.read(File.join(root, "CastReader/Views/MainTabView.swift"))
abort "Inbox retry behavior is missing" unless main_tab.include?("shareInboxErrors")
abort "Inbox item must survive a failed open" if main_tab.match?(/func complete.*?ShareInboxStore\.remove/m)
abort "Inbox link previews are missing" unless main_tab.include?("ShareInboxLinkMetadataLoader.fetch")

store = File.read(File.join(root, "CastReader/Services/ShareInbox.swift"))
abort "Inbox retention cap is missing" unless store.include?("maximumItemCount")
abort "Inbox payload cap is missing" unless store.include?("maximumPayloadBytes")
abort "Shared caption URL extraction is missing" unless store.include?("ShareInboxLinkExtractor")
abort "Inbox preview persistence is missing" unless store.include?("previewImageFilename")
abort "Inbox read cursor persistence is missing" unless store.include?("lastSeenDefaultsKey")
abort "Inbox fallback titles must be stored semantically" unless store.include?("ShareInboxFallbackTitle")

settings = File.read(File.join(root, "CastReader/Models/AppSettings.swift"))
abort "App language is not mirrored to App Group" unless settings.include?("group.com.same.castreader") && settings.include?("sharedDefaults?.set")
abort "Inbox fallback titles do not follow the in-app language" unless settings.include?("localizedDisplayTitle")

extension_controller = File.read(File.join(root, "CastReader Share Extension/ShareViewController.swift"))
abort "Share extension must not pretend it can foreground the containing app" if extension_controller.include?("extensionContext?.open")
abort "Share extension success feedback is missing" unless extension_controller.include?("showSavedState")
abort "Share extension still offers non-executable Read/Explain choices" if extension_controller.include?("readTapped") || extension_controller.include?("explainTapped")
abort "Share extension does not close after saving" unless extension_controller.include?("completeRequest(returningItems: nil)")
abort "Share extension does not read the shared in-app language" unless extension_controller.include?("UserDefaults(suiteName: appGroup)")

puts "Share Extension + durable content inbox contract OK: one-step save, target embedding, retry/delete, unread state, retention cap, and 9 locales."
