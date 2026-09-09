#if DEBUG
import SwiftUI
import ZIPFoundation

/// Deterministic speech provider for simulator acceptance. It exercises the
/// production import, History, coordinator, AVPlayer, and reader UI; only the
/// remote synthesis is replaced. Never compiled into release builds.
struct ReadingResumeFixtureSpeech: ParagraphSpeechGenerating {
    func generateTTSForParagraph(
        paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        if ProcessInfo.processInfo.arguments.contains("-CastReaderResumeDelayedAudio") {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let chunks = ["Resume destination ", "chapter one hundred."]
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let segment = AudioSegment(paragraphIndex: paragraphIndex, segmentIndex: index,
                audioData: Self.wav(), timestamps: chunk.split(separator: " ").enumerated().map {
                    TTSTimestamp(word: String($0.element), startTime: Double($0.offset) * 4,
                                 endTime: Double($0.offset) * 4 + 3)
                }, duration: 16, text: chunk, isWavFormat: true)
            await onSegmentReady(segment)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func wav() -> Data {
        var data = Data()
        func ascii(_ x: String) { data.append(Data(x.utf8)) }
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + 256000); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16); ascii("data"); u32(256000)
        data.append(Data(repeating: 0, count: 256000))
        return data
    }

    static func epub() throws -> Data {
        let archive = try Archive(accessMode: .create)
        func add(_ path: String, _ text: String) throws {
            let bytes = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) {
                position, size in bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        let manifest = (1...100).map { "<item id='c\($0)' href='c\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
        let spine = (1...100).map { "<itemref idref='c\($0)'/>" }.joined()
        try add("OEBPS/content.opf", """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">resume-mvp-100</dc:identifier><dc:title>Resume MVP 100 chapters</dc:title><dc:language>en</dc:language></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """)
        for chapter in 1...100 {
            let text = chapter == 100 ? "Resume destination chapter one hundred." : "This is chapter \(chapter). Every chapter has its own content and must preserve its position."
            try add("OEBPS/c\(chapter).xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'><body><h1>Chapter \(chapter)</h1><p>\(text)</p></body></html>")
        }
        guard let bytes = archive.data else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
}

@MainActor
struct ReadingResumeMVPFixtureView: View {
    @StateObject private var coordinator: PlayerCoordinator
    private let store: HistoryStore
    @State private var failure: String?

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResumeMVPAcceptance", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("-CastReaderResetResumeFixture") {
            try? FileManager.default.removeItem(at: directory)
        }
        let history = HistoryStore(directory: directory)
        store = history
        _coordinator = StateObject(wrappedValue: PlayerCoordinator(
            historyStore: history, speechGenerator: ReadingResumeFixtureSpeech()))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = coordinator.session {
                HStack {
                    Button("Play chapter 100") {
                        session.readVM.jump(to: session.document.paragraphs.count - 1)
                    }.accessibilityIdentifier("resumeFixtureStart")
                    Button("Next audio segment") { session.readVM.skipForward(); session.readVM.skipForward() }
                        .accessibilityIdentifier("resumeFixtureAdvance")
                }.font(.caption)
                ReadingResumeFixtureStatus(vm: session.readVM)
                ReaderHostView(readVM: session.readVM, explainVM: session.explainVM,
                               coordinator: coordinator, document: session.document)
            } else if let failure { Text(failure) }
            else { ProgressView() }
        }
        .task {
            guard coordinator.session == nil else { return }
            // This flag stays process-local: no persistent Pro preference is modified.
            do {
                if let record = store.records.first, let reopened = try await store.reopen(record) {
                    coordinator.open(reopened)
                } else {
                    guard let document = DocumentBuilder.fromEPUB(data: try ReadingResumeFixtureSpeech.epub(), title: "Resume MVP 100 chapters") else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    coordinator.open(document)
                }
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct ReadingResumeFixtureStatus: View {
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject private var audio = AudioPlayerService.shared
    var body: some View {
        Text("paragraph=\(vm.currentParagraphIndex);segment=\(audio.currentSegment?.segmentIndex ?? -1);time=\(Int(audio.currentTime));playing=\(vm.isPlaying);waiting=\(vm.isWaitingForPlayableAudio);userPaused=\(vm.isPlaybackPausedByUser);queued=\(audio.hasQueuedSegments)")
            .font(.caption2).accessibilityIdentifier("resumeFixtureStatus")
    }
}

/// Real Home/Library and the common resume service with an isolated local
/// store. The test chooses a chapter and pauses actual AVPlayer playback;
/// no progress file is seeded by the acceptance harness.
@MainActor
struct UnifiedCatalogAcceptanceView: View {
    @StateObject private var coordinator: PlayerCoordinator
    @StateObject private var history: HistoryStore
    @StateObject private var imports = ImportRouter()
    @State private var showsLibrary = false
    @State private var showsSettings = false
    @State private var failure: String?
    private static var didReset = false
    private static let itemID = "catalog-mvp-100"

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnifiedCatalogAcceptance", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("-CastReaderResetResumeFixture"), !Self.didReset {
            Self.didReset = true
            try? FileManager.default.removeItem(at: directory)
        }
        let store = HistoryStore(directory: directory)
        _history = StateObject(wrappedValue: store)
        _coordinator = StateObject(wrappedValue: PlayerCoordinator(historyStore: store,
            speechGenerator: ReadingResumeFixtureSpeech()))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Home") { coordinator.close(); showsLibrary = false }
                    .accessibilityIdentifier("catalogHome")
                Button("Library") { coordinator.close(); showsLibrary = true }
                    .accessibilityIdentifier("catalogLibrary")
                Button("Settings") { showsSettings = true }
                    .accessibilityIdentifier("catalogSettings")
                Button("Notification") {
                    Task {
                        guard case .continueReading(let id, let mode) = ResumeReminderDeepLink.action(
                            from: ResumeReminderDeepLink.userInfo(documentID: Self.itemID)) else { return }
                        do { _ = try await coordinator.resume.open(itemID: id, mode: mode == .read ? .read : .explain,
                            autoplay: true, entryPoint: "notification_acceptance") }
                        catch { failure = error.localizedDescription }
                    }
                }.accessibilityIdentifier("catalogNotification")
            }.font(.caption)
            if let session = coordinator.session {
                Button("Play chapter 100") { session.readVM.jump(to: session.document.paragraphs.count - 1) }
                    .accessibilityIdentifier("resumeFixtureStart")
                ReadingResumeFixtureStatus(vm: session.readVM)
                ReaderHostView(readVM: session.readVM, explainVM: session.explainVM,
                    coordinator: coordinator, document: session.document)
            } else if showsLibrary {
                NavigationStack { LibraryView(history: history) }
            } else {
                HomeView(history: history, onRequestLibraryConnection: { _ in })
            }
            if let failure { Text(failure).accessibilityIdentifier("catalogFailure") }
        }
        .environmentObject(coordinator).environmentObject(imports)
        .sheet(isPresented: $showsSettings) {
            SettingsView(history: history).environmentObject(coordinator).environmentObject(imports)
        }
        .task {
            if history.records.isEmpty {
                do {
                    guard var doc = DocumentBuilder.fromEPUB(data: try ReadingResumeFixtureSpeech.epub(), title: "Catalog 100 chapters") else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    doc.id = Self.itemID
                    coordinator.open(doc)
                } catch { failure = error.localizedDescription }
            }
        }
    }
}
#endif
