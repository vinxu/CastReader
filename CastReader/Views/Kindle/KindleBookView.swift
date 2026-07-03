//
//  KindleBookView.swift
//  CastReader
//

import Combine
import AVFoundation
import SwiftUI
import UIKit
import WebKit

struct KindleBookView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var importRouter: ImportRouter
    @StateObject private var model: KindleBookViewModel

    init(book: KindleBook) {
        _model = StateObject(wrappedValue: KindleBookViewModel(book: book))
    }

    init(model: KindleBookViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .bottomLeading) {
                KindleWebView(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)
                preparingStatusOverlay
            }
            Divider()
            playbackBar
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            importRouter.hideMainChrome = true
            model.loadIfNeeded()
        }
        .onDisappear {
            importRouter.hideMainChrome = false
            if model.shouldKeepAliveForMiniPlayer {
                KindlePlaybackCenter.shared.activate(model: model)
            } else {
                model.stopAll()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if KindlePlaybackCenter.shared.isPresented && KindlePlaybackCenter.shared.isOwning(model) {
                    KindlePlaybackCenter.shared.minimize()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.foreground)
                    .frame(width: 34, height: 34)
            }

            Text(model.book.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundColor(AppTheme.foreground)

            Spacer(minLength: 8)

            Text("朗读")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(AppTheme.surfaceVariant, in: Capsule())

            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(Text("刷新 Kindle 书籍"))
        }
        .frame(height: 52)
        .padding(.horizontal, 14)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var preparingStatusOverlay: some View {
        if model.isPreparing, !model.statusText.isEmpty {
            Text(model.statusText)
                .font(.caption.weight(.medium))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var playbackBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let vm = model.readVM {
                KindleReadPlaybackBar(vm: vm, start: { startCurrentMode() })
            } else {
                KindleEmptyPlaybackBar(isPreparing: model.isPreparing, play: { startCurrentMode() })
            }
        }
        .frame(height: 96)
        .background(.regularMaterial)
    }

    private func startCurrentMode() {
        Task {
            do {
                try await model.startCurrentMode()
            } catch {
                #if DEBUG
                NSLog("CRDBG KINDLE start error mode=%@ %@", model.mode.rawValue, error.localizedDescription)
                #endif
                model.statusText = error.localizedDescription
            }
        }
    }
}

private struct KindleEmptyPlaybackBar: View {
    let isPreparing: Bool
    let play: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button {} label: {
                Image(systemName: "gobackward.15").font(.system(size: 20))
            }
            .disabled(true)
            .opacity(0.38)
            Button(action: play) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(AppTheme.primary)
            }
            .disabled(isPreparing)
            Button {} label: {
                Image(systemName: "goforward.15").font(.system(size: 20))
            }
            .disabled(true)
            .opacity(0.38)
            Spacer(minLength: 0)
            SpeedMenu()
        }
        .foregroundColor(AppTheme.foreground)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

private struct KindleReadPlaybackBar: View {
    @ObservedObject var vm: ReadAloudViewModel
    let start: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button { vm.skipBackward() } label: {
                Image(systemName: "gobackward.15").font(.system(size: 20))
            }
            Button(action: start) {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(AppTheme.primary)
            }
            Button { vm.skipForward() } label: {
                Image(systemName: "goforward.15").font(.system(size: 20))
            }
            Spacer(minLength: 0)
            SpeedMenu()
        }
        .foregroundColor(AppTheme.foreground)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

private struct KindleExplainPlaybackBar: View {
    @ObservedObject var vm: ExplainViewModel

    var body: some View {
        ExplainControlBar(vm: vm)
    }
}

private enum KindleRunLog {
    static func write(_ message: String) {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) [\(UIApplication.shared.applicationState.debugName)] \(message)\n"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = docs.appendingPathComponent("kindle-background-probe.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(line.utf8).write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            try? handle.close()
        }
        #endif
    }
}

private extension UIApplication.State {
    var debugName: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

struct KindleMiniPlayerView: View {
    @ObservedObject var center: KindlePlaybackCenter
    @ObservedObject private var audio = AudioPlayerService.shared

    private var model: KindleBookViewModel? { center.model }

    private var statusText: String {
        guard model != nil else { return String(localized: "已暂停") }
        if audio.isPlaying { return String(localized: "朗读中") }
        return String(localized: "已暂停")
    }

    var body: some View {
        if let model {
            HStack(spacing: 12) {
                KindleCoverView(urlString: model.book.coverURL)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.mutedForeground.opacity(0.12), lineWidth: 0.5))
                    .onTapGesture { center.expand() }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundColor(AppTheme.foreground)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { center.expand() }

                Button {
                    Task { try? await model.startCurrentMode() }
                } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19))
                        .foregroundColor(AppTheme.foreground)
                        .frame(width: 34, height: 34)
                }

                Button { center.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.mutedForeground)
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.mutedForeground.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 8)
        }
    }
}

@MainActor
final class KindlePlaybackCenter: ObservableObject {
    static let shared = KindlePlaybackCenter()

    @Published private(set) var model: KindleBookViewModel?
    @Published var isPresented = false

    var showsMiniPlayer: Bool {
        model != nil && !isPresented
    }

    private init() {}

    func open(book: KindleBook) {
        if let active = model, active.isSameBook(as: book) {
            active.refreshMetadata(from: book)
            isPresented = true
            return
        }

        let old = model
        let next = KindleBookViewModel(book: book)
        model = next
        isPresented = true
        old?.stopAll()
    }

    func activate(model: KindleBookViewModel) {
        self.model = model
    }

    func isOwning(_ candidate: KindleBookViewModel) -> Bool {
        model === candidate
    }

    func expand() {
        guard model != nil else { return }
        isPresented = true
    }

    func minimize() {
        isPresented = false
    }

    func close() {
        let active = model
        model = nil
        isPresented = false
        active?.stopAll()
    }

    func clear(ifModel candidate: KindleBookViewModel) {
        guard model === candidate else { return }
        model = nil
        isPresented = false
    }
}

@MainActor
final class KindleBookViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var book: KindleBook
    @Published var isPreparing = false
    @Published var statusText = ""
    @Published var mode: ReaderMode = .read
    @Published var readVM: ReadAloudViewModel?
    @Published var explainVM: ExplainViewModel?

    let webView: WKWebView

    private var liveDocument: ReadingDocument?
    private var livePage: CapturedKindlePage?
    private var livePageKey: String?
    private var liveStartParagraphIndex: Int?
    private var liveVisibleTopNorm: CGFloat?
    private var liveVisibleBottomNorm: CGFloat?
    private var pendingCaptureKey: String?
    private var suppressNextScrollParagraphIndex: Int?
    private var lastHighlightedWordByParagraph: [String: Int] = [:]
    private var shownMarkIds = Set<String>()
    private var didLoad = false
    private var pageKeysByDocumentID: [String: [Int: String]] = [:]
    private var lastSyncedPageIndex: Int?
    private var isAdvancingLivePage = false
    private var cancellables = Set<AnyCancellable>()
    private var playbackCancellables = Set<AnyCancellable>()
    private let store = KindleLibraryStore.shared

    // Render layer: consumes word routes and paints highlight/marks onto the live Kindle page.
    private var highlightSequence: Task<Void, Never>?
    private var paragraphPrepTasks: [String: Task<Void, Never>] = [:]
    private var preparedParagraphKeys = Set<String>()

    // Page cache layer: captures ordered Kindle page images + OCR documents. It does not own playback text.
    private var pageCacheTask: Task<Void, Never>?
    private var cachingNextPageAfterKey: String?
    private var cachedNextPage: KindleCachedPage?

    // Playback prefetch layer: owns audio generated for a known utterance. Kept separate from page cache.
    private var cachedStartAudio: KindleAudioPrefetch?

    // Text queue layer: converts cached pages into logical utterances + render routes.
    private var textQueue: KindleTextQueue?
    private var activeReadPageSlot: KindleReadPageSlot = .current

    // Playback layer: tracks continuation after a cross-page utterance has consumed the next page's first paragraph.
    private var pendingCurrentPageContinuation = false
    private var pendingContinuationParagraphIndex: Int?
    private var pendingContinuationSegments: [AudioSegment] = []
    private var pendingContinuationTask: Task<Void, Never>?

    var shouldKeepAliveForMiniPlayer: Bool {
        if AudioPlayerService.shared.currentBookId == book.id { return true }
        if let vm = readVM, vm.currentParagraphIndex >= 0 { return true }
        if let vm = explainVM, vm.status.isActive || vm.isPlaying { return true }
        return false
    }

    init(book: KindleBook) {
        self.book = book
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(WKUserScript(
            source: KindleWebScripts.pageCaptureBootstrap,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func isSameBook(as candidate: KindleBook) -> Bool {
        if book.id == candidate.id { return true }
        if let lhs = book.asin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           let rhs = candidate.asin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !lhs.isEmpty,
           lhs == rhs {
            return true
        }
        return Self.normalizedReaderIdentity(book.readerURL) == Self.normalizedReaderIdentity(candidate.readerURL)
    }

    func refreshMetadata(from latest: KindleBook) {
        guard isSameBook(as: latest) else { return }
        book.title = latest.title.isEmpty ? book.title : latest.title
        book.author = latest.author.isEmpty ? book.author : latest.author
        book.coverURL = latest.coverURL ?? book.coverURL
        book.progressLabel = latest.progressLabel.isEmpty ? book.progressLabel : latest.progressLabel
        book.lastOpenedAt = latest.lastOpenedAt ?? book.lastOpenedAt
        book.lastSyncedAt = max(book.lastSyncedAt, latest.lastSyncedAt)
        book.lastReadPageKey = latest.lastReadPageKey ?? book.lastReadPageKey
        book.lastReadURL = latest.lastReadURL ?? book.lastReadURL
    }

    private static func normalizedReaderIdentity(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        let keep = Set(["asin"])
        components.queryItems = components.queryItems?
            .filter { keep.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
        components.fragment = nil
        return components.string ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        load(book.effectiveReaderURL)
        store.markOpened(book)
    }

    func reload() {
        resetLiveSession()
        if webView.url == nil {
            load(book.effectiveReaderURL)
        } else {
            webView.reload()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusText = String(localized: "打开任意位置，然后点播放开始朗读。")
        installCaptureScript()
    }

    func selectMode(_ newMode: ReaderMode, autoStart: Bool = false) {
        guard newMode == .read else {
            mode = .read
            explainVM?.stop()
            explainVM?.deactivate()
            readVM?.activate()
            Task { _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()") }
            if autoStart {
                Task { try? await startCurrentMode() }
            }
            return
        }
        guard mode != newMode else {
            if autoStart {
                Task { try? await startCurrentMode() }
            }
            return
        }
        if newMode == .read {
            explainVM?.deactivate()
            readVM?.activate()
            Task { _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()") }
        } else {
            readVM?.deactivate()
            explainVM?.activate()
        }
        mode = newMode
        if autoStart {
            Task { try? await startCurrentMode() }
        }
    }

    func startCurrentMode() async throws {
        #if DEBUG
        NSLog("CRDBG KINDLE start requested mode=%@ hasRead=%@ readPara=%d preparing=%@",
              mode.rawValue,
              readVM == nil ? "N" : "Y",
              readVM?.currentParagraphIndex ?? -99,
              isPreparing ? "Y" : "N")
        #endif
        switch mode {
        case .read:
            if let vm = readVM, vm.currentParagraphIndex >= 0, !vm.isFinished {
                vm.togglePlayPause()
                return
            }
            let singlePageDoc = try await ensureLiveDocument(force: true)
            let doc = try await buildTextQueueForCurrentPage(baseDocument: singlePageDoc)
            let vm = readVM ?? makeReadVM(document: doc)
            readVM = vm
            recordPlaybackStart(language: doc.language)
            explainVM?.deactivate()
            vm.activate()
            let start = liveStartParagraphIndex ?? doc.paragraphs.first(where: { $0.type.isReadable })?.id ?? 0
            suppressNextScrollParagraphIndex = start
            #if DEBUG
            NSLog("CRDBG KINDLE read start doc=%@ paras=%d start=%d liveKey=%@",
                  String(doc.id.prefix(8)),
                  doc.paragraphs.count,
                  start,
                  Self.keyLog(livePageKey ?? ""))
            #endif
            if start > 0 {
                vm.jump(to: start)
            } else {
                vm.start()
            }
            KindlePlaybackCenter.shared.activate(model: self)
        case .explain:
            mode = .read
            try await startCurrentMode()
        }
    }

    func stopAll() {
        stopFollowing()
        cancelPageCaching(clearPrepared: true)
        clearPendingContinuation()
        readVM?.stop()
        explainVM?.stop()
        readVM?.deactivate()
        explainVM?.deactivate()
        playbackCancellables.removeAll()
        Task { _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()") }
    }

    func prepareDocument(pageBudget: Int) async throws -> ReadingDocument {
        guard !isPreparing else {
            throw KindleBookError.busy
        }
        isPreparing = true
        statusText = String(localized: "正在准备 Kindle 页面…")
        defer { isPreparing = false }

        installCaptureScript()
        try await waitForPageReady()

        var captured: [CapturedKindlePage] = []
        var seenKeys = Set<String>()
        let target = max(1, min(pageBudget, 10))

        for index in 0..<target {
            if index > 0 {
                statusText = String(format: String(localized: "正在预加载第 %d 页…"), index + 1)
                try await scrollForward()
                try await Task.sleep(nanoseconds: 850_000_000)
            }
            statusText = String(format: String(localized: "正在捕获第 %d 页…"), index + 1)
            let page = try await captureVisiblePage(pageIndex: index)
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if captured.isEmpty { throw KindleBookError.noText }
                break
            }
            if !page.key.isEmpty, seenKeys.contains(page.key) { break }
            if !page.key.isEmpty { seenKeys.insert(page.key) }
            captured.append(page)
        }

        guard !captured.isEmpty else { throw KindleBookError.noImage }
        if let firstKey = captured.first?.key, !firstKey.isEmpty {
            _ = try? await scrollToKey(firstKey)
        }

        let doc = makeDocument(from: captured)
        pageKeysByDocumentID[doc.id] = Dictionary(uniqueKeysWithValues: captured.map { ($0.pageIndex, $0.key) })
        if let first = captured.first {
            store.updateProgress(bookID: book.id, pageKey: first.key, url: first.url, progressLabel: first.progress)
        }
        statusText = String(localized: "已就绪。")
        return doc
    }

    private func ensureLiveDocument(force: Bool = false) async throws -> ReadingDocument {
        if !force, let liveDocument { return liveDocument }
        guard !isPreparing else { throw KindleBookError.busy }
        isPreparing = true
        statusText = String(localized: "正在准备当前 Kindle 页面…")
        defer { isPreparing = false }

        if force {
            liveDocument = nil
            livePage = nil
            livePageKey = nil
            liveStartParagraphIndex = nil
            liveVisibleTopNorm = nil
            liveVisibleBottomNorm = nil
            pendingCaptureKey = nil
            suppressNextScrollParagraphIndex = nil
            textQueue = nil
            activeReadPageSlot = .current
            clearPendingContinuation()
            cancelPageCaching(clearPrepared: true)
            lastHighlightedWordByParagraph.removeAll()
            shownMarkIds.removeAll()
            cancelLiveHighlightTasks()
            playbackCancellables.removeAll()
            readVM?.stop()
            explainVM?.stop()
            readVM = nil
            explainVM = nil
            _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")
        }

        installCaptureScript()
        try await waitForPageReady()
        if force {
            statusText = String(localized: "正在对齐 Kindle 页面…")
            if let alignedKey = try? await alignCurrentReadingPageToTop(), !alignedKey.isEmpty {
                pendingCaptureKey = alignedKey
            }
            try await Task.sleep(nanoseconds: 520_000_000)
        }
        try await waitForKindleImageStable()
        var lastOverlayError: Error?
        for attempt in 1...3 {
            if attempt > 1 {
                statusText = String(localized: "正在刷新当前 Kindle 页面…")
                _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")
                try await Task.sleep(nanoseconds: 220_000_000)
                try await waitForKindleImageStable()
            }
            let page = try await captureVisiblePage(pageIndex: 0, targetKey: pendingCaptureKey)
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KindleBookError.noText
            }
            let doc = makeLiveDocument(from: page)
            guard hasReadableParagraphs(doc) else {
                throw KindleBookError.noText
            }
            do {
                let actualLiveKey = try await installLiveOverlay(page: page, document: doc)
                liveDocument = doc
                livePage = page
                livePageKey = actualLiveKey
                liveStartParagraphIndex = firstVisibleReadableParagraph(
                    in: doc,
                    visibleTopNorm: page.visibleTopNorm,
                    visibleBottomNorm: page.visibleBottomNorm
                ) ?? firstReadableParagraph(in: doc)
                liveVisibleTopNorm = 0
                liveVisibleBottomNorm = 1
                if pendingCaptureKey == page.key {
                    pendingCaptureKey = nil
                }
                #if DEBUG
                let wordCount = doc.paragraphs.reduce(0) { $0 + $1.words.count }
                let startHead = doc.paragraphs.first(where: { $0.id == liveStartParagraphIndex })?.text.prefix(48) ?? ""
                NSLog("CRDBG KINDLE live document key=%@ captured=%@ session=%d kind=%@ paras=%d words=%d chars=%d visible=%.3f..%.3f start=%d head=%@ attempt=%d",
                      Self.keyLog(actualLiveKey),
                      Self.keyLog(page.key),
                      page.sessionId,
                      page.kind,
                      doc.paragraphs.count,
                      wordCount,
                      doc.fullText.count,
                      liveVisibleTopNorm ?? -1,
                      liveVisibleBottomNorm ?? -1,
                      liveStartParagraphIndex ?? -1,
                      String(startHead),
                      attempt)
                #endif
                resetViewModels(document: doc)
                store.updateProgress(bookID: book.id, pageKey: page.key, url: page.url, progressLabel: page.progress)
                if mode == .read {
                    startCachingNextPage(afterKey: actualLiveKey)
                }
                statusText = String(localized: "当前 Kindle 页面已就绪。")
                return doc
            } catch KindleBookError.overlayFailed(let reason) where reason == "live-candidate-not-visible" || reason == "captured-page-not-visible" {
                lastOverlayError = KindleBookError.overlayFailed(reason)
                #if DEBUG
                NSLog("CRDBG KINDLE live recapture attempt=%d key=%@ reason=%@",
                      attempt,
                      Self.keyLog(page.key),
                      reason)
                #endif
                liveDocument = nil
                livePage = nil
                livePageKey = nil
                liveStartParagraphIndex = nil
                liveVisibleTopNorm = nil
                liveVisibleBottomNorm = nil
                pendingCaptureKey = nil
                textQueue = nil
                activeReadPageSlot = .current
                continue
            }
        }
        throw lastOverlayError ?? KindleBookError.overlayFailed("live-candidate-not-visible")
    }

    private func resetLiveSession() {
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveVisibleTopNorm = nil
        liveVisibleBottomNorm = nil
        pendingCaptureKey = nil
        suppressNextScrollParagraphIndex = nil
        textQueue = nil
        activeReadPageSlot = .current
        clearPendingContinuation()
        cancelPageCaching(clearPrepared: true)
        lastHighlightedWordByParagraph.removeAll()
        shownMarkIds.removeAll()
        cancelLiveHighlightTasks()
        playbackCancellables.removeAll()
        readVM?.stop()
        explainVM?.stop()
        readVM = nil
        explainVM = nil
        KindlePlaybackCenter.shared.clear(ifModel: self)
        Task { _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()") }
    }

    private func resetViewModels(document: ReadingDocument) {
        playbackCancellables.removeAll()
        shownMarkIds.removeAll()
        lastHighlightedWordByParagraph.removeAll()
        cancelLiveHighlightTasks()
        readVM = makeReadVM(document: document)
        explainVM = makeExplainVM(document: document)
        bindLivePlayback(document: document)
    }

    private func makeReadVM(document: ReadingDocument) -> ReadAloudViewModel {
        let vm = ReadAloudViewModel(document: document)
        vm.configurePlaybackMetadata(id: book.id, title: book.title, coverURL: book.coverURL)
        return vm
    }

    private func makeExplainVM(document: ReadingDocument) -> ExplainViewModel {
        let vm = ExplainViewModel(document: document)
        vm.scenario = ExplainContentType.book.rawValue
        vm.configurePlaybackMetadata(
            id: book.id,
            title: book.title,
            coverURL: book.coverURL,
            chapterTitle: String(localized: "解读")
        )
        return vm
    }

    private func recordPlaybackStart(language: String) {
        store.markOpened(book)
        HistoryStore.shared.recordKindleBook(book, language: language)
    }

    private func buildTextQueueForCurrentPage(baseDocument: ReadingDocument) async throws -> ReadingDocument {
        guard mode == .read, let currentPage = livePage else {
            textQueue = nil
            activeReadPageSlot = .current
            return baseDocument
        }

        let currentKey = (livePageKey ?? currentPage.key).trimmingCharacters(in: .whitespacesAndNewlines)
        var nextPrepared: KindleCachedPage?
        if let prepared = cachedNextPage,
           prepared.afterKey == currentKey,
           !prepared.page.key.isEmpty,
           prepared.page.key != currentKey {
            nextPrepared = prepared
        } else if !currentKey.isEmpty {
            do {
                let nextPage = try await captureNextPage(afterKey: currentKey)
                if !nextPage.key.isEmpty, nextPage.key != currentKey {
                    let nextDocument = makeLiveDocument(from: nextPage)
                    if hasReadableParagraphs(nextDocument) {
                        nextPrepared = KindleCachedPage(
                            afterKey: currentKey,
                            page: nextPage,
                            document: nextDocument,
                            startParagraphIndex: firstReadableParagraph(in: nextDocument)
                        )
                        cachedNextPage = nextPrepared
                    }
                }
            } catch {
                #if DEBUG
                NSLog("CRDBG KINDLE read window next miss key=%@ error=%@",
                      Self.keyLog(currentKey),
                      error.localizedDescription)
                #endif
            }
        }

        let window = buildTextQueue(currentPage: currentPage, currentDocument: baseDocument, nextPrepared: nextPrepared)
        textQueue = window
        activeReadPageSlot = .current
        liveDocument = window.document
        liveStartParagraphIndex = window.startParagraphIndex
        resetViewModels(document: window.document)
        let actualKey = try await installLiveOverlay(page: currentPage, document: window.currentOverlayDocument)
        livePageKey = actualKey
        #if DEBUG
        NSLog("CRDBG KINDLE read window ready current=%@ next=%@ paras=%d start=%d bridge=%@",
              Self.keyLog(actualKey),
              Self.keyLog(window.nextPage?.key ?? ""),
              window.document.paragraphs.count,
              window.startParagraphIndex ?? -1,
              window.hasCrossPageBridge ? "Y" : "N")
        #endif
        return window.document
    }

    private func buildTextQueue(
        currentPage: CapturedKindlePage,
        currentDocument: ReadingDocument,
        nextPrepared: KindleCachedPage?
    ) -> KindleTextQueue {
        let currentParas = currentDocument.paragraphs.filter(Self.isReadableKindleParagraph)
        let nextParas = nextPrepared?.document.paragraphs.filter(Self.isReadableKindleParagraph) ?? []
        let shouldBridge =
            currentParas.last.flatMap { last in
                nextParas.first.map { Self.shouldMergeKindleContinuation(prev: last.text, next: $0.text) }
            } ?? false

        var logical: [ReadingParagraph] = []
        var currentOverlay: [ReadingParagraph] = []
        var nextOverlay: [ReadingParagraph] = []
        var routes: [String: KindleRenderRoute] = [:]
        var nextWordID = 0

        func remap(_ words: [OCRWord]) -> [OCRWord] {
            words.map { word in
                defer { nextWordID += 1 }
                return OCRWord(id: nextWordID, text: word.text, bboxNorm: word.bboxNorm)
            }
        }

        func routeKey(paragraphID: Int, wordIndex: Int) -> String { "\(paragraphID)#\(wordIndex)" }

        func appendSingle(_ source: ReadingParagraph, slot: KindleReadPageSlot) {
            let paragraphID = logical.count
            let words = remap(source.words)
            let paragraph = ReadingParagraph(
                id: paragraphID,
                text: source.text,
                type: source.type,
                words: words,
                bboxNorm: source.bboxNorm ?? unionNorm(for: words),
                pageIndex: slot == .current ? 0 : 1
            )
            logical.append(paragraph)
            let overlayParagraph = paragraph
            if slot == .current {
                currentOverlay.append(overlayParagraph)
            } else {
                nextOverlay.append(overlayParagraph)
            }
            for idx in words.indices {
                routes[routeKey(paragraphID: paragraphID, wordIndex: idx)] = KindleRenderRoute(
                    slot: slot,
                    overlayParagraphID: paragraphID,
                    overlayWordIndex: idx
                )
            }
        }

        func appendBridge(_ current: ReadingParagraph, _ next: ReadingParagraph) {
            let paragraphID = logical.count
            let currentWords = remap(current.words)
            let nextWords = remap(next.words)
            let text = Self.joinKindleContinuation(prev: current.text, next: next.text)
            let logicalWords = currentWords + nextWords
            logical.append(ReadingParagraph(
                id: paragraphID,
                text: text,
                type: current.type,
                words: logicalWords,
                bboxNorm: current.bboxNorm ?? unionNorm(for: currentWords),
                pageIndex: 0
            ))
            currentOverlay.append(ReadingParagraph(
                id: paragraphID,
                text: text,
                type: current.type,
                words: currentWords,
                bboxNorm: current.bboxNorm ?? unionNorm(for: currentWords),
                pageIndex: 0
            ))
            nextOverlay.append(ReadingParagraph(
                id: paragraphID,
                text: text,
                type: next.type,
                words: nextWords,
                bboxNorm: next.bboxNorm ?? unionNorm(for: nextWords),
                pageIndex: 1
            ))
            for idx in currentWords.indices {
                routes[routeKey(paragraphID: paragraphID, wordIndex: idx)] = KindleRenderRoute(
                    slot: .current,
                    overlayParagraphID: paragraphID,
                    overlayWordIndex: idx
                )
            }
            for idx in nextWords.indices {
                routes[routeKey(paragraphID: paragraphID, wordIndex: currentWords.count + idx)] = KindleRenderRoute(
                    slot: .next,
                    overlayParagraphID: paragraphID,
                    overlayWordIndex: idx
                )
            }
        }

        let bridgeCurrentIndex = shouldBridge ? currentParas.indices.last : nil
        let bridgeNextIndex = shouldBridge && !nextParas.isEmpty ? nextParas.startIndex : nil

        for idx in currentParas.indices {
            if idx == bridgeCurrentIndex, let nextIndex = bridgeNextIndex {
                appendBridge(currentParas[idx], nextParas[nextIndex])
            } else {
                appendSingle(currentParas[idx], slot: .current)
            }
        }

        let start = liveStartParagraphIndex.flatMap { idx in
            logical.indices.contains(idx) ? idx : nil
        } ?? logical.first(where: { $0.type.isReadable })?.id

        let language = currentDocument.language
        let document = ReadingDocument(
            title: currentDocument.title,
            sourceKind: .kindle,
            language: language,
            paragraphs: logical,
            sourceURL: currentDocument.sourceURL
        )
        let currentOverlayDocument = ReadingDocument(
            title: currentDocument.title,
            sourceKind: .kindle,
            language: language,
            paragraphs: currentOverlay,
            sourceURL: currentDocument.sourceURL
        )
        let nextOverlayDocument = nextPrepared.map { prepared in
            ReadingDocument(
                title: prepared.document.title,
                sourceKind: .kindle,
                language: prepared.document.language,
                paragraphs: nextOverlay,
                sourceURL: prepared.document.sourceURL
            )
        }
        let nextResumeParagraphIndex: Int? = {
            guard let nextPrepared else { return nil }
            if shouldBridge {
                return nextParas.dropFirst().first?.id
            }
            return firstReadableParagraph(in: nextPrepared.document)
        }()

        return KindleTextQueue(
            document: document,
            currentPage: currentPage,
            currentOverlayDocument: currentOverlayDocument,
            nextPage: nextPrepared?.page,
            nextBaseDocument: nextPrepared?.document,
            nextOverlayDocument: nextOverlayDocument,
            nextResumeParagraphIndex: nextResumeParagraphIndex,
            wordRoutes: routes,
            startParagraphIndex: start,
            hasCrossPageBridge: shouldBridge
        )
    }

    private func hasReadableParagraphs(_ document: ReadingDocument) -> Bool {
        document.paragraphs.contains {
            $0.type.isReadable && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func bindLivePlayback(document: ReadingDocument) {
        guard let readVM, let explainVM else { return }

        readVM.$photoHighlightWordIndex
            .receive(on: RunLoop.main)
            .sink { [weak self, weak readVM] wordIndex in
                guard let self,
                      let readVM,
                      self.mode == .read,
                      let wordIndex else { return }
                let paragraphIndex = readVM.currentParagraphIndex
                guard paragraphIndex >= 0 else { return }
                self.enqueueHighlightWord(paragraphIndex: paragraphIndex, wordIndex: wordIndex)
            }
            .store(in: &playbackCancellables)

        readVM.$currentParagraphIndex
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] paragraphIndex in
                guard let self, self.mode == .read, paragraphIndex >= 0 else { return }
                let key = "\(self.livePageKey ?? "")#\(paragraphIndex)"
                self.lastHighlightedWordByParagraph.removeValue(forKey: key)
                self.preparedParagraphKeys.remove(key)
            }
            .store(in: &playbackCancellables)

        readVM.$isFinished
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] finished in
                guard let self, finished, self.mode == .read else { return }
                Task { await self.advanceToNextLivePageIfNeeded() }
            }
            .store(in: &playbackCancellables)

        explainVM.$activeMarks
            .receive(on: RunLoop.main)
            .sink { [weak self] marks in
                guard let self else { return }
                Task { await self.pushMarks(marks) }
            }
            .store(in: &playbackCancellables)

        explainVM.$scrollTarget
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] paragraphIndex in
                guard let self, self.mode == .explain, paragraphIndex >= 0 else { return }
                Task { await self.scrollToParagraph(paragraphIndex) }
            }
            .store(in: &playbackCancellables)
    }

    @discardableResult
    private func startReadPlayback(
        document: ReadingDocument,
        startHint: Int? = nil,
        prefetchedIndex: Int? = nil,
        prefetchedSegments: [AudioSegment] = [],
        reason: String
    ) -> Bool {
        guard mode == .read, let vm = readVM else { return false }
        vm.activate()
        let start = startHint
            ?? liveStartParagraphIndex
            ?? document.paragraphs.first(where: { $0.type.isReadable })?.id
            ?? 0
        suppressNextScrollParagraphIndex = start
        KindleRunLog.write("KINDLE read playback start reason=\(reason) key=\(Self.keyLog(livePageKey ?? "")) p=\(start) prefetched=\(prefetchedIndex == start ? prefetchedSegments.count : 0)")
        if prefetchedIndex == start, !prefetchedSegments.isEmpty {
            vm.startWithPrefetchedSegments(prefetchedSegments, paragraphIndex: start)
        } else if start > 0 {
            vm.jump(to: start)
        } else {
            vm.start()
        }
        return true
    }

    private func resetReadSourceStateForAdvance() async {
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveVisibleTopNorm = nil
        liveVisibleBottomNorm = nil
        pendingCaptureKey = nil
        suppressNextScrollParagraphIndex = nil
        textQueue = nil
        activeReadPageSlot = .current
        lastHighlightedWordByParagraph.removeAll()
        shownMarkIds.removeAll()
        cancelLiveHighlightTasks()
        _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")
    }

    private func advanceToNextLivePageIfNeeded() async {
        guard mode == .read, !isAdvancingLivePage else { return }
        isAdvancingLivePage = true
        let oldKey = livePageKey ?? ""
        let oldTop = liveVisibleTopNorm
        let oldBottom = liveVisibleBottomNorm
        defer { isAdvancingLivePage = false }

        statusText = String(localized: "正在加载下一页 Kindle 页面…")
        KindleRunLog.write("KINDLE read advance begin key=\(Self.keyLog(oldKey))")
        #if DEBUG
        NSLog("CRDBG KINDLE live advance begin key=%@ top=%@ bottom=%@",
              Self.keyLog(oldKey),
              String(describing: oldTop),
              String(describing: oldBottom))
        #endif

        if await continueCurrentTextQueueIfNeeded() { return }
        if await advanceUsingCachedPageIfAvailable(after: oldKey) { return }
        await advanceBySourceScroll(oldKey: oldKey, oldTop: oldTop, oldBottom: oldBottom)
    }

    private func continueCurrentTextQueueIfNeeded() async -> Bool {
        if pendingCurrentPageContinuation,
           let continuationDocument = liveDocument,
           let resumeIndex = liveStartParagraphIndex {
            do {
                pendingCurrentPageContinuation = false
                let prefetchedIndex = pendingContinuationParagraphIndex
                let prefetchedSegments = pendingContinuationSegments
                pendingContinuationParagraphIndex = nil
                pendingContinuationSegments = []
                pendingContinuationTask?.cancel()
                pendingContinuationTask = nil

                let doc = try await buildTextQueueForCurrentPage(baseDocument: continuationDocument)
                let start = liveStartParagraphIndex ?? resumeIndex
                KindleRunLog.write("KINDLE read bridge continue key=\(Self.keyLog(livePageKey ?? "")) start=\(start) prefetched=\(prefetchedIndex == start ? prefetchedSegments.count : 0)")
                #if DEBUG
                NSLog("CRDBG KINDLE bridge continue key=%@ start=%d paras=%d prefetched=%d",
                      Self.keyLog(livePageKey ?? ""),
                      start,
                      doc.paragraphs.count,
                      prefetchedIndex == start ? prefetchedSegments.count : 0)
                #endif
                _ = startReadPlayback(
                    document: doc,
                    startHint: start,
                    prefetchedIndex: prefetchedIndex,
                    prefetchedSegments: prefetchedSegments,
                    reason: "current-page-continuation"
                )
                return true
            } catch {
                KindleRunLog.write("KINDLE read bridge continue miss key=\(Self.keyLog(livePageKey ?? "")) error=\(error.localizedDescription)")
                clearPendingContinuation()
            }
        }
        return false
    }

    private func advanceUsingCachedPageIfAvailable(after oldKey: String) async -> Bool {
        if let prepared = cachedNextPage,
           prepared.afterKey == oldKey,
           !prepared.page.key.isEmpty,
           prepared.page.key != oldKey {
            do {
                cachedNextPage = nil
                let singlePageDoc = try await activatePreparedNextPage(prepared, oldKey: oldKey)
                let doc = try await buildTextQueueForCurrentPage(baseDocument: singlePageDoc)
                let newKey = livePageKey ?? ""
                let start = liveStartParagraphIndex ?? doc.paragraphs.first(where: { $0.type.isReadable })?.id ?? 0
                let startAudio = cachedStartAudio
                if startAudio?.pageKey == prepared.page.key {
                    cachedStartAudio = nil
                }
                #if DEBUG
                NSLog("CRDBG KINDLE live advance prepared ready oldKey=%@ newKey=%@ start=%d paras=%d chars=%d",
                      Self.keyLog(oldKey),
                      Self.keyLog(newKey),
                      start,
                      doc.paragraphs.count,
                      doc.fullText.count)
                #endif
                if start == startAudio?.paragraphIndex, !(startAudio?.segments.isEmpty ?? true) {
                    KindleRunLog.write("KINDLE read advance prefetched-audio key=\(Self.keyLog(newKey)) p=\(start) segs=\(startAudio?.segments.count ?? 0)")
                    #if DEBUG
                    NSLog("CRDBG KINDLE live advance use prefetched audio key=%@ p=%d segs=%d",
                          Self.keyLog(newKey),
                          start,
                          startAudio?.segments.count ?? 0)
                    #endif
                }
                _ = startReadPlayback(
                    document: doc,
                    startHint: start,
                    prefetchedIndex: startAudio?.paragraphIndex,
                    prefetchedSegments: startAudio?.segments ?? [],
                    reason: "cached-next-page"
                )
                return true
            } catch {
                #if DEBUG
                NSLog("CRDBG KINDLE prepared advance fallback oldKey=%@ prepared=%@ error=%@",
                      Self.keyLog(oldKey),
                      Self.keyLog(prepared.page.key),
                      error.localizedDescription)
                #endif
                cachedNextPage = nil
            }
        }
        return false
    }

    private func advanceBySourceScroll(oldKey: String, oldTop: CGFloat?, oldBottom: CGFloat?) async {
        await resetReadSourceStateForAdvance()

        do {
            var advanceResult: [String: Any] = [:]
            var doc: ReadingDocument?
            var lastAdvanceError: Error?

            for attempt in 1...5 {
                advanceResult = try await scrollForward(fromVisibleBottom: 1, keepingKey: oldKey)
                let advanceMode = advanceResult["mode"] as? String ?? ""
                let afterKey = advanceResult["afterKey"] as? String ?? ""
                let targetKey = advanceResult["targetKey"] as? String ?? ""

                if !targetKey.isEmpty, targetKey != oldKey {
                    pendingCaptureKey = targetKey
                } else if !afterKey.isEmpty, afterKey != oldKey {
                    pendingCaptureKey = afterKey
                } else {
                    pendingCaptureKey = nil
                }

                try await Task.sleep(nanoseconds: 850_000_000)
                do {
                    let loadedSinglePageDoc = try await ensureLiveDocument(force: false)
                    let loadedDoc = try await buildTextQueueForCurrentPage(baseDocument: loadedSinglePageDoc)
                    guard hasReadableParagraphs(loadedDoc) else {
                        throw KindleBookError.noText
                    }
                    doc = loadedDoc
                    break
                } catch {
                    lastAdvanceError = error
                    #if DEBUG
                    NSLog("CRDBG KINDLE live advance retry attempt=%d mode=%@ oldKey=%@ after=%@ target=%@ error=%@",
                          attempt,
                          advanceMode,
                          Self.keyLog(oldKey),
                          Self.keyLog(afterKey),
                          Self.keyLog(targetKey),
                          error.localizedDescription)
                    #endif
                    await resetReadSourceStateForAdvance()
                    try await Task.sleep(nanoseconds: 280_000_000)
                }
            }

            guard let doc else {
                throw lastAdvanceError ?? KindleBookError.noText
            }
            let newKey = livePageKey ?? ""
            let newTop = liveVisibleTopNorm
            let newBottom = liveVisibleBottomNorm
            if !oldKey.isEmpty, oldKey == newKey {
                statusText = String(localized: "已到达当前 Kindle 内容末尾。")
                #if DEBUG
                NSLog("CRDBG KINDLE live advance no-move key=%@ oldTop=%@ newTop=%@",
                      Self.keyLog(newKey),
                      String(describing: oldTop),
                      String(describing: newTop))
                #endif
                return
            }
            let start = liveStartParagraphIndex ?? doc.paragraphs.first(where: { $0.type.isReadable })?.id ?? 0
            KindleRunLog.write("KINDLE read advance ready key=\(Self.keyLog(newKey)) old=\(Self.keyLog(oldKey)) start=\(start) paras=\(doc.paragraphs.count)")
            #if DEBUG
            NSLog("CRDBG KINDLE live advance ready key=%@ oldKey=%@ oldTop=%@ oldBottom=%@ newTop=%@ newBottom=%@ start=%d advance=%@",
                  Self.keyLog(newKey),
                  Self.keyLog(oldKey),
                  String(describing: oldTop),
                  String(describing: oldBottom),
                  String(describing: newTop),
                  String(describing: newBottom),
                  start,
                  String(describing: advanceResult))
            #endif
            _ = startReadPlayback(document: doc, startHint: start, reason: "source-advance")
        } catch {
            statusText = error.localizedDescription
            KindleRunLog.write("KINDLE read advance error \(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE live advance error %@", error.localizedDescription)
            #endif
        }
    }

    private func installLiveOverlay(page: CapturedKindlePage, document: ReadingDocument) async throws -> String {
        let payload: [String: Any] = [
            "key": page.key,
            "sessionId": page.sessionId,
            "title": page.title,
            "imagePixelWidth": Double(page.document.imagePixelSize?.width ?? 0),
            "imagePixelHeight": Double(page.document.imagePixelSize?.height ?? 0),
            "paragraphs": document.paragraphs.map { paragraphPayload($0) }
        ]
        let json = try jsonString(payload)
        var result: [String: Any] = [:]
        var lastReason = "unknown"
        for attempt in 0..<8 {
            result = try await evaluateJSON("window.__crKindleLiveSetPage && window.__crKindleLiveSetPage(\(json))")
            if result["ok"] as? Bool == true { break }
            lastReason = result["reason"] as? String ?? lastReason
            #if DEBUG
            NSLog("CRDBG KINDLE live overlay wait attempt=%d key=%@ reason=%@ candidates=%@",
                  attempt + 1,
                  Self.keyLog(page.key),
                  lastReason,
                  String(describing: result["candidates"] ?? ""))
            #endif
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        if result["ok"] as? Bool != true {
            throw KindleBookError.overlayFailed(lastReason)
        }
        let actualKey = result["key"] as? String ?? page.key
        #if DEBUG
        NSLog("CRDBG KINDLE live overlay key=%@ requested=%@ session=%d kind=%@ paras=%d resultKind=%@ fallback=%@ parent=%@ position=%@ local=%@",
              Self.keyLog(actualKey),
              Self.keyLog(page.key),
              page.sessionId,
              page.kind,
              document.paragraphs.count,
              String(describing: result["kind"] ?? ""),
              String(describing: result["fallback"] ?? false),
              String(describing: result["parent"] ?? ""),
              String(describing: result["position"] ?? ""),
              String(describing: result["local"] ?? ""))
        #endif
        return actualKey
    }

    private func highlightWord(paragraphIndex: Int, wordIndex: Int) async {
        let route = textQueue?.wordRoutes["\(paragraphIndex)#\(wordIndex)"]
        if let route {
            await switchRenderPageIfNeeded(to: route.slot)
            await paintHighlightWord(paragraphIndex: route.overlayParagraphID, wordIndex: route.overlayWordIndex)
            if route.slot == .current,
               textQueue?.wordRoutes["\(paragraphIndex)#\(wordIndex + 1)"]?.slot == .next {
                Task { [weak self] in await self?.switchRenderPageIfNeeded(to: .next) }
            }
        } else {
            await paintHighlightWord(paragraphIndex: paragraphIndex, wordIndex: wordIndex)
        }
    }

    private func paintHighlightWord(paragraphIndex: Int, wordIndex: Int) async {
        let paragraphKey = liveParagraphKey(paragraphIndex)
        guard !Task.isCancelled else { return }
        if let last = lastHighlightedWordByParagraph[paragraphKey], wordIndex < last {
            #if DEBUG
            NSLog("CRDBG KINDLE highlight skip backwards key=%@ p=%d word=%d<%d",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  wordIndex,
                  last)
            #endif
            return
        }
        lastHighlightedWordByParagraph[paragraphKey] = wordIndex
        do {
            let result = try await evaluateJSON("window.__crKindleLiveHighlightWord && window.__crKindleLiveHighlightWord(\(paragraphIndex), \(wordIndex))")
            #if DEBUG
            if result["ok"] as? Bool != true {
                KindleRunLog.write("KINDLE read highlight miss key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex) reason=\(result["reason"] as? String ?? "unknown")")
                NSLog("CRDBG KINDLE highlight miss key=%@ p=%d w=%d reason=%@",
                      Self.keyLog(livePageKey ?? ""),
                      paragraphIndex,
                      wordIndex,
                      result["reason"] as? String ?? "unknown")
            } else {
                if wordIndex == 0 || wordIndex % 12 == 0 {
                    KindleRunLog.write("KINDLE read highlight hit key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex) word=\(String(describing: result["wordText"] ?? ""))")
                }
                NSLog("CRDBG KINDLE highlight key=%@ p=%d w=%d word=%@ bbox=%@ pct=%@ xy=%@,%@ %@x%@ screen=%@ ov=%@,%@ %@x%@ img=%@ imgOffset=%@ parentRect=%@ stale=%@ position=%@ parent=%@ point=%@ local=%@",
                      Self.keyLog(livePageKey ?? ""),
                      paragraphIndex,
                      wordIndex,
                      String(describing: result["wordText"] ?? ""),
                      String(describing: result["bboxNorm"] ?? ""),
                      String(describing: result["pct"] ?? ""),
                      String(describing: result["left"] ?? "?"),
                      String(describing: result["top"] ?? "?"),
                      String(describing: result["width"] ?? "?"),
                      String(describing: result["height"] ?? "?"),
                      String(describing: result["screen"] ?? ""),
                      String(describing: result["overlayLeft"] ?? "?"),
                      String(describing: result["overlayTop"] ?? "?"),
                      String(describing: result["overlayWidth"] ?? "?"),
                      String(describing: result["overlayHeight"] ?? "?"),
                      String(describing: result["imgRect"] ?? ""),
                      String(describing: result["imgOffset"] ?? ""),
                      String(describing: result["parentRect"] ?? ""),
                      String(describing: result["stale"] ?? false),
                      String(describing: result["position"] ?? ""),
                      String(describing: result["parent"] ?? ""),
                      String(describing: result["point"] ?? ""),
                      String(describing: result["local"] ?? ""))
            }
            #endif
        } catch {
            KindleRunLog.write("KINDLE read highlight error key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex) error=\(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE highlight error key=%@ p=%d w=%d %@",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  wordIndex,
                  error.localizedDescription)
            #endif
        }
    }

    private func switchRenderPageIfNeeded(to slot: KindleReadPageSlot) async {
        guard activeReadPageSlot != slot, let window = textQueue else { return }
        switch slot {
        case .current:
            guard let key = window.currentPage.key.nilIfEmpty else { return }
            await activateRenderPage(
                slot: .current,
                page: window.currentPage,
                overlayDocument: window.currentOverlayDocument,
                key: key
            )
        case .next:
            guard let page = window.nextPage,
                  let overlayDocument = window.nextOverlayDocument,
                  let key = page.key.nilIfEmpty else { return }
            await activateRenderPage(
                slot: .next,
                page: page,
                overlayDocument: overlayDocument,
                key: key
            )
        }
    }

    private func activateRenderPage(
        slot: KindleReadPageSlot,
        page: CapturedKindlePage,
        overlayDocument: ReadingDocument,
        key: String
    ) async {
        do {
            _ = try await scrollToKey(key, block: "start")
            try await Task.sleep(nanoseconds: 260_000_000)
            try await waitForKindleImageStable()
            let actualKey = try await installLiveOverlay(page: page, document: overlayDocument)
            livePage = page
            livePageKey = actualKey
            activeReadPageSlot = slot
            lastHighlightedWordByParagraph.removeAll()
            store.updateProgress(bookID: book.id, pageKey: page.key, url: page.url, progressLabel: page.progress)
            if slot == .next, mode == .read {
                if let window = textQueue,
                   let document = window.nextBaseDocument,
                   let resumeIndex = window.nextResumeParagraphIndex {
                    liveDocument = document
                    liveStartParagraphIndex = resumeIndex
                    pendingCurrentPageContinuation = true
                    startPrepareCurrentPageContinuation(document: document, paragraphIndex: resumeIndex)
                    KindleRunLog.write("KINDLE read bridge switched key=\(Self.keyLog(actualKey)) resume=\(resumeIndex)")
                }
                startCachingNextPage(afterKey: actualKey)
            }
            #if DEBUG
            NSLog("CRDBG KINDLE read window switch slot=%@ key=%@ paras=%d",
                  slot.logName,
                  Self.keyLog(actualKey),
                  overlayDocument.paragraphs.count)
            #endif
        } catch {
            #if DEBUG
            NSLog("CRDBG KINDLE read window switch miss slot=%@ key=%@ error=%@",
                  slot.logName,
                  Self.keyLog(key),
                  error.localizedDescription)
            #endif
        }
    }

    private func liveParagraphKey(_ paragraphIndex: Int) -> String {
        "\(livePageKey ?? "")#\(paragraphIndex)"
    }

    private func cancelLiveHighlightTasks() {
        highlightSequence?.cancel()
        highlightSequence = nil
        paragraphPrepTasks.values.forEach { $0.cancel() }
        paragraphPrepTasks.removeAll()
        preparedParagraphKeys.removeAll()
    }

    private func cancelPageCaching(clearPrepared: Bool) {
        pageCacheTask?.cancel()
        pageCacheTask = nil
        cachingNextPageAfterKey = nil
        if clearPrepared {
            cachedNextPage = nil
            cachedStartAudio = nil
        }
    }

    private func clearPendingContinuation() {
        pendingCurrentPageContinuation = false
        pendingContinuationParagraphIndex = nil
        pendingContinuationSegments = []
        pendingContinuationTask?.cancel()
        pendingContinuationTask = nil
    }

    private func startPrepareCurrentPageContinuation(document: ReadingDocument, paragraphIndex: Int) {
        guard pendingContinuationParagraphIndex != paragraphIndex || pendingContinuationSegments.isEmpty else { return }
        pendingContinuationTask?.cancel()
        pendingContinuationParagraphIndex = paragraphIndex
        pendingContinuationSegments = []
        guard let paragraph = document.paragraphs.first(where: { $0.id == paragraphIndex }) else { return }
        KindleRunLog.write("KINDLE read continuation preload start p=\(paragraphIndex)")
        pendingContinuationTask = Task { [weak self] in
            do {
                let segments = try await self?.generateDetachedTTSSegments(
                    paragraphIndex: paragraphIndex,
                    text: paragraph.text,
                    language: document.language
                ) ?? []
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.pendingContinuationParagraphIndex == paragraphIndex else { return }
                    self.pendingContinuationSegments = segments
                    self.pendingContinuationTask = nil
                    KindleRunLog.write("KINDLE read continuation preload ready p=\(paragraphIndex) segs=\(segments.count)")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.pendingContinuationParagraphIndex == paragraphIndex else { return }
                    self.pendingContinuationTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.pendingContinuationParagraphIndex == paragraphIndex else { return }
                    self.pendingContinuationTask = nil
                    KindleRunLog.write("KINDLE read continuation preload miss p=\(paragraphIndex) error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func startCachingNextPage(afterKey rawKey: String) {
        let afterKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterKey.isEmpty else { return }
        if cachedNextPage?.afterKey == afterKey { return }
        if cachingNextPageAfterKey == afterKey { return }

        cancelPageCaching(clearPrepared: false)
        cachingNextPageAfterKey = afterKey
        #if DEBUG
        NSLog("CRDBG KINDLE page preload start after=%@", Self.keyLog(afterKey))
        #endif
        KindleRunLog.write("KINDLE read preload start after=\(Self.keyLog(afterKey))")
        pageCacheTask = Task { [weak self] in
            await self?.cacheNextPage(afterKey: afterKey)
        }
    }

    private func cacheNextPage(afterKey: String) async {
        defer {
            if cachingNextPageAfterKey == afterKey {
                cachingNextPageAfterKey = nil
                pageCacheTask = nil
            }
        }
        do {
            let page = try await captureNextPage(afterKey: afterKey)
            guard !Task.isCancelled else { return }
            guard !page.key.isEmpty, page.key != afterKey else {
                throw KindleBookError.captureFailed("next-page-same-key")
            }
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KindleBookError.noText
            }
            let doc = makeLiveDocument(from: page)
            guard hasReadableParagraphs(doc) else {
                throw KindleBookError.noText
            }
            cachedNextPage = KindleCachedPage(
                afterKey: afterKey,
                page: page,
                document: doc,
                startParagraphIndex: firstReadableParagraph(in: doc)
            )
            cachedStartAudio = nil
            #if DEBUG
            NSLog("CRDBG KINDLE page preload ready after=%@ key=%@ paras=%d words=%d chars=%d",
                  Self.keyLog(afterKey),
                  Self.keyLog(page.key),
                  doc.paragraphs.count,
                  doc.paragraphs.reduce(0) { $0 + $1.words.count },
                  doc.fullText.count)
            #endif
            KindleRunLog.write("KINDLE read preload ready after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(page.key)) paras=\(doc.paragraphs.count) chars=\(doc.fullText.count)")
            do {
                let startIndex = firstReadableParagraph(in: doc) ?? -1
                if startIndex >= 0,
                   let paragraph = doc.paragraphs.first(where: { $0.id == startIndex }) {
                    let segments = try await generateDetachedTTSSegments(
                        paragraphIndex: startIndex,
                        text: paragraph.text,
                        language: doc.language
                    )
                    guard !Task.isCancelled else { return }
                    if let current = cachedNextPage,
                       current.afterKey == afterKey,
                       current.page.key == page.key {
                        cachedStartAudio = KindleAudioPrefetch(
                            pageKey: page.key,
                            paragraphIndex: startIndex,
                            segments: segments
                        )
                        #if DEBUG
                        NSLog("CRDBG KINDLE page preload tts ready after=%@ key=%@ p=%d segs=%d",
                              Self.keyLog(afterKey),
                              Self.keyLog(page.key),
                              startIndex,
                              segments.count)
                        #endif
                        KindleRunLog.write("KINDLE read preload tts-ready after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(page.key)) p=\(startIndex) segs=\(segments.count)")
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                KindleRunLog.write("KINDLE read preload tts-miss after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(page.key)) error=\(error.localizedDescription)")
                #if DEBUG
                NSLog("CRDBG KINDLE page preload tts miss after=%@ key=%@ error=%@",
                      Self.keyLog(afterKey),
                      Self.keyLog(page.key),
                      error.localizedDescription)
                #endif
            }
        } catch is CancellationError {
            KindleRunLog.write("KINDLE read preload cancelled after=\(Self.keyLog(afterKey))")
            #if DEBUG
            NSLog("CRDBG KINDLE page preload cancelled after=%@", Self.keyLog(afterKey))
            #endif
        } catch {
            KindleRunLog.write("KINDLE read preload miss after=\(Self.keyLog(afterKey)) error=\(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE page preload miss after=%@ error=%@",
                  Self.keyLog(afterKey),
                  error.localizedDescription)
            #endif
        }
    }

    private func activatePreparedNextPage(_ prepared: KindleCachedPage, oldKey: String) async throws -> ReadingDocument {
        statusText = String(localized: "正在打开下一页 Kindle 页面…")
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveVisibleTopNorm = nil
        liveVisibleBottomNorm = nil
        pendingCaptureKey = nil
        suppressNextScrollParagraphIndex = nil
        textQueue = nil
        activeReadPageSlot = .current
        lastHighlightedWordByParagraph.removeAll()
        shownMarkIds.removeAll()
        cancelLiveHighlightTasks()
        _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")

        _ = try await scrollToKey(prepared.page.key, block: "start")
        try await Task.sleep(nanoseconds: 520_000_000)
        try await waitForKindleImageStable()

        let actualLiveKey = try await installLiveOverlay(page: prepared.page, document: prepared.document)
        liveDocument = prepared.document
        livePage = prepared.page
        livePageKey = actualLiveKey
        liveStartParagraphIndex = prepared.startParagraphIndex ?? firstReadableParagraph(in: prepared.document)
        liveVisibleTopNorm = 0
        liveVisibleBottomNorm = 1
        resetViewModels(document: prepared.document)
        store.updateProgress(bookID: book.id, pageKey: prepared.page.key, url: prepared.page.url, progressLabel: prepared.page.progress)
        if mode == .read {
            startCachingNextPage(afterKey: actualLiveKey)
        }
        statusText = String(localized: "下一页 Kindle 页面已就绪。")
        #if DEBUG
        NSLog("CRDBG KINDLE page preload consumed oldKey=%@ requested=%@ actual=%@ start=%d",
              Self.keyLog(oldKey),
              Self.keyLog(prepared.page.key),
              Self.keyLog(actualLiveKey),
              liveStartParagraphIndex ?? -1)
        #endif
        KindleRunLog.write("KINDLE read preload consumed old=\(Self.keyLog(oldKey)) requested=\(Self.keyLog(prepared.page.key)) actual=\(Self.keyLog(actualLiveKey)) start=\(liveStartParagraphIndex ?? -1)")
        return prepared.document
    }

    private func generateDetachedTTSSegments(
        paragraphIndex: Int,
        text: String,
        language: String
    ) async throws -> [AudioSegment] {
        var segments: [AudioSegment] = []
        var remainingText = text
        var segmentIndex = 0
        let voice = AppSettings.shared.voice(for: language)

        while !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Task.checkCancellation()
            let response = try await APIService.shared.generateTTS(
                text: remainingText,
                voice: voice,
                speed: 1.0,
                language: language
            )
            try Task.checkCancellation()
            guard let audioData = Data(base64Encoded: response.audio) else {
                throw TTSError.generationFailed("Failed to decode prefetched audio")
            }
            let raw = AudioSegment(
                paragraphIndex: paragraphIndex,
                segmentIndex: segmentIndex,
                audioData: audioData,
                timestamps: response.safeTimestamps,
                duration: response.safeDuration,
                text: response.processedText ?? remainingText,
                unprocessedText: response.unprocessedText ?? ""
            )
            segments.append(ensureDetachedDuration(raw))

            if let unprocessed = response.unprocessedText,
               !unprocessed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remainingText = unprocessed
                segmentIndex += 1
            } else {
                break
            }
        }
        return segments
    }

    private func ensureDetachedDuration(_ segment: AudioSegment) -> AudioSegment {
        guard segment.duration <= 0.01,
              let duration = try? AVAudioPlayer(data: segment.audioData).duration,
              duration > 0 else {
            return segment
        }
        return AudioSegment(
            paragraphIndex: segment.paragraphIndex,
            segmentIndex: segment.segmentIndex,
            audioData: segment.audioData,
            timestamps: segment.timestamps,
            duration: duration,
            text: segment.text,
            isWavFormat: segment.isWavFormat,
            unprocessedText: segment.unprocessedText,
            speaker: segment.speaker
        )
    }

    private func enqueueHighlightWord(paragraphIndex: Int, wordIndex: Int) {
        let previous = highlightSequence
        highlightSequence = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.highlightWord(paragraphIndex: paragraphIndex, wordIndex: wordIndex)
        }
    }

    private func scrollToParagraph(_ paragraphIndex: Int) async {
        if suppressNextScrollParagraphIndex == paragraphIndex {
            suppressNextScrollParagraphIndex = nil
            #if DEBUG
            NSLog("CRDBG KINDLE paragraph scroll suppressed initial key=%@ p=%d",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex)
            #endif
            return
        }
        do {
            let result = try await evaluateJSON("window.__crKindleLiveScrollToParagraph && window.__crKindleLiveScrollToParagraph(\(paragraphIndex))")
            #if DEBUG
            if result["ok"] as? Bool != true {
                NSLog("CRDBG KINDLE paragraph scroll miss key=%@ p=%d reason=%@",
                      Self.keyLog(livePageKey ?? ""),
                      paragraphIndex,
                      result["reason"] as? String ?? "unknown")
            } else {
                NSLog("CRDBG KINDLE paragraph scroll key=%@ p=%d needed=%@ delta=%@ top=%@ bottom=%@ upper=%@ lower=%@ vh=%@ before=%@ after=%@",
                      Self.keyLog(livePageKey ?? ""),
                      paragraphIndex,
                      String(describing: result["needed"] ?? false),
                      String(describing: result["delta"] ?? 0),
                      String(describing: result["top"] ?? "?"),
                      String(describing: result["bottom"] ?? "?"),
                      String(describing: result["upper"] ?? "?"),
                      String(describing: result["lower"] ?? "?"),
                      String(describing: result["viewportH"] ?? "?"),
                      String(describing: result["beforeBestKey"] ?? result["beforeKey"] ?? ""),
                      String(describing: result["afterKey"] ?? ""))
            }
            #endif
        } catch {
            #if DEBUG
            NSLog("CRDBG KINDLE paragraph scroll error key=%@ p=%d %@",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  error.localizedDescription)
            #endif
        }
    }

    private func pushMarks(_ marks: [ResolvedMark]) async {
        guard mode == .explain else { return }
        if marks.isEmpty {
            shownMarkIds.removeAll()
            _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()")
            return
        }
        for mark in marks where !shownMarkIds.contains(mark.id.uuidString) {
            shownMarkIds.insert(mark.id.uuidString)
            var payload: [String: Any] = [
                "id": mark.id.uuidString,
                "paragraphIndex": mark.paragraphIndex,
                "charStart": mark.charRange.lowerBound,
                "charEnd": mark.charRange.upperBound,
                "action": mark.action,
                "seed": Int(truncatingIfNeeded: mark.seed & 0xFFFFFFFF)
            ]
            if let n = mark.n { payload["n"] = n }
            if let weight = mark.weight { payload["weight"] = weight }
            if let role = mark.role { payload["role"] = role }
            if let json = try? jsonString(payload) {
                _ = try? await evaluateJSON("window.__crKindleLiveShowMark && window.__crKindleLiveShowMark(\(json))")
            }
        }
    }

    private func paragraphPayload(_ paragraph: ReadingParagraph) -> [String: Any] {
        var payload: [String: Any] = [
            "id": paragraph.id,
            "text": paragraph.text,
            "words": paragraph.words.map { wordPayload($0) }
        ]
        if let bbox = paragraph.bboxNorm {
            payload["bboxNorm"] = rectPayload(bbox)
        }
        return payload
    }

    private func wordPayload(_ word: OCRWord) -> [String: Any] {
        [
            "id": word.id,
            "text": word.text,
            "bboxNorm": rectPayload(word.bboxNorm)
        ]
    }

    private func rectPayload(_ rect: CGRect) -> [String: Double] {
        [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.size.width,
            "height": rect.size.height
        ]
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { throw KindleBookError.invalidPayload }
        return string
    }

    func follow(coordinator: PlayerCoordinator, document: ReadingDocument) {
        stopFollowing()
        lastSyncedPageIndex = nil
        guard let session = coordinator.session, session.id == document.id else { return }

        session.readVM.$currentParagraphIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] idx in
                self?.syncToParagraph(idx, document: document)
            }
            .store(in: &cancellables)

        session.explainVM.$scrollTarget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] idx in
                self?.syncToParagraph(idx, document: document)
            }
            .store(in: &cancellables)
    }

    func stopFollowing() {
        cancellables.removeAll()
    }

    private func syncToParagraph(_ paragraphIndex: Int, document: ReadingDocument) {
        guard paragraphIndex >= 0,
              paragraphIndex < document.paragraphs.count,
              let pageIndex = document.paragraphs[paragraphIndex].pageIndex,
              pageIndex != lastSyncedPageIndex else { return }
        lastSyncedPageIndex = pageIndex
        guard let key = pageKeysByDocumentID[document.id]?[pageIndex], !key.isEmpty else { return }
        Task {
            _ = try? await scrollToKey(key)
            store.updateProgress(bookID: book.id, pageKey: key, url: webView.url?.absoluteString)
        }
    }

    private func load(_ raw: String) {
        guard let url = URL(string: raw) ?? URL(string: KindleWebScripts.libraryURL.absoluteString) else { return }
        webView.load(URLRequest(url: url))
    }

    private func installCaptureScript() {
        webView.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap, completionHandler: nil)
    }

    private func waitForPageReady() async throws {
        for _ in 0..<12 {
            installCaptureScript()
            if let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()"),
               (state["heldKeys"] as? Int ?? 0) > 0 || !(state["key"] as? String ?? "").isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func waitForKindleImageStable() async throws {
        var previousSignature: String?
        var stableHits = 0
        for attempt in 0..<14 {
            installCaptureScript()
            if let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()"),
               let rect = state["rect"] as? [String: Any] {
                let signature = [
                    state["key"] as? String ?? "",
                    String(describing: rect["left"] ?? ""),
                    String(describing: rect["top"] ?? ""),
                    String(describing: rect["width"] ?? ""),
                    String(describing: rect["height"] ?? "")
                ].joined(separator: "|")
                if signature == previousSignature {
                    stableHits += 1
                    if stableHits >= 2 {
                        #if DEBUG
                        NSLog("CRDBG KINDLE layout stable attempt=%d sig=%@",
                              attempt + 1,
                              signature)
                        #endif
                        return
                    }
                } else {
                    previousSignature = signature
                    stableHits = 0
                }
            }
            try await Task.sleep(nanoseconds: 160_000_000)
        }
        #if DEBUG
        NSLog("CRDBG KINDLE layout stable timeout")
        #endif
    }

    private func alignCurrentReadingPageToTop() async throws -> String? {
        let result = try await evaluateJSON("window.__crKindleAlignBestPageToTop && window.__crKindleAlignBestPageToTop()")
        #if DEBUG
        NSLog("CRDBG KINDLE align current result=%@",
              String(describing: result))
        #endif
        guard result["ok"] as? Bool == true else { return nil }
        return (result["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func captureVisiblePage(pageIndex: Int, targetKey: String? = nil) async throws -> CapturedKindlePage {
        var lastReason = "no-visible-kindle-image"
        for _ in 0..<10 {
            let trimmedTarget = targetKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let script: String
            if trimmedTarget.isEmpty {
                script = "window.__crKindleCurrentPageSnapshot && window.__crKindleCurrentPageSnapshot(1200, 0.9)"
            } else {
                let escapedTarget = trimmedTarget
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                script = "window.__crKindlePageSnapshotForKey && window.__crKindlePageSnapshotForKey('\(escapedTarget)', 1200, 0.9)"
            }
            let payload = try await evaluateJSON(script)
            if payload["ok"] as? Bool == true {
                #if DEBUG
                let rect = payload["pageRect"] as? [String: Any] ?? [:]
                NSLog("CRDBG KINDLE capture key=%@ target=%@ session=%@ kind=%@ visible=%@..%@ rect=%@,%@ %@x%@ area=%@ band=%@",
                      Self.keyLog(payload["key"] as? String ?? ""),
                      Self.keyLog(trimmedTarget),
                      String(describing: payload["sessionId"] ?? "?"),
                      payload["kind"] as? String ?? "",
                      String(describing: payload["visibleTopNorm"] ?? "?"),
                      String(describing: payload["visibleBottomNorm"] ?? "?"),
                      String(describing: rect["left"] ?? "?"),
                      String(describing: rect["top"] ?? "?"),
                      String(describing: rect["width"] ?? "?"),
                      String(describing: rect["height"] ?? "?"),
                      String(describing: payload["visibleArea"] ?? "?"),
                      String(describing: payload["bandVisibleArea"] ?? "?"))
                #endif
                return try await makeCapturedPage(from: payload, pageIndex: pageIndex)
            }
            lastReason = payload["reason"] as? String ?? lastReason
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw KindleBookError.captureFailed(lastReason)
    }

    private func captureNextPage(afterKey: String) async throws -> CapturedKindlePage {
        installCaptureScript()
        let escapedKey = afterKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        var lastReason = "no-next-candidate"
        for attempt in 0..<6 {
            let payload = try await evaluateJSON("window.__crKindleNextPageSnapshot && window.__crKindleNextPageSnapshot('\(escapedKey)', 1200, 0.9)")
            if payload["ok"] as? Bool == true {
                #if DEBUG
                let rect = payload["pageRect"] as? [String: Any] ?? [:]
                NSLog("CRDBG KINDLE preload capture after=%@ key=%@ session=%@ kind=%@ rect=%@,%@ %@x%@ ordered=%@",
                      Self.keyLog(afterKey),
                      Self.keyLog(payload["key"] as? String ?? ""),
                      String(describing: payload["sessionId"] ?? "?"),
                      payload["kind"] as? String ?? "",
                      String(describing: rect["left"] ?? "?"),
                      String(describing: rect["top"] ?? "?"),
                      String(describing: rect["width"] ?? "?"),
                      String(describing: rect["height"] ?? "?"),
                      String(describing: payload["ordered"] ?? ""))
                #endif
                return try await makeCapturedPage(from: payload, pageIndex: 0)
            }
            lastReason = payload["reason"] as? String ?? lastReason
            #if DEBUG
            NSLog("CRDBG KINDLE preload capture wait attempt=%d after=%@ reason=%@ ordered=%@",
                  attempt + 1,
                  Self.keyLog(afterKey),
                  lastReason,
                  String(describing: payload["ordered"] ?? ""))
            #endif
            try await Task.sleep(nanoseconds: 260_000_000)
        }
        throw KindleBookError.captureFailed(lastReason)
    }

    private func makeCapturedPage(from payload: [String: Any], pageIndex: Int) async throws -> CapturedKindlePage {
        guard let dataURL = payload["image"] as? String,
              let imageData = Self.decodeDataURL(dataURL),
              let image = UIImage(data: imageData) else {
            throw KindleBookError.badImage
        }

        var ocrDoc = try await OCRService.shared.recognize(
            image: image,
            languages: CaptureFlowViewModel.visionLanguages(),
            title: book.title,
            paragraphStrategy: .kindleLayout
        )
        ocrDoc.sourceKind = .kindle
        return CapturedKindlePage(
            pageIndex: pageIndex,
            key: payload["key"] as? String ?? "",
            sessionId: Self.int(from: payload["sessionId"]) ?? 0,
            kind: payload["kind"] as? String ?? "",
            title: payload["title"] as? String ?? book.title,
            url: payload["url"] as? String ?? webView.url?.absoluteString,
            progress: payload["progress"] as? String,
            visibleTopNorm: Self.number(from: payload["visibleTopNorm"]) ?? 0,
            visibleBottomNorm: Self.number(from: payload["visibleBottomNorm"]) ?? 1,
            imageData: imageData,
            document: ocrDoc,
            text: ocrDoc.fullText
        )
    }

    private func makeDocument(from pages: [CapturedKindlePage]) -> ReadingDocument {
        var paragraphs: [ReadingParagraph] = []
        var nextParagraphID = 0
        var nextWordID = 0

        for page in pages {
            paragraphs.append(ReadingParagraph(
                id: nextParagraphID,
                text: "",
                type: .image,
                pageIndex: page.pageIndex,
                imageData: page.imageData
            ))
            nextParagraphID += 1

            for para in page.document.paragraphs where para.type.isReadable && !para.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let remappedWords = para.words.map { word -> OCRWord in
                    defer { nextWordID += 1 }
                    return OCRWord(id: nextWordID, text: word.text, bboxNorm: word.bboxNorm)
                }
                paragraphs.append(ReadingParagraph(
                    id: nextParagraphID,
                    text: para.text,
                    type: para.type,
                    words: remappedWords,
                    bboxNorm: para.bboxNorm,
                    pageIndex: page.pageIndex
                ))
                nextParagraphID += 1
            }
        }

        return ReadingDocument(
            title: "\(book.title) · Kindle",
            sourceKind: .kindle,
            language: pages.first?.document.language ?? Constants.TTS.defaultLanguage,
            paragraphs: paragraphs,
            sourceURL: book.readerURL
        )
    }

    private func makeLiveDocument(from page: CapturedKindlePage) -> ReadingDocument {
        var paragraphs: [ReadingParagraph] = []
        var nextParagraphID = 0
        var nextWordID = 0

        for para in page.document.paragraphs where para.type.isReadable && !para.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !para.words.isEmpty else { continue }
            let paraText = para.text
            guard !paraText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let remappedWords = para.words.map { word -> OCRWord in
                defer { nextWordID += 1 }
                return OCRWord(id: nextWordID, text: word.text, bboxNorm: word.bboxNorm)
            }
            paragraphs.append(ReadingParagraph(
                id: nextParagraphID,
                text: paraText,
                type: para.type,
                words: remappedWords,
                bboxNorm: para.bboxNorm ?? unionNorm(for: remappedWords),
                pageIndex: 0
            ))
            nextParagraphID += 1
        }
        #if DEBUG
        NSLog("CRDBG KINDLE live full-page paras=%d words=%d imageVisible=%.3f..%.3f",
              paragraphs.count,
              paragraphs.reduce(0) { $0 + $1.words.count },
              Double(page.visibleTopNorm),
              Double(page.visibleBottomNorm))
        #endif

        return ReadingDocument(
            title: book.title,
            sourceKind: .kindle,
            language: page.document.language,
            paragraphs: paragraphs,
            sourceURL: page.url ?? book.readerURL
        )
    }

    private func firstReadableParagraph(in document: ReadingDocument) -> Int? {
        document.paragraphs.first {
            $0.type.isReadable && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.id
    }

    private func firstVisibleReadableParagraph(
        in document: ReadingDocument,
        visibleTopNorm: CGFloat,
        visibleBottomNorm: CGFloat
    ) -> Int? {
        let top = max(0, min(1, visibleTopNorm))
        let bottom = max(top, min(1, visibleBottomNorm))
        return document.paragraphs.first { paragraph in
            guard paragraph.type.isReadable,
                  !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let bbox = paragraph.bboxNorm else { return false }
            let paraTop = max(0, min(1, 1 - bbox.maxY))
            let paraBottom = max(paraTop, min(1, 1 - bbox.minY))
            return paraBottom >= top && paraTop <= bottom
        }?.id
    }

    private func unionNorm(for words: [OCRWord]) -> CGRect? {
        guard let first = words.first else { return nil }
        var minX = first.bboxNorm.minX
        var minY = first.bboxNorm.minY
        var maxX = first.bboxNorm.maxX
        var maxY = first.bboxNorm.maxY
        for word in words.dropFirst() {
            minX = min(minX, word.bboxNorm.minX)
            minY = min(minY, word.bboxNorm.minY)
            maxX = max(maxX, word.bboxNorm.maxX)
            maxY = max(maxY, word.bboxNorm.maxY)
        }
        return CGRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    private static func isReadableKindleParagraph(_ paragraph: ReadingParagraph) -> Bool {
        paragraph.type.isReadable &&
        !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !paragraph.words.isEmpty
    }

    private static func shouldMergeKindleContinuation(prev: String, next: String) -> Bool {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || n.isEmpty { return false }
        if isLikelyKindleHeading(p) || isLikelyKindleHeading(n) { return false }
        if endsWithKindleDash(p) { return true }
        if endsWithKindleHardTerminal(p) { return false }
        return true
    }

    private static func joinKindleContinuation(prev: String, next: String) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if endsWithKindleDash(p) {
            return normalizeKindleText(String(p.dropLast()) + n)
        }
        return normalizeKindleText("\(p) \(n)")
    }

    private static func normalizeKindleText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func isLikelyKindleHeading(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.range(of: #"^(chapter|book|part|contents)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let lowercase = t.unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) }
        return t.count <= 90 && letters.count >= 5 && lowercase.isEmpty
    }

    private static func startsWithLowercaseLetter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            let s = String(scalar)
            return s == s.lowercased() && s != s.uppercased()
        }
        return false
    }

    private static func endsWithKindleDash(_ text: String) -> Bool {
        guard let scalar = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last else { return false }
        return Set("-‐‑‒–—―".unicodeScalars).contains(scalar)
    }

    private static func endsWithKindleHardTerminal(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"[.!?。！？]["')\]\u{201D}\u{2019}]*$"#, options: .regularExpression) != nil
    }

    private static func endsWithKindleSoftContinuationPunctuation(_ text: String) -> Bool {
        var scalars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        let closers = Set("\"')]\u{201D}\u{2019}".unicodeScalars)
        while let last = scalars.last, closers.contains(last) {
            scalars.removeLast()
        }
        guard let last = scalars.last else { return false }
        return Set(",;:–—".unicodeScalars).contains(last)
    }

    private func scrollForward() async throws {
        _ = try await scrollForward(fromVisibleBottom: nil, keepingKey: "")
    }

    @discardableResult
    private func scrollForward(fromVisibleBottom visibleBottom: CGFloat?, keepingKey key: String) async throws -> [String: Any] {
        let bottomArg = visibleBottom.map { String(format: "%.6f", Double($0)) } ?? "null"
        let escapedKey = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let script = "window.__crKindleLiveAdvanceScroll ? window.__crKindleLiveAdvanceScroll(\(bottomArg), '\(escapedKey)') : (window.__crKindleScroll && window.__crKindleScroll(Math.max(520, Math.floor((window.innerHeight || 700) * 0.82))))"
        let result = try await evaluateJSON(script)
        #if DEBUG
        NSLog("CRDBG KINDLE advance scroll bottom=%@ key=%@ result=%@",
              String(describing: visibleBottom),
              Self.keyLog(key),
              String(describing: result))
        #endif
        return result
    }

    @discardableResult
    private func scrollToKey(_ key: String, block: String = "nearest") async throws -> [String: Any] {
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedBlock = block.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return try await evaluateJSON("window.__crKindleScrollToKey && window.__crKindleScrollToKey('\(escaped)', '\(escapedBlock)')")
    }

    private func evaluateJSON(_ script: String) async throws -> [String: Any] {
        let result = try await evaluate(script)
        let data: Data
        if let string = result as? String {
            data = Data(string.utf8)
        } else if JSONSerialization.isValidJSONObject(result) {
            data = try JSONSerialization.data(withJSONObject: result)
        } else {
            throw KindleBookError.invalidPayload
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    @discardableResult
    private func evaluate(_ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as Any)
                }
            }
        }
    }

    private static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }

    private static func stableKey(_ data: Data) -> String {
        let head = data.prefix(384)
        return "\(data.count)-\(head.base64EncodedString().prefix(18))"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private static func keyLog(_ key: String) -> String {
        guard !key.isEmpty else { return "" }
        return String(key.prefix(24))
    }

    private static func number(from value: Any?) -> CGFloat? {
        if let n = value as? NSNumber { return CGFloat(truncating: n) }
        if let d = value as? Double { return CGFloat(d) }
        if let s = value as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }

    private static func int(from value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }
}

private struct KindleCachedPage {
    let afterKey: String
    let page: CapturedKindlePage
    let document: ReadingDocument
    let startParagraphIndex: Int?
}

private struct KindleAudioPrefetch {
    let pageKey: String
    let paragraphIndex: Int
    let segments: [AudioSegment]
}

private enum KindleReadPageSlot {
    case current
    case next

    var logName: String {
        switch self {
        case .current: return "current"
        case .next: return "next"
        }
    }
}

private struct KindleRenderRoute {
    let slot: KindleReadPageSlot
    let overlayParagraphID: Int
    let overlayWordIndex: Int
}

private struct KindleTextQueue {
    let document: ReadingDocument
    let currentPage: CapturedKindlePage
    let currentOverlayDocument: ReadingDocument
    let nextPage: CapturedKindlePage?
    let nextBaseDocument: ReadingDocument?
    let nextOverlayDocument: ReadingDocument?
    let nextResumeParagraphIndex: Int?
    let wordRoutes: [String: KindleRenderRoute]
    let startParagraphIndex: Int?
    let hasCrossPageBridge: Bool
}

private struct CapturedKindlePage {
    let pageIndex: Int
    let key: String
    let sessionId: Int
    let kind: String
    let title: String
    let url: String?
    let progress: String?
    let visibleTopNorm: CGFloat
    let visibleBottomNorm: CGFloat
    let imageData: Data
    let document: ReadingDocument
    let text: String
}

private enum KindleBookError: LocalizedError {
    case busy
    case noImage
    case noText
    case badImage
    case invalidPayload
    case captureFailed(String)
    case overlayFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return String(localized: "Kindle 页面正在准备中。")
        case .noImage:
            return String(localized: "没有找到 Kindle 页面图片，请打开书籍页面后重试。")
        case .noText:
            return String(localized: "当前 Kindle 页面没有识别到可朗读文本。")
        case .badImage:
            return String(localized: "Kindle 页面图片无法解析。")
        case .invalidPayload:
            return String(localized: "Kindle 返回了异常的页面数据。")
        case .captureFailed(let reason):
            return String(format: String(localized: "无法捕获 Kindle 页面：%@"), reason)
        case .overlayFailed(let reason):
            return String(format: String(localized: "无法把高亮附加到 Kindle 页面：%@"), reason)
        }
    }
}

private struct KindlePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .background(AppTheme.primary.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct KindleSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(AppTheme.primary)
            .padding(.vertical, 12)
            .background(AppTheme.primary.opacity(configuration.isPressed ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
