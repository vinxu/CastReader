#if DEBUG
import SwiftUI

/// Uses production reader controls and AVPlayer with deterministic local audio.
/// All history is confined to a separate acceptance-test directory.
@MainActor
struct SleepTimerAcceptanceFixture: View {
    @StateObject private var coordinator: PlayerCoordinator
    @ObservedObject private var audio = AudioPlayerService.shared
    @ObservedObject private var timer = AudioPlayerService.shared.sleepTimer

    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SleepTimerAcceptance", isDirectory: true)
        _coordinator = StateObject(wrappedValue: PlayerCoordinator(
            historyStore: HistoryStore(directory: directory), speechGenerator: SleepTimerFixtureSpeech()))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Read") { startSample(.read) }.accessibilityIdentifier("sleepFixtureRead")
                Button("Explain") { startSample(.explain) }.accessibilityIdentifier("sleepFixtureExplain")
                Button("3s") { timer.start(after: 3) }.accessibilityIdentifier("sleepFixtureShortTimer")
                Button("8s") { timer.start(after: 8) }.accessibilityIdentifier("sleepFixtureBackgroundTimer")
                Button("Close") { coordinator.close() }.accessibilityIdentifier("sleepFixtureClose")
            }.font(.caption).buttonStyle(.bordered)
            Text("playing=\(audio.isPlaying);expired=\(timer.requiresExplicitResume);active=\(timer.isActive);time=\(Int(audio.currentTime));segment=\(audio.currentSegment?.segmentIndex ?? -1)")
                .font(.caption2.monospaced()).accessibilityIdentifier("sleepFixtureStatus")
            if let session = coordinator.session {
                if coordinator.isReaderPresented {
                    ReaderHostView(readVM: session.readVM, explainVM: session.explainVM,
                                   coordinator: coordinator, document: session.document)
                } else {
                    Spacer()
                    Button("Expand") { coordinator.expand() }.accessibilityIdentifier("sleepFixtureExpand")
                    MiniPlayerView(coordinator: coordinator)
                }
            } else {
                Spacer()
                Text("Sleep timer acceptance")
                Spacer()
            }
        }
        .task { openDocument() }
    }

    private func openDocument() {
        guard coordinator.session == nil else { return }
        coordinator.open(ReadingDocument(id: "sleep-timer-acceptance", title: "Sleep Timer · Reading sample",
            sourceKind: .text, language: "en", paragraphs: [
                ReadingParagraph(id: 0, text: "Make time for a little reading", type: .heading(1)),
                ReadingParagraph(id: 1, text: "Set a sleep timer and settle into a comfortable position. When the time is up, CastReader pauses the audio and keeps your place. You can continue from the same word whenever you are ready.", type: .paragraph),
                ReadingParagraph(id: 2, text: "Open the more menu to adjust text size, font, and line spacing. These settings make the page easier to follow while you listen.", type: .paragraph)
            ]))
    }

    private func startSample(_ mode: ReaderMode) {
        openDocument()
        guard let session = coordinator.session else { return }
        timer.resumeByUser()
        coordinator.mode = mode
        coordinator.expand()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if mode == .read {
                session.readVM.jump(to: 1)
            } else {
                session.readVM.deactivate()
                session.explainVM.activate()
                session.explainVM.status = .streaming(block: 0, total: 1)
                session.explainVM.explanationText = "A sleep timer pauses your listening and keeps your place."
                if let token = audio.activePlaybackSession {
                    _ = audio.loadSegments([SleepTimerFixtureSpeech.segment(text: session.document.paragraphs[1].text, paragraph: 1)], session: token)
                }
            }
        }
    }
}

struct SleepTimerFixtureSpeech: ParagraphSpeechGenerating {
    func generateTTSForParagraph(
        paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        try Task.checkCancellation()
        await onSegmentReady(Self.segment(text: text, paragraph: paragraphIndex))
    }

    static func segment(text: String, paragraph: Int) -> AudioSegment {
        let words = text.split(separator: " ")
        let span = 16 / Double(max(1, words.count))
        return AudioSegment(paragraphIndex: paragraph, segmentIndex: 0,
            audioData: ReadingResumeFixtureSpeech.wav(), timestamps: words.enumerated().map {
                TTSTimestamp(word: String($0.element), startTime: Double($0.offset) * span,
                             endTime: Double($0.offset + 1) * span)
            }, duration: 16, text: text, isWavFormat: true)
    }
}
#endif
