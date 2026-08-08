//
//  WeReadFirstLaunchFlowView.swift
//  CastReader
//
//  中国区首启引导：微信读书强绑定，四屏。
//
//  与海外 Kindle 五屏引导的差别只有一处——微信读书是单站点，没有 storefront
//  确认屏，`.sample` 之后直接进 `.login`（见 `BoundLibraryOnboardingStore`
//  的 `stepAfterSample`）。其余阶段语义、埋点与激活判据完全一致。
//
//  登录铁律：docs/WeRead-iOS-Login-Session-Contract.md
//

import SwiftUI

struct WeReadFirstLaunchFlowView: View {
    @ObservedObject var onboarding: BoundLibraryOnboardingStore
    let onSkip: () -> Void
    let onStartBook: (WeReadBook) -> Void

    @ObservedObject private var wereadStore = WeReadLibraryStore.shared
    @StateObject private var syncModel = WeReadLibrarySyncViewModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedFirstListenBookID: String?

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            content
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
        }
        // 刻意不给 content 加 `.id(phase)`：登录到进入书架期间必须保持同一个
        // WKWebView 与同一个 document，任何强制重建都可能换掉正在轮询的登录 UID。
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: onboarding.phase)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boundLibraryOnboarding")
        .accessibilityValue(colorScheme == .dark ? "dark" : "light")
        .onChange(of: syncModel.onboardingState) { _, state in
            handleConnectionState(state)
        }
        .onChange(of: onboarding.phase) { _, phase in
            handlePhaseChange(phase)
        }
        .onChange(of: scenePhase) { _, nextPhase in
            handleScenePhase(nextPhase)
        }
        .task {
            // 主题只能在首次加载前准备；加载后改主题只允许设 overrideUserInterfaceStyle。
            syncModel.updateTheme(isDark: colorScheme == .dark)
            handlePhaseChange(onboarding.phase)
        }
        .onDisappear {
            syncModel.stopOnboardingAutomation()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch onboarding.phase {
        case .sample:
            valueStep
        case .storefront:
            // 微信读书没有站点确认屏。历史状态若停在这里，直接推进到登录。
            Color.clear.task { onboarding.confirmLibrarySelection(.weread) }
        case .login, .scan:
            connectionStep
        case .firstListen:
            firstListenStep
        case .postponed, .activated:
            Color.clear
        }
    }

    // MARK: - 屏 0 · 价值

    private var valueStep: some View {
        GeometryReader { proxy in
            let contentWidth = max(
                0,
                min(BoundLibraryOnboardingLayout.maxContentWidth, proxy.size.width)
                    - BoundLibraryOnboardingLayout.horizontalPadding * 2
            )
            let illustrationHeight = min(248, max(196, proxy.size.height * 0.30))

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    OnboardingHeroTitle(
                        title: AppLocalized("把你的微信读书变成有声书")
                    )
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("wereadOnboarding.sample.title")

                    Text(
                        AppLocalized("用微信登录，同步你的微信读书书架，选一本就能开始朗读。")
                    )
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.mutedForeground)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("wereadOnboarding.sample.subtitle")
                }

                Spacer(minLength: 16)

                Image("OnboardingReadAloudIllustration")
                    .resizable()
                    .scaledToFill()
                    .frame(width: contentWidth, height: illustrationHeight)
                    .clipped()
                    .accessibilityHidden(true)

                Spacer(minLength: 16)

                VStack(spacing: 2) {
                    OnboardingPrimaryButton(title: AppLocalized("同步微信读书书架")) {
                        onboarding.completeSample()
                    }
                    .accessibilityIdentifier("wereadOnboarding.sample.start")

                    Button(AppLocalized("我没有微信读书"), action: onSkip)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedForeground)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .accessibilityIdentifier("wereadOnboarding.sample.skip")
                }
                .frame(maxWidth: .infinity)
            }
            .frame(
                maxWidth: BoundLibraryOnboardingLayout.maxContentWidth,
                maxHeight: .infinity,
                alignment: .leading
            )
            .padding(.horizontal, BoundLibraryOnboardingLayout.horizontalPadding)
            .padding(.top, 32)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wereadOnboarding.sample.screen")
    }

    // MARK: - 屏 1/2 · 登录与自动准备（同一个容器，WebView 不重建）

    private var connectionStep: some View {
        VStack(spacing: 0) {
            onboardingHeader(
                progress: onboarding.phase == .scan
                    ? AppLocalized("连接微信读书 · 2/2")
                    : AppLocalized("连接微信读书 · 1/2"),
                title: onboarding.phase == .scan
                    ? AppLocalized("正在准备你的微信读书书架")
                    : AppLocalized("用微信登录微信读书"),
                subtitle: onboarding.phase == .scan
                    ? AppLocalized("找到第一本可朗读的书后会自动继续。")
                    : AppLocalized("登录成功后会自动继续，无需再点按钮。")
            )
            .frame(maxWidth: BoundLibraryOnboardingLayout.maxContentWidth, alignment: .leading)
            .padding(.horizontal, BoundLibraryOnboardingLayout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)

            if onboarding.phase == .login {
                loginGuidance
            }

            ZStack {
                WeReadWebView(webView: syncModel.webView)
                    .opacity(onboarding.phase == .login ? 1 : 0.001)
                    .allowsHitTesting(onboarding.phase == .login)
                    .accessibilityHidden(onboarding.phase != .login)
                    .accessibilityIdentifier("wereadOnboarding.login.webView")

                if onboarding.phase == .scan {
                    scanOverlay
                }
            }
            .frame(minHeight: 250, maxHeight: .infinity)
            .layoutPriority(1)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.72), lineWidth: 1)
            }
            .padding(.horizontal, 12)

            Button(AppLocalized("稍后"), action: onSkip)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedForeground)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, BoundLibraryOnboardingLayout.horizontalPadding)
                .padding(.bottom, 12)
                .accessibilityIdentifier(
                    onboarding.phase == .scan
                        ? "wereadOnboarding.scan.postpone"
                        : "wereadOnboarding.login.postpone"
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            onboarding.phase == .scan
                ? "wereadOnboarding.scan.screen"
                : "wereadOnboarding.login.screen"
        )
    }

    /// 二维码登录的操作指引。
    ///
    /// 微信读书网页在非微信浏览器里只给二维码，用户没法用同一块屏幕扫自己，
    /// 必须长按识别。这三步是中国区首启转化的关键路径，不能省。
    private var loginGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(AppLocalized("这是微信读书官方页面。CastReader 看不到，也不会保存你的微信账号和密码。"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield.fill")
            }
            .foregroundStyle(AppTheme.primaryText)

            Text(AppLocalized("长按下方二维码 → 选择「识别图中二维码」→ 在微信里确认后回到 CastReader"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wereadOnboarding.login.qrGuidance")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: BoundLibraryOnboardingLayout.maxContentWidth, alignment: .leading)
        .background(AppTheme.primary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(.horizontal, BoundLibraryOnboardingLayout.horizontalPadding)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var scanOverlay: some View {
        ZStack {
            AppTheme.background

            switch syncModel.onboardingState {
            case .empty:
                centeredScrollable { scanEmptyState }
            case .failed(let message):
                centeredScrollable { scanFailedState(message: message) }
            default:
                VStack(spacing: 15) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.primary.opacity(0.12))
                            .frame(width: 68, height: 68)
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(AppTheme.primary)
                    }
                    ProgressView()
                        .tint(AppTheme.primary)
                    Text(
                        String(
                            format: AppLocalized("已找到 %d 本"),
                            discoveredBookCount
                        )
                    )
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.foreground)
                    .accessibilityIdentifier("wereadOnboarding.scan.foundCount")
                    Text(AppLocalized("正在定位你最近在读的一本…"))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .multilineTextAlignment(.center)
                }
                .accessibilityIdentifier("wereadOnboarding.scan.status")
                .accessibilityValue(AppLocalized("正在扫描"))
            }
        }
    }

    private var scanEmptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
            Text(AppLocalized("你的微信读书书架还没有书"))
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.foreground)
                .multilineTextAlignment(.center)
            Text(AppLocalized("在微信读书里加入一本书后回来，或者先用拍照、文件等方式听。"))
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            OnboardingPrimaryButton(title: AppLocalized("重新扫描")) {
                syncModel.retryOnboardingScan()
            }
            .accessibilityIdentifier("wereadOnboarding.scan.retry")
            Button(AppLocalized("先用其他方式听"), action: onSkip)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(minHeight: 44)
                .accessibilityIdentifier("wereadOnboarding.scan.skip")
        }
        .padding(24)
        .accessibilityIdentifier("wereadOnboarding.scan.emptyStatus")
        .accessibilityValue(AppLocalized("书架为空"))
    }

    private func scanFailedState(message: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
            Text(AppLocalized("书架还没有准备好"))
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.foreground)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            OnboardingPrimaryButton(title: AppLocalized("重新扫描")) {
                syncModel.retryOnboardingScan()
            }
            .accessibilityIdentifier("wereadOnboarding.scan.retryFailed")
            Button(AppLocalized("先用其他方式听"), action: onSkip)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(minHeight: 44)
        }
        .padding(24)
        .accessibilityIdentifier("wereadOnboarding.scan.failedStatus")
        .accessibilityValue(AppLocalized("扫描失败"))
    }

    // MARK: - 屏 3 · 真实首听

    private var firstListenStep: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Label(
                            AppLocalized("微信读书已连接"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.success)
                        .layoutPriority(1)
                        .accessibilityIdentifier("wereadOnboarding.firstListen.connectionStatus")
                        .accessibilityValue("success")

                        Spacer(minLength: 8)

                        Button(AppLocalized("稍后"), action: onSkip)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.mutedForeground)
                            .frame(minWidth: 44, minHeight: 44)
                    }

                    VStack(spacing: 6) {
                        Text(AppLocalized("先从这本开始"))
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(AppTheme.foreground)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(AppLocalized("已替你选好，也可以点其他书。"))
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedForeground)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    if !firstListenBooks.isEmpty {
                        LazyVStack(spacing: 10) {
                            ForEach(firstListenBooks) { book in
                                firstListenBookOption(book)
                            }
                        }
                        .padding(.top, 20)
                    } else {
                        ProgressView()
                            .tint(AppTheme.primary)
                            .padding(.top, 52)
                            .task {
                                onboarding.beginLibraryScan()
                                syncModel.startOnboardingAutomation()
                            }
                    }
                }
                .frame(maxWidth: BoundLibraryOnboardingLayout.maxContentWidth)
                .padding(.horizontal, BoundLibraryOnboardingLayout.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            if let book = selectedFirstListenBook {
                VStack(spacing: 8) {
                    OnboardingPrimaryButton(title: AppLocalized("开始听这本")) {
                        onStartBook(book)
                        onboarding.startFirstListen(bookID: book.id, source: .weread)
                    }
                    .accessibilityIdentifier("wereadOnboarding.firstListen.start")
                    .accessibilityValue(book.id)

                    Text(AppLocalized("点击后自动朗读 · 听满 30 秒完成首次激活"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: BoundLibraryOnboardingLayout.maxContentWidth)
                .padding(.horizontal, BoundLibraryOnboardingLayout.horizontalPadding)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wereadOnboarding.firstListen.screen")
    }

    private func firstListenBookOption(_ book: WeReadBook) -> some View {
        let isSelected = book.id == selectedFirstListenBook?.id

        return Button {
            selectedFirstListenBookID = book.id
        } label: {
            HStack(spacing: 12) {
                WeReadCoverView(urlString: book.coverURL)
                    .frame(width: 44, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(recommendationReason(for: book))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.primary : AppTheme.mutedForeground)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.primary.opacity(0.08) : AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? AppTheme.primary.opacity(0.55) : AppTheme.border.opacity(0.7),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wereadOnboarding.firstListen.option")
        .accessibilityValue(book.id)
    }

    // MARK: - 派生数据

    private var discoveredBookCount: Int {
        if case .scanning(let found) = syncModel.onboardingState { return found }
        return max(syncModel.availableCount, wereadStore.books.count)
    }

    private var firstListenBooks: [WeReadBook] {
        Array(
            WeReadOnboardingBookRecommendation
                .candidates(from: wereadStore.books, hasListeningAnchor: hasListeningAnchor)
                .prefix(3)
        )
    }

    private var selectedFirstListenBook: WeReadBook? {
        if let selectedFirstListenBookID,
           let match = firstListenBooks.first(where: { $0.id == selectedFirstListenBookID }) {
            return match
        }
        if let recommendedID = onboarding.recommendedBookID,
           let match = firstListenBooks.first(where: { $0.id == recommendedID }) {
            return match
        }
        return firstListenBooks.first
    }

    private func hasListeningAnchor(_ bookID: String) -> Bool {
        wereadStore.anchor(for: bookID) != nil
    }

    private func recommendationReason(for book: WeReadBook) -> String {
        switch WeReadOnboardingBookRecommendation.reason(
            for: book,
            hasListeningAnchor: hasListeningAnchor
        ) {
        case .recent: return AppLocalized("最近在读")
        case .first: return AppLocalized("书架第一本")
        }
    }

    // MARK: - 状态推进

    private func handlePhaseChange(_ phase: BoundLibraryOnboardingPhase) {
        switch phase {
        case .sample, .storefront:
            syncModel.stopOnboardingAutomation()
        case .login, .scan:
            syncModel.startOnboardingAutomation()
        case .firstListen, .postponed, .activated:
            if phase != .firstListen {
                syncModel.stopOnboardingAutomation()
            }
        }
    }

    private func handleConnectionState(_ state: BoundLibraryOnboardingConnectionState) {
        switch state {
        case .idle:
            break
        case .awaitingLogin:
            if onboarding.phase == .scan {
                onboarding.requireLibraryLogin()
            }
        case .scanning:
            if onboarding.phase == .login {
                onboarding.beginLibraryScan()
            }
        case .ready:
            guard let book = WeReadOnboardingBookRecommendation.choose(
                from: wereadStore.books,
                hasListeningAnchor: hasListeningAnchor
            ) else { return }
            syncModel.stopOnboardingAutomation()
            onboarding.prepareFirstListen(bookID: book.id)
        case .empty, .failed:
            if onboarding.phase == .login {
                onboarding.beginLibraryScan()
            }
        }
    }

    /// 用户去微信确认登录时 App 会进后台。页面原始的登录轮询请求会被挂起，
    /// 回前台必须恢复**同一个** UID 的那次请求，而不是重新导航。
    private func handleScenePhase(_ next: ScenePhase) {
        guard onboarding.phase == .login || onboarding.phase == .scan else { return }
        switch next {
        case .active:
            syncModel.resumeAfterExternalLogin()
            syncModel.startOnboardingAutomation()
        case .inactive, .background:
            syncModel.preserveLoginSessionBeforeBackground()
            syncModel.stopOnboardingAutomation()
        @unknown default:
            break
        }
    }

    // MARK: - 布局辅助

    private func onboardingHeader(
        progress: String,
        title: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(progress)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedForeground)
                Spacer(minLength: 8)
                OnboardingStepDots(
                    current: onboarding.phase == .scan ? 1 : 0,
                    total: 2
                )
            }

            OnboardingAdaptiveTitle(title: title)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func centeredScrollable<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                content()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
