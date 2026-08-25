//
//  CloudStorageViews.swift
//  CastReader
//

import SwiftUI

struct CloudStorageFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var model: CloudStorageFlowViewModel
    @State private var showsAccountMenu = false
    @State private var showsDisconnectConfirmation = false
    @State private var showsSwitchConfirmation = false
    @State private var notice: String?
    @State private var disconnectRecovery: CloudDisconnectResult?

    private let onComplete: (DocumentImportResult) -> Void
    private let onCancel: () -> Void

    init(
        provider: CloudProviderID,
        scenario: ExplainContentType?,
        mode: ReaderMode,
        analyticsContext: AnalyticsContentContext?,
        forceAccountSelection: Bool = false,
        showsDisclosureOnStart: Bool = false,
        privacyReviewOnly: Bool = false,
        expectedAccount: CloudAccount? = nil,
        onComplete: @escaping (DocumentImportResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: CloudStorageFlowViewModel(
            provider: provider,
            scenario: scenario,
            mode: mode,
            analyticsContext: analyticsContext,
            forceAccountSelection: forceAccountSelection,
            showsDisclosureOnStart: showsDisclosureOnStart,
            privacyReviewOnly: privacyReviewOnly,
            expectedAccount: expectedAccount
        ))
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationView {
            content
                .navigationTitle(model.provider.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(model.stage.blocksBrowser || model.switchCandidate != nil)
        .task { model.start() }
        .onDisappear { model.viewDidDisappear() }
        .onChange(of: model.importedResult?.contentSessionKey) { _, _ in
            guard let result = model.importedResult else { return }
            onComplete(result)
        }
        .onChange(of: model.didCancel) { _, cancelled in
            guard cancelled else { return }
            dismiss()
            onCancel()
        }
        .onChange(of: model.didFinishPrivacyReview) { _, finished in
            guard finished else { return }
            dismiss()
        }
        .onChange(of: model.switchCandidate) { _, candidate in
            showsSwitchConfirmation = candidate != nil
        }
        .confirmationDialog(
            CloudLocalized("选择导出格式"),
            isPresented: Binding(
                get: { model.exportPromptItem != nil },
                set: { if !$0 { model.exportPromptItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = model.exportPromptItem {
                ForEach(item.exportOptions, id: \.rawValue) { format in
                    Button(exportTitle(format)) {
                        model.importExport(format, item: item)
                    }
                }
            }
            Button(CloudLocalized("取消"), role: .cancel) { model.exportPromptItem = nil }
        } message: {
            Text(CloudLocalized("云端文档会在设备上导出后进入现有阅读器"))
        }
        .alert(
            CloudLocalized("不支持此格式"),
            isPresented: Binding(
                get: { model.unsupportedItem != nil },
                set: { if !$0 { model.dismissUnsupportedItem() } }
            )
        ) {
            Button(CloudLocalized("好"), role: .cancel) {
                model.dismissUnsupportedItem()
            }
        } message: {
            Text(CloudLocalized("此文件暂时无法朗读或解读"))
        }
        .alert(
            CloudLocalized("确认更换账号？"),
            isPresented: $showsSwitchConfirmation
        ) {
            Button(CloudLocalized("继续使用当前账号"), role: .cancel) {
                model.cancelAccountSwitch()
            }
            Button(CloudLocalized("确认更换")) {
                model.confirmAccountSwitch()
            }
        } message: {
            Text(model.accountSwitchMessage)
        }
        .confirmationDialog(
            CloudLocalized("账号操作"),
            isPresented: $showsAccountMenu,
            titleVisibility: .visible
        ) {
            Button(CloudLocalized("更换账号")) { model.switchAccount() }
            Button(CloudLocalized("查看数据使用说明")) { model.showDisclosureAgain() }
            Button(CloudLocalized("解除关联"), role: .destructive) { showsDisconnectConfirmation = true }
            Button(CloudLocalized("取消"), role: .cancel) {}
        }
        .alert(CloudLocalized("解除关联？"), isPresented: $showsDisconnectConfirmation) {
            Button(CloudLocalized("取消"), role: .cancel) {}
            Button(CloudLocalized("解除关联"), role: .destructive) {
                Task {
                    let result = await model.disconnect()
                    disconnectRecovery = result.remoteRevocationStatus == .unconfirmed
                        ? result
                        : nil
                    notice = disconnectMessage(result)
                }
            }
        } message: {
            Text(CloudLocalized("这会删除本机保存的授权关联并取消当前操作；阅读历史基础信息会保留。"))
        }
        .alert(
            CloudLocalized("提示"),
            isPresented: Binding(
                get: { notice != nil },
                set: {
                    if !$0 {
                        notice = nil
                        disconnectRecovery = nil
                    }
                }
            )
        ) {
            if let recovery = disconnectRecovery,
               recovery.provider == .googleDrive,
               recovery.remoteRevocationStatus == .unconfirmed {
                if recovery.retryable {
                    Button(CloudLocalized("重试")) {
                        retryGoogleRevocation()
                    }
                }
                Button(CloudLocalized("在 Google 账号中管理授权")) {
                    if let url = URL(string: "https://myaccount.google.com/connections") {
                        openURL(url)
                    }
                }
            }
            Button(CloudLocalized("好"), role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .disclosure:
            CloudPrivacyDisclosureView(
                provider: model.provider,
                isReviewOnly: model.disclosureIsReviewOnly,
                onContinue: model.acceptDisclosure,
                onCancel: {
                    dismiss()
                    onCancel()
                }
            )
        case .browsing:
            CloudFileBrowserView(model: model)
        case .failed(let failure):
            CloudFlowErrorView(
                provider: model.provider,
                failure: failure,
                onRetry: model.retry,
                onClose: {
                    dismiss()
                    onCancel()
                }
            )
        default:
            CloudImportProgressView(
                provider: model.provider,
                stage: model.stage,
                progress: model.downloadProgress,
                filename: model.currentFilename,
                onCancel: model.cancel
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                model.cancel()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text(CloudLocalized("关闭")))
        }
        if model.account != nil, model.stage == .browsing {
            if let selectedDrive = model.selectedDrive {
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(model.drives) { drive in
                            Button {
                                model.selectDrive(drive)
                            } label: {
                                if drive.id == selectedDrive.id {
                                    Label(drive.name, systemImage: "checkmark")
                                } else {
                                    Text(drive.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            CloudProviderIcon(provider: model.provider, size: 24)
                            Text(selectedDrive.name)
                                .font(.headline)
                                .lineLimit(1)
                            if model.drives.count > 1 {
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                    }
                    .disabled(model.drives.count < 2)
                    .accessibilityLabel(
                        Text(
                            String(
                                format: CloudLocalized("切换云盘，当前 %@"),
                                selectedDrive.name
                            )
                        )
                    )
                }
            } else {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        CloudProviderIcon(provider: model.provider, size: 24)
                        Text(model.provider.displayName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showsAccountMenu = true } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(
                    Text(
                        String(
                            format: CloudLocalized("%@ 账号操作"),
                            model.provider.displayName
                        )
                    )
                )
            }
        }
    }

    private func exportTitle(_ format: CloudExportFormat) -> String {
        switch format {
        case .pdf: return "PDF"
        case .docx: return CloudLocalized("Word（DOCX）")
        }
    }

    private func disconnectMessage(_ result: CloudDisconnectResult) -> String {
        switch result.remoteRevocationStatus {
        case .confirmed:
            return CloudLocalized("账号关联及云盘授权已解除")
        case .unconfirmed:
            return CloudLocalized("已从此设备断开；云盘端授权暂未确认撤销，可稍后在云盘账号设置中检查")
        case .unsupported:
            return CloudLocalized("已从此设备断开")
        }
    }

    private func retryGoogleRevocation() {
        notice = nil
        disconnectRecovery = nil
        Task {
            let result = await CloudStorageCenter.shared
                .retryPendingRemoteRevocation(for: .googleDrive)
            disconnectRecovery = result.remoteRevocationStatus == .unconfirmed
                ? result
                : nil
            notice = disconnectMessage(result)
        }
    }
}

struct CloudStorageProviderRow: View {
    let provider: CloudProviderID
    let state: CloudConnectionState
    let isConfigured: Bool
    let onOpen: () -> Void
    let onSwitchAccount: () -> Void
    let onDisconnect: () -> Void
    let onShowPrivacy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    CloudProviderIcon(provider: provider, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.foreground)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(subtitleColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if case .connecting = state {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(AppTheme.mutedForeground.opacity(0.65))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isConfigured || isConnecting)

            if isConnected {
                Menu {
                    Button(CloudLocalized("更换账号"), action: onSwitchAccount)
                    Button(CloudLocalized("查看数据使用说明"), action: onShowPrivacy)
                    Button(CloudLocalized("解除关联"), role: .destructive, action: onDisconnect)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.mutedForeground)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(
                    Text(
                        String(
                            format: CloudLocalized("%@ 账号操作"),
                            provider.displayName
                        )
                    )
                )
            }
        }
        .padding(14)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
        )
        .accessibilityIdentifier("cloudProvider.\(provider.rawValue)")
    }

    private var subtitle: String {
        guard isConfigured else { return CloudLocalized("暂不可用") }
        switch state {
        case .disconnected: return CloudLocalized("未连接")
        case .connecting: return CloudLocalized("正在连接…")
        case .needsReauthorization: return CloudLocalized("需要重新连接")
        case .connected(let account):
            return account.maskedEmail ?? account.displayName ?? CloudLocalized("已连接")
        }
    }

    private var subtitleColor: Color {
        if !isConfigured { return AppTheme.mutedForeground }
        if case .needsReauthorization = state { return AppTheme.primaryText }
        return AppTheme.mutedForeground
    }

    private var isConnected: Bool {
        if case .connected = state { return true }
        if case .needsReauthorization = state { return true }
        return false
    }

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }
}

struct CloudProviderIcon: View {
    let provider: CloudProviderID
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            if provider == .googleDrive {
                GoogleDriveMark()
                    .padding(size * 0.16)
            } else {
                Image(systemName: "cloud.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(AppTheme.primary)
                    .padding(size * 0.23)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

}

/// Compact vector mark so the Drive browser is immediately recognizable
/// without depending on an image asset or a web-rendered provider page.
private struct GoogleDriveMark: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                polygon([
                    CGPoint(x: 0.44, y: 0.08),
                    CGPoint(x: 0.60, y: 0.08),
                    CGPoint(x: 0.91, y: 0.65),
                    CGPoint(x: 0.72, y: 0.65),
                ], width: width, height: height)
                .fill(Color(red: 0.20, green: 0.66, blue: 0.33))

                polygon([
                    CGPoint(x: 0.44, y: 0.08),
                    CGPoint(x: 0.09, y: 0.65),
                    CGPoint(x: 0.28, y: 0.65),
                    CGPoint(x: 0.53, y: 0.27),
                ], width: width, height: height)
                .fill(Color(red: 0.98, green: 0.73, blue: 0.04))

                polygon([
                    CGPoint(x: 0.09, y: 0.65),
                    CGPoint(x: 0.28, y: 0.65),
                    CGPoint(x: 0.72, y: 0.65),
                    CGPoint(x: 0.91, y: 0.65),
                    CGPoint(x: 0.80, y: 0.86),
                    CGPoint(x: 0.20, y: 0.86),
                ], width: width, height: height)
                .fill(Color(red: 0.26, green: 0.52, blue: 0.96))
            }
        }
    }

    private func polygon(
        _ points: [CGPoint],
        width: CGFloat,
        height: CGFloat
    ) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.x * width, y: first.y * height))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * width, y: point.y * height))
            }
            path.closeSubpath()
        }
    }
}

private struct CloudPrivacyDisclosureView: View {
    let provider: CloudProviderID
    let isReviewOnly: Bool
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    CloudProviderIcon(provider: provider, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            String(
                                format: CloudLocalized("连接 %@"),
                                provider.displayName
                            )
                        )
                            .font(.title3.weight(.bold))
                        Text(CloudLocalized("只读访问 · 原文件不上 CastReader 云端"))
                            .font(.subheadline)
                            .foregroundColor(AppTheme.mutedForeground)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    disclosureRow(
                        icon: "lock.shield.fill",
                        title: CloudLocalized("仅申请读取权限"),
                        detail: CloudLocalized("CastReader 不会在你的云盘中创建、修改、移动或删除文件。")
                    )
                    disclosureRow(
                        icon: "iphone.gen3",
                        title: CloudLocalized("文件只下载到这台设备"),
                        detail: CloudLocalized("支持的文档会进入临时目录并在本机校验、解析；不会上传到 CastReader 的文件存储。")
                    )
                    disclosureRow(
                        icon: "waveform.and.mic",
                        title: CloudLocalized("朗读或解读可能发送全文"),
                        detail: CloudLocalized("仅当你主动开始朗读或解读时，CastReader 才会发送在本机解析出的处理所需文本（可能覆盖所选文件全文）；原始文件不会发送到文件上传或存储接口。")
                    )
                    disclosureRow(
                        icon: "clock.arrow.circlepath",
                        title: CloudLocalized("历史只保存远程引用"),
                        detail: CloudLocalized("本机会保存脱敏账号提示、派生账号 key、云盘与文件 ID、文件名、格式和版本；保留到你删除记录或 App 数据。原文件不永久保存。")
                    )
                    disclosureRow(
                        icon: "trash",
                        title: CloudLocalized("删除与控制"),
                        detail: CloudLocalized("解除关联会立即删除可访问文件的本机关联；若 Google 撤销暂未确认，只在隔离的撤销队列保留旧令牌用于重试，CastReader 不会使用它获取文件，确认后删除。删除文库记录会删除远程引用。")
                    )
                }
                .padding(18)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 10) {
                    Button(action: onContinue) {
                        Text(isReviewOnly ? AppLocalized("完成") : CloudLocalized("继续连接"))
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button(CloudLocalized("取消"), action: onCancel)
                        .foregroundColor(AppTheme.mutedForeground)
                    if let privacyURL = URL(string: Constants.API.privacyURL) {
                        Link(
                            CloudLocalized("查看完整隐私政策"),
                            destination: privacyURL
                        )
                        .font(.footnote.weight(.semibold))
                    }
                }
            }
            .padding(22)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("cloudPrivacy.\(provider.rawValue)")
    }

    private func disclosureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppTheme.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CloudFileBrowserView: View {
    @ObservedObject var model: CloudStorageFlowViewModel

    var body: some View {
        List {
            if !model.isShowingSearchResults, !model.folderPath.isEmpty {
                breadcrumbSection
            }
            if model.folders.isEmpty && model.items.isEmpty && !model.isLoadingPage {
                ContentUnavailableView(
                    model.isShowingSearchResults
                        ? CloudLocalized("未找到匹配的文件")
                        : CloudLocalized("这个文件夹是空的"),
                    systemImage: model.isShowingSearchResults
                        ? "magnifyingglass"
                        : "folder"
                )
                .listRowBackground(Color.clear)
            }
            if !model.folders.isEmpty {
                Section(CloudLocalized("文件夹")) {
                    ForEach(model.folders) { folder in
                        Button { model.openFolder(folder) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(AppTheme.primary)
                                    .font(.title3)
                                Text(folder.name)
                                    .foregroundColor(AppTheme.foreground)
                                    .lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(AppTheme.mutedForeground)
                            }
                        }
                        .onAppear { model.loadNextPageIfNeeded(currentFolder: folder) }
                    }
                }
            }
            if !model.items.isEmpty {
                Section(CloudLocalized("文件")) {
                    ForEach(model.items) { item in
                        CloudFileRow(item: item) { model.choose(item) }
                            .onAppear { model.loadNextPageIfNeeded(currentItem: item) }
                    }
                }
            }
            if model.isLoadingPage {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
            Section {
                Label(
                    CloudLocalized("原文件仅下载到本机临时目录，不会上传到 CastReader 云端"),
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundColor(AppTheme.mutedForeground)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(CloudLocalized("搜索 Google Drive"))
        )
        .task(id: model.searchText) {
            let trimmed = model.searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            model.updateSearchResults(for: trimmed)
        }
        .accessibilityIdentifier("cloudBrowser.\(model.provider.rawValue)")
    }

    private var breadcrumbSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Button(CloudLocalized("根目录")) { model.navigateToFolder(at: nil) }
                    ForEach(Array(model.folderPath.enumerated()), id: \.element.id) { index, folder in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(AppTheme.mutedForeground)
                        Button(folder.name) { model.navigateToFolder(at: index) }
                    }
                }
                .font(.caption.weight(.semibold))
            }
        }
    }
}

private struct CloudFileRow: View {
    let item: CloudItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(AppTheme.foreground)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cloudFile.\(item.id)")
    }

    private var isSupported: Bool {
        item.kind == .file || item.kind == .exportableDocument
    }

    private var icon: String {
        if item.kind == .exportableDocument { return "doc.text.fill" }
        switch SupportedDocumentFormat(fileExtension: URL(fileURLWithPath: item.name).pathExtension) {
        case .pdf: return "doc.richtext.fill"
        case .docx: return "doc.text.fill"
        case .epub: return "book.closed.fill"
        case .text: return "doc.plaintext.fill"
        case nil: return "doc.fill"
        }
    }

    private var detail: String {
        guard isSupported else { return CloudLocalized("不支持此格式") }
        var parts: [String] = []
        if item.kind == .exportableDocument { parts.append(CloudLocalized("可导出")) }
        if let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modifiedAt = item.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? CloudLocalized("可朗读与解读") : parts.joined(separator: " · ")
    }
}

private struct CloudImportProgressView: View {
    let provider: CloudProviderID
    let stage: CloudStorageFlowViewModel.Stage
    let progress: CloudDownloadProgress?
    let filename: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            CloudProviderIcon(provider: provider, size: 58)
            VStack(spacing: 8) {
                Text(stageTitle)
                    .font(.headline)
                if let filename {
                    Text(filename)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(2)
                }
            }
            Group {
                if let fraction = progress?.fractionCompleted {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(AppTheme.mutedForeground)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .frame(maxWidth: 260)
            Text(CloudLocalized("原文件只在本机临时处理"))
                .font(.caption)
                .foregroundColor(AppTheme.mutedForeground)
            Button(CloudLocalized("取消"), role: .cancel, action: onCancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(AppTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("cloudImportProgress")
    }

    private var stageTitle: String {
        switch stage {
        case .authorizing, .confirmingAccountSwitch:
            return CloudLocalized("正在连接账号…")
        case .gettingFileInfo: return CloudLocalized("正在获取文件信息…")
        case .downloading: return CloudLocalized("正在下载…")
        case .checkingFile: return CloudLocalized("正在检查文件…")
        case .parsing(let format):
            switch format {
            case .pdf: return CloudLocalized("正在解析 PDF…")
            case .docx: return CloudLocalized("正在解析 Word…")
            case .epub: return CloudLocalized("正在解析 EPUB…")
            case .text: return CloudLocalized("正在准备阅读器…")
            }
        case .preparingReader: return CloudLocalized("正在准备阅读器…")
        case .disclosure, .browsing, .failed: return CloudLocalized("正在处理…")
        }
    }
}

private struct CloudFlowErrorView: View {
    let provider: CloudProviderID
    let failure: CloudFlowFailurePresentation
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            CloudProviderIcon(provider: provider, size: 56)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundColor(.orange)
            Text(failure.message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(AppTheme.foreground)
                .accessibilityIdentifier("cloudFlowFailureMessage")
            if failure.showsRetry {
                Button(
                    failure.recovery == .reconnect
                        ? CloudLocalized("重新连接")
                        : CloudLocalized("重试"),
                    action: onRetry
                )
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cloudFlowRetryButton")
            }
            Button(CloudLocalized("关闭"), action: onClose)
                .foregroundColor(AppTheme.mutedForeground)
                .accessibilityIdentifier("cloudFlowCloseButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .background(AppTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("cloudFlowError")
    }
}

/// One recovery contract is shared by Home, Library and system Continue so a
/// remote-reference failure never silently falls back to an unrelated import.
struct CloudHistoryFailurePresentation: Identifiable {
    enum Recovery: Equatable {
        case reconnect(forceAccountSelection: Bool)
        case removeRecord
        case retry
        case dismiss
    }

    let id = UUID()
    let record: HistoryRecord
    let message: String
    let recovery: Recovery

    static func make(record: HistoryRecord, error: Error) -> CloudHistoryFailurePresentation? {
        if error is CancellationError { return nil }
        if let importError = error as? DocumentImportError {
            switch importError {
            case .cancelled:
                return nil
            case .resourceLimitExceeded(.insufficientDeviceStorage):
                return CloudHistoryFailurePresentation(
                    record: record,
                    message: CloudLocalized("设备可用空间不足，无法下载此文件"),
                    recovery: .dismiss
                )
            case .resourceLimitExceeded:
                return CloudHistoryFailurePresentation(
                    record: record,
                    message: CloudLocalized("文件过大或解压后体积异常，已停止导入"),
                    recovery: .removeRecord
                )
            case .invalidPDF, .invalidDOCX, .invalidEPUB, .parseFailed:
                return CloudHistoryFailurePresentation(
                    record: record,
                    message: CloudLocalized("文件可能已损坏、受密码或 DRM 保护，暂时无法读取"),
                    recovery: .removeRecord
                )
            case .unsupportedExtension, .extensionMismatch, .mimeTypeMismatch:
                return CloudHistoryFailurePresentation(
                    record: record,
                    message: CloudLocalized("文件格式与扩展名不一致，已停止导入"),
                    recovery: .removeRecord
                )
            case .byteCountMismatch, .emptyFile, .fileReadFailed, .invalidLocalURL:
                return CloudHistoryFailurePresentation(
                    record: record,
                    message: CloudLocalized("下载的文件不完整，请重新下载"),
                    recovery: .retry
                )
            }
        }
        guard let cloudError = error as? CloudStorageError else {
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("云盘暂时无法完成此操作，请重试"),
                recovery: .retry
            )
        }
        switch cloudError {
        case .userCancelled, .staleSession:
            return nil
        case .accountMismatch:
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("当前连接的账号不是这个文件所属账号，请切换账号后再试"),
                recovery: .reconnect(forceAccountSelection: true)
            )
        case .notConnected, .needsReauthorization:
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("连接原账号后继续"),
                recovery: .reconnect(forceAccountSelection: false)
            )
        case .itemUnavailable, .downloadNotAllowed:
            return CloudHistoryFailurePresentation(
                record: record,
                message: cloudError == .downloadNotAllowed
                    ? CloudLocalized("该文件不允许下载")
                    : CloudLocalized("文件已被移动、删除，或当前账号无权访问"),
                recovery: .removeRecord
            )
        case .unsupportedItem, .unsupportedExportFormat:
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("此文件暂时无法朗读或解读"),
                recovery: .removeRecord
            )
        case .rateLimited:
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("云盘请求过于频繁，请稍后重试"),
                recovery: .retry
            )
        case .network:
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("网络连接失败，请检查网络后重试"),
                recovery: .retry
            )
        case .invalidConfiguration:
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("该云盘尚未完成开发者配置，请稍后再试"),
                recovery: .dismiss
            )
        case .invalidResponse:
            return CloudHistoryFailurePresentation(
                record: record,
                message: CloudLocalized("云盘暂时无法完成此操作，请重试"),
                recovery: .retry
            )
        case .provider(let code, let retryable):
            let presentation = CloudFlowFailurePresentation.make(
                error: cloudError,
                hasRetrySelection: true
            )
            return CloudHistoryFailurePresentation(
                record: record,
                message: presentation.message,
                recovery: retryable ? .retry : (
                    code.lowercased() == "google_export_size_limit"
                        ? .removeRecord
                        : .dismiss
                )
            )
        }
    }

    static func contentChanged(
        record: HistoryRecord,
        result: DocumentImportResult
    ) -> Bool {
        result.finalRevision != (record.contentRevision ?? record.origin?.revision)
            || result.format != record.effectiveFormat
            || result.origin?.originalName != record.origin?.originalName
    }
}
