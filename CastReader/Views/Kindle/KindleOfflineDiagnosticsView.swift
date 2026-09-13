#if DEBUG
import AVFoundation
import SwiftUI
import WebKit

@MainActor
struct SystemSpeechAcceptanceView: View {
    let document: ReadingDocument?
    @StateObject private var speech = SystemSpeechPlaybackService()
    @State private var language = "en-US"
    @State private var voiceID = ""
    @State private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var voices: [SystemSpeechVoice] = []
    @State private var paragraphs: [ReadingParagraph] = []
    @State private var sceneEvents = 0
    @Environment(\.scenePhase) private var scenePhase

    init(document: ReadingDocument? = nil) { self.document = document }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("第一阶段 · 本机语音验证")
                    .font(.headline)
                if document == nil {
                    Picker("语言", selection: $language) {
                        Text("English").tag("en-US")
                        Text("简体中文").tag("zh-CN")
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("systemSpeechLanguage")
                }
                Picker("本机声音", selection: $voiceID) {
                    if voices.isEmpty { Text("没有对应语言的声音").tag("") }
                    ForEach(voices) { voice in Text("\(voice.name) · \(voice.language)").tag(voice.id) }
                }
                .accessibilityIdentifier("systemSpeechVoice")
                HStack {
                    Button("播放") { speech.play() }.accessibilityIdentifier("systemSpeechPlay")
                    Button("暂停") { speech.pause() }.accessibilityIdentifier("systemSpeechPause")
                    Button("停止") { speech.stop() }.accessibilityIdentifier("systemSpeechStop")
                    Button("下一句") { speech.seek(to: speech.currentUnitIndex + 1, autoplay: true) }
                        .accessibilityIdentifier("systemSpeechNext")
                }.buttonStyle(.bordered)
                Slider(value: $rate, in: 0.3...0.65, step: 0.05)
                    .accessibilityLabel("System speech rate")
                    .accessibilityIdentifier("systemSpeechRate")
                Text("state=\(speech.state.rawValue);unit=\(speech.currentUnitIndex);ranges=\(speech.callbackCount);firstMs=\(speech.firstSpeechMilliseconds ?? -1);scene=\(scenePhase == .active ? "active" : "background");sceneEvents=\(sceneEvents)")
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("systemSpeechStatus")
                if let code = speech.errorCode { Text(code).foregroundStyle(.red) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(paragraphs) { paragraph in
                                Text(highlighted(paragraph))
                                    .font(.system(size: 22))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(paragraph.id)
                            }
                        }
                    }
                    .onChange(of: speech.highlightedParagraphID) { id in
                        if let id, scenePhase == .active { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: scenePhase) { phase in
                        sceneEvents += 1
                        if phase == .active, let id = speech.highlightedParagraphID { proxy.scrollTo(id, anchor: .center) }
                        saveDiagnostic()
                    }
                }
                Text("测试入口：使用系统实时朗读，未生成音频文件。请核对声音与橙色高亮；回调数量不代表人工同步验收通过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("离线语音诊断")
            .navigationBarTitleDisplayMode(.inline)
            .task { prepare() }
            .onChange(of: language) { _ in prepare() }
            .onChange(of: voiceID) { value in speech.setVoice(value) }
            .onChange(of: rate) { value in speech.setRate(Float(value)) }
            .onChange(of: speech.state) { _ in saveDiagnostic() }
            .onChange(of: speech.callbackCount) { count in if count % 10 == 0 { saveDiagnostic() } }
            .onDisappear { speech.closePlayback(); saveDiagnostic() }
        }
    }

    private func prepare() {
        AudioPlayerService.shared.stop()
        if let document {
            language = document.language
            paragraphs = document.paragraphs.filter { $0.type.isReadable && !$0.text.isEmpty }
        } else {
            let text = language.hasPrefix("zh")
                ? "这是本机系统语音的离线测试。每一个橙色高亮都来自系统正在朗读的文字范围。\n暂停后，可以从原来的位置继续。切换声音或速度时，可以重复当前句子，但不能漏读。\n关掉网络之后，再次打开已经保存的内容。文字、高亮和阅读位置都应该留在这台手机上。"
                : "This is a reading test using the voice installed on this phone. The orange highlight follows the text range reported by the speech system.\nPause the reading, then continue from the same position. A change of voice or speed may repeat the current sentence, but it must not skip a sentence.\nAfter the network is turned off, saved pages should still open. The words, highlights, and reading position remain on this phone."
            paragraphs = text.split(separator: "\n").enumerated().map { ReadingParagraph(id: $0.offset, text: String($0.element)) }
        }
        voices = SystemSpeechPlaybackService.voices(language: language)
        voiceID = voices.first?.id ?? ""
        speech.load(paragraphs.flatMap { SystemSpeechTextPlan.units(paragraphID: $0.id, text: $0.text) }, voiceID: voiceID)
        speech.connectPlayback(title: document?.title ?? "系统语音测试")
    }

    private func highlighted(_ paragraph: ReadingParagraph) -> AttributedString {
        var value = AttributedString(paragraph.text)
        guard speech.highlightedParagraphID == paragraph.id, let nsRange = speech.highlightRange,
              let range = Range(nsRange, in: paragraph.text),
              let start = AttributedString.Index(range.lowerBound, within: value),
              let end = AttributedString.Index(range.upperBound, within: value) else { return value }
        value[start..<end].backgroundColor = .orange.opacity(0.4)
        return value
    }

    private func saveDiagnostic() {
        let record: [String: Any] = ["version": 1, "state": speech.state.rawValue,
            "unit": speech.currentUnitIndex, "rangeCallbacks": speech.callbackCount,
            "firstSpeechMilliseconds": speech.firstSpeechMilliseconds ?? -1,
            "language": language, "voiceID": voiceID, "sceneEvents": sceneEvents,
            "errorCode": speech.errorCode ?? "", "syntheticFixture": document == nil]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        try? data.write(to: root.appendingPathComponent("system-speech-acceptance.json"), options: .atomic)
    }
}

@MainActor
struct KindleOfflineDiagnosticsView: View {
    @ObservedObject var model: KindleBookViewModel
    @State private var status = "探针只观察当前页面。请先开始采样，再回到 Kindle 手动打开 Page Flip。"
    @State private var sourcePosition = ""
    @State private var captured: ReadingDocument?
    @State private var busy = false
    @State private var showSpeech = false
    @State private var showImageBenchmark = false
    @StateObject private var imageBenchmark = KindleOfflineDownloadCoordinator(store: .imageBenchmark)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("图片缓存速度验证") {
                    Button("重新采集整本图片（独立副本）") { showImageBenchmark = true }
                        .accessibilityIdentifier("kindleOfflineImageBenchmark")
                    Text("保留原离线书。验证副本使用同一下载流程，下载时不识别文字。")
                        .font(.footnote)
                }
                Section("当前页本机朗读") {
                    Text("捕获实际可见页并在本机 OCR，不自动翻页。")
                    Button("识别当前页并试听") {
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do { captured = try await model.captureOfflineDiagnosticPage(); showSpeech = true }
                            catch { status = "当前页采集未完成，请回到 Kindle 确认页面已加载。" }
                        }
                    }.disabled(busy).accessibilityIdentifier("kindleOfflineCaptureDiagnostic")
                    Button("保存当前页到本机") {
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do {
                                _ = try await model.saveCurrentOfflinePage()
                                status = "当前页已保存，可从已保存页面中离线打开。"
                            } catch { status = "保存未完成。请确认账号已连接且当前页已加载。" }
                        }
                    }.disabled(busy).accessibilityIdentifier("kindleOfflineSaveCurrentPage")
                    NavigationLink("已保存页面") { KindleOfflinePageListView() }
                }
                Section("Page Flip 旁观探针") {
                    HStack {
                        TextField("源位置", text: $sourcePosition).keyboardType(.numberPad)
                        Button("定位") { run("jump:" + sourcePosition) }.disabled(Int(sourcePosition) == nil)
                    }

                    Button("验证整书源页面") { run("renderer") }
                        .accessibilityIdentifier("kindleOfflineRendererCapabilities")
                    Button("读取整书定位能力") { run("source") }
                        .accessibilityIdentifier("kindleOfflineSourceCapabilities")
                    Button("开始采样") { run("start") }
                        .accessibilityIdentifier("kindleOfflineProbeStart")
                    Button("读取采样") { run("poll") }
                        .accessibilityIdentifier("kindleOfflineProbePoll")
                    Button("停止采样") { run("stop") }
                        .accessibilityIdentifier("kindleOfflineProbeStop")
                    Text("操作流程：开始采样 → 完成 → 在 Kindle 内浏览 Page Flip → 返回此面板读取或停止。采样结果写入本机诊断文件，不保存书籍正文。")
                        .font(.footnote)
                }.disabled(busy)
                Section("结果") {
                    Text(status).font(.caption.monospaced())
                        .accessibilityIdentifier("kindleOfflineProbeStatus")
                    if busy { ProgressView() }
                }
            }
            .navigationTitle("离线能力诊断")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showSpeech) {
                if let captured { SystemSpeechAcceptanceView(document: captured) }
            }
            .sheet(isPresented: $showImageBenchmark) {
                KindleOfflineDownloadView(model: model, download: imageBenchmark)
            }
        }
    }

    private func run(_ command: String) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { status = try await model.runOfflinePageFlipDiagnostic(command) }
            catch { status = "采样未完成，请确认 Kindle 正文页面已加载。" }
        }
    }
}
/// Isolated UI acceptance fixture. It exercises the real coordinator and sheet
/// with synthetic images; its duration is never a Kindle speed benchmark.
@MainActor
struct KindleOfflineDownloadFixture: View {
    @StateObject private var model: KindleBookViewModel
    @StateObject private var download: KindleOfflineDownloadCoordinator
    @State private var presented = false
    private let source: OfflineDownloadUIFixtureSource
    private let scope = KindleOfflinePageStore.digest("offline-download-ui-fixture")

    init() {
        let source = OfflineDownloadUIFixtureSource()
        self.source = source
        _model = StateObject(wrappedValue: KindleBookViewModel(book: source.offlineSourceBook, websiteDataStore: .nonPersistent()))
        _download = StateObject(wrappedValue: KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("OfflineDownloadUI-" + UUID().uuidString))))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("本地合成测试书 · 仅验证交互，不代表真实下载速度")
            Button("打开下载面板") { presented = true }
                .accessibilityIdentifier("offlineFixtureOpen")
        }.padding()
            .sheet(isPresented: $presented) {
                KindleOfflineDownloadView(model: model, download: download, fixtureStart: {
                    download.start(source: source, scope: scope, stillAuthorized: { true })
                }, fixtureScope: scope)
            }
    }
}

@MainActor
private final class OfflineDownloadUIFixtureSource: KindleOfflineBookSource {
    let offlineSourceBook = KindleBook(id: "offline-ui-fixture", title: "离线下载交互测试（本地测试书）", author: "Test",
        readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "", lastSyncedAt: Date())
    private lazy var image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 36)).pngData { context in
        UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 36))
    }
    private func position(_ ordinal: Int) -> KindleOfflineSourcePosition {
        .init(start: ordinal * 10, end: ordinal * 10 + 9, minimum: 0, maximum: 2399,
            layoutID: "fixture", fingerprint: "fixture-\(ordinal)")
    }
    func beginOfflineBookCapture(restoring interruptedPosition: KindleOfflineSourcePosition?) async throws -> KindleOfflineSourcePosition {
        try await Task.sleep(for: .milliseconds(800))
        return interruptedPosition ?? position(100)
    }
    func captureOfflineBookPage(after previous: KindleOfflineSourcePosition?) async throws -> KindleOfflineCapturedPage {
        try await Task.sleep(for: .milliseconds(250))
        return KindleOfflineCapturedPage(position: position(previous.map { ($0.end + 1) / 10 } ?? 0),
            document: ReadingDocument(title: offlineSourceBook.title, sourceKind: .kindle, language: "en-US",
                paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: image)]),
            requiresOCR: true, sourceWordCount: 0)
    }
    func endOfflineBookCapture() async -> Bool {
        try? await Task.sleep(for: .milliseconds(800))
        return true
    }
}
#endif
