import AVFoundation
import Combine
import SwiftUI

@MainActor
final class KindleOfflineBookReaderModel: ObservableObject {
    @Published private(set) var book: KindleOfflineBook
    @Published private(set) var document: ReadingDocument?
    @Published private(set) var pageImage: UIImage?
    @Published private(set) var pageIndex = 0
    @Published private(set) var loading = false
    @Published private(set) var preparingSpeech = false
    private(set) var recognitionCount = 0
    @Published private(set) var error: String?
    @Published var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @Published var voiceID = ""
    @Published private(set) var voices: [SystemSpeechVoice] = []
    private var voiceLanguage: String?
    var onClosed: (() -> Void)?
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
    private var wantsPlayback = false
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
        NotificationCenter.default.publisher(for: KindleOfflineBookStore.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, notification.object as? KindleOfflineBookStore === self.store,
                      notification.userInfo?["scope"] as? String == self.scope else { return }
                Task { @MainActor [weak self] in await self?.refreshSavedBook() }
            }.store(in: &observers)
    }

    private func refreshSavedBook() async {
        guard !closed, scopeIsCurrent else { return }
        let run = generation
        do {
            let fresh = try await store.load(id: book.id, scope: scope)
            guard run == generation, !closed, scopeIsCurrent else { return }
            guard let fresh, fresh.generation == book.generation else { close(); return }
            book = fresh
        } catch {
            guard run == generation, !closed else { return }
            pause()
            self.error = AppLocalized("书籍索引读取失败，请返回离线书籍重新打开。")
        }
    }

    private var scopeIsCurrent: Bool { scopeValidator() }
    private func validateScope() {
        guard !scopeIsCurrent else { return }
        close()
        document = nil; pageImage = nil
        error = AppLocalized("账号已切换，请从当前账号的离线书籍重新打开。")
    }

    func open() async {
        await checkpointTask?.value
        guard !Task.isCancelled, scopeIsCurrent else { validateScope(); return }
        closed = false; wantsPlayback = false
        cancelPreparation()
        let run = UUID(); generation = run
        loading = true; document = nil; pageImage = nil
        speech.load([], voiceID: voiceID)
        defer { if generation == run { loading = false } }
        do {
            guard let fresh = try await store.load(id: book.id, scope: scope) else {
                error = AppLocalized("本机副本已删除，请返回离线书籍。"); return
            }
            guard generation == run, !closed, !Task.isCancelled, scopeIsCurrent else { validateScope(); return }
            book = fresh
            voices = []; voiceLanguage = nil
            voiceID = book.readingPosition.voiceID
            speechRate = min(0.65, max(0.3, book.readingPosition.speechRate ?? Double(AVSpeechUtteranceDefaultSpeechRate)))
            speech.setRate(Float(speechRate))
            speech.connectPlayback(title: book.title)
            speech.onPlaybackDetached = { [weak self] in self?.close() }
            speech.onCheckpoint = { [weak self] unit, _ in self?.checkpoint(unit) }
            speech.onPlayRequested = { [weak self] in self?.play() }
            speech.onPlaybackInterrupted = { [weak self] in self?.wantsPlayback = false; self?.cancelPreparation() }
            await loadPage(min(book.readingPosition.page, max(0, book.pages.count - 1)), resume: book.readingPosition, automatically: false)
        } catch { if generation == run, !closed { self.error = AppLocalized("书籍索引读取失败，请返回离线书籍重新打开。") } }
    }

    func play() {
        wantsPlayback = true
        beginPlayback(automatically: false)
    }

    func pause() {
        wantsPlayback = false
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
            guard wantsPlayback, speech.canContinueAutomatically else { return }
        } else { speech.prepareForUserPlayback() }
        if !speech.units.isEmpty, !(speech.state == .finished && pageIndex + 1 < book.pages.count) {
            guard hasMatchingVoice else { return }
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
                          self.wantsPlayback, self.speech.canContinueAutomatically else { return }
                    guard await self.prepareVoice(for: doc) else { return }
                    try Task.checkCancellation()
                    guard self.playbackRequest == request, self.pageIndex == index, self.wantsPlayback,
                          self.speech.canContinueAutomatically else { return }
                    self.installDocument(doc, resume: self.pendingResume)
                    if !self.speech.units.isEmpty {
                        guard self.hasMatchingVoice else { return }
                        self.speech.playAutomatically()
                        self.prefetchNextPage()
                        return
                    }
                    if self.book.pages[index].requiresOCR == true, self.book.pages[index].sourceWordCount != 0 {
                        throw OCRError.noText
                    }
                    guard index + 1 < self.book.pages.count else { self.error = AppLocalized("这一页没有可朗读文字。"); return }
                    await self.loadPage(index + 1, resume: nil, automatically: false)
                    guard self.pageIndex != index else { return }
                }
            } catch is CancellationError {
                // Pause, page change and closing never start speech after OCR returns.
            } catch {
                if self.playbackRequest == request, !self.closed {
                    self.speech.stop()
                    self.error = AppLocalized("这一页文字识别未完成，图片已保存在手机。请点击播放重试。")
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
        if pageImage == nil, let bytes = doc.paragraphs.first(where: { $0.type == .image })?.imageData {
            pageImage = UIImage(data: bytes)
        }
        let units = doc.paragraphs.filter(\.type.isReadable).flatMap { SystemSpeechTextPlan.units(paragraphID: $0.id, text: $0.text) }
        speech.load(units, voiceID: voiceID)
        if let resume, let sentence = units.firstIndex(where: { $0.paragraphID == resume.paragraphID && $0.sourceRange.location == resume.sentenceStart }) {
            speech.seek(to: sentence, autoplay: false)
        }
        if !units.isEmpty { pendingResume = nil }
    }

    private var hasMatchingVoice: Bool {
        guard !voices.isEmpty, voices.contains(where: { $0.id == voiceID }) else {
            wantsPlayback = false
            error = AppLocalized("这台设备尚无适合此书的声音。请联网下载系统声音后重试。")
            return false
        }
        return true
    }

    private func prepareVoice(for doc: ReadingDocument) async -> Bool {
        guard doc.paragraphs.contains(where: { $0.type.isReadable && !$0.text.isEmpty }) else { return true }
        guard voiceLanguage != doc.language else { return true }
        let run = generation
        let available = await SystemSpeechPlaybackService.availableVoices(language: doc.language)
        guard run == generation, !closed, !Task.isCancelled, scopeIsCurrent else { return false }
        voices = available
        voiceID = available.first(where: { $0.id == voiceID })?.id ?? available.first?.id ?? ""
        voiceLanguage = doc.language
        return true
    }

    func changeVoice(_ id: String) {
        guard scopeIsCurrent, !closed, voices.contains(where: { $0.id == id }) else { validateScope(); return }
        voiceID = id
        speech.setVoice(id)
        persistCurrentPosition()
    }

    func changeRate(_ value: Double) {
        guard value.isFinite, scopeIsCurrent, !closed else { return }
        speechRate = min(0.65, max(0.3, value))
        speech.setRate(Float(speechRate))
        persistCurrentPosition()
    }

    func persistCurrentPosition() {
        if speech.units.indices.contains(speech.currentUnitIndex) { checkpoint(speech.units[speech.currentUnitIndex]) }
        else { saveCursor(paragraphID: pendingResume?.paragraphID ?? 1, sentenceStart: pendingResume?.sentenceStart ?? 0) }
    }

    func retryPage() {
        wantsPlayback = false
        cancelPreparation()
        Task { await loadPage(pageIndex, resume: pendingResume, automatically: false) }
    }

    var reachedSavedEnd: Bool {
        pageIndex + 1 == book.pages.count && speech.state == .finished
    }


    func selectPage(_ index: Int) {
        guard book.pages.indices.contains(index), !loading else { return }
        wantsPlayback = false
        cancelPreparation()
        Task { await loadPage(index, resume: nil, automatically: false) }
    }

    func close() {
        guard !closed else { return }
        wantsPlayback = false
        persistCurrentPosition()
        closed = true
        cancelPreparation()
        speech.onPlaybackDetached = nil
        speech.closePlayback()
        loading = false
        generation = UUID()
        onClosed?()
    }

    private func loadPage(_ index: Int, resume: KindleOfflineBook.ReadingPosition?, automatically: Bool) async {
        guard scopeIsCurrent, !closed, book.pages.indices.contains(index) else {
            if index >= book.pages.count && book.status != .complete { error = AppLocalized("已到已保存内容的末尾。请联网继续下载整本书。") }
            advancing = false
            return
        }
        let run = UUID(); generation = run
        loading = true
        speech.load([], voiceID: voiceID)
        document = nil; pageImage = nil
        pageIndex = index
        defer { if generation == run { loading = false; advancing = false } }
        do {
            let cached = try await store.cachedSpeechPage(book: book, ordinal: index, scope: scope)
            let doc: ReadingDocument
            if let cached { doc = cached }
            else { doc = try await store.openPage(book: book, ordinal: index, scope: scope) }
            guard generation == run, !closed, scopeIsCurrent else { return }
            guard await prepareVoice(for: doc), generation == run, !closed, scopeIsCurrent else { return }
            pageIndex = index
            pendingResume = resume
            installDocument(doc, resume: resume)
            let units = speech.units
            error = nil
            loading = false
            if let unit = units.first { checkpoint(units.indices.contains(speech.currentUnitIndex) ? units[speech.currentUnitIndex] : unit) }
            else { saveCursor(paragraphID: resume?.paragraphID ?? (book.pages[index].requiresOCR == true ? 1 : 0), sentenceStart: resume?.sentenceStart ?? 0) }
            if automatically, wantsPlayback, speech.canContinueAutomatically {
                beginPlayback(automatically: true)
            }
        } catch {
            if generation == run, !closed, scopeIsCurrent {
                wantsPlayback = false
                self.error = AppLocalized("这一页文件缺失或损坏，请重新保存此书。其他已保存页面仍可阅读。")
            }
        }
    }

    private func saveCursor(paragraphID: Int, sentenceStart: Int) {
        guard scopeIsCurrent, !closed, !loading else { return }
        var value = KindleOfflineBook.ReadingPosition()
        value.page = pageIndex; value.paragraphID = paragraphID
        value.sentenceStart = sentenceStart; value.voiceID = voiceID; value.speechRate = speechRate
        if value != lastCheckpoint {
            lastCheckpoint = value
            let previous = checkpointTask, store = store, scope = scope, book = book
            checkpointTask = Task { [weak self] in
                await previous?.value
                do { try await store.saveReadingPosition(value, book: book, scope: scope) }
                catch { self?.lastCheckpoint = nil; self?.error = AppLocalized("朗读位置未能保存，请检查本机空间。") }
            }
        }
    }

    private func checkpoint(_ unit: SystemSpeechUnit) {
        guard scopeIsCurrent, !closed, !loading else { return }
        saveCursor(paragraphID: unit.paragraphID, sentenceStart: unit.sourceRange.location)
        if speech.state == .finished, wantsPlayback, speech.canContinueAutomatically, !advancing, pageIndex + 1 < book.pages.count {
            advancing = true
            let run = generation, request = playbackRequest, next = pageIndex + 1
            Task { [weak self] in
                guard let self, self.generation == run, self.playbackRequest == request, self.wantsPlayback, !self.closed else { return }
                await self.loadPage(next, resume: nil, automatically: true)
            }
        }
    }
}
