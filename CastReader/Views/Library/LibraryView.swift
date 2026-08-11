//
//  LibraryView.swift
//  CastReader
//
//  文库 = 本地历史记录：处理/朗读/解读/粘贴过的所有内容在此留存。
//  支持「按来源类型筛选（默认全部）+ 标题/网址搜索 + 重开 + 删除 + 清除」。
//  **纯本地、不上云**（见 HistoryStore）。
//

import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @EnvironmentObject private var importRouter: ImportRouter
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var cloudStorage = CloudStorageCenter.shared
    @State private var opening = false
    @State private var openingMessage = ""
    @State private var openingProgress: CloudHistoryReopenProgress?
    @State private var openingTask: Task<Void, Never>?
    @State private var openingAttemptID: UUID?
    @State private var notice: String?
    @State private var cloudFailure: CloudHistoryFailurePresentation?
    @State private var searchText = ""
    @State private var selectedKind: ReadingSourceKind? = nil   // nil = 全部

    // 类型筛选固定展示顺序（只展示实际出现过的类型）。
    static let kindOrder: [ReadingSourceKind] = [
        .youtube, .web, .pdf, .docx, .epub, .kindle, .weread, .googleBooks, .kobo,
        .photo, .text,
    ]

    private var availableKinds: [ReadingSourceKind] {
        let present = Set(history.visibleRecords.map { $0.sourceKind })
        return Self.kindOrder.filter { present.contains($0) }
    }

    /// 当前筛选 + 搜索后的记录（records 已按 lastOpenedAt 倒序）。
    private var filtered: [HistoryRecord] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return history.visibleRecords.filter { rec in
            let kindOK = selectedKind == nil || rec.sourceKind == selectedKind
            let textOK = q.isEmpty
                || rec.title.localizedCaseInsensitiveContains(q)
                || (rec.sourceURL?.localizedCaseInsensitiveContains(q) ?? false)
            return kindOK && textOK
        }
    }

    // 作为「设置」里的二级页被 push（不自带 NavigationView，复用设置页的导航栈）。
    var body: some View {
        content
            .navigationTitle("文库")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或网址")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(destination: LibrarySourcesView()) {
                        Image(systemName: "books.vertical")
                    }
                    .accessibilityLabel(AppLocalized("管理书架来源"))
                    .accessibilityIdentifier("librarySourcesToolbarButton")
                }
            }
            .alert(
                CloudLocalized("提示"),
                isPresented: Binding(
                    get: { notice != nil },
                    set: { if !$0 { notice = nil } }
                )
            ) {
                Button(CloudLocalized("好"), role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
            .confirmationDialog(
                CloudLocalized("提示"),
                isPresented: Binding(
                    get: { cloudFailure != nil },
                    set: { if !$0 { cloudFailure = nil } }
                ),
                titleVisibility: .visible,
                presenting: cloudFailure
            ) { failure in
                switch failure.recovery {
                case .reconnect(let forceAccountSelection):
                    Button(CloudLocalized("连接云盘")) {
                        cloudFailure = nil
                        importRouter.reconnectCloud(
                            failure.record.origin?.provider ?? .unavailableA,
                            forceAccountSelection: forceAccountSelection,
                            expectedAccount: failure.record.origin.map {
                                CloudAccount(
                                    provider: $0.provider,
                                    stableAccountKey: $0.accountKey,
                                    maskedEmail: $0.maskedAccountHint
                                )
                            }
                        )
                    }
                case .removeRecord:
                    Button(CloudLocalized("从文库移除此记录"), role: .destructive) {
                        history.delete(failure.record.id)
                        cloudFailure = nil
                    }
                case .retry:
                    Button(CloudLocalized("重试")) {
                        cloudFailure = nil
                        open(failure.record)
                    }
                case .dismiss:
                    EmptyView()
                }
                Button(CloudLocalized("取消"), role: .cancel) { cloudFailure = nil }
            } message: { failure in
                Text(failure.message)
            }
            .task {
                guard Constants.Features.cloudStorageEnabled else { return }
                await cloudStorage.refreshConnectionStates()
            }
            .onDisappear {
                cancelOpening()
            }
    }

    @ViewBuilder
    private var content: some View {
        if history.visibleRecords.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if availableKinds.count > 1 { categoryBar }
                if filtered.isEmpty {
                    noResultState
                } else {
                    listView
                }
            }
            .background(AppTheme.background)
        }
    }

    // MARK: - 列表

    private var listView: some View {
        List {
            Section {
                ForEach(filtered) { rec in
                    Button { open(rec) } label: {
                        HistoryRow(
                            record: rec,
                            connectionState: rec.origin.map {
                                cloudStorage.state(for: $0.provider)
                            },
                            providerIsConfigured: rec.origin.map {
                                cloudStorage.isConfigured($0.provider)
                            } ?? true
                        )
                    }
                        .buttonStyle(.plain)
                        .disabled(opening)
                }
                .onDelete { offsets in
                    offsets.map { filtered[$0].id }.forEach { history.delete($0) }
                }
            } footer: {
                if Constants.Features.cloudStorageEnabled {
                    Label(
                        CloudLocalized("原文件仅下载到本机临时目录，不会上传到 CastReader 云端"),
                        systemImage: "lock.shield"
                    )
                        .font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if opening {
                VStack(spacing: 10) {
                    if case .downloading(let progress) = openingProgress,
                       let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                            .frame(maxWidth: 220)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.mutedForeground)
                    } else {
                        ProgressView().scaleEffect(1.15)
                    }
                    if !openingMessage.isEmpty {
                        Text(openingMessage)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedForeground)
                    }
                    if openingProgress != nil {
                        Button(CloudLocalized("取消"), role: .cancel) {
                            cancelOpening()
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - 分类筛选条

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(title: AppLocalized("全部"), count: history.visibleRecords.count, kind: nil)
                ForEach(availableKinds, id: \.self) { k in
                    categoryChip(title: label(k), count: history.visibleRecords.filter { $0.sourceKind == k }.count, kind: k)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(AppTheme.background)
    }

    private func categoryChip(title: String, count: Int, kind: ReadingSourceKind?) -> some View {
        let selected = selectedKind == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedKind = kind }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Text("\(count)").font(.caption.weight(.semibold))
                    .foregroundColor(selected ? .white.opacity(0.85) : AppTheme.mutedForeground)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? AppTheme.primary : AppTheme.primary.opacity(0.1))
            .foregroundColor(selected ? .white : AppTheme.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func label(_ k: ReadingSourceKind) -> String {
        switch k {
        case .web: return AppLocalized("网页")
        case .pdf: return "PDF"
        case .docx: return "DOCX"
        case .epub: return "EPUB"
        case .kindle: return "Kindle"
        case .weread: return "微信读书"
        case .googleBooks: return "Google Play"
        case .kobo: return "Kobo"
        case .oreilly: return "O’Reilly"
        case .youtube: return "YouTube"
        case .photo: return AppLocalized("图片")
        case .text: return AppLocalized("文本")
        }
    }

    // MARK: - 空态

    private var noResultState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(AppTheme.mutedForeground)
            Text(searchText.isEmpty
                 ? LocalizedStringKey("该分类暂无记录")
                 : LocalizedStringKey("未找到匹配「\(searchText)」的记录"))
                .font(.subheadline).foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 48)).foregroundColor(AppTheme.mutedForeground)
            Text("还没有历史记录").font(.headline).foregroundColor(AppTheme.mutedForeground)
            Text("在首页拍摄、上传、输入网址或文本，处理过的内容会出现在这里")
                .font(.subheadline).foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Label("仅保存在本机，不上传云端", systemImage: "lock.shield")
                .font(.caption).foregroundColor(AppTheme.mutedForeground).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }

    private func open(_ rec: HistoryRecord) {
        guard !opening else { return }
        if rec.sourceKind == .youtube {
            guard let sourceURL = rec.sourceURL,
                  YouTubeRouteCenter.shared.open(
                    sourceURL,
                    entry: .history
                  ) else {
                notice = AppLocalized("这不是有效的 YouTube 视频链接")
                return
            }
            // MainTabView owns the unified cache/progress/quota route. Keeping
            // Library on that route avoids a second, non-resuming reader path.
            return
        }
        openingTask?.cancel()
        let attemptID = UUID()
        openingAttemptID = attemptID
        opening = true
        openingProgress = rec.requiresRemoteReopen ? .validatingAccount : nil
        openingMessage = rec.requiresRemoteReopen
            ? CloudLocalized("正在连接账号…")
            : ""
        openingTask = Task { @MainActor in
            defer {
                if openingAttemptID == attemptID {
                    opening = false
                    openingMessage = ""
                    openingProgress = nil
                    openingTask = nil
                    openingAttemptID = nil
                }
            }
            let context = ProductAnalytics.shared.beginContentIntent(
                source: .history,
                format: AnalyticsContentFormat(rec.sourceKind),
                entryPoint: "library_history_reopen",
                intendedMode: "read"
            )
            if rec.requiresRemoteReopen {
                do {
                    let result = try await CloudHistoryReopenService().reopen(
                        rec,
                        mode: .read,
                        analyticsContext: context
                    ) { progress in
                        Task { @MainActor in
                            guard openingAttemptID == attemptID else { return }
                            openingProgress = progress
                            openingMessage = cloudHistoryProgressLabel(progress)
                        }
                    }
                    guard !Task.isCancelled,
                          openingAttemptID == attemptID else { return }
                    coordinator.open(result.document, analyticsContext: context)
                    if CloudHistoryFailurePresentation.contentChanged(
                        record: rec,
                        result: result
                    ) {
                        notice = CloudLocalized("云端文件已更新，已加载最新版本")
                    }
                } catch {
                    guard !Task.isCancelled,
                          openingAttemptID == attemptID else { return }
                    cloudFailure = CloudHistoryFailurePresentation.make(
                        record: rec,
                        error: error
                    )
                }
                return
            }

            do {
                if let doc = try await history.reopen(rec) {
                    guard !Task.isCancelled,
                          openingAttemptID == attemptID else { return }
                    coordinator.open(doc, analyticsContext: context)
                }
            } catch is CancellationError {
                return
            } catch {
                guard openingAttemptID == attemptID else { return }
                notice = error.localizedDescription
            }
        }
    }

    private func cancelOpening() {
        openingTask?.cancel()
        openingTask = nil
        openingAttemptID = nil
        opening = false
        openingMessage = ""
        openingProgress = nil
    }

    private func cloudHistoryProgressLabel(_ progress: CloudHistoryReopenProgress) -> String {
        switch progress {
        case .validatingAccount:
            return CloudLocalized("正在连接账号…")
        case .downloading:
            return CloudLocalized("正在下载…")
        case .importing(let value):
            switch value.stage {
            case .checkingFile: return CloudLocalized("正在检查文件…")
            case .parsing(.pdf): return CloudLocalized("正在解析 PDF…")
            case .parsing(.docx): return CloudLocalized("正在解析 Word…")
            case .parsing(.epub): return CloudLocalized("正在解析 EPUB…")
            case .parsing(.text): return CloudLocalized("正在准备阅读器…")
            case .preparingReader: return CloudLocalized("正在准备阅读器…")
            }
        }
    }

}

// MARK: - History Row

private struct HistoryRow: View {
    let record: HistoryRecord
    let connectionState: CloudConnectionState?
    let providerIsConfigured: Bool

    var body: some View {
        HStack(spacing: 14) {
            CoverThumbnail(record: record, cornerRadius: 8)
                .frame(width: 48, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.foreground).lineLimit(2)
                Text("\(sourceLabel) · \(relativeTime)").font(.caption).foregroundColor(AppTheme.mutedForeground)
                if let remoteStatus {
                    Text(remoteStatus)
                        .font(.caption2)
                        .foregroundColor(remoteStatusColor)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.mutedForeground.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var sourceLabel: String {
        let format: String = switch record.sourceKind {
        case .web: AppLocalized("网页")
        case .pdf: "PDF"
        case .docx: "DOCX"
        case .epub: "EPUB"
        case .kindle: "Kindle"
        case .weread: "微信读书"
        case .googleBooks: "Google Play"
        case .kobo: "Kobo"
        case .oreilly: "O’Reilly"
        case .youtube: "YouTube"
        case .photo: AppLocalized("图片")
        case .text: AppLocalized("文本")
        }
        if let provider = record.origin?.provider {
            return "\(provider.displayName) · \(format)"
        }
        return format
    }

    private var remoteStatus: String? {
        guard let origin = record.origin else { return nil }
        let hint = origin.maskedAccountHint
        guard providerIsConfigured else {
            return [hint, CloudLocalized("暂不可用")].compactMap { $0 }.joined(separator: " · ")
        }
        let stateText: String? = switch connectionState {
        case .some(.connected(let account)) where account.stableAccountKey == origin.accountKey:
            nil
        case .some(.connecting):
            CloudLocalized("正在连接…")
        case .some(.needsReauthorization):
            CloudLocalized("需要重新连接")
        case .some(.connected), .some(.disconnected), .none:
            CloudLocalized("需连接原账号")
        }
        let combined = [hint, stateText].compactMap { $0 }.joined(separator: " · ")
        return combined.isEmpty ? nil : combined
    }

    private var remoteStatusColor: Color {
        guard let origin = record.origin else { return AppTheme.mutedForeground }
        if case .some(.connected(let account)) = connectionState,
           account.stableAccountKey == origin.accountKey {
            return AppTheme.mutedForeground
        }
        return AppTheme.primaryText
    }

    /// 「多久前读过」：短时间走本地化相对文案，较久日期交给当前 Locale 格式化。
    private var relativeTime: String { Self.relative(record.lastOpenedAt) }

    static func relative(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return AppLocalized("刚刚") }                       // 含时钟漂移/未来（s<0）兜底
        if s < 3600 { return AppLocalized("\(Int(s / 60)) 分钟前") }
        if s < 86_400 { return AppLocalized("\(Int(s / 3600)) 小时前") }
        if s < 86_400 * 2 { return AppLocalized("昨天") }
        if s < 86_400 * 7 { return AppLocalized("\(Int(s / 86_400)) 天前") }
        let dateStyle: Date.FormatStyle.DateStyle = s < 86_400 * 365 ? .abbreviated : .numeric
        return date.formatted(
            Date.FormatStyle(date: dateStyle, time: .omitted)
                .locale(.current)
        )
    }
}

// MARK: - Document Row（后端文档卡片，保留供潜在引用；文库主列表已改为本地历史）

struct DocumentRow: View {
    let document: Document
    var isLoading: Bool = false

    private var thumbnailURL: URL? {
        guard let thumbnail = document.thumbnail, !thumbnail.isEmpty,
              let encoded = thumbnail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = thumbnailURL {
                    CachedAsyncImage(url: url) { thumbnailPlaceholder }
                } else {
                    thumbnailPlaceholder
                }
            }
            .frame(width: 50, height: 65)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(document.name).font(.headline).lineLimit(2)
                HStack(spacing: 8) {
                    if let wordCount = document.wordCount {
                        Text("\(wordCount) words").font(.caption).foregroundColor(AppTheme.mutedForeground)
                    }
                    if let chapterCount = document.chapterCount, chapterCount > 0 {
                        Text("\(chapterCount) chapters").font(.caption).foregroundColor(AppTheme.mutedForeground)
                    }
                }
                if let status = document.processingStatus, !status.isReady {
                    Text(status.displayText)
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(statusColor(for: status).opacity(0.2))
                        .foregroundColor(statusColor(for: status))
                        .cornerRadius(4)
                }
            }
            Spacer()
            if isLoading { ProgressView() }
        }
        .padding(.vertical, 4)
    }

    private var thumbnailPlaceholder: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: gradientColors(for: document.name), startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(document.name)
                .font(.system(size: 8)).fontWeight(.semibold).foregroundColor(.white)
                .lineLimit(2).padding(4)
        }
    }

    private func gradientColors(for name: String) -> [Color] {
        let gradients: [[Color]] = [
            [Color(red: 251/255, green: 113/255, blue: 133/255), Color(red: 253/255, green: 186/255, blue: 116/255)],
            [Color(red: 96/255, green: 165/255, blue: 250/255), Color(red: 129/255, green: 140/255, blue: 248/255)],
            [Color(red: 52/255, green: 211/255, blue: 153/255), Color(red: 34/255, green: 211/255, blue: 238/255)],
            [Color(red: 252/255, green: 211/255, blue: 77/255), Color(red: 234/255, green: 179/255, blue: 8/255)],
            [Color(red: 217/255, green: 70/255, blue: 239/255), Color(red: 236/255, green: 72/255, blue: 153/255)],
        ]
        var hash = 0
        for char in name.unicodeScalars { hash = Int(char.value) &+ ((hash << 5) &- hash) }
        return gradients[abs(hash) % gradients.count]
    }

    private func statusColor(for status: ProcessingStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .processing: return AppTheme.primary
        case .completed: return .green
        case .failed: return .red
        }
    }
}
