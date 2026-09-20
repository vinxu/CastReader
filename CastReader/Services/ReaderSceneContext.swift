import SwiftUI
import Combine

/// UI state is owned by a window. Authentication, content stores and the audio
/// output remain app-wide; asynchronous routes capture this object explicitly.
@MainActor
final class ReaderSceneContext: ObservableObject, Identifiable {
    static let legacy = ReaderSceneContext(legacyServices: true)
    let id = UUID()
    let keyboard = ReaderWindowKeyboard()
    weak var window: UIWindow?
    @Published var sceneSessionID: String?
    let player: PlayerCoordinator
    let kindle: KindlePlaybackCenter
    let offline: KindleOfflinePlaybackCenter
    let voicePanel: PlaybackVoicePanelCenter
    let bottomMetrics: BottomOverlayMetrics
    let youtubeRoutes: YouTubeRouteCenter
    let youtubeService: YouTubeTranscriptService
    let captionSwitcher: YouTubeCaptionLanguageSwitcher
    let studyBoost: StudyBoostRouter
    let voiceGift: VoiceGiftRouteCenter

    init(legacyServices: Bool = false, player suppliedPlayer: PlayerCoordinator? = nil) {
        #if DEBUG
        if let suppliedPlayer { player = suppliedPlayer }
        else if ProcessInfo.processInfo.arguments.contains("-CastReaderMultiWindowFixture") {
            player = PlayerCoordinator(historyStore: HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ipad-window-\(UUID().uuidString)")), speechGenerator: ReadingResumeScenarioSpeech())
        } else { player = PlayerCoordinator() }
        #else
        player = suppliedPlayer ?? PlayerCoordinator()
        #endif
        kindle = legacyServices ? .shared : KindlePlaybackCenter()
        offline = legacyServices ? .shared : KindleOfflinePlaybackCenter()
        voicePanel = legacyServices ? .shared : PlaybackVoicePanelCenter()
        bottomMetrics = legacyServices ? .shared : BottomOverlayMetrics()
        youtubeRoutes = legacyServices ? .shared : YouTubeRouteCenter()
        youtubeService = legacyServices ? .shared : YouTubeTranscriptService()
        captionSwitcher = legacyServices ? .shared : YouTubeCaptionLanguageSwitcher(transcriptService: youtubeService)
        studyBoost = legacyServices ? .shared : StudyBoostRouter()
        voiceGift = legacyServices ? .shared : VoiceGiftRouteCenter()
        player.scene = self
        kindle.scene = self
        offline.scene = self
        ReaderSceneRegistry.shared.register(self)
    }

    static func makeWindowContext() -> ReaderSceneContext {
        #if DEBUG
        // Historical acceptance fixtures intentionally exercise the legacy
        // singleton API. Normal and multi-window launches use isolated state.
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("-CastReaderMultiWindowFixture"),
           args.contains(where: { $0.hasPrefix("-CastReader") && ($0.contains("Fixture") || $0.contains("Scenario")) }) {
            return .legacy
        }
        #endif
        return ReaderSceneContext()
    }

    var ownsPlayback: Bool { player.ownsPlaybackSession || kindle.ownsPlaybackSession || offline.ownsPlaybackSession }
    var isKeyWindow: Bool { window?.isKeyWindow == true }

    var notificationUserInfo: [AnyHashable: Any] { ["readerSceneID": id.uuidString] }
    func accepts(_ notification: Notification) -> Bool {
        if let target = notification.userInfo?["readerSceneID"] as? String { return target == id.uuidString }
        return isKeyWindow
    }

    func resetForAccountBoundary() {
        player.close()
        kindle.close()
        offline.stop()
        voicePanel.dismiss()
        captionSwitcher.resetForAccountBoundary()
        youtubeRoutes.resetForAccountBoundary()
        youtubeService.cancel()
        studyBoost.dismiss()
        if let request = voiceGift.requestID { voiceGift.consume(request) }
    }

    func adoptPlayback(from source: ReaderSceneContext) {
        guard source !== self, source.ownsPlayback else { return }
        // Moving an existing VM/WK preserves generated audio and exact clocks.
        player.close(preservingSleepTimer: true)
        kindle.close(preservingSleepTimer: true)
        offline.stop(preservingSleepTimer: true)
        if source.player.ownsPlaybackSession { player.adoptPlayback(from: source.player) }
        else if source.kindle.ownsPlaybackSession { kindle.adoptPlayback(from: source.kindle) }
        else if source.offline.ownsPlaybackSession { offline.adoptPlayback(from: source.offline) }
    }

    func handleOpenURL(_ url: URL) {
        if CloudStorageCenter.isOAuthRedirectURL(url) {
            _ = CloudStorageCenter.handleOAuthRedirect(url)
        } else if StudyBoostDeepLink.matches(url) {
            studyBoost.open()
        } else if url.scheme == "castreader", url.host == "safari" {
            SafariAppRouteCenter.shared.open(url)
        } else if url.scheme == "castreader", url.host == "voice-gift" {
            voiceGift.open()
        } else if url.scheme == "castreader", url.host == "youtube" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let raw = components?.queryItems?.first(where: { $0.name == "url" })?.value {
                let entry = components?.queryItems?.first(where: { $0.name == "entry" })?.value
                _ = youtubeRoutes.open(raw, entry: entry.flatMap(YouTubeListenEntry.init(rawValue:)) ?? .scheme)
            }
        } else if let action = SystemAction.from(url: url) {
            SystemActionStore.shared.enqueue(action, origin: .deepLink)
        } else if url.scheme == "castreader", url.host == "share-inbox" {
            NotificationCenter.default.post(name: .castReaderShareInboxChanged, object: nil)
        }
    }
}

/// A small atomic checkpoint supplements SceneStorage, whose persistence timing
/// is system-controlled. Payloads and playback positions stay in their existing
/// account-scoped stores; this only remembers what each surviving window shows.
struct ReaderWindowBookmark: Codable, Equatable {
    var itemID: String
    var offlineBookID: String
    var mode: String
    var tab: Int
    var scope: String
}

@MainActor
final class ReaderWindowBookmarkStore {
    static let shared = ReaderWindowBookmarkStore()
    private let url: URL
    private var values: [String: ReaderWindowBookmark]
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("reader-windows-v1.json")
        if let data = try? Data(contentsOf: url), data.count < 131_072,
           let saved = try? JSONDecoder().decode([String: ReaderWindowBookmark].self, from: data) {
            values = saved
        } else { values = [:] }
    }
    func load(sessionID: String, scope: String) -> ReaderWindowBookmark? {
        guard let value = values[sessionID], value.scope == scope else { return nil }
        return value
    }
    func save(_ value: ReaderWindowBookmark, sessionID: String) {
        guard !sessionID.isEmpty, !value.scope.isEmpty, values[sessionID] != value else { return }
        values[sessionID] = value
        persist()
    }
    func retain(sessionIDs: Set<String>) {
        let kept = values.filter { sessionIDs.contains($0.key) }
        guard kept.count != values.count else { return }
        values = kept
        persist()
    }
    func remove(sessionIDs: Set<String>) {
        for id in sessionIDs { values.removeValue(forKey: id) }
        persist()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
final class ReaderSceneRegistry {
    static let shared = ReaderSceneRegistry()
    private final class Entry {
        weak var context: ReaderSceneContext?
        init(_ context: ReaderSceneContext) { self.context = context }
    }
    private var entries: [UUID: Entry] = [:]
    private var retainedPlayback: ReaderSceneContext?
    private var playbackOwner: ReaderSceneContext?
    private var audioObserver: AnyCancellable?
    private var disconnectObserver: NSObjectProtocol?
    private init() {
        disconnectObserver = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIScene else { return }
                self?.discarded(sessionIDs: [scene.session.persistentIdentifier])
            }
        }
    }
    func discarded(sessionIDs: Set<String>) {
        for context in contexts where context.sceneSessionID.map(sessionIDs.contains) == true {
            disconnected(context)
        }
    }
    var contexts: [ReaderSceneContext] { entries.values.compactMap(\.context) }
    var presentationContext: ReaderSceneContext? {
        contexts.first(where: \.isKeyWindow) ?? contexts.first(where: \.ownsPlayback) ?? (contexts.count == 1 ? contexts.first : nil)
    }
    func presents(_ target: UUID?, in context: ReaderSceneContext) -> Bool {
        target.map { $0 == context.id } ?? (presentationContext === context)
    }

    func register(_ context: ReaderSceneContext) {
        entries = entries.filter { $0.value.context != nil }
        entries[context.id] = Entry(context)
        if audioObserver == nil {
            audioObserver = AudioPlayerService.shared.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.playbackOwner = self.contexts.first(where: \.ownsPlayback)
                }
            }
        }
    }

    func attached(_ context: ReaderSceneContext, window: UIWindow) {
        ReaderWindowBookmarkStore.shared.retain(sessionIDs: Set(UIApplication.shared.openSessions.map(\.persistentIdentifier)))
        context.window = window
        context.sceneSessionID = window.windowScene?.session.persistentIdentifier
        context.youtubeService.presentationWindow = window
        context.kindle.model?.setReadingSurfaceAttached(true)
        if let retained = retainedPlayback, retained !== context {
            context.adoptPlayback(from: retained)
            retainedPlayback = nil
        }
    }

    func disconnected(_ context: ReaderSceneContext) {
        guard context.sceneSessionID != nil || context.window != nil else { return }
        context.sceneSessionID = nil
        context.window = nil
        context.kindle.model?.setReadingSurfaceAttached(false)
        if context.ownsPlayback {
            let targets = contexts.filter { $0 !== context && $0.window?.windowScene?.activationState != .unattached && $0.window != nil }
            if let target = targets.first(where: \.isKeyWindow) ?? targets.first {
                target.adoptPlayback(from: context)
                playbackOwner = target

            } else {
                retainedPlayback = context
            }
        } else { context.resetForAccountBoundary() }
    }

    func resetForAccountBoundary() {
        for context in contexts { context.resetForAccountBoundary() }
        retainedPlayback = nil
        playbackOwner = nil
    }
}

private struct ReaderSceneEnvironment: ViewModifier {
    let scene: ReaderSceneContext
    func body(content: Content) -> some View {
        content.environmentObject(scene)
            .environmentObject(scene.voicePanel)
            .environmentObject(scene.bottomMetrics)
            .environmentObject(scene.captionSwitcher)
            .environmentObject(scene.kindle)
            .environmentObject(scene.offline)
    }
}

extension View {
    func readerSceneEnvironment(_ scene: ReaderSceneContext) -> some View {
        modifier(ReaderSceneEnvironment(scene: scene))
    }
}

/// The window is obtained from the actual mounted view, never from the first
/// connected scene. Disconnect is distinct from ordinary backgrounding.
struct ReaderSceneWindowProbe: UIViewRepresentable {
    let context: ReaderSceneContext
    func makeUIView(context: Context) -> Probe { Probe(owner: self.context) }
    func updateUIView(_ view: Probe, context: Context) { view.attach() }
    final class Probe: UIView {
        private weak var owner: ReaderSceneContext?
        init(owner: ReaderSceneContext) {
            self.owner = owner
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        func attach() {
            guard let window, let owner, owner.window !== window,
                  let windowScene = window.windowScene,
                  windowScene.activationState != .unattached,
                  UIApplication.shared.openSessions.contains(windowScene.session) else { return }
            // Attachment may occur during SwiftUI's updateUIView transaction.
            // Publish scene identity and migrate a retained reader on the next
            // run-loop turn, after rechecking the actual mounted window.
            DispatchQueue.main.async { [weak self, weak owner, weak window] in
                guard let self, let owner, let window, self.window === window,
                      owner.window !== window, window.windowScene?.activationState != .unattached,
                      let session = window.windowScene?.session,
                      UIApplication.shared.openSessions.contains(session) else { return }
                ReaderSceneRegistry.shared.attached(owner, window: window)
            }
        }
    }
}

#if DEBUG
/// Two real UIKit scenes on one simulator; only synthesis is replaced with a
/// local WAV. The reader, ownership transfer, scene routing and close behavior
/// are production code. No account or Kindle credentials are changed.
@MainActor
struct IPadMultiWindowAcceptanceFixture: View {
    private let scene: ReaderSceneContext
    @ObservedObject private var coordinator: PlayerCoordinator
    init(scene: ReaderSceneContext) {
        self.scene = scene
        _coordinator = ObservedObject(wrappedValue: scene.player)
    }
    @Environment(\.openWindow) private var openWindow
    @State private var number = 0
    @State private var prepared = false
    @State private var actionResult = "none"
    @State private var viewport = CGSize.zero
    @ObservedObject private var audio = AudioPlayerService.shared
    private static var nextNumber = 0
    private static var numbers: [UUID: Int] = [:]

    private var prefix: String { "window\(number)" }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Text("Window \(number)").font(.headline)
                    Button("New window") { openWindow(id: "main") }
                        .accessibilityIdentifier("\(prefix).new")
                    Button("Play / resume") { play() }
                        .accessibilityIdentifier("\(prefix).play")
                    Button("Pause") { scene.player.session?.readVM.pausePlayback() }
                        .accessibilityIdentifier("\(prefix).pause")
                    Button("Close this window") { closeWindow() }
                        .accessibilityIdentifier("\(prefix).close")
                }.buttonStyle(.bordered).padding(8)
                TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                    Text(diagnostics).font(.caption.monospaced())
                        .accessibilityIdentifier("\(prefix).status")
                }
                HStack {
                    ForEach(ReaderSceneRegistry.shared.contexts.filter { $0 !== scene && $0.window != nil }, id: \.id) { other in
                        if let value = Self.numbers[other.id] {
                            Button("Focus \(value)") {
                                guard let session = other.window?.windowScene?.session else { return }
                                UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil)
                            }.accessibilityIdentifier("\(prefix).focus\(value)")
                            Button("Close \(value)") {
                                guard let session = other.window?.windowScene?.session else { return }
                                UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
                                    actionResult = "close-error=\(error.localizedDescription)"
                                }
                                actionResult = "close-requested=\(value)"
                            }.accessibilityIdentifier("\(prefix).closeOther\(value)")
                        }
                    }
                }.padding(4)
                if let session = scene.player.session {
                    ReaderHostView(readVM: session.readVM, explainVM: session.explainVM,
                                   coordinator: scene.player, document: session.document)
                        .id(session.instanceID)
                } else { Text("Reading surface is moving to another window.") }
            }
            .environment(\.appViewport, geometry.size)
            .onAppear { viewport = geometry.size }
            .onChange(of: geometry.size) { viewport = $0 }
            .overlay { PlaybackVoicePanelOverlay(center: scene.voicePanel) }
        }
        .task {
            guard number == 0 else { return }
            Self.nextNumber += 1; number = Self.nextNumber
            Self.numbers[scene.id] = number
            _ = AppSettings.shared.setVoice("af_heart", for: "en")
            AppSettings.shared.autoPlay = false
            AppSettings.shared.speed = 1
            let text = (0..<80).map { "Window reading word \($0) preserves its place while another window is browsing." }.joined(separator: " ")
            let doc = ReadingDocument(id: "ipad-multiwindow-public-sample", title: "Reading across iPad windows",
                sourceKind: .text, language: "en", paragraphs: [ReadingParagraph(id: 0, text: text, type: .paragraph, words: [], bboxNorm: nil)])
            scene.player.open(doc, autoplay: false)
        }
    }
    private var diagnostics: String {
        let states = ReaderSceneRegistry.shared.contexts.compactMap { context -> String? in
            guard let n = Self.numbers[context.id] else { return nil }
            return "w\(n):owner=\(context.ownsPlayback),playing=\(context.player.session?.readVM.isPlaying ?? false),panel=\(context.voicePanel.isPresented),attached=\(context.window != nil)"
        }.sorted().joined(separator: ";")
        return "time=\(String(format: "%.2f", audio.playbackPosition));\(states);action=\(actionResult);scenes=\(UIApplication.shared.connectedScenes.count);viewport=\(Int(viewport.width))x\(Int(viewport.height));orientation=\(scene.window?.windowScene?.interfaceOrientation.rawValue ?? -1)"
    }
    private func play() {
        guard let session = scene.player.session else { return }
        if prepared || session.readVM.currentParagraphIndex >= 0 {
            session.readVM.ensurePlaying()
        } else {
            prepared = true
            let text = session.document.paragraphs[0].text
            let samples = 8000 * 180
            var data = Data()
            func bytes<T>(_ value: T) { var value = value; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            data.append(Data("RIFF".utf8)); bytes(UInt32(36 + samples * 2).littleEndian)
            data.append(Data("WAVEfmt ".utf8)); bytes(UInt32(16).littleEndian)
            bytes(UInt16(1).littleEndian); bytes(UInt16(1).littleEndian)
            bytes(UInt32(8000).littleEndian); bytes(UInt32(16000).littleEndian)
            bytes(UInt16(2).littleEndian); bytes(UInt16(16).littleEndian)
            data.append(Data("data".utf8)); bytes(UInt32(samples * 2).littleEndian)
            data.append(Data(repeating: 0, count: samples * 2))
            let words = text.split(separator: " ")
            let wordDuration = 178.0 / Double(words.count)
            let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: data,
                timestamps: words.enumerated().map { TTSTimestamp(word: String($0.element), startTime: Double($0.offset) * wordDuration, endTime: Double($0.offset + 1) * wordDuration - 0.01) },
                duration: 180, text: text, isWavFormat: true)
            session.readVM.startWithCachedSegments([segment], paragraphIndex: 0, segmentID: segment.id,
                progress: 0, isReplayEligible: false, autoplay: true)
        }
    }
    private func closeWindow() {
        guard let session = scene.window?.windowScene?.session else { return }
        let target = ReaderSceneRegistry.shared.contexts.first { $0 !== scene && $0.window != nil }
        let nextSession = target?.window?.windowScene?.session
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            actionResult = "close-error=\(error.localizedDescription)"
        }
        // The QA control performs the user's explicit return to the surviving
        // window after dismissing the foreground scene. iPad otherwise returns
        // to Home; this does not substitute for the real disconnect/migration.
        if let nextSession {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                UIApplication.shared.requestSceneSessionActivation(nextSession, userActivity: nil, options: nil)
            }
        }

    }
}
#endif
