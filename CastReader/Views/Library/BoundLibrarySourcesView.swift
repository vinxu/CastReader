//
//  BoundLibrarySourcesView.swift
//  CastReader
//
//  One scalable place for commercial reading-platform connections. Platform
//  stores keep owning their authentication, cookie, sync and disconnect rules;
//  this view only presents their shared product contract.
//

import SwiftUI

struct LibrarySourcesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            LibrarySourcesView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(AppLocalized("关闭")) { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

struct LibrarySourcesView: View {
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    @ObservedObject private var kindleStore = KindleLibraryStore.shared
    @ObservedObject private var weReadStore = WeReadLibraryStore.shared
    @ObservedObject private var googleBooksStore = GoogleBooksLibraryStore.shared
    @ObservedObject private var koboStore = KoboLibraryStore.shared
    @ObservedObject private var oreillyStore = OReillyLibraryStore.shared

    @State private var activeConnection: BoundLibraryOnboardingSource?
    @State private var pendingDisconnect: BoundLibraryOnboardingSource?

    var body: some View {
        List {
            Section {
                sourceSummary
            }

            if !connectedSources.isEmpty {
                Section(AppLocalized("已连接")) {
                    ForEach(connectedSources) { source in
                        connectedRow(source)
                    }
                }
                .accessibilityIdentifier("shelfSourcesConnectedSection")
            }

            if !availableSources.isEmpty {
                Section(AppLocalized("可连接")) {
                    ForEach(availableSources) { source in
                        availableRow(source)
                    }
                }
                .accessibilityIdentifier("shelfSourcesAvailableSection")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle(AppLocalized("书架来源"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("shelfSourcesScreen")
        .sheet(item: $activeConnection) { source in
            connectionView(source)
        }
        .confirmationDialog(
            disconnectTitle,
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let source = pendingDisconnect {
                Button(AppLocalized("解除绑定"), role: .destructive) {
                    disconnect(source)
                }
            }
            Button(AppLocalized("取消"), role: .cancel) {
                pendingDisconnect = nil
            }
        } message: {
            Text(disconnectMessage)
        }
    }

    private var sourceSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(AppTheme.primary)
                .frame(width: 42, height: 42)
                .background(
                    AppTheme.primary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("管理书架来源"))
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)
                Text(AppLocalized("登录后同步书架与阅读进度"))
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func connectedRow(_ source: BoundLibraryOnboardingSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceIdentity(source, connected: true)

            Divider()

            HStack(spacing: 10) {
                NavigationLink {
                    libraryView(source)
                } label: {
                    Label(AppLocalized("查看全部"), systemImage: "books.vertical")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(AppTheme.primary)

                Spacer(minLength: 0)

                Button {
                    activeConnection = source
                } label: {
                    Label(AppLocalized("重新同步"), systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(AppTheme.primary)
                .accessibilityIdentifier("shelfSourcePrimaryAction.\(source.rawValue)")

                Menu {
                    Button(AppLocalized("解除绑定"), role: .destructive) {
                        pendingDisconnect = source
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundColor(AppTheme.mutedForeground)
                }
                .accessibilityLabel(AppLocalized("解除绑定"))
                .accessibilityIdentifier("shelfSourceDisconnect.\(source.rawValue)")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelfSourceRow.\(source.rawValue)")
    }

    private func availableRow(_ source: BoundLibraryOnboardingSource) -> some View {
        HStack(spacing: 12) {
            sourceIcon(source)
            VStack(alignment: .leading, spacing: 3) {
                Text(sourceTitle(source))
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)
                Text(AppLocalized("登录后同步书架"))
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
            }
            Spacer()
            Button {
                activeConnection = source
            } label: {
                HStack(spacing: 6) {
                    Text(AppLocalized("连接"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.primaryText)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(AppTheme.mutedForeground)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("shelfSourcePrimaryAction.\(source.rawValue)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelfSourceRow.\(source.rawValue)")
        .accessibilityValue(AppLocalized("未绑定"))
    }

    private func sourceIdentity(
        _ source: BoundLibraryOnboardingSource,
        connected: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            sourceIcon(source)

            VStack(alignment: .leading, spacing: 3) {
                Text(sourceTitle(source))
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)
                Text(sourceDetail(source))
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
                    .lineLimit(2)
                Text(String(format: AppLocalized("已同步 %d 本书。"), bookCount(source)))
                    .font(.caption)
                    .foregroundColor(lastError(source) == nil ? AppTheme.primary : AppTheme.destructive)
                if let error = lastError(source) {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(AppTheme.destructive)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(connected ? AppLocalized("已绑定") : AppLocalized("未绑定"))
                .font(.caption.weight(.semibold))
                .foregroundColor(connected ? AppTheme.primary : AppTheme.mutedForeground)
        }
    }

    private func sourceIcon(_ source: BoundLibraryOnboardingSource) -> some View {
        Image(systemName: sourceIconName(source))
            .font(.system(size: 19, weight: .semibold))
            .foregroundColor(AppTheme.primary)
            .frame(width: 42, height: 42)
            .background(
                AppTheme.primary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
    }

    private var orderedSources: [BoundLibraryOnboardingSource] {
        let selected = appLanguage.selectedLanguage
        let languageCode = selected == .system
            ? Locale.autoupdatingCurrent.language.languageCode?.identifier
            : selected.rawValue
        let preferred: [BoundLibraryOnboardingSource]
        if languageCode?.lowercased().hasPrefix("zh") == true {
            preferred = [.kindle, .weread, .googleBooks, .kobo, .oreilly]
        } else {
            preferred = [.kindle, .googleBooks, .kobo, .oreilly, .weread]
        }
        // 中国大陆版把微信读书排到第一，其余书库仍全部保留。按发行区域排序，
        // 不按界面语言，所以界面是中文的海外用户不受影响。
        let available = AppRegion.current.availableBoundLibraries
        let availableSet = Set(available)
        if AppRegion.current == .cn {
            // 直接采用区域给出的顺序：微信读书在前，其余按可用性排在后面。
            return available
        }
        return preferred.filter(availableSet.contains)
    }

    private var connectedSources: [BoundLibraryOnboardingSource] {
        orderedSources.filter(isConnected)
    }

    private var availableSources: [BoundLibraryOnboardingSource] {
        orderedSources.filter { !isConnected($0) }
    }

    private func isConnected(_ source: BoundLibraryOnboardingSource) -> Bool {
        switch source {
        case .kindle: return !kindleStore.needsConnection
        case .weread: return !weReadStore.needsConnection
        case .googleBooks: return !googleBooksStore.needsConnection
        case .kobo: return !koboStore.needsConnection
        case .oreilly: return !oreillyStore.needsConnection
        }
    }

    private func bookCount(_ source: BoundLibraryOnboardingSource) -> Int {
        switch source {
        case .kindle: return kindleStore.boundBooks.count
        case .weread: return weReadStore.books.count
        case .googleBooks: return googleBooksStore.books.count
        case .kobo: return koboStore.books.count
        case .oreilly: return oreillyStore.books.count
        }
    }

    private func sourceTitle(_ source: BoundLibraryOnboardingSource) -> String {
        switch source {
        case .kindle: return "Kindle"
        case .weread: return AppLocalized("微信读书")
        case .googleBooks: return AppLocalized("Google Play 图书")
        case .kobo: return "Kobo"
        case .oreilly: return "O’Reilly Learning"
        }
    }

    private func sourceIconName(_ source: BoundLibraryOnboardingSource) -> String {
        switch source {
        case .kindle: return "books.vertical.fill"
        case .weread: return "book.closed.fill"
        case .googleBooks: return "book.pages.fill"
        case .kobo: return "book.closed.fill"
        case .oreilly: return "text.book.closed.fill"
        }
    }

    private func sourceDetail(_ source: BoundLibraryOnboardingSource) -> String {
        switch source {
        case .kindle:
            return "\(kindleStore.boundStorefront.flag) \(kindleStore.boundStorefront.displayName) · \(kindleStore.boundAccountDisplayName)"
        case .weread:
            return weReadStore.accountLabel ?? AppLocalized("微信读书账号")
        case .googleBooks:
            return googleBooksStore.accountLabel ?? AppLocalized("已登录")
        case .kobo:
            return koboStore.accountLabel ?? AppLocalized("已登录")
        case .oreilly:
            return oreillyStore.accountLabel ?? AppLocalized("已登录")
        }
    }

    private func lastError(_ source: BoundLibraryOnboardingSource) -> String? {
        let value: String?
        switch source {
        case .kindle: value = kindleStore.lastError
        case .weread: value = weReadStore.lastError
        case .googleBooks: value = googleBooksStore.lastError
        case .kobo: value = koboStore.lastError
        case .oreilly: value = oreillyStore.lastError
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    @ViewBuilder
    private func libraryView(_ source: BoundLibraryOnboardingSource) -> some View {
        switch source {
        case .kindle: KindleLibraryView()
        case .weread: WeReadLibraryView()
        case .googleBooks: GoogleBooksLibraryView()
        case .kobo: KoboLibraryView()
        case .oreilly: OReillyLibraryView()
        }
    }

    @ViewBuilder
    private func connectionView(_ source: BoundLibraryOnboardingSource) -> some View {
        switch source {
        case .kindle: KindleLibraryConnectView()
        case .weread: WeReadLibraryConnectView()
        case .googleBooks: GoogleBooksLibraryConnectView()
        case .kobo: KoboLibraryConnectView()
        case .oreilly: OReillyLibraryConnectView()
        }
    }

    private var disconnectTitle: String {
        guard let source = pendingDisconnect else {
            return AppLocalized("解除绑定")
        }
        switch source {
        case .kindle:
            return AppLocalized("解绑 Kindle？")
        case .weread:
            return AppLocalized("解除微信读书绑定？")
        case .googleBooks:
            return AppLocalized("解除 Google Play 图书绑定？")
        case .kobo:
            return AppLocalized("解除 Kobo 绑定？")
        case .oreilly:
            return AppLocalized("解除 O’Reilly 绑定？")
        }
    }

    private var disconnectMessage: String {
        guard let source = pendingDisconnect else { return "" }
        switch source {
        case .googleBooks, .kobo, .oreilly:
            return AppLocalized("只清除 CastReader 中对应平台的书架和阅读进度；共享网页登录状态会保留。")
        case .kindle, .weread:
            return AppLocalized("解除绑定只会清除 CastReader 中对应平台的本地数据，不会影响原平台账号或书籍。")
        }
    }

    private func disconnect(_ source: BoundLibraryOnboardingSource) {
        pendingDisconnect = nil
        Task { @MainActor in
            switch source {
            case .kindle:
                KindlePlaybackCenter.shared.close()
                await kindleStore.disconnectAccount()
            case .weread:
                await weReadStore.disconnectAccount()
            case .googleBooks:
                await googleBooksStore.disconnectAccount()
            case .kobo:
                await koboStore.disconnectAccount()
            case .oreilly:
                await oreillyStore.disconnectAccount()
            }
        }
    }
}
