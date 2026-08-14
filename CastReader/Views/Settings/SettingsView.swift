//
//  SettingsView.swift
//  CastReader
//
//  设置：播放（语速/自动播放/自动滚动）、音色（按语言，Pro 锁）、解读（语言/深度）、外观（高亮色）、TTS 引擎、Pro。
//

import SwiftUI

struct SettingsView: View {
    private let shareInboxUnreadCount: Int
    private let onOpenShareInbox: (() -> Void)?
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
    @State private var showsDeleteAccountConfirm = false
    @State private var deleteAccountError: String?
    @State private var showClearHistory = false
    @State private var showSignOutConfirm = false
    @State private var showVoiceBrowser = false
    @State private var isRestoring = false
    @State private var showRestoreResult = false
    @State private var restoreMessage = ""
    /// 绑定 `AppRegion` 的覆盖值，这样内部开关切换后界面能立即反映。
    @AppStorage("appRegion.v1.override") private var regionOverrideRaw: String = ""
    /// 空值表示跟随后台；线路只在下次完整启动时重新解析。
    @AppStorage("serviceRouting.v1.override") private var serviceRouteOverrideRaw: String = ""
    @State private var isRefreshingServiceRoute = false
    @State private var serviceRouteRefreshMessage: String?

    init(
        shareInboxUnreadCount: Int = 0,
        onOpenShareInbox: (() -> Void)? = nil,
        onRequestLibraryOnboarding: ((Bool) -> Void)? = nil
    ) {
        self.shareInboxUnreadCount = shareInboxUnreadCount
        self.onOpenShareInbox = onOpenShareInbox
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
                if AppRegion.current == .cn {
                    chinaAboutSection
                }
                dataSection
                if showsInternalRegionSwitcher {
                    internalRegionSection
                }
                #if DEBUG
                debugSection
                #endif
            }
            .navigationTitle("设置")
            // 设置是 sheet，但没有关闭按钮时只能下拉退出。与书架来源等 sheet 对齐，
            // 在左上角补一颗「关闭」。
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("关闭")) { dismiss() }
                        .accessibilityIdentifier("settingsCloseButton")
                }
            }
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
                // 硬登录墙下退出登录 = 回到登录页才能继续用，误触代价高 → 二次确认。
                Button(role: .destructive) { showSignOutConfirm = true } label: { Text("退出登录") }
                    .confirmationDialog(
                        Text(AppLocalized("退出登录后需要重新登录才能继续使用 CastReader。")),
                        isPresented: $showSignOutConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(AppLocalized("退出登录"), role: .destructive) { auth.signOut() }
                        Button(AppLocalized("取消"), role: .cancel) {}
                    }
                deleteAccountButton
            } else {
                Button { showLogin = true } label: {
                    Label("登录 / 注册", systemImage: "person.crop.circle")
                }
                Text("登录后 Pro 与额度跨设备同步")
                    .font(.caption2).foregroundColor(AppTheme.mutedForeground)
            }
        }
    }

    /// 账号注销。个人信息保护法与国内应用商店的强制要求：
    /// 必须能在 App 内自助发起，且要有明确的二次确认与后果说明。
    @ViewBuilder
    private var deleteAccountButton: some View {
        Button(role: .destructive) {
            deleteAccountError = nil
            showsDeleteAccountConfirm = true
        } label: {
            Text(AppLocalized("注销账号"))
        }
        .disabled(auth.isWorking)
        .confirmationDialog(
            AppLocalized("确定要注销账号吗？"),
            isPresented: $showsDeleteAccountConfirm,
            titleVisibility: .visible
        ) {
            Button(AppLocalized("确认注销"), role: .destructive) {
                Task { await deleteAccount() }
            }
            Button(AppLocalized("管理订阅")) {
                Task { await pro.openManageSubscriptions() }
            }
            Button(AppLocalized("取消"), role: .cancel) {}
        } message: {
            Text(
                AppLocalized(
                    "提交后会立即退出登录，账号与个人信息将按服务端告知的期限删除。Apple 自动续订和退款不会随账号注销自动处理。"
                )
            )
        }

        if let deleteAccountError {
            Text(deleteAccountError)
                .font(.caption2)
                .foregroundColor(AppTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deleteAccount() async {
        do {
            _ = try await auth.deleteAccount()
            deleteAccountError = nil
        } catch let error as PhoneAuthError {
            deleteAccountError = error.errorDescription
        } catch {
            deleteAccountError = PhoneAuthError.network.errorDescription
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
        // 会员标识只保留在设置页账号卡内；右上角工具栏始终是无会员装饰的账号头像。
        .overlay(alignment: .bottomTrailing) {
            if pro.isPro { proCrownBadge }
        }
    }

    /// 描边画在底层而不是 `.overlay`：叠在上面会从皇冠头顶切过去。
    private var proCrownBadge: some View {
        ZStack {
            Circle()
                .fill(AppTheme.systemBackground)
                .frame(width: 21, height: 21)
            Circle()
                .fill(AppTheme.primary)
                .frame(width: 17, height: 17)
            Image(systemName: "crown.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(AppTheme.primaryForeground)
        }
        .offset(x: 3, y: 3)
        .accessibilityIdentifier("settingsProBadge")
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
            .accessibilityIdentifier("settingsProLink")
            if pro.isPro {
                Button("管理订阅") { Task { await pro.openManageSubscriptions() } }
            }
            // 不按 isPro 门控：真正需要恢复购买的，恰恰是已付费却被识别成免费的人。
            // 把它藏在「升级 Pro」页里，等于要求这些用户先点开一个让他们再付一次钱的页面。
            Button("恢复购买") { restorePurchases() }
                .disabled(isRestoring)
            if pro.needsEmailSync && !auth.hasSyncableAccount {
                Button("登录账号同步 Pro") { showLogin = true }
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
        guard pro.isPro else { return "解锁全部朗读与解读能力" }
        if pro.isCrossPlatformPro {
            return pro.serverPlan == "yearly" ? "年度订阅" : (pro.serverPlan == "monthly" ? "月度订阅" : "已解锁")
        }
        if pro.needsEmailSync {
            if auth.hasSyncableAccount { return "本机已解锁，跨平台同步待完成" }
            return "已检测到购买，请登录账号同步 Pro"
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
            shareInboxRow
        } footer: {
            Text("拍摄、上传、输入网址或文本，处理过的内容都在这里。仅保存在本机。")
        }
    }

    /// 收件箱从首页 toolbar 下沉到这里。它是低频入口（要先从别的 app 分享内容过来），
    /// 但未读数必须往上冒到齿轮上，否则用户不会知道有待处理的内容。
    private var shareInboxRow: some View {
        Button {
            onOpenShareInbox?()
            dismiss()
        } label: {
            HStack {
                Image(systemName: shareInboxUnreadCount > 0 ? "tray.full.fill" : "tray.fill")
                    .foregroundColor(AppTheme.primary)
                Text("内容接收箱")
                    .foregroundColor(AppTheme.foreground)
                Spacer()
                if shareInboxUnreadCount > 0 {
                    Text("\(shareInboxUnreadCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.primary))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.mutedForeground)
            }
        }
        .accessibilityIdentifier("settingsShareInboxLink")
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

    // MARK: 关于 / 中国大陆合规信息

    private var chinaAboutSection: some View {
        Section {
            Link(destination: URL(string: "https://beian.miit.gov.cn/")!) {
                HStack(spacing: 12) {
                    Label(AppLocalized("ICP备案"), systemImage: "checkmark.shield")
                    Spacer()
                    Text("沪ICP备14008512号-12A")
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityIdentifier("settingsICPLink")
            .accessibilityLabel(
                Text("\(AppLocalized("ICP备案"))，沪ICP备14008512号-12A")
            )
        } header: {
            Text(AppLocalized("关于"))
        } footer: {
            Text(AppLocalized("点击备案号可前往工业和信息化部备案管理系统查询。"))
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
            Text(verbatim: "默认显示当前账号的真实会员状态。仅在需要模拟会员功能时手动开启；StoreKit 本地购买测试需在 Xcode 中运行。")
        }
    }
    #endif

    // MARK: - 内部：发行体验与服务线路

    private var showsInternalRegionSwitcher: Bool {
        // Route controls are a build/distribution testing capability, not an
        // account entitlement. A production account must never unlock them.
        ServiceRouting.allowsLocalOverride || AppRegion.overrideRegion != nil
    }

    private var internalRegionSection: some View {
        Section {
            Picker("产品发行区域", selection: $regionOverrideRaw) {
                Text("跟随 App Store 地区").tag("")
                Text("中国大陆（CHN）").tag(AppRegion.cn.rawValue)
                Text("全球（Global）").tag(AppRegion.global.rawValue)
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("settingsRegionOverride")

            HStack {
                Text("当前产品体验")
                Spacer()
                Text(AppRegion.current == .cn ? "中国大陆" : "全球")
                    .foregroundColor(AppTheme.mutedForeground)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settingsRegionEffective")
            .accessibilityValue(AppRegion.current.rawValue)

            HStack {
                Text("产品判据来源")
                Spacer()
                Text(AppRegion.provenance.rawValue)
                    .foregroundColor(AppTheme.mutedForeground)
            }
            HStack {
                Text("App Store 地区")
                Spacer()
                Text(AppRegion.resolvedStorefrontCode ?? "解析中…")
                    .foregroundColor(AppTheme.mutedForeground)
            }

            if ServiceRouting.allowsLocalOverride {
                Divider()

                Picker("自有 API 服务线路", selection: $serviceRouteOverrideRaw) {
                    Text("跟随后台（默认全球网关）").tag("")
                    Text(ServiceRoute.globalGateway.displayName).tag(ServiceRoute.globalGateway.rawValue)
                    Text(ServiceRoute.chinaGateway.displayName).tag(ServiceRoute.chinaGateway.rawValue)
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("settingsServiceRouteOverride")

                HStack {
                    Text("当前进程线路")
                    Spacer()
                    Text(ServiceRouting.current.displayName)
                        .foregroundColor(AppTheme.mutedForeground)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settingsServiceRouteEffective")
                .accessibilityValue(ServiceRouting.current.rawValue)

                HStack {
                    Text("下次启动线路")
                    Spacer()
                    Text(ServiceRouting.nextLaunchSnapshot.route.displayName)
                        .foregroundColor(AppTheme.mutedForeground)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settingsServiceRouteNextLaunch")
                .accessibilityValue(ServiceRouting.nextLaunchSnapshot.route.rawValue)

                HStack {
                    Text("下次启动来源")
                    Spacer()
                    Text(ServiceRouting.nextLaunchSnapshot.provenance.rawValue)
                        .foregroundColor(AppTheme.mutedForeground)
                }

                HStack {
                    Text("后台缓存")
                    Spacer()
                    Text(backendServiceRouteDescription)
                        .foregroundColor(AppTheme.mutedForeground)
                        .multilineTextAlignment(.trailing)
                }

                Button {
                    refreshBackendServiceRoute()
                } label: {
                    HStack {
                        Label("刷新后台线路配置", systemImage: "arrow.clockwise")
                        Spacer()
                        if isRefreshingServiceRoute { ProgressView() }
                    }
                }
                .disabled(isRefreshingServiceRoute)
                .accessibilityIdentifier("settingsServiceRouteRefresh")

                if let serviceRouteRefreshMessage {
                    Text(serviceRouteRefreshMessage)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .accessibilityIdentifier("settingsServiceRouteRefreshResult")
                }

                serviceRouteEndpointDiagnostics
            }

            Button {
                reopenLibraryOnboarding(reset: true)
            } label: {
                Label("重置首启引导", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("内部测试 · 区域与网络")
        } footer: {
            Text(
                "两项开关彼此独立，切换后请完全退出并重新打开 App。当前进程固定使用一条网络线路，"
                + "避免登录、支付、上传或朗读中途混用后端。配置缺失、过期或拉取失败时默认全球网关。"
                + "中国产品体验仅把微信读书设为默认；Kindle、YouTube、Google 图书、Kobo、O’Reilly "
                + "等书架连接仍全部保留，但登录页隐藏 Google，提供手机号、Apple 与邮箱。服务线路只选择入口域名；"
                + "全球与中国线路的登录会话和本地数据完全隔离，首次切到目标线路需登录该线路账号，切回后可恢复原线路账号。"
            )
        }
    }

    private var backendServiceRouteDescription: String {
        guard let route = ServiceRouting.cachedBackendRoute else {
            return "未获取（默认全球网关）"
        }
        guard ServiceRouting.isBackendCacheValid else {
            return "已过期（默认全球网关）"
        }
        return route.displayName
    }

    @ViewBuilder
    private var serviceRouteEndpointDiagnostics: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("当前进程实际 Host")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.mutedForeground)
            Text("账号 / Pro：\(host(of: Constants.API.webURL))")
            Text("文档 / 上传：\(host(of: Constants.API.readerServiceURL))")
            Text("TTS：\(host(of: TTSEndpoint.primaryBase()))")
            Text("QuickRead：\(host(of: QuickReadEndpoint.base()))")
        }
        .font(.caption.monospaced())
        .foregroundColor(AppTheme.mutedForeground)
        .textSelection(.enabled)
        .accessibilityIdentifier("settingsServiceRouteHosts")
    }

    private func host(of rawURL: String) -> String {
        URL(string: rawURL)?.host ?? rawURL
    }

    private func refreshBackendServiceRoute() {
        isRefreshingServiceRoute = true
        serviceRouteRefreshMessage = nil
        Task {
            let outcome = await ServiceRouting.refreshBackendConfiguration()
            serviceRouteRefreshMessage = outcome.displayMessage
            isRefreshingServiceRoute = false
        }
    }

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
