#if DEBUG
import SwiftUI
import WebKit

/// Local images feed the production download/storage/reader screens. This
/// fixture requires no account or network and is never a speed benchmark.
@MainActor
struct KindleOfflineFlowFixture: View {
    @StateObject private var reader: KindleBookViewModel
    @StateObject private var download: KindleOfflineDownloadCoordinator
    @ObservedObject private var offline = KindleOfflinePlaybackCenter.shared
    @State private var presented = false
    @State private var route: [String] = []
    @State private var loaded = false
    private let source: KindleOfflineFlowSource
    private let scope = KindleOfflinePageStore.digest("offline-flow-simulator-only")

    init() {
        let source = KindleOfflineFlowSource()
        self.source = source
        let folder = ProcessInfo.processInfo.environment["CASTREADER_OFFLINE_FIXTURE_ID"] ?? "manual"
        let safeFolder = KindleOfflinePageStore.digest(folder)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineFlowFixture").appendingPathComponent(safeFolder)
        _download = StateObject(wrappedValue: KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(root: root)))
        _reader = StateObject(wrappedValue: KindleBookViewModel(book: source.offlineSourceBook, websiteDataStore: .nonPersistent()))
    }

    var body: some View {
        NavigationStack(path: $route) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                OfflineDownloadsEntryCard(store: download.store, scopeProvider: { scope })
                NavigationLink("打开正在读的书", value: "reader").accessibilityIdentifier("offlineFlowOnlineBook")
                NavigationLink("离线书籍", value: "library").accessibilityIdentifier("libraryOfflineBooks")
                Section {
                    Text("模拟器验收 · 本地合成书").font(.caption).foregroundStyle(.secondary)
                    Text("相同的保存、书架、阅读与系统朗读界面；没有 Kindle 网络请求。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                }.padding(16)
            }.navigationTitle("文库")
                .navigationDestination(for: String.self) { destination in
                    if destination == "library" {
                        KindleOfflineLibraryView(store: download.store, scopeProvider: { scope }, continueDownload: { _ in presented = true })
                    } else {
                        VStack(spacing: 24) {
                            Image(systemName: "book.pages").font(.system(size: 64)).foregroundStyle(AppTheme.primary)
                            Text(source.offlineSourceBook.title).font(.title2)
                            Text("在右上角“更多”中保存整本书。")
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .navigationTitle("正在阅读").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .primaryAction) { ReaderMoreButton() } }
                            .environment(\.readerOfflineAction, ReaderOfflineAction(title: "离线保存整本书", open: { presented = true }))
                    }
                }
                .sheet(isPresented: $presented, onDismiss: {
                    offline.presentAfterDownload(continueDownload: { presented = true })
                }) {
                    KindleOfflineDownloadView(model: reader, download: download, fixtureStart: {
                        download.start(source: source, scope: scope, stillAuthorized: { true })
                    }, fixtureScope: scope)
                }
                .task {
                    guard !loaded else { return }; loaded = true
                    if ProcessInfo.processInfo.arguments.contains("-CastReaderOfflineFixtureResumeViewport") {
                        await seedSavedViewport()
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("-CastReaderOfflineFixturePartial") {
                        await download.refresh(sourceBookID: source.offlineSourceBook.id, scope: scope)
                        if download.book == nil {
                            download.start(source: source, scope: scope, stillAuthorized: { true })
                            while download.isRunning, (download.book?.pages.count ?? 0) < 3 { try? await Task.sleep(for: .milliseconds(50)) }
                            await download.stopAndWait()
                        }
                    }
                }
        }.preferredColorScheme(UserDefaults.standard.string(forKey: "CastReaderFixtureAppearance") == "Dark" ? .dark : nil)
        .overlay(alignment: .bottom) {
            if offline.showsMiniPlayer { KindleOfflineMiniPlayer(center: offline).padding(.bottom, 68) }
        }
        .overlay { KindleOfflinePlaybackSurface(center: offline) }
        .overlay(alignment: .bottom) {
            if offline.model == nil && ProcessInfo.processInfo.arguments.contains("-CastReaderOfflineFixtureMiniPlayer") {
                // Reproduce MainTabView's persistent online player overlay.
                Button("在线会话 · 已暂停") {}.padding(20)
                    .frame(maxWidth: .infinity).background(.regularMaterial)
                    .padding(.bottom, 68).accessibilityIdentifier("offlineFixtureRootMiniPlayer")
            }
        }
    }

    private func seedSavedViewport() async {
        do {
            guard try await download.store.list(scope: scope).isEmpty else { return }
            let captured = try await source.captureOfflineBookPage(after: nil)
            let position = KindleOfflineSourcePosition(start: 0, end: 9, minimum: 0, maximum: 9,
                layoutID: "saved-viewport", fingerprint: "saved-viewport-page")
            var book = try await download.store.prepare(source: source.offlineSourceBook, scope: scope, originalPosition: position)
            book = try await download.store.append(document: captured.document, position: position, to: book,
                scope: scope, requiresOCR: true, sourceWordCount: 240)
            book = try await download.store.finish(book, scope: scope)
            var recognized = captured.document
            recognized.paragraphs += (1...24).map {
                ReadingParagraph(id: $0, text: "Paragraph \($0). The saved sentence belongs here. Keep this reading position after reopening the book.")
            }
            try await download.store.saveSpeechPage(recognized, book: book, ordinal: 0, scope: scope)
            var cursor = KindleOfflineBook.ReadingPosition()
            cursor.paragraphID = 18
            try await download.store.saveReadingPosition(cursor, book: book, scope: scope)
        } catch { assertionFailure("Could not seed the saved viewport fixture: \(error)") }
    }
}

@MainActor
private final class KindleOfflineFlowSource: KindleOfflineBookSource {
    let offlineSourceBook = KindleBook(id: "offline-flow-book", title: "The Little Journey", author: "CastReader 本地测试书",
        readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "", language: "en-US", lastSyncedAt: Date())
    private let pageCount = 12
    private var failedAttempts = 0
    private var captureSession = 0
    private func position(_ index: Int) -> KindleOfflineSourcePosition {
        .init(start: index * 10, end: index * 10 + 9, minimum: 0, maximum: pageCount * 10 - 1,
              layoutID: "local-flow-layout", fingerprint: "local-flow-page-\(index)")
    }
    func beginOfflineBookCapture(restoring interruptedPosition: KindleOfflineSourcePosition?) async throws -> KindleOfflineSourcePosition {
        captureSession += 1
        try await Task.sleep(for: .milliseconds(300))
        return interruptedPosition ?? position(0)
    }
    func captureOfflineBookPage(after previous: KindleOfflineSourcePosition?) async throws -> KindleOfflineCapturedPage {
        try await Task.sleep(for: .milliseconds(Int(ProcessInfo.processInfo.environment["CASTREADER_OFFLINE_FIXTURE_DELAY"] ?? "600") ?? 600))
        let index = previous.map { ($0.end + 1) / 10 } ?? 0
        // Hold the first resumed request so the UI can exercise cancellation
        // without racing this tiny local book's completion. The next session
        // uses normal fixture timing and verifies that resuming releases it.
        if ProcessInfo.processInfo.arguments.contains("-CastReaderOfflineFixturePartial"), captureSession == 2, index == 3 {
            try await Task.sleep(for: .seconds(30))
        }
        if ProcessInfo.processInfo.arguments.contains("-CastReaderOfflineFixtureFailure"), index == 2, failedAttempts < 3 {
            failedAttempts += 1
            throw KindleOfflineCaptureFailure.pageNotReady
        }
        let chinese = ProcessInfo.processInfo.arguments.contains("-CastReaderOfflineFixtureChinese")
        let text = chinese
            ? "第\(index + 1)頁\n\n我們一起讀書，聽見中文的聲音。\n\n離線閱讀不需要網路。這本書已經保存在手機裡，每一頁都按照原來的順序繼續朗讀。"
            : "Chapter \(index / 4 + 1)\n\nPage \(index + 1). The little journey continues.\n\nWe save this page on the phone. We can read and listen without a network. Each page follows the page before it."
        let tall = ProcessInfo.processInfo.arguments.contains("-CastReaderOfflineFixtureTallPage")
        let size = CGSize(width: 800, height: tall ? 2400 : 1100)
        let image = UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 18
            (text as NSString).draw(in: CGRect(x: 70, y: 80, width: 660, height: 900), withAttributes: [
                .font: UIFont.systemFont(ofSize: 38), .foregroundColor: UIColor.black, .paragraphStyle: paragraph])
            if tall {
                ("END OF PAGE" as NSString).draw(at: CGPoint(x: 70, y: size.height - 90),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.black])
            }
        }
        return KindleOfflineCapturedPage(position: position(index), document: ReadingDocument(title: offlineSourceBook.title,
            sourceKind: .kindle, language: "en-US", paragraphs: [.init(id: 0, text: "", type: .image, imageData: image)]),
            requiresOCR: true, sourceWordCount: 38)
    }
    func endOfflineBookCapture() async -> Bool {
        try? await Task.sleep(for: .milliseconds(300))
        return true
    }
}
#endif
