//
//  KindleFirstLaunchFlowView.swift
//  CastReader
//
//  First launch: explain the Kindle value, confirm one Amazon storefront, then
//  keep login, shelf discovery, and the first real playback linear.
//

import SwiftUI

struct KindleFirstLaunchFlowView: View {
    @ObservedObject var onboarding: BoundLibraryOnboardingStore
    let onSkip: () -> Void
    let onStartBook: (KindleBook) -> Void

    @ObservedObject private var kindleStore = KindleLibraryStore.shared
    @StateObject private var syncModel = KindleLibrarySyncViewModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsStorefrontPicker = false
    @State private var storefrontOptionIDs: [String] = []
    @State private var selectedStorefrontID: String?
    @State private var recommendedStorefrontID: String?
    @State private var selectedFirstListenBookID: String?
    private let forcesRebind = ProcessInfo.processInfo.arguments.contains(
        "-CastReaderForceLibraryOnboardingRebind"
    )

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            content
                .id(onboarding.phase.rawValue)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
        }
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
            guard onboarding.phase == .login || onboarding.phase == .scan else { return }
            if nextPhase == .active {
                syncModel.startOnboardingAutomation()
            } else {
                syncModel.stopOnboardingAutomation()
            }
        }
        .task {
            handlePhaseChange(onboarding.phase)
        }
        .onDisappear {
            syncModel.stopOnboardingAutomation()
        }
        .sheet(isPresented: $showsStorefrontPicker) {
            storefrontPicker
        }
    }

    @ViewBuilder
    private var content: some View {
        switch onboarding.phase {
        case .sample:
            sampleStep
        case .storefront:
            storefrontStep
        case .login, .scan:
            connectionStep
        case .firstListen:
            firstListenStep
        case .postponed, .activated:
            Color.clear
        }
    }

    private var sampleStep: some View {
        GeometryReader { proxy in
            let contentWidth = max(
                0,
                min(KindleOnboardingLayout.maxContentWidth, proxy.size.width)
                    - KindleOnboardingLayout.horizontalPadding * 2
            )
            let illustrationHeight = min(
                248,
                max(196, proxy.size.height * 0.30)
            )

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    OnboardingHeroTitle(
                        title: AppLocalized("把你的 Kindle 书变成有声书")
                    )
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("kindleOnboarding.sample.title")

                    Text(
                        AppLocalized(
                            "登录 Amazon 账号，同步 Kindle 书架，选一本就能开始朗读。"
                        )
                    )
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.mutedForeground)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("kindleOnboarding.sample.subtitle")
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
                    OnboardingPrimaryButton(title: AppLocalized("同步 Kindle 书架")) {
                        onboarding.completeSample()
                    }
                    .accessibilityIdentifier("kindleOnboarding.sample.start")

                    Button(AppLocalized("我没有 Kindle"), action: onSkip)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedForeground)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .accessibilityIdentifier("kindleOnboarding.sample.skip")
                }
                .frame(maxWidth: .infinity)
            }
            .frame(
                maxWidth: KindleOnboardingLayout.maxContentWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kindleOnboarding.sample.screen")
    }

    private var storefrontStep: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(AppLocalized("1 · 选站"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedForeground)
                        OnboardingStepDots(current: 0, total: 4)
                    }

                    OnboardingAdaptiveTitle(
                        title: AppLocalized("你在哪个亚马逊买书？")
                    )
                    .padding(.top, 18)
                    .accessibilityAddTraits(.isHeader)

                    VStack(spacing: 10) {
                        ForEach(storefrontOptions) { storefront in
                            storefrontOption(storefront)
                        }
                    }
                    .padding(.top, 24)
                }
                .frame(
                    maxWidth: KindleOnboardingLayout.maxContentWidth,
                    alignment: .leading
                )
                .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 2) {
                OnboardingPrimaryButton(title: AppLocalized("就是这个")) {
                    commitSelectedStorefront()
                    onboarding.confirmKindleStorefront()
                    syncModel.startOnboardingAutomation()
                }
                .accessibilityIdentifier("kindleOnboarding.storefront.continue")

                Button(AppLocalized("跳过"), action: onSkip)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .accessibilityIdentifier("kindleOnboarding.storefront.postpone")
            }
            .frame(maxWidth: KindleOnboardingLayout.maxContentWidth)
            .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kindleOnboarding.storefront.screen")
    }

    private var storefrontOptions: [KindleStorefront] {
        let ids = storefrontOptionIDs.isEmpty
            ? defaultStorefrontOptionIDs
            : storefrontOptionIDs
        return ids.compactMap { KindleStorefront.entry(id: $0) }
    }

    private var defaultStorefrontOptionIDs: [String] {
        kindleStore.orderedStorefrontCandidates
            .map(\.id)
    }

    private func prepareStorefrontOptionsIfNeeded() {
        guard storefrontOptionIDs.isEmpty else { return }
        let options = defaultStorefrontOptionIDs
        let initialID = options.first ?? kindleStore.boundStorefrontID
        recommendedStorefrontID = initialID
        selectedStorefrontID = initialID
        storefrontOptionIDs = options
    }

    private func commitSelectedStorefront() {
        guard let storefront = KindleStorefront.entry(
            id: selectedStorefrontID ?? kindleStore.boundStorefrontID
        ) else { return }
        syncModel.switchStorefront(to: storefront)
    }

    private func storefrontOption(_ storefront: KindleStorefront) -> some View {
        let selectedID = selectedStorefrontID ?? kindleStore.boundStorefrontID
        let recommendedID = recommendedStorefrontID ?? kindleStore.boundStorefrontID
        let isSelected = storefront.id == selectedID
        let isRecommended = storefront.id == recommendedID
        let accessibilityTitle = isRecommended
            ? String(
                format: AppLocalized("%@（已按地区预选）"),
                storefront.displayName
            )
            : storefront.displayName

        return Button {
            selectedStorefrontID = storefront.id
        } label: {
            HStack(spacing: 10) {
                Text(storefront.displayName)
                    .font(.title3.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .allowsTightening(true)

                if isRecommended {
                    Text(AppLocalized("推荐"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.primary.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.buttonPrimaryForeground)
                        .frame(width: 24, height: 24)
                        .background(AppTheme.primary, in: Circle())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.horizontal, 16)
            .background(isSelected ? AppTheme.primary.opacity(0.055) : AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        isSelected ? AppTheme.primary : AppTheme.border.opacity(0.72),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("kindleOnboarding.storefront.option.\(storefront.id)")
    }

    private var connectionStep: some View {
        VStack(spacing: 0) {
            onboardingHeader(
                progress: onboarding.phase == .scan
                    ? AppLocalized("连接 Kindle · 3/3")
                    : AppLocalized("连接 Kindle · 2/3"),
                title: onboarding.phase == .scan
                    ? AppLocalized("正在准备你的 Kindle 书架")
                    : AppLocalized("登录 Amazon，读取你的 Kindle 书架"),
                subtitle: onboarding.phase == .scan
                    ? AppLocalized("找到第一本可播放的书后会自动继续。")
                    : AppLocalized("登录成功后会自动继续，无需再点按钮。")
            )
            .frame(maxWidth: KindleOnboardingLayout.maxContentWidth, alignment: .leading)
            .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)

            if onboarding.phase == .login {
                Label {
                    Text(AppLocalized("这是 Amazon 官方页面。CastReader 看不到，也不会保存你的密码。"))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                }
                .foregroundStyle(AppTheme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(
                    maxWidth: KindleOnboardingLayout.maxContentWidth,
                    alignment: .leading
                )
                .background(AppTheme.primary.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
                .padding(.bottom, 10)
            }

            ZStack {
                KindleWebView(webView: syncModel.webView)
                    .opacity(onboarding.phase == .login ? 1 : 0.001)
                    .allowsHitTesting(onboarding.phase == .login)
                    .accessibilityHidden(onboarding.phase != .login)
                    .accessibilityIdentifier("kindleOnboarding.login.webView")

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
                .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
                .padding(.bottom, 12)
                .accessibilityIdentifier(
                    onboarding.phase == .scan
                        ? "kindleOnboarding.scan.postpone"
                        : "kindleOnboarding.login.postpone"
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            onboarding.phase == .scan
                ? "kindleOnboarding.scan.screen"
                : "kindleOnboarding.login.screen"
        )
    }

    @ViewBuilder
    private var scanOverlay: some View {
        ZStack {
            AppTheme.background

            switch syncModel.onboardingState {
            case .empty:
                GeometryReader { proxy in
                    ScrollView(showsIndicators: false) {
                        scanEmptyState
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: proxy.size.height, alignment: .center)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            case .failed(let message):
                GeometryReader { proxy in
                    ScrollView(showsIndicators: false) {
                        scanFailedState(message: message)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: proxy.size.height, alignment: .center)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
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
                            syncModel.discoveredBookCount
                        )
                    )
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.foreground)
                    .accessibilityIdentifier("kindleOnboarding.scan.foundCount")
                    Text(AppLocalized("正在定位一本可以立即朗读的书…"))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .multilineTextAlignment(.center)
                }
                .accessibilityIdentifier("kindleOnboarding.scan.status")
                .accessibilityValue(AppLocalized("正在扫描"))
            }
        }
    }

    private var scanEmptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
            Text(AppLocalized("这个站点暂时没有找到可播放的书"))
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.foreground)
                .multilineTextAlignment(.center)
            if let candidate = syncModel.recoveryStorefronts.first {
                Text(
                    String(
                        format: AppLocalized("你的书可能在 %@。"),
                        candidate.displayName
                    )
                )
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                OnboardingPrimaryButton(
                    title: String(format: AppLocalized("试试 %@"), candidate.displayName)
                ) {
                    syncModel.switchStorefront(to: candidate)
                    onboarding.confirmKindleStorefront()
                }
                .accessibilityIdentifier("kindleOnboarding.scan.changeStorefront")
            }
            Button(AppLocalized("返回示例内容")) {
                syncModel.stopOnboardingAutomation()
                onboarding.restartSample()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(minHeight: 44)
        }
        .padding(24)
        .accessibilityIdentifier("kindleOnboarding.scan.status")
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
            OnboardingPrimaryButton(title: AppLocalized("重新扫描")) {
                syncModel.retryOnboardingScan()
            }
            .accessibilityIdentifier("kindleOnboarding.scan.retry")
            Button(AppLocalized("更换 Amazon 站点")) {
                showsStorefrontPicker = true
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(minHeight: 44)
        }
        .padding(24)
        .accessibilityIdentifier("kindleOnboarding.scan.status")
        .accessibilityValue(AppLocalized("扫描失败"))
    }

    private var firstListenStep: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Label(
                            AppLocalized("Kindle 已连接"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.success)
                        .layoutPriority(1)
                        .accessibilityIdentifier(
                            "kindleOnboarding.firstListen.connectionStatus"
                        )
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
                                onboarding.beginKindleScan()
                                syncModel.startOnboardingAutomation()
                            }
                    }
                }
                .frame(maxWidth: KindleOnboardingLayout.maxContentWidth)
                .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            if let book = selectedFirstListenBook {
                VStack(spacing: 8) {
                    OnboardingPrimaryButton(title: AppLocalized("开始听这本")) {
                        onStartBook(book)
                        onboarding.startFirstListen(bookID: book.id)
                    }
                    .accessibilityIdentifier("kindleOnboarding.firstListen.start")
                    .accessibilityValue(book.id)

                    Text(AppLocalized("点击后自动朗读 · 听满 30 秒完成首次激活"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: KindleOnboardingLayout.maxContentWidth)
                .padding(.horizontal, KindleOnboardingLayout.horizontalPadding)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kindleOnboarding.firstListen.screen")
    }

    private func firstListenBookOption(_ book: KindleBook) -> some View {
        let isSelected = book.id == selectedFirstListenBook?.id

        return Button {
            selectedFirstListenBookID = book.id
        } label: {
            HStack(spacing: 12) {
                KindleCoverView(urlString: book.coverURL)
                    .frame(width: 52, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                        .lineLimit(2)
                    Text(book.displayAuthor)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .lineLimit(1)
                    Text(
                        book.id == recommendedBook?.id
                            ? recommendationLabel(for: book)
                            : book.displayProgress
                    )
                        .font(.caption)
                        .foregroundStyle(
                            book.id == recommendedBook?.id
                                ? AppTheme.primaryText
                                : AppTheme.mutedForeground
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? AppTheme.primary : AppTheme.border
                    )
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                isSelected ? AppTheme.primary.opacity(0.055) : AppTheme.surface
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? AppTheme.primary : AppTheme.border.opacity(0.76),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("kindleOnboarding.firstListen.book.\(book.id)")
    }

    private func onboardingHeader(
        progress: String,
        title: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
            Text(title)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storefrontPicker: some View {
        NavigationStack {
            List(kindleStore.orderedStorefrontCandidates) { storefront in
                Button {
                    syncModel.switchStorefront(to: storefront)
                    showsStorefrontPicker = false
                    if onboarding.phase == .scan || onboarding.phase == .login {
                        onboarding.confirmKindleStorefront()
                        syncModel.startOnboardingAutomation()
                    }
                } label: {
                    HStack {
                        Text("\(storefront.flag) \(storefront.displayName)")
                            .foregroundStyle(AppTheme.foreground)
                        Spacer()
                        if storefront.id == kindleStore.boundStorefrontID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppTheme.primary)
                        }
                    }
                }
                .accessibilityIdentifier("kindleOnboarding.storefront.option.\(storefront.id)")
            }
            .navigationTitle(AppLocalized("选择 Amazon 站点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("取消")) { showsStorefrontPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var recommendedBook: KindleBook? {
        if let id = onboarding.recommendedBookID,
           let persisted = kindleStore.boundBooks.first(where: { $0.id == id }) {
            return persisted
        }
        return KindleOnboardingBookRecommendation.choose(
            from: kindleStore.boundBooks,
            expectedStorefrontID: kindleStore.boundStorefrontID,
            hasListeningAnchor: kindleStore.hasListeningAnchor(for:)
        )
    }

    private var firstListenBooks: [KindleBook] {
        let recent = kindleStore.sortedBooks(sort: .recent, query: "")
            .filter(\.isLikelyLibraryBook)
        guard let recommendedBook else { return recent }
        return [recommendedBook] + recent.filter { $0.id != recommendedBook.id }
    }

    private var selectedFirstListenBook: KindleBook? {
        if let selectedFirstListenBookID,
           let selected = firstListenBooks.first(where: {
               $0.id == selectedFirstListenBookID
           }) {
            return selected
        }
        return recommendedBook ?? firstListenBooks.first
    }

    private func recommendationLabel(for book: KindleBook) -> String {
        if kindleStore.hasListeningAnchor(for: book.id) || book.lastOpenedAt != nil {
            return AppLocalized("最近阅读")
        }
        if !book.progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppLocalized("有阅读进度")
        }
        return AppLocalized("已为你准备好")
    }

    private func handlePhaseChange(_ phase: BoundLibraryOnboardingPhase) {
        switch phase {
        case .sample:
            syncModel.stopOnboardingAutomation()
        case .storefront:
            syncModel.stopOnboardingAutomation()
            prepareStorefrontOptionsIfNeeded()
            if !forcesRebind,
               kindleStore.hasConnected,
               let book = KindleOnboardingBookRecommendation.choose(
                   from: kindleStore.boundBooks,
                   expectedStorefrontID: kindleStore.boundStorefrontID,
                   hasListeningAnchor: kindleStore.hasListeningAnchor(for:)
               ) {
                onboarding.prepareFirstListen(bookID: book.id)
            }
        case .login, .scan:
            syncModel.startOnboardingAutomation()
        case .firstListen, .postponed, .activated:
            if phase != .firstListen {
                syncModel.stopOnboardingAutomation()
            }
        }
    }

    private func handleConnectionState(_ state: KindleOnboardingConnectionState) {
        switch state {
        case .idle:
            break
        case .awaitingLogin:
            if onboarding.phase == .scan {
                onboarding.requireKindleLogin()
            }
        case .scanning:
            if onboarding.phase == .login {
                onboarding.beginKindleScan()
            }
        case .ready:
            guard let book = KindleOnboardingBookRecommendation.choose(
                from: kindleStore.boundBooks,
                expectedStorefrontID: kindleStore.boundStorefrontID,
                hasListeningAnchor: kindleStore.hasListeningAnchor(for:)
            ) else { return }
            syncModel.stopOnboardingAutomation()
            onboarding.prepareFirstListen(bookID: book.id)
        case .empty, .failed:
            if onboarding.phase == .login {
                onboarding.beginKindleScan()
            }
        }
    }
}

enum KindleOnboardingBookRecommendation {
    static func choose(
        from books: [KindleBook],
        expectedStorefrontID: String,
        hasListeningAnchor: (String) -> Bool = { _ in false }
    ) -> KindleBook? {
        books
            .filter {
                $0.isLikelyLibraryBook
                    && ($0.storefrontID ?? expectedStorefrontID) == expectedStorefrontID
            }
            .sorted { lhs, rhs in
                let lhsAnchor = hasListeningAnchor(lhs.id)
                let rhsAnchor = hasListeningAnchor(rhs.id)
                if lhsAnchor != rhsAnchor { return lhsAnchor }

                let lhsOpened = lhs.lastOpenedAt
                let rhsOpened = rhs.lastOpenedAt
                if (lhsOpened != nil) != (rhsOpened != nil) { return lhsOpened != nil }
                if lhsOpened != rhsOpened {
                    return (lhsOpened ?? .distantPast) > (rhsOpened ?? .distantPast)
                }

                let lhsProgress = !lhs.progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let rhsProgress = !rhs.progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if lhsProgress != rhsProgress { return lhsProgress }

                let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
            .first
    }
}

private enum KindleOnboardingLayout {
    static let maxContentWidth: CGFloat = 520
    static let horizontalPadding: CGFloat = 24
}

private struct OnboardingHeroTitle: View {
    let title: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            singleLine(size: 34)
            singleLine(size: 32)
            singleLine(size: 30)
            singleLine(size: 28)

            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.foreground)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func singleLine(size: CGFloat) -> some View {
        Text(title)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct OnboardingAdaptiveTitle: View {
    let title: String
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 32

    var body: some View {
        Text(title)
            .font(.system(size: titleSize, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.foreground)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingPrimaryButton: View {
    let title: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .foregroundStyle(AppTheme.buttonPrimaryForeground)
                .background(AppTheme.buttonPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
    }
}

private struct OnboardingStepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index == current ? AppTheme.mutedForeground : Color.clear)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.mutedForeground, lineWidth: 1.5)
                    }
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}
