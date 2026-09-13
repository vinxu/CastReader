import AVFoundation
import Combine
import SwiftUI

@MainActor
struct KindleOfflineLibraryView: View {
    @ObservedObject private var library = KindleLibraryStore.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var books: [KindleOfflineBook] = []
    @State private var error: String?
    let store: KindleOfflineBookStore
    private var scope: String? { KindleOfflineContext.currentScope }

    init(store: KindleOfflineBookStore = .shared) { self.store = store }

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if books.isEmpty {
                ContentUnavailableView("还没有离线书籍", systemImage: "arrow.down.circle",
                    description: Text("打开正在读的 Kindle 书，在“更多”中选择“离线保存整本书”。"))
            }
            if let scope {
                ForEach(books) { book in
                    NavigationLink {
                        KindleOfflineBookReaderView(book: book, scope: scope, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.title).font(.headline)
                            Text(book.status == .complete ? "整本已保存 · \(book.pages.count) 页" : "尚未完成 · 已保存 \(book.pages.count) 页")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(book.byteCount), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(book.pages.isEmpty)
                }
            }
        }
        .navigationTitle("离线书籍")
        .task(id: scope) {
            books = []; error = nil
            guard let scope else { error = "请先连接 Kindle 账号。"; return }
            do {
                let result = try await store.list(scope: scope)
                guard scope == self.scope else { return }
                books = result
            } catch { self.error = "本机书籍列表读取失败，已保存的文件仍保留。" }
        }
    }
}

@MainActor
final class KindleOfflineBookReaderModel: ObservableObject {
    @Published private(set) var book: KindleOfflineBook
    @Published private(set) var document: ReadingDocument?
    @Published private(set) var pageIndex = 0
    @Published private(set) var loading = false
    @Published private(set) var preparingSpeech = false
    private(set) var recognitionCount = 0
    @Published private(set) var error: String?
    @Published var voiceID = ""
    @Published private(set) var voices: [SystemSpeechVoice] = []
    let speech: SystemSpeechPlaybackService
    private let scopeValidator: @MainActor () -> Bool
    private let scope: String
    private let store: KindleOfflineBookStore
    private let recognizer: any KindleOfflineRecognizing
    private struct RecognitionTask {
        let id: UUID
        let task: Task<ReadingDocument, Error>
    }
    private var recognitionTasks: [Int: RecognitionTask] = [:]
    private var preparationTask: Task<Void, Never>?
    private var playbackRequest = UUID()
    private var pendingResume: KindleOfflineBook.ReadingPosition?
    private var generation = UUID()
    private var advancing = false
    private var closed = false
    private var checkpointTask: Task<Void, Never>?
    private var lastCheckpoint: KindleOfflineBook.ReadingPosition?
    private var observers: Set<AnyCancellable> = []

    init(book: KindleOfflineBook, scope: String, store: KindleOfflineBookStore = .shared,
         speech: SystemSpeechPlaybackService? = nil, scopeValidator: (@MainActor () -> Bool)? = nil,
         recognizer: (any KindleOfflineRecognizing)? = nil) {
        self.book = book; self.scope = scope; self.store = store
        self.speech = speech ?? SystemSpeechPlaybackService()
        self.recognizer = recognizer ?? KindleOfflineOCRService()
        self.scopeValidator = scopeValidator ?? { scope == KindleOfflineContext.currentScope }
        AuthService.shared.$account.sink { [weak self] _ in self?.validateScope() }.store(in: &observers)
        KindleLibraryStore.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.validateScope() }
        }.store(in: &observers)
    }

    private var scopeIsCurrent: Bool { scopeValidator() }
    private func validateScope() {
        guard !scopeIsCurrent else { return }
        close()
        document = nil
        error = "账号已切换，请从当前账号的离线书籍重新打开。"
    }

    func open() async {
        do {
            guard let fresh = try await store.load(id: book.id, scope: scope), scopeIsCurrent else { validateScope(); return }
            book = fresh
            voices = SystemSpeechPlaybackService.voices(language: book.language)
            voiceID = voices.first(where: { $0.id == book.readingPosition.voiceID })?.id ?? voices.first?.id ?? ""
            speech.connectPlayback(title: book.title)
            speech.onCheckpoint = { [weak self] unit, _ in self?.checkpoint(unit) }
            speech.onPlayRequested = { [weak self] in self?.play() }
            speech.onPlaybackInterrupted = { [weak self] in self?.cancelPreparation() }
            await loadPage(min(book.readingPosition.page, max(0, book.pages.count - 1)), resume: book.readingPosition, automatically: false)
        } catch { self.error = "书籍索引读取失败。" }
    }

    func play() { beginPlayback(automatically: false) }

    func pause() {
        cancelPreparation()
        speech.pause()
    }

    private func cancelPreparation() {
        playbackRequest = UUID()
        preparationTask?.cancel(); preparationTask = nil
        recognitionTasks.values.forEach { $0.task.cancel() }; recognitionTasks.removeAll()
        preparingSpeech = false
    }

    private func beginPlayback(automatically: Bool) {
        guard scopeIsCurrent, !closed, !loading, !preparingSpeech else { validateScope(); return }
        if automatically {
            guard speech.canContinueAutomatically else { return }
        } else { speech.prepareForUserPlayback() }
        if !speech.units.isEmpty, !(speech.state == .finished && pageIndex + 1 < book.pages.count) {
            if automatically { speech.playAutomatically() } else { speech.play() }
            prefetchNextPage()
            return
        }
        let request = UUID(); playbackRequest = request
        preparingSpeech = true; error = nil
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.playbackRequest == request { self.preparingSpeech = false; self.preparationTask = nil } }
            do {
                if self.speech.state == .finished, self.pageIndex + 1 < self.book.pages.count {
                    await self.loadPage(self.pageIndex + 1, resume: nil, automatically: false)
                }
                while !Task.isCancelled, self.playbackRequest == request, !self.closed, self.scopeIsCurrent {
                    let index = self.pageIndex
                    let doc = try await self.recognizedPage(at: index)
                    try Task.checkCancellation()
                    guard self.playbackRequest == request, self.pageIndex == index, self.scopeIsCurrent,
                          self.speech.canContinueAutomatically else { return }
                    self.installDocument(doc, resume: self.pendingResume)
                    if !self.speech.units.isEmpty {
                        self.speech.playAutomatically()
                        self.prefetchNextPage()
                        return
                    }
                    if self.book.pages[index].requiresOCR == true, self.book.pages[index].sourceWordCount != 0 {
                        throw OCRError.noText
                    }
                    guard index + 1 < self.book.pages.count else { self.error = "这一页没有可朗读文字。"; return }
                    await self.loadPage(index + 1, resume: nil, automatically: false)
                    guard self.pageIndex != index else { return }
                }
            } catch is CancellationError {
                // Pause, page change and closing never start speech after OCR returns.
            } catch {
                if self.playbackRequest == request, !self.closed {
                    self.speech.stop()
                    self.error = "这一页文字识别未完成，图片已保存在手机。请点击播放重试。"
                }
            }
        }
    }

    private func recognizedPage(at index: Int) async throws -> ReadingDocument {
        if let task = recognitionTasks[index] { return try await task.task.value }
        let id = UUID()
        let task = Task { @MainActor [self] in
            if let cached = try await store.cachedSpeechPage(book: book, ordinal: index, scope: scope) { return cached }
            let raw = try await store.openPage(book: book, ordinal: index, scope: scope)
            try Task.checkCancellation()
            guard scopeIsCurrent, !closed else { throw CancellationError() }
            recognitionCount += 1
            let recognized = try await recognizer.recognize(raw, sourceWordCount: book.pages[index].sourceWordCount)
            try Task.checkCancellation()
            guard scopeIsCurrent, !closed else { throw CancellationError() }
            try await store.saveSpeechPage(recognized, book: book, ordinal: index, scope: scope)
            return recognized
        }
        recognitionTasks[index] = RecognitionTask(id: id, task: task)
        do { return try await task.value }
        catch {
            if recognitionTasks[index]?.id == id { recognitionTasks.removeValue(forKey: index) }
            throw error
        }
    }

    private func prefetchNextPage() {
        guard speech.state == .speaking || speech.state == .preparing, pageIndex + 1 < book.pages.count else { return }
        let next = pageIndex + 1
        let request = playbackRequest
        for index in Array(recognitionTasks.keys) where index != pageIndex && index != next {
            recognitionTasks.removeValue(forKey: index)?.task.cancel()
        }
        // A one-page lookahead begins only after a user starts listening.
        Task { [weak self] in
            guard let self, !self.closed, self.playbackRequest == request, self.scopeIsCurrent,
                  self.speech.canContinueAutomatically,
                  self.speech.state == .speaking || self.speech.state == .preparing else { return }
            _ = try? await self.recognizedPage(at: next)
        }
    }

    private func installDocument(_ doc: ReadingDocument, resume: KindleOfflineBook.ReadingPosition?) {
        document = doc
        let units = doc.paragraphs.filter(\.type.isReadable).flatMap { SystemSpeechTextPlan.units(paragraphID: $0.id, text: $0.text) }
        speech.load(units, voiceID: voiceID)
        if let resume, let sentence = units.firstIndex(where: { $0.paragraphID == resume.paragraphID && $0.sourceRange.location == resume.sentenceStart }) {
            speech.seek(to: sentence, autoplay: false)
        }
        if !units.isEmpty { pendingResume = nil }
    }

    func changeVoice(_ id: String) {
        guard scopeIsCurrent, !closed else { validateScope(); return }
        speech.setVoice(id)
    }

    func selectPage(_ index: Int) {
        guard book.pages.indices.contains(index), !loading else { return }
        cancelPreparation()
        Task { await loadPage(index, resume: nil, automatically: false) }
    }

    func close() {
        guard !closed else { return }
        cancelPreparation()
        speech.closePlayback()
        closed = true
        generation = UUID()
    }

    private func loadPage(_ index: Int, resume: KindleOfflineBook.ReadingPosition?, automatically: Bool) async {
        guard scopeIsCurrent, !closed, book.pages.indices.contains(index) else {
            if index >= book.pages.count && book.status != .complete { error = "已到已保存内容的末尾。请联网继续下载整本书。" }
            advancing = false
            return
        }
        let run = UUID(); generation = run
        loading = true
        speech.stop()
        defer { if generation == run { loading = false; advancing = false } }
        do {
            let cached = try await store.cachedSpeechPage(book: book, ordinal: index, scope: scope)
            let doc: ReadingDocument
            if let cached { doc = cached }
            else { doc = try await store.openPage(book: book, ordinal: index, scope: scope) }
            guard generation == run, !closed, scopeIsCurrent else { return }
            pageIndex = index
            pendingResume = resume
            installDocument(doc, resume: resume)
            let units = speech.units
            error = nil
            loading = false
            if let unit = units.first { checkpoint(units.indices.contains(speech.currentUnitIndex) ? units[speech.currentUnitIndex] : unit) }
            else { saveCursor(paragraphID: resume?.paragraphID ?? (book.pages[index].requiresOCR == true ? 1 : 0), sentenceStart: resume?.sentenceStart ?? 0) }
            if automatically, speech.canContinueAutomatically {
                beginPlayback(automatically: true)
            }
        } catch { self.error = "这一页文件缺失或损坏，请联网修复下载。其他已保存页面仍可阅读。" }
    }

    private func saveCursor(paragraphID: Int, sentenceStart: Int) {
        guard scopeIsCurrent, !closed, !loading else { return }
        var value = KindleOfflineBook.ReadingPosition()
        value.page = pageIndex; value.paragraphID = paragraphID
        value.sentenceStart = sentenceStart; value.voiceID = voiceID
        if value != lastCheckpoint {
            lastCheckpoint = value
            let previous = checkpointTask, store = store, scope = scope, book = book
            checkpointTask = Task { [weak self] in
                await previous?.value
                do { try await store.saveReadingPosition(value, book: book, scope: scope) }
                catch { self?.lastCheckpoint = nil; self?.error = "朗读位置未能保存，请检查本机空间。" }
            }
        }
    }

    private func checkpoint(_ unit: SystemSpeechUnit) {
        guard scopeIsCurrent, !closed, !loading else { return }
        saveCursor(paragraphID: unit.paragraphID, sentenceStart: unit.sourceRange.location)
        if speech.state == .finished, speech.canContinueAutomatically, !advancing, pageIndex + 1 < book.pages.count {
            advancing = true
            let run = generation, next = pageIndex + 1
            Task { [weak self] in
                guard let self, self.generation == run, !self.closed else { return }
                await self.loadPage(next, resume: nil, automatically: true)
            }
        }
    }
}

@MainActor
struct KindleOfflineBookReaderView: View {
    @StateObject private var model: KindleOfflineBookReaderModel
    init(book: KindleOfflineBook, scope: String, store: KindleOfflineBookStore = .shared) {
        _model = StateObject(wrappedValue: KindleOfflineBookReaderModel(book: book, scope: scope, store: store))
    }
    var body: some View {
        KindleOfflineBookReaderContent(model: model, speech: model.speech)
            .environment(\.readerOfflineAction, nil)
            .environment(\.readerAppearanceSource, .text)
            .navigationTitle(model.book.title).navigationBarTitleDisplayMode(.inline)
            .task { await model.open() }
            .onDisappear { model.close() }
    }
}

@MainActor
private struct KindleOfflineBookReaderContent: View {
    @ObservedObject var model: KindleOfflineBookReaderModel
    @ObservedObject var speech: SystemSpeechPlaybackService
    @ObservedObject private var network = NetworkReachability.shared
    @ObservedObject private var appearance = ReaderAppearanceSettings.shared
    @State private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var pageInput = ""
    @State private var showPagePicker = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { model.selectPage(model.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.pageIndex == 0 || model.loading)
                Spacer()
                Button { pageInput = String(model.pageIndex + 1); showPagePicker = true } label: {
                    Text("第 \(model.pageIndex + 1) / \(model.book.pages.count) 页").font(.subheadline.monospacedDigit())
                }.disabled(model.loading).accessibilityIdentifier("offlineBookPageStatus")
                Spacer()
                Button { model.selectPage(model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.pageIndex + 1 >= model.book.pages.count || model.loading)
            }
            HStack {
                Button(model.preparingSpeech || speech.state == .speaking || speech.state == .preparing ? "暂停" : "播放") {
                    if model.preparingSpeech || speech.state == .speaking || speech.state == .preparing { model.pause() }
                    else { model.play() }
                }.accessibilityIdentifier("offlineBookPlay")
                Button("上一句") { model.pause(); speech.seek(to: max(0, speech.currentUnitIndex - 1), autoplay: false) }.disabled(speech.units.isEmpty)
                Button("下一句") { model.pause(); speech.seek(to: speech.currentUnitIndex + 1, autoplay: false) }.disabled(speech.units.isEmpty)
                ReaderMoreButton()
            }.buttonStyle(.bordered)
            Picker("本机声音", selection: $model.voiceID) {
                ForEach(model.voices) { Text("\($0.name) · \($0.language)").tag($0.id) }
            }.onChange(of: model.voiceID) { model.changeVoice($0) }
            HStack {
                Text("朗读速度").font(.caption)
                Slider(value: $rate, in: 0.3...0.65, step: 0.05)
                    .accessibilityLabel("朗读速度")
                    .onChange(of: rate) { speech.setRate(Float($0)) }
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if speech.errorCode != nil { Text("系统朗读暂时不可用，请切换本机声音后重试。").font(.footnote).foregroundStyle(.red) }
            if model.loading { ProgressView("正在读取本机页面…") }
            if model.preparingSpeech { ProgressView("正在本机识别文字…") }
            if let document = model.document {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let bytes = document.paragraphs.first(where: { $0.type == .image })?.imageData,
                               let image = UIImage(data: bytes) {
                                if document.paragraphs.contains(where: { $0.type.isReadable && !$0.text.isEmpty }) {
                                    DisclosureGroup("查看保存的原页面") { Image(uiImage: image).resizable().scaledToFit() }
                                } else { Image(uiImage: image).resizable().scaledToFit() }
                            }
                            ForEach(document.paragraphs.filter { $0.type != .image }) { paragraph in
                                Text(highlighted(paragraph))
                                    .font(.system(size: appearance.textSize, design: appearance.usesSerif ? .serif : .default))
                                    .lineSpacing(appearance.lineSpacing).id(paragraph.id)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .id(model.pageIndex)
                    .task(id: speech.highlightedParagraphID) {
                        await Task.yield()
                        if !Task.isCancelled, scenePhase == .active, let id = speech.highlightedParagraphID { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: scenePhase) { phase in
                        if phase == .active, let id = speech.highlightedParagraphID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("\(model.book.status == .complete ? "整本已保存" : "部分已保存") · \(network.isOnline ? "网络已连接" : "无网络连接") · 本机系统朗读")
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("offlineBookNetworkStatus")
            Text("第 \(min(speech.currentUnitIndex + 1, speech.units.count)) / \(speech.units.count) 句 · \(playbackStatus)")
                .font(.caption2).accessibilityIdentifier("offlineBookSpeechStatus")
        }.padding()
        .alert("跳转页码", isPresented: $showPagePicker) {
            TextField("页码", text: $pageInput).keyboardType(.numberPad)
            Button("跳转") { if let page = Int(pageInput), page >= 1, page <= model.book.pages.count { model.selectPage(page - 1) } }
            Button("取消", role: .cancel) {}
        } message: { Text("1 – \(model.book.pages.count)") }
        .onChange(of: speech.state) { _ in saveDiagnostic() }
        .onChange(of: model.loading) { _ in saveDiagnostic() }
        .onChange(of: model.preparingSpeech) { _ in saveDiagnostic() }
        .onChange(of: speech.callbackCount) { count in if count % 10 == 0 { saveDiagnostic() } }
        .onChange(of: scenePhase) { _ in saveDiagnostic() }
    }

    private var playbackStatus: String {
        switch speech.state {
        case .idle: return AppLocalized("尚未开始")
        case .preparing: return "准备朗读…"
        case .speaking: return "正在朗读"
        case .paused: return AppLocalized("已暂停")
        case .finished: return "朗读完成"
        case .failed: return "播放失败"
        }
    }

    private func saveDiagnostic() {
        #if DEBUG
        let record: [String: Any] = ["version": 1, "bookID": model.book.id, "generation": model.book.generation.uuidString,
            "complete": model.book.status == .complete, "savedPages": model.book.pages.count,
            "page": model.pageIndex, "unit": speech.currentUnitIndex,
            "state": speech.state.rawValue, "rangeCallbacks": speech.callbackCount,
            "recognitionCount": model.recognitionCount, "preparingSpeech": model.preparingSpeech,
            "firstSpeechMilliseconds": speech.firstSpeechMilliseconds ?? -1,
            "voiceID": model.voiceID, "networkHint": network.isOnline,
            "scene": scenePhase == .active ? "active" : "background",
            "errorCode": speech.errorCode ?? ""]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: root.appendingPathComponent("kindle-offline-book-speech.json"), options: .atomic)
        #endif
    }

    private func highlighted(_ paragraph: ReadingParagraph) -> AttributedString {
        var result = AttributedString(paragraph.text)
        guard paragraph.id == speech.highlightedParagraphID, let nsRange = speech.highlightRange,
              let range = Range(nsRange, in: paragraph.text),
              let start = AttributedString.Index(range.lowerBound, within: result),
              let end = AttributedString.Index(range.upperBound, within: result) else { return result }
        result[start..<end].backgroundColor = .orange.opacity(0.4)
        return result
    }
}
