//
//  SettingsView.swift
//  CastReader
//
//  设置：播放（语速/自动播放/自动滚动）、音色（按语言，Pro 锁）、解读（语言/深度）、外观（高亮色）、TTS 引擎、Pro。
//

import SwiftUI

struct SettingsView: View {
    private let onRequestLibraryOnboarding: ((Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var quota = QuotaManager.shared
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var kindleStore = KindleLibraryStore.shared
    @ObservedObject private var weReadStore = WeReadLibraryStore.shared
    @ObservedObject private var googleBooksStore = GoogleBooksLibraryStore.shared
    @ObservedObject private var koboStore = KoboLibraryStore.shared
    @ObservedObject private var oreillyStore = OReillyLibraryStore.shared
    @ObservedObject private var libraryOnboarding = BoundLibraryOnboardingStore.shared
    @ObservedObject private var voiceCatalog = VoiceCatalogService.shared
    @ObservedObject private var history = HistoryStore.shared
    @State private var showPaywall = false
    @State private var showLogin = false
    @State private var showClearHistory = false
    @State private var showVoiceBrowser = false
    @State private var isRestoring = false
    @State private var showRestoreResult = false
    @State private var restoreMessage = ""

    init(onRequestLibraryOnboarding: ((Bool) -> Void)? = nil) {
        self.onRequestLibraryOnboarding = onRequestLibraryOnboarding
    }

    private var explainLanguages: [(String, String)] {
        [("", AppLocalized("跟随原文"))] + SupportedTTSLanguage.allCases.map {
            ($0.rawValue, $0.nativeName)
        }
    }
    private let palette = ["#FD5F01", "#FFD400", "#34C759", "#0A84FF", "#FF2D55", "#AF52DE"]

    var body: some View {
        NavigationView {
            Form {
                accountSection
                languageSection
                connectedServicesSection
                proSection
                librarySection
                playbackSection
                voiceSection
                explainSection
                appearanceSection
                supportSection
                dataSection
                #if DEBUG
                debugSection
                #endif
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showPaywall) {
                PaywallView(analyticsTrigger: "settings_upgrade", analyticsSurface: "settings")
            }
            .sheet(isPresented: $showVoiceBrowser) { VoiceBrowserView() }
            .sheet(isPresented: $showLogin) { LoginView() }
            .alert("清除全部历史记录？", isPresented: $showClearHistory) {
                Button("清除全部", role: .destructive) { HistoryStore.shared.clearAll() }
                Button("取消", role: .cancel) {}
            } message: { Text("将删除文库中全部本地历史，此操作不可撤销。") }
            .alert("恢复购买", isPresented: $showRestoreResult) {
                Button("好", role: .cancel) {}
            } message: { Text(restoreMessage) }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 应用语言

    private var languageSection: some View {
        Section {
            NavigationLink {
                AppLanguagePickerView()
            } label: {
                HStack {
                    Label("语言", systemImage: "globe")
                    Spacer()
                    Text(appLanguage.selectedLanguage.displayName)
                        .foregroundColor(AppTheme.mutedForeground)
                }
            }
            .accessibilityIdentifier("settingsLanguageLink")
        }
    }

    // MARK: 账号

    @ViewBuilder
    private var accountSection: some View {
        Section("账号") {
            if let acc = auth.account {
                HStack(spacing: 12) {
                    avatar(acc)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acc.displayName).font(.headline)
                        if let email = acc.email, !email.isEmpty {
                            Text(email).font(.caption).foregroundColor(AppTheme.mutedForeground)
                        }
                    }
                    Spacer()
                }
                Button(role: .destructive) { auth.signOut() } label: { Text("退出登录") }
            } else {
                Button { showLogin = true } label: {
                    Label("登录 / 注册", systemImage: "person.crop.circle")
                }
                Text("登录后 Pro 与额度跨设备同步")
                    .font(.caption2).foregroundColor(AppTheme.mutedForeground)
            }
        }
    }

    private func avatar(_ acc: UserAccount) -> some View {
        Group {
            if let s = acc.pictureURL, let url = URL(string: s) {
                CachedAsyncImage(url: url) { initialCircle(acc) }
            } else {
                initialCircle(acc)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func initialCircle(_ acc: UserAccount) -> some View {
        ZStack {
            Circle().fill(AppTheme.primary.opacity(0.15))
            Text(acc.initial).font(.headline).foregroundColor(AppTheme.primary)
        }
    }

    // MARK: 书架来源

    private var connectedServicesSection: some View {
        Section {
            NavigationLink {
                LibrarySourcesView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .foregroundColor(AppTheme.primary)
                        .frame(width: 34, height: 34)
                        .background(
                            AppTheme.primary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalized("书架来源"))
                            .font(.headline)
                        Text(AppLocalized("管理书架来源"))
                            .font(.caption)
                            .foregroundColor(AppTheme.mutedForeground)
                    }
                    Spacer()
                    if connectedShelfSourceCount > 0 {
                        Text("\(connectedShelfSourceCount)")
                            .foregroundColor(AppTheme.mutedForeground)
                    }
                }
            }
            .accessibilityIdentifier("settingsShelfSourcesLink")
        } header: {
            Text(AppLocalized("内容服务"))
        } footer: {
            Text(AppLocalized("登录后同步书架与阅读进度"))
        }
    }

    private var connectedShelfSourceCount: Int {
        [
            !kindleStore.needsConnection,
            !weReadStore.needsConnection,
            !googleBooksStore.needsConnection,
            !koboStore.needsConnection,
            !oreillyStore.needsConnection,
        ].filter { $0 }.count
    }

    // MARK: Pro

    private var proSection: some View {
        Section {
            NavigationLink {
                UpgradeView()
            } label: {
                HStack {
                    Image(systemName: proIconName)
                        .foregroundColor(AppTheme.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proTitle).font(.headline)
                        if pro.isPro {
                            Text(proSubtitle)
                                .font(.caption).foregroundColor(AppTheme.mutedForeground)
                        } else {
                            Text(String(format: AppLocalized("今日朗读剩余 %d 分钟 · 解读 %d 次"), Int(quota.listenRemaining / 60), quota.explainRemaining))
                                .font(.caption).foregroundColor(AppTheme.mutedForeground)
                        }
                    }
                }
            }
            if pro.isPro {
                Button("管理订阅") { Task { await pro.openManageSubscriptions() } }
            }
            // 不按 isPro 门控：真正需要恢复购买的，恰恰是已付费却被识别成免费的人。
            // 把它藏在「升级 Pro」页里，等于要求这些用户先点开一个让他们再付一次钱的页面。
            Button("恢复购买") { restorePurchases() }
                .disabled(isRestoring)
            if pro.needsEmailSync && !auth.hasEmailAccount {
                Button("登录邮箱同步 Pro") { showLogin = true }
            }
            if auth.needsAppleRelink && !pro.isPro {
                appleRelinkRow
            }
        }
    }

    /// Apple 登录没换到后端 user id 时，Pro 只能按 device_id 查——网页端订阅或换过设备
    /// 的用户会被当成未订阅。重新登录一次是唯一修复路径（见 `needsAppleRelink`）。
    private var appleRelinkRow: some View {
        Button { showLogin = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("重新登录以同步 Pro")
                Text("账号未完成关联，在其他设备或网页订阅的 Pro 可能无法识别")
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func restorePurchases() {
        isRestoring = true
        Task {
            await pro.restore()
            isRestoring = false
            restoreMessage = pro.isPro
                ? AppLocalized("已恢复 Pro 会员")
                : AppLocalized("未找到可恢复的购买")
            showRestoreResult = true
        }
    }

    private var proIconName: String {
        if pro.needsEmailSync { return "exclamationmark.seal.fill" }
        return pro.isPro ? "crown.fill" : "crown"
    }

    private var proTitle: LocalizedStringKey {
        pro.isPro ? "CastReader Pro" : "升级到 Pro"
    }

    private var proSubtitle: LocalizedStringKey {
        if pro.isCrossPlatformPro {
            return pro.serverPlan == "yearly" ? "年度订阅" : (pro.serverPlan == "monthly" ? "月度订阅" : "已解锁")
        }
        if pro.needsEmailSync {
            return auth.hasEmailAccount ? "本机已解锁，跨平台同步待完成" : "已检测到购买，请登录邮箱同步 Pro"
        }
        return "已解锁"
    }

    // MARK: 文库（历史记录入口；从底部 Tab 下沉到设置）

    private var librarySection: some View {
        Section {
            NavigationLink {
                LibraryView()
            } label: {
                HStack {
                    Image(systemName: "books.vertical.fill").foregroundColor(AppTheme.primary)
                    Text("文库")
                    Spacer()
                    Text("\(history.visibleRecords.count)")
                        .foregroundColor(AppTheme.mutedForeground)
                }
                .accessibilityIdentifier("settingsLibraryLink")
            }
            .accessibilityIdentifier("settingsLibraryLink")
        } footer: {
            Text("拍摄、上传、输入网址或文本，处理过的内容都在这里。仅保存在本机。")
        }
    }

    // MARK: 播放

    private var playbackSection: some View {
        Section("播放") {
            VStack(alignment: .leading) {
                HStack {
                    Text("语速")
                    Spacer()
                    Text(String(format: "%.2gx", settings.speed)).foregroundColor(AppTheme.mutedForeground)
                }
                Slider(value: Binding(
                    get: { settings.speed },
                    set: { newValue in handleSpeedChange(newValue) }),
                    in: AppSettings.minSpeed...AppSettings.maxSpeed,
                    step: 0.25)
                if !pro.isPro {
                    Text("免费版语速上限 2.0x").font(.caption2).foregroundColor(AppTheme.mutedForeground)
                }
            }
            Toggle("自动播放", isOn: $settings.autoPlay)
            Toggle("自动滚动", isOn: $settings.autoScroll)
        }
    }

    private func handleSpeedChange(_ newValue: Double) {
        if !pro.isPro && newValue > AppSettings.freeMaxSpeed {
            Task { @MainActor in
                await pro.refresh()
                if pro.isPro {
                    settings.speed = newValue
                } else {
                    settings.speed = AppSettings.freeMaxSpeed
                    showPaywall = true
                }
            }
        } else {
            settings.speed = newValue
        }
    }

    // MARK: 音色

    private var voiceSection: some View {
        Section("音色") {
            Button { showVoiceBrowser = true } label: {
                HStack {
                    Label("管理各语言音色", systemImage: "waveform")
                    Spacer()
                    Text(VoiceBrowserLanguage.languageCountText(VoiceCatalog.availableLanguages.count))
                        .foregroundStyle(AppTheme.mutedForeground)
                }
            }
            Text("每种语言分别记忆所选音色；可用语言由云端目录自动更新。")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedForeground)
        }
        .id(voiceCatalog.revision)
    }

    // MARK: 解读

    private var explainSection: some View {
        Section("解读") {
            Picker("讲解语言", selection: $settings.explainLanguage) {
                ForEach(explainLanguages, id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("讲解深度", selection: $settings.explainDepth) {
                ForEach(QuickreadDepth.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        Section("高亮颜色") {
            HStack(spacing: 14) {
                ForEach(palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hexString: hex))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(AppTheme.foreground, lineWidth: settings.highlightColorHex == hex ? 2 : 0))
                        .onTapGesture { settings.highlightColorHex = hex }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 支持与反馈

    private var supportSection: some View {
        Section("支持与反馈") {
            Button {
                openURL(AppReviewPromptManager.appStoreReviewURL) { accepted in
                    guard accepted else { return }
                    Task { @MainActor in
                        AppReviewPromptManager.shared.recordSettingsStoreLinkOpened()
                    }
                }
            } label: {
                Label("评价 CastReader", systemImage: "star.bubble")
            }
            .accessibilityIdentifier("settingsRateCastReader")

            Button {
                guard let url = URL(
                    string: "mailto:support@castreader.ai?subject=CastReader%20iOS%20Feedback"
                ) else { return }
                openURL(url)
            } label: {
                Label("发送反馈", systemImage: "envelope")
            }
            .accessibilityIdentifier("settingsSendFeedback")
        }
    }

    // MARK: 数据（历史管理——「清除全部」下沉到此，避免文库列表页误触）

    private var dataSection: some View {
        Section {
            Button {
                reopenLibraryOnboarding(reset: false)
            } label: {
                Label("重新打开书库引导", systemImage: "books.vertical")
            }
            Button(role: .destructive) { showClearHistory = true } label: {
                Label("清除全部历史记录", systemImage: "trash")
            }
        } header: {
            Text("数据")
        } footer: {
            Text("删除文库中全部本地历史。历史仅保存在本机，不会上传或同步到云端。")
        }
    }

    #if DEBUG
    // MARK: 调试（仅 DEBUG，发布构建不含）

    private var debugSection: some View {
        Section {
            Toggle("模拟 Pro 解锁", isOn: $pro.debugForcePro)
            Button {
                reopenLibraryOnboarding(reset: true)
            } label: {
                Label("重置书库首次引导", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("调试")
        } footer: {
            Text("开发期默认解锁全部能力。测试真实付费 / 跨平台权益时请关闭，并在 Xcode 中运行（StoreKit 本地配置才会生效）。")
        }
    }
    #endif

    private func reopenLibraryOnboarding(reset: Bool) {
        if let onRequestLibraryOnboarding {
            onRequestLibraryOnboarding(reset)
            dismiss()
            return
        }

        dismiss()
        Task { @MainActor in
            await Task.yield()
            if reset {
                libraryOnboarding.reset()
            } else {
                libraryOnboarding.presentChooser()
            }
        }
    }
}

private struct AppLanguagePickerView: View {
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    var body: some View {
        List(AppLanguage.allCases) { language in
            Button {
                appLanguage.select(language)
            } label: {
                HStack {
                    Text(language.displayName)
                        .foregroundColor(AppTheme.foreground)
                    Spacer()
                    if appLanguage.selectedLanguage == language {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundColor(AppTheme.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("appLanguage.\(language.rawValue)")
        }
        .navigationTitle(AppLocalized("语言"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
