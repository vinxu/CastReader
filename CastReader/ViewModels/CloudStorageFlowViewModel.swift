//
//  CloudStorageFlowViewModel.swift
//  CastReader
//

import Foundation

/// A single, testable contract for the cloud failure screen. Keeping recovery
/// separate from copy prevents a permanent failure from accidentally gaining a
/// Retry button just because its message happens to mention trying again.
struct CloudFlowFailurePresentation: Equatable {
    enum Recovery: Equatable {
        /// Replay the retained remote item and export choice.
        case retrySelection
        /// Run the provider connection/picker flow again.
        case reconnect
        /// There is no useful in-app recovery for this failure.
        case close
    }

    let message: String
    let recovery: Recovery

    var showsRetry: Bool {
        recovery == .retrySelection || recovery == .reconnect
    }

    static func make(error: Error, hasRetrySelection: Bool) -> Self {
        func transient(_ message: String) -> Self {
            Self(
                message: message,
                recovery: hasRetrySelection ? .retrySelection : .reconnect
            )
        }

        if let error = error as? CloudStorageError {
            switch error {
            case .notConnected, .needsReauthorization:
                return Self(
                    message: CloudLocalized("连接已失效，请重新连接后再试"),
                    recovery: .reconnect
                )
            case .accountMismatch:
                return Self(
                    message: CloudLocalized("当前连接的账号不是这个文件所属账号，请切换账号后再试"),
                    recovery: .reconnect
                )
            case .itemUnavailable:
                return Self(
                    message: CloudLocalized("文件已被移动、删除，或当前账号无权访问"),
                    recovery: .close
                )
            case .downloadNotAllowed:
                return Self(message: CloudLocalized("该文件不允许下载"), recovery: .close)
            case .unsupportedItem, .unsupportedExportFormat:
                return Self(
                    message: CloudLocalized("此文件暂时无法朗读或解读"),
                    recovery: .close
                )
            case .rateLimited:
                return transient(CloudLocalized("云盘请求过于频繁，请稍后重试"))
            case .network:
                return transient(CloudLocalized("网络连接失败，请检查网络后重试"))
            case .invalidConfiguration:
                return Self(
                    message: CloudLocalized("该云盘尚未完成开发者配置，请稍后再试"),
                    recovery: .close
                )
            case .userCancelled, .staleSession:
                return Self(message: CloudLocalized("操作已取消"), recovery: .close)
            case .invalidResponse:
                return Self(
                    message: CloudLocalized("云盘返回了无法识别的数据，暂时无法完成此操作"),
                    recovery: .close
                )
            case .provider(let code, let retryable):
                switch code.lowercased() {
                case "google_domain_policy", "onedrive_admin_policy":
                    return Self(
                        message: CloudLocalized("组织策略禁止 CastReader 访问此云盘，请联系组织管理员"),
                        recovery: .close
                    )
                case "google_export_size_limit":
                    return Self(
                        message: CloudLocalized("此 Google 文档超过 Google Drive 的导出大小限制，无法导入"),
                        recovery: .close
                    )
                case "google_authorization_in_progress":
                    return Self(
                        message: CloudLocalized("云盘暂时无法完成此操作，请重试"),
                        recovery: .reconnect
                    )
                case "google_access_not_configured":
                    return Self(
                        message: CloudLocalized("该云盘尚未完成开发者配置，请稍后再试"),
                        recovery: .close
                    )
                default:
                    if retryable {
                        return transient(CloudLocalized("云盘暂时无法完成此操作，请重试"))
                    }
                    return Self(
                        message: CloudLocalized("云盘拒绝了此操作，请联系云盘管理员或稍后查看服务状态"),
                        recovery: .close
                    )
                }
            }
        }

        if let error = error as? DocumentImportError {
            switch error {
            case .invalidPDF, .invalidDOCX, .invalidEPUB, .parseFailed:
                return Self(
                    message: CloudLocalized("文件可能已损坏、受密码或 DRM 保护，暂时无法读取"),
                    recovery: .close
                )
            case .unsupportedExtension, .extensionMismatch, .mimeTypeMismatch:
                return Self(
                    message: CloudLocalized("文件格式与扩展名不一致，已停止导入"),
                    recovery: .close
                )
            case .byteCountMismatch, .emptyFile, .fileReadFailed:
                return hasRetrySelection
                    ? Self(
                        message: CloudLocalized("下载的文件不完整，请重新下载"),
                        recovery: .retrySelection
                    )
                    : Self(
                        message: CloudLocalized("下载的文件不完整，请重新下载"),
                        recovery: .close
                    )
            case .invalidLocalURL:
                return Self(
                    message: CloudLocalized("下载的文件不完整，请重新下载"),
                    recovery: .close
                )
            case .resourceLimitExceeded(let reason):
                return reason == .insufficientDeviceStorage
                    ? Self(
                        message: CloudLocalized("设备可用空间不足，请在系统设置中管理存储空间后再试"),
                        recovery: .close
                    )
                    : Self(
                        message: CloudLocalized("文件过大或解压后体积异常，已停止导入"),
                        recovery: .close
                    )
            case .cancelled:
                return Self(message: CloudLocalized("操作已取消"), recovery: .close)
            }
        }

        return Self(
            message: CloudLocalized("云盘暂时无法完成此操作，请稍后再试"),
            recovery: .close
        )
    }
}

@MainActor
final class CloudStorageFlowViewModel: ObservableObject {
    enum Stage: Equatable {
        case disclosure
        case authorizing
        case confirmingAccountSwitch
        case browsing
        case gettingFileInfo
        case downloading
        case checkingFile
        case parsing(SupportedDocumentFormat)
        case preparingReader
        case failed(CloudFlowFailurePresentation)

        var blocksBrowser: Bool {
            switch self {
            case .authorizing, .confirmingAccountSwitch, .gettingFileInfo,
                 .downloading, .checkingFile, .parsing, .preparingReader:
                return true
            case .disclosure, .browsing, .failed:
                return false
            }
        }
    }

    let provider: CloudProviderID
    let scenario: ExplainContentType?
    let mode: ReaderMode

    @Published private(set) var stage: Stage = .authorizing
    @Published private(set) var account: CloudAccount?
    @Published private(set) var folders: [CloudFolder] = []
    @Published private(set) var items: [CloudItem] = []
    @Published private(set) var folderPath: [CloudFolder] = []
    @Published private(set) var drives: [CloudDrive] = []
    @Published private(set) var selectedDrive: CloudDrive?
    @Published private(set) var nextCursor: CloudCursor?
    @Published private(set) var isLoadingPage = false
    @Published private(set) var downloadProgress: CloudDownloadProgress?
    @Published private(set) var currentFilename: String?
    @Published private(set) var importedResult: DocumentImportResult?
    @Published private(set) var didCancel = false
    @Published private(set) var didFinishPrivacyReview = false
    @Published private(set) var switchCandidate: CloudAccount?
    @Published var exportPromptItem: CloudItem?
    @Published private(set) var unsupportedItem: CloudItem?
    @Published var searchText = ""
    @Published private(set) var isShowingSearchResults = false

    private let analyticsContext: AnalyticsContentContext?
    private let center: CloudStorageCenter
    private let pipeline: DocumentImportPipeline
    private let forceAccountSelection: Bool
    private let showsDisclosureOnStart: Bool
    private let privacyReviewOnly: Bool
    private let expectedAccount: CloudAccount?
    private var operationTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var importSession: ImportSession?
    /// Keeps the exact remote selection across a retryable transfer/import
    /// failure so Retry replays the same item and export choice.
    private var retrySelection: (item: CloudItem, exportFormat: CloudExportFormat?)?
    private var activeSearchQuery: String?
    private var started = false
    private var returnsToBrowserAfterPrivacy = false

    init(
        provider: CloudProviderID,
        scenario: ExplainContentType?,
        mode: ReaderMode,
        analyticsContext: AnalyticsContentContext?,
        forceAccountSelection: Bool = false,
        showsDisclosureOnStart: Bool = false,
        privacyReviewOnly: Bool = false,
        expectedAccount: CloudAccount? = nil,
        center: CloudStorageCenter? = nil,
        pipeline: DocumentImportPipeline = DocumentImportPipeline()
    ) {
        self.provider = provider
        self.scenario = scenario
        self.mode = mode
        self.analyticsContext = analyticsContext
        self.forceAccountSelection = forceAccountSelection
        self.showsDisclosureOnStart = showsDisclosureOnStart
        self.privacyReviewOnly = privacyReviewOnly
        self.expectedAccount = expectedAccount
        self.center = center ?? .shared
        self.pipeline = pipeline
        account = expectedAccount
    }

    deinit {
        operationTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        guard center.isConfigured(provider) else {
            stage = .failed(CloudFlowFailurePresentation.make(
                error: CloudStorageError.invalidConfiguration(code: "cloud_not_configured"),
                hasRetrySelection: false
            ))
            return
        }
        if privacyReviewOnly {
            stage = .disclosure
            return
        }
        if showsDisclosureOnStart {
            stage = .disclosure
        } else {
            // A tap immediately authorizes when needed, then opens the durable
            // native Drive browser. A valid refresh token skips OAuth entirely.
            connectAndBrowse(forceAccountSelection: forceAccountSelection)
        }
    }

    func acceptDisclosure() {
        CloudPrivacyAcknowledgementStore.acknowledge(provider)
        if privacyReviewOnly {
            didFinishPrivacyReview = true
            return
        }
        if returnsToBrowserAfterPrivacy {
            returnsToBrowserAfterPrivacy = false
            stage = .browsing
            return
        }
        connectAndBrowse(forceAccountSelection: forceAccountSelection)
    }

    var disclosureIsReviewOnly: Bool {
        privacyReviewOnly || returnsToBrowserAfterPrivacy
    }

    func showDisclosureAgain() {
        operationTask?.cancel()
        operationTask = nil
        activeOperationID = nil
        discardStagedAccountIfNeeded()
        retrySelection = nil
        returnsToBrowserAfterPrivacy = account != nil
        stage = .disclosure
    }

    func retry() {
        if let retrySelection {
            importItem(
                retrySelection.item,
                exportFormat: retrySelection.exportFormat
            )
        } else {
            connectAndBrowse(forceAccountSelection: forceAccountSelection)
        }
    }

    func cancel() {
        stopOutstandingWork()
        didCancel = true
    }

    /// Interactive sheet dismissal bypasses the toolbar close action. Cancel
    /// the same list/import work without emitting a second dismissal
    /// callback from a view that is already disappearing.
    func viewDidDisappear() {
        // Presenting ASWebAuthenticationSession can temporarily remove this
        // SwiftUI hierarchy from the visible tree on a real device. Cancelling
        // here would abort OAuth while leaving `stage == .authorizing`, so the
        // user would return to a spinner that can never complete. Interactive
        // dismissal is disabled for every blocking stage; deinit and explicit
        // Cancel still tear down genuine exits.
        guard !stage.blocksBrowser else {
            #if DEBUG
            print("CloudStorageFlow provider=\(provider.rawValue) event=transient_disappear_ignored")
            #endif
            return
        }
        stopOutstandingWork()
    }

    private func stopOutstandingWork() {
        operationTask?.cancel()
        operationTask = nil
        activeOperationID = nil
        discardStagedAccountIfNeeded()
        retrySelection = nil
        if let importSession {
            Task { await CloudImportCoordinator.shared.cancel(importSession) }
            self.importSession = nil
        }
    }

    func switchAccount() {
        retrySelection = nil
        stageAccountSwitch()
    }

    func confirmAccountSwitch() {
        guard switchCandidate != nil else { return }
        switchCandidate = nil
        runOperation { [weak self] in
            guard let self else { return }
            self.stage = .authorizing
            do {
                self.account = try await self.center.commitStagedAccount(self.provider)
                try await self.refreshDriveOptions()
                self.folderPath = []
                try await self.loadPage(
                    folder: self.driveRootFolder,
                    cursor: nil,
                    replacing: true
                )
                self.stage = .browsing
            } catch {
                await self.center.discardStagedAccount(self.provider)
                self.handle(error)
            }
        }
    }

    func cancelAccountSwitch() {
        guard switchCandidate != nil else { return }
        switchCandidate = nil
        runOperation { [weak self] in
            guard let self else { return }
            await self.center.discardStagedAccount(self.provider)
            self.stage = .browsing
            if self.folders.isEmpty, self.items.isEmpty, self.account != nil {
                do {
                    try await self.loadPage(
                        folder: self.driveRootFolder,
                        cursor: nil,
                        replacing: true
                    )
                } catch {
                    self.handle(error)
                }
            }
        }
    }

    var accountSwitchMessage: String {
        let current = account.map(Self.accountLabel) ?? CloudLocalized("账号")
        let candidate = switchCandidate.map(Self.accountLabel) ?? CloudLocalized("账号")
        return String(
            format: CloudLocalized("将从 %@ 更换为 %@。确认后，当前文件列表会刷新。"),
            current,
            candidate
        )
    }

    func disconnect() async -> CloudDisconnectResult {
        operationTask?.cancel()
        operationTask = nil
        activeOperationID = nil
        let result = await center.disconnect(provider)
        account = nil
        folders = []
        items = []
        drives = []
        selectedDrive = nil
        folderPath = []
        nextCursor = nil
        currentFilename = nil
        retrySelection = nil
        clearSearchState()
        stage = .disclosure
        return result
    }

    func openFolder(_ folder: CloudFolder) {
        guard stage == .browsing else { return }
        let openedFromSearch = isShowingSearchResults
        clearSearchState()
        runOperation { [weak self] in
            guard let self else { return }
            do {
                try await self.loadPage(folder: folder, cursor: nil, replacing: true)
                if openedFromSearch {
                    self.folderPath = [folder]
                } else {
                    self.folderPath.append(folder)
                }
            } catch {
                self.handle(error)
            }
        }
    }

    func navigateToFolder(at index: Int?) {
        guard stage == .browsing else { return }
        clearSearchState()
        runOperation { [weak self] in
            guard let self else { return }
            let target: CloudFolder?
            if let index, self.folderPath.indices.contains(index) {
                target = self.folderPath[index]
            } else {
                target = self.driveRootFolder
            }
            do {
                try await self.loadPage(folder: target, cursor: nil, replacing: true)
                if let index {
                    self.folderPath = Array(self.folderPath.prefix(index + 1))
                } else {
                    self.folderPath = []
                }
            } catch {
                self.handle(error)
            }
        }
    }

    func selectDrive(_ drive: CloudDrive) {
        guard (provider == .oneDrive || provider == .googleDrive),
              stage == .browsing,
              drives.contains(drive),
              selectedDrive?.id != drive.id else { return }
        clearSearchState()
        runOperation { [weak self] in
            guard let self else { return }
            self.selectedDrive = drive
            self.folderPath = []
            do {
                try await self.loadPage(
                    folder: self.driveRootFolder,
                    cursor: nil,
                    replacing: true
                )
            } catch {
                self.handle(error)
            }
        }
    }

    func loadNextPageIfNeeded(currentItem: CloudItem? = nil, currentFolder: CloudFolder? = nil) {
        guard let nextCursor, !isLoadingPage, stage == .browsing else { return }
        let isLastItem = currentItem.map { $0.id == items.last?.id } ?? false
        let isLastFolder = currentFolder.map { $0.id == folders.last?.id && items.isEmpty } ?? false
        guard isLastItem || isLastFolder else { return }
        runOperation { [weak self] in
            guard let self else { return }
            do {
                if let query = self.activeSearchQuery {
                    try await self.loadSearchPage(
                        query: query,
                        cursor: nextCursor,
                        replacing: false
                    )
                } else {
                    try await self.loadPage(
                        folder: self.folderPath.last ?? self.driveRootFolder,
                        cursor: nextCursor,
                        replacing: false
                    )
                }
            } catch {
                self.handle(error)
            }
        }
    }

    /// Runs a Drive-wide filename search inside the currently selected drive.
    /// The view debounces edits before calling this method, so only the latest
    /// query reaches the API. Clearing the field restores the current folder.
    func updateSearchResults(for rawQuery: String) {
        guard stage == .browsing else { return }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            guard activeSearchQuery != nil || isShowingSearchResults else { return }
            activeSearchQuery = nil
            isShowingSearchResults = false
            runOperation { [weak self] in
                guard let self else { return }
                do {
                    try await self.loadPage(
                        folder: self.folderPath.last ?? self.driveRootFolder,
                        cursor: nil,
                        replacing: true
                    )
                } catch {
                    self.handle(error)
                }
            }
            return
        }

        guard query != activeSearchQuery || !isShowingSearchResults else { return }
        activeSearchQuery = query
        isShowingSearchResults = true
        runOperation { [weak self] in
            guard let self else { return }
            do {
                try await self.loadSearchPage(
                    query: query,
                    cursor: nil,
                    replacing: true
                )
                #if DEBUG
                print(
                    "CloudStorageFlow provider=\(self.provider.rawValue) "
                        + "event=search_ready query_length=\(query.count)"
                )
                #endif
            } catch {
                self.handle(error)
            }
        }
    }

    func choose(_ item: CloudItem) {
        #if DEBUG
        print(
            "CloudStorageFlow provider=\(provider.rawValue) event=file_selected "
                + "kind=\(String(describing: item.kind)) "
                + "mime=\(item.mimeType ?? "missing")"
        )
        #endif
        guard item.kind == .file || item.kind == .exportableDocument else {
            unsupportedItem = item
            return
        }
        if item.exportOptions.count > 1 {
            exportPromptItem = item
        } else {
            importItem(item, exportFormat: item.exportOptions.first)
        }
    }

    func dismissUnsupportedItem() {
        unsupportedItem = nil
    }

    func importExport(_ format: CloudExportFormat, item: CloudItem) {
        exportPromptItem = nil
        importItem(item, exportFormat: format)
    }

    private func connectAndBrowse(forceAccountSelection: Bool = false) {
        runOperation { [weak self] in
            guard let self else { return }
            self.capturePublishedAccount()
            self.stage = .authorizing
            #if DEBUG
            print("CloudStorageFlow provider=\(self.provider.rawValue) event=connect_begin")
            #endif
            do {
                // Let the covering SwiftUI sheet finish becoming key before
                // ASWebAuthenticationSession asks for its presentation anchor.
                // Starting in the same update pass is unreliable on device.
                if self.provider == .googleDrive {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    try Task.checkCancellation()
                }
                if forceAccountSelection {
                    try await self.performStageAccountSwitch()
                    return
                }
                self.account = try await self.center.ensureConnected(
                    self.provider,
                    expectedAccount: self.expectedAccount
                )
                self.clearSearchState()
                try await self.refreshDriveOptions()
                self.folderPath = []
                try await self.loadPage(
                    folder: self.driveRootFolder,
                    cursor: nil,
                    replacing: true
                )
                self.stage = .browsing
                #if DEBUG
                print("CloudStorageFlow provider=\(self.provider.rawValue) event=browser_ready")
                #endif
            } catch {
                #if DEBUG
                print("CloudStorageFlow provider=\(self.provider.rawValue) event=connect_failed type=\(String(describing: type(of: error)))")
                #endif
                if error as? CloudStorageError == .accountMismatch,
                   let candidate = await self.center.stagedCandidateAccount(
                    for: self.provider
                   ) {
                    self.switchCandidate = candidate
                    self.stage = .confirmingAccountSwitch
                    return
                }
                self.handle(error)
            }
        }
    }

    private func stageAccountSwitch() {
        runOperation { [weak self] in
            guard let self else { return }
            do {
                try await self.performStageAccountSwitch()
            } catch {
                self.handle(error)
            }
        }
    }

    private func performStageAccountSwitch() async throws {
        capturePublishedAccount()
        let priorAccount = account
        stage = .authorizing
        let candidate = try await center.stageAnotherAccount(provider)
        if let expectedAccount,
           candidate.stableAccountKey != expectedAccount.stableAccountKey {
            await center.discardStagedAccount(provider)
            throw CloudStorageError.accountMismatch
        }
        if candidate.stableAccountKey == priorAccount?.stableAccountKey {
            await center.discardStagedAccount(provider)
            stage = .browsing
            if folders.isEmpty, items.isEmpty, account != nil {
                try await loadPage(
                    folder: driveRootFolder,
                    cursor: nil,
                    replacing: true
                )
            }
            return
        }
        switchCandidate = candidate
        // Keep the existing account and its browser visible under the
        // confirmation sheet. No request can use B before commit.
        stage = .browsing
    }

    private func capturePublishedAccount() {
        switch center.state(for: provider) {
        case .connected(let published), .needsReauthorization(let published?):
            account = published
        case .disconnected, .connecting, .needsReauthorization(nil):
            break
        }
    }

    private func discardStagedAccountIfNeeded() {
        guard switchCandidate != nil else { return }
        switchCandidate = nil
        let center = center
        let provider = provider
        Task { await center.discardStagedAccount(provider) }
    }

    private func loadPage(
        folder: CloudFolder?,
        cursor: CloudCursor?,
        replacing: Bool
    ) async throws {
        isLoadingPage = true
        defer { isLoadingPage = false }
        let page = try await center.list(provider: provider, folder: folder, cursor: cursor)
        try Task.checkCancellation()
        apply(page, replacing: replacing)
    }

    private func loadSearchPage(
        query: String,
        cursor: CloudCursor?,
        replacing: Bool
    ) async throws {
        isLoadingPage = true
        defer { isLoadingPage = false }
        let selectedDriveID = selectedDrive?.id == "root"
            ? nil
            : selectedDrive?.id
        let page = try await center.search(
            provider: provider,
            query: query,
            driveID: selectedDriveID,
            cursor: cursor
        )
        try Task.checkCancellation()
        guard activeSearchQuery == query else { return }
        apply(page, replacing: replacing)
    }

    private func clearSearchState() {
        searchText = ""
        activeSearchQuery = nil
        isShowingSearchResults = false
    }

    private func apply(_ page: CloudPage, replacing: Bool) {
        if replacing {
            folders = page.folders
            items = page.items
        } else {
            var folderIDs = Set(folders.map { "\($0.driveID ?? ""):\($0.id)" })
            folders.append(contentsOf: page.folders.filter {
                folderIDs.insert("\($0.driveID ?? ""):\($0.id)").inserted
            })
            var itemIDs = Set(items.map { "\($0.driveID ?? ""):\($0.id)" })
            items.append(contentsOf: page.items.filter {
                itemIDs.insert("\($0.driveID ?? ""):\($0.id)").inserted
            })
        }
        nextCursor = page.nextCursor
    }

    private var driveRootFolder: CloudFolder? {
        guard let drive = selectedDrive else { return nil }
        return CloudFolder(
            provider: drive.provider,
            accountKey: drive.accountKey,
            driveID: drive.id,
            id: "root",
            name: drive.name
        )
    }

    private func refreshDriveOptions() async throws {
        let available = try await center.listDrives(provider: provider)
        try Task.checkCancellation()
        drives = available
        if let selectedDrive,
           let retained = available.first(where: { $0.id == selectedDrive.id }) {
            self.selectedDrive = retained
        } else {
            selectedDrive = available.first(where: \.isDefault) ?? available.first
        }
    }

    private func importItem(_ item: CloudItem, exportFormat: CloudExportFormat?) {
        retrySelection = (item, exportFormat)
        runOperation { [weak self] in
            guard let self else { return }
            self.stage = .gettingFileInfo
            self.downloadProgress = nil
            self.currentFilename = item.name

            let coordinator = CloudImportCoordinator.shared
            let session = await coordinator.begin(
                provider: self.provider,
                scenario: self.scenario,
                mode: self.mode,
                analyticsContext: self.analyticsContext
            )
            self.importSession = session

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CastReaderCloudImports", isDirectory: true)
                .appendingPathComponent(session.id.uuidString, isDirectory: true)
            do {
                try CloudTemporaryFileSecurity.prepareDirectory(directory)
                let destination = directory.appendingPathComponent(
                    Self.safeFilename(item.name, exportFormat: exportFormat)
                )
                #if DEBUG
                print(
                    "CloudStorageFlow provider=\(self.provider.rawValue) "
                        + "event=temporary_destination_ready "
                        + "isFileURL=\(destination.isFileURL) "
                        + "policyAllowed=\(CloudDownloadDestinationPolicy.allows(destination))"
                )
                #endif
                let progressHandler = coordinator.progressHandler(for: session) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard await coordinator.isCurrent(session) else { return }
                        self?.downloadProgress = progress
                        self?.stage = .downloading
                    }
                }
                let provider = self.provider
                let center = self.center
                let pipeline = self.pipeline
                let scenarioOrigin = CloudDocumentOrigin(
                    provider: item.provider,
                    accountKey: item.accountKey,
                    maskedAccountHint: self.account?.maskedEmail,
                    driveID: item.driveID,
                    remoteItemID: item.id,
                    revision: item.revision,
                    resourceKey: item.resourceKey,
                    originalName: item.name,
                    mimeType: item.mimeType,
                    modifiedAt: item.modifiedAt
                )

                let result = try await coordinator.run(for: session) {
                    let receipt = try await center.download(
                        provider: provider,
                        item: item,
                        exportFormat: exportFormat,
                        destination: destination,
                        progress: progressHandler
                    )
                    let request = DocumentImportRequest(
                        receipt: receipt,
                        origin: scenarioOrigin,
                        session: session
                    )
                    return try await pipeline.importDocument(request) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard await coordinator.isCurrent(session) else { return }
                            self?.apply(progress)
                        }
                    }
                }
                try? FileManager.default.removeItem(at: directory)
                guard await coordinator.finish(session) else { return }
                self.importSession = nil
                self.clearRetrySelection(ifMatching: item, exportFormat: exportFormat)
                self.importedResult = result
            } catch {
                try? FileManager.default.removeItem(at: directory)
                _ = await coordinator.finish(session)
                self.importSession = nil
                if !Self.canRetrySelectedItem(after: error) {
                    self.clearRetrySelection(ifMatching: item, exportFormat: exportFormat)
                }
                self.handle(error)
            }
        }
    }

    private func apply(_ progress: DocumentImportProgress) {
        switch progress.stage {
        case .checkingFile: stage = .checkingFile
        case .parsing(let format): stage = .parsing(format)
        case .preparingReader: stage = .preparingReader
        }
    }

    private func runOperation(_ operation: @escaping @MainActor () async -> Void) {
        operationTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        operationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            guard self?.activeOperationID == operationID else { return }
            self?.operationTask = nil
            self?.activeOperationID = nil
        }
    }

    private func handle(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        #if DEBUG
        print(
            "CloudStorageFlow provider=\(provider.rawValue) event=operation_failed "
                + "error=\(String(reflecting: error))"
        )
        #endif
        if let storageError = error as? CloudStorageError, storageError == .userCancelled {
            didCancel = true
            return
        }
        if let coordinationError = error as? CloudImportCoordinationError,
           coordinationError == .cancelled || coordinationError == .staleSession {
            didCancel = true
            return
        }
        if let importError = error as? DocumentImportError, importError == .cancelled {
            didCancel = true
            return
        }
        stage = .failed(CloudFlowFailurePresentation.make(
            error: error,
            hasRetrySelection: retrySelection != nil
        ))
    }

    private func clearRetrySelection(
        ifMatching item: CloudItem,
        exportFormat: CloudExportFormat?
    ) {
        guard retrySelection?.item == item,
              retrySelection?.exportFormat == exportFormat else { return }
        retrySelection = nil
    }

    private static func canRetrySelectedItem(after error: Error) -> Bool {
        CloudFlowFailurePresentation.make(
            error: error,
            hasRetrySelection: true
        ).recovery == .retrySelection
    }

    private static func safeFilename(_ raw: String, exportFormat: CloudExportFormat?) -> String {
        var name = URL(fileURLWithPath: raw).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "document" }
        if let exportFormat,
           SupportedDocumentFormat(fileExtension: URL(fileURLWithPath: name).pathExtension)
            != exportFormat.documentFormat {
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                + "." + exportFormat.rawValue
        }
        return name
    }

    private static func accountLabel(_ account: CloudAccount) -> String {
        account.maskedEmail ?? account.displayName ?? CloudLocalized("账号")
    }

}
