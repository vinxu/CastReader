import AVFoundation
import Combine
import SwiftUI

@MainActor
enum KindleOfflineContext {
    static var currentScope: String? {
        let account = AccountContentScopeBridge.storagePartition
        guard account != "unassigned", let binding = KindleLibraryStore.shared.offlineContentBindingID else { return nil }
        return KindleOfflinePageStore.digest(account + ":" + KindleLibraryStore.shared.boundStorefrontID + ":" + binding)
    }
}

#if DEBUG
@MainActor
struct KindleOfflinePageFixture: View {
    @State private var ready = false
    @State private var error: String?
    private let scope = KindleOfflinePageStore.digest("offline-page-local-fixture-v1")
    var body: some View {
        NavigationStack {
            Group {
                if ready { KindleOfflinePageListView(scopeOverride: scope) }
                else if let error { Text(error) }
                else { ProgressView("准备本地测试页…") }
            }
        }.task {
            do {
                if try await KindleOfflinePageStore.shared.list(scope: scope).isEmpty {
                    let text = "This page was saved on this device. System speech reads the original text and reports the highlighted range. Pause the reading, then continue from the same sentence. Closing and opening this page should preserve the last sentence. No cloud voice is needed to read this saved page."
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 780, height: 1100)).pngData { context in
                        UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 780, height: 1100))
                        (text as NSString).draw(in: CGRect(x: 60, y: 80, width: 660, height: 950),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
                    }
                    let document = ReadingDocument(title: "离线朗读 · 本地测试页", sourceKind: .kindle, language: "en-US", paragraphs: [
                        ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: image),
                        ReadingParagraph(id: 1, text: text, pageIndex: 0)
                    ])
                    _ = try await KindleOfflinePageStore.shared.save(document: document, pageKey: "local-fixture:page-1", scope: scope)
                }
                ready = true
            } catch { self.error = "本地测试页创建失败：\(error.localizedDescription)" }
        }
    }
}

@MainActor
struct KindleOfflinePageListView: View {
    @ObservedObject private var library = KindleLibraryStore.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var pages: [KindleOfflinePageStore.SavedPage] = []
    @State private var error: String?
    var scopeOverride: String? = nil
    private var scope: String? { scopeOverride ?? KindleOfflineContext.currentScope }

    var body: some View {
        List {
            Section {
                Text("这里保存的是你确认过的独立页面。保存数量不代表整本书的页数，页面之间不会自动连读。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                if pages.isEmpty { Text("还没有已保存页面") }
            }
            if let scope {
                ForEach(pages) { page in
                    NavigationLink {
                        KindleOfflineSavedPageView(page: page, scope: scope, fixture: scopeOverride != nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.title).lineLimit(2)
                            Text("1 个已确认页面 · \(ByteCountFormatter.string(fromByteCount: Int64(page.byteCount), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(page.savedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("offlineSavedPage_\(page.id)")
                }
            }
        }
        .navigationTitle("已保存页面")
        .task(id: scope) { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        pages = []; error = nil
        guard let scope else { error = "当前账号没有可访问的 Kindle 离线内容。"; return }
        do {
            let loaded = try await KindleOfflinePageStore.shared.list(scope: scope)
            guard scope == self.scope else { return }
            pages = loaded
        } catch { self.error = "本机索引读取失败，已有页面文件仍保留。" }
    }
}

@MainActor
final class KindleOfflineSavedPageModel: ObservableObject {
    @Published private(set) var document: ReadingDocument?
    @Published private(set) var error: String?
    @Published var voiceID = ""
    @Published private(set) var voices: [SystemSpeechVoice] = []
    let speech = SystemSpeechPlaybackService()
    let page: KindleOfflinePageStore.SavedPage
    private let scope: String
    private let fixture: Bool
    private var lastCheckpoint: KindleOfflinePageStore.Checkpoint?
    private var checkpointTask: Task<Void, Never>?
    private var lastDiagnosticState: SystemSpeechPlaybackService.State?
    private var observers: Set<AnyCancellable> = []

    init(page: KindleOfflinePageStore.SavedPage, scope: String, fixture: Bool) {
        self.page = page; self.scope = scope; self.fixture = fixture
        AuthService.shared.$account.sink { [weak self] _ in self?.validateScope() }.store(in: &observers)
        KindleLibraryStore.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.validateScope() }
        }.store(in: &observers)
    }

    private var scopeIsCurrent: Bool { fixture || scope == KindleOfflineContext.currentScope }
    private func validateScope() {
        guard !scopeIsCurrent else { return }
        speech.closePlayback()
        document = nil
        error = "账号已切换，请从当前账号的已保存页面重新打开。"
    }

    func open() async {
        do {
            let (_, document) = try await KindleOfflinePageStore.shared.open(page.id, scope: scope)
            // A damaged position can fall back to the beginning without making
            // an intact saved page unusable. Content corruption still blocks.
            let saved = try? await KindleOfflinePageStore.shared.checkpoint(pageID: page.id, scope: scope)
            guard scopeIsCurrent else { validateScope(); return }
            self.document = document
            voices = SystemSpeechPlaybackService.voices(language: document.language)
            voiceID = saved.flatMap { checkpoint in voices.first(where: { $0.id == checkpoint.voiceID })?.id } ?? voices.first?.id ?? ""
            let units = document.paragraphs.filter(\.type.isReadable).flatMap {
                SystemSpeechTextPlan.units(paragraphID: $0.id, text: $0.text)
            }
            speech.load(units, voiceID: voiceID, language: document.language)
            if let saved, let index = units.firstIndex(where: { $0.paragraphID == saved.paragraphID && $0.sourceRange.location == saved.sentenceStart }) {
                speech.seek(to: index, autoplay: false)
            }
            speech.onCheckpoint = { [weak self] unit, _ in self?.persist(unit) }
            speech.connectPlayback(title: page.title)
        } catch { self.error = "页面文件缺失或校验失败，请联网回到原页重新保存。" }
    }

    func changeVoice(_ id: String) {
        guard scopeIsCurrent else { validateScope(); return }
        speech.setVoice(id)
    }

    func play() {
        guard scopeIsCurrent else { validateScope(); return }
        speech.play()
    }

    func close() { speech.closePlayback() }

    private func persist(_ unit: SystemSpeechUnit) {
        guard scopeIsCurrent else { return }
        if speech.callbackCount % 10 == 0 || lastDiagnosticState != speech.state { writeDiagnostic() }
        let value = KindleOfflinePageStore.Checkpoint(snapshotHash: page.snapshotHash,
            paragraphID: unit.paragraphID, sentenceStart: unit.sourceRange.location, voiceID: voiceID)
        guard value != lastCheckpoint else { return }
        lastCheckpoint = value
        let previous = checkpointTask, id = page.id, scope = scope
        checkpointTask = Task { [weak self] in
            await previous?.value
            do { try await KindleOfflinePageStore.shared.saveCheckpoint(value, pageID: id, scope: scope) }
            catch { self?.lastCheckpoint = nil; self?.error = "朗读位置未能保存，请检查本机空间。" }
        }
    }

    private func writeDiagnostic() {
        lastDiagnosticState = speech.state
        let record: [String: Any] = ["version": 1, "syntheticFixture": fixture,
            "pageID": page.id, "state": speech.state.rawValue, "unit": speech.currentUnitIndex,
            "rangeCallbacks": speech.callbackCount, "firstSpeechMilliseconds": speech.firstSpeechMilliseconds ?? -1,
            "voiceID": voiceID, "networkIsOnlineHint": NetworkReachability.shared.isOnline,
            "errorCode": speech.errorCode ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
              let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let directory = root.appendingPathComponent("KindleOfflineDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("saved-page-latest.json"), options: .atomic)
    }
}

@MainActor
struct KindleOfflineSavedPageView: View {
    @StateObject private var model: KindleOfflineSavedPageModel
    init(page: KindleOfflinePageStore.SavedPage, scope: String, fixture: Bool = false) {
        _model = StateObject(wrappedValue: KindleOfflineSavedPageModel(page: page, scope: scope, fixture: fixture))
    }
    var body: some View {
        Group {
            if let document = model.document {
                KindleOfflineSavedPageContent(model: model, speech: model.speech, document: document)
            } else if let error = model.error { Text(error).padding() }
            else { ProgressView("正在读取本机页面…") }
        }
        .navigationTitle("离线朗读")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.open() }
        .onDisappear { model.close() }
    }
}

@MainActor
private struct KindleOfflineSavedPageContent: View {
    @ObservedObject var model: KindleOfflineSavedPageModel
    @ObservedObject var speech: SystemSpeechPlaybackService
    @ObservedObject private var network = NetworkReachability.shared
    let document: ReadingDocument
    @State private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("播放") { model.play() }.accessibilityIdentifier("offlineSpeechPlay")
                Button("暂停") { speech.pause() }.accessibilityIdentifier("offlineSpeechPause")
                Button("上一句") { speech.seek(to: max(0, speech.currentUnitIndex - 1), autoplay: false) }
                Button("下一句") { speech.seek(to: speech.currentUnitIndex + 1, autoplay: false) }
            }.buttonStyle(.bordered)
            Picker("本机声音", selection: $model.voiceID) {
                if model.voices.isEmpty { Text("无可用声音，仍可阅读页面").tag("") }
                ForEach(model.voices) { Text("\($0.name) · \($0.language)").tag($0.id) }
            }.onChange(of: model.voiceID) { value in model.changeVoice(value) }
            Slider(value: $rate, in: 0.3...0.65, step: 0.05)
                .accessibilityLabel("朗读速度")
                .onChange(of: rate) { speech.setRate(Float($0)) }
            Text("第 \(min(speech.currentUnitIndex + 1, speech.units.count)) / \(speech.units.count) 句 · \(speech.state.rawValue)")
                .font(.caption).accessibilityIdentifier("offlineSpeechStatus")
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            if let code = speech.errorCode { Text("系统声音未能开始朗读（\(code)）。可切换本机声音后重试。").font(.caption) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let imageData = document.paragraphs.first(where: { $0.type == .image })?.imageData,
                           let image = UIImage(data: imageData) {
                            DisclosureGroup("查看保存的原页面") {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .overlay { GeometryReader { geometry in
                                        ForEach(Array(imageHighlights.enumerated()), id: \.offset) { _, box in
                                            RoundedRectangle(cornerRadius: 3).fill(.orange.opacity(0.4))
                                                .frame(width: box.width * geometry.size.width, height: box.height * geometry.size.height)
                                                .position(x: box.midX * geometry.size.width, y: (1 - box.midY) * geometry.size.height)
                                        }
                                    } }
                            }
                        }
                        ForEach(document.paragraphs.filter { $0.type != .image }) { paragraph in
                            Text(highlighted(paragraph)).font(.system(size: 22)).id(paragraph.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .task(id: speech.highlightedParagraphID) {
                    // The saved sentence is loaded before this view appears, so
                    // observing only changes misses the initial restored position.
                    await Task.yield()
                    guard !Task.isCancelled, scenePhase == .active,
                          let id = speech.highlightedParagraphID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active, let id = speech.highlightedParagraphID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Text("已保存 1 个确认页面 · \(network.isOnline ? "网络可用" : "无网络连接") · 本机系统朗读")
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("offlineNetworkStatus")
        }.padding()
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

    private var imageHighlights: [CGRect] {
        guard let paragraph = document.paragraphs.first(where: { $0.id == speech.highlightedParagraphID }),
              let range = speech.highlightRange else { return [] }
        let source = paragraph.text as NSString
        var cursor = 0
        return paragraph.words.compactMap { word in
            guard !word.text.isEmpty, cursor <= source.length else { return nil }
            let found = source.range(of: word.text, range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound else { return nil }
            cursor = NSMaxRange(found)
            guard NSIntersectionRange(found, range).length > 0,
                  word.bboxSource == .visionTextRange || word.bboxSource == .tesseractWord else { return nil }
            return word.bboxNorm
        }
    }
}
#endif
