import SwiftUI
import UniformTypeIdentifiers

/// A drop is staged in its receiving window and requires an explicit choice of
/// mode. Parsing uses the same local pipeline as Files; cancelling never alters
/// the active reader. Only our temporary copy is deleted during cleanup.
@MainActor
final class ReaderDropImportModel: ObservableObject {
    enum Payload {
        case file(URL), text(String), link(URL)
    }
    static func isYouTube(_ payload: Payload?) -> Bool {
        guard case .link(let url) = payload else { return false }
        return YouTubeURLParser.parse(url.absoluteString) != nil
    }
    struct Review: Identifiable {
        let id = UUID()
        var title: String
        var payload: Payload?
        var error: String?
    }
    @Published var review: Review?
    @Published var busy = false
    @Published var queued: [QueueItem] = []
    struct QueueItem: Identifiable {
        let id = UUID()
        let loader: ReaderDropImportModel
        var status = AppLocalized("等待导入")
        var documentID: String?
        var webLink: URL?
    }
    private let historyStore: HistoryStore
    init(historyStore: HistoryStore? = nil) { self.historyStore = historyStore ?? .shared }
    private var generation = UUID()
    private var progress: Progress?
    private var parseTask: Task<Void, Never>?
    private var stagedFile: URL?
    private var boundary: AccountContentBoundaryToken?
    nonisolated private static let maximumBytes: Int64 = 50 * 1_024 * 1_024
    static let types: [UTType] = [.fileURL, .url, .pdf, .image, .text,
        UTType("org.idpf.epub-container")!, UTType("org.openxmlformats.wordprocessingml.document")!]

    @discardableResult
    func receive(_ providers: [NSItemProvider]) -> Bool {
        guard review == nil, !providers.isEmpty else { return false }
        guard providers.count <= 8 else {
            review = Review(title: AppLocalized("导入内容"), error: AppLocalized("每次最多拖入 8 项内容。"))
            return true
        }
        guard let boundary = AccountContentIsolation.captureBoundaryToken() else { return false }
        self.boundary = boundary
        let token = UUID(); generation = token
        if providers.count > 1 {
            review = Review(title: AppLocalized("导入队列"))
            // Start every provider inside the drop callback. Files are staged
            // to disk; expensive parsing below is strictly sequential.
            queued = providers.map { provider in
                let loader = ReaderDropImportModel(historyStore: historyStore)
                loader.receive([provider])
                return QueueItem(loader: loader)
            }
            return true
        }
        let provider = providers[0]
        let suggestedName = provider.suggestedName
        review = Review(title: suggestedName ?? AppLocalized("导入内容"))
        busy = true
        // Begin loading while onDrop is still executing, as required by UIKit.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let completion: (URL?) -> Void = { [weak self] url in
                let result = Result { try Self.urlPayload(url, suggestedName: suggestedName) }
                Task { @MainActor in
                    if let self { self.finish(result, token: token) }
                    else if case .success(.file(let url)) = result { Self.removeCopy(url) }
                }
            }
            if provider.canLoadObject(ofClass: NSURL.self) {
                progress = provider.loadObject(ofClass: NSURL.self) { object, _ in completion(object as? URL) }
            } else {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.url.identifier
                progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    completion(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
        } else if let type = provider.registeredTypeIdentifiers.first(where: { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .pdf) ||
                id == "org.idpf.epub-container" || id == "org.openxmlformats.wordprocessingml.document"
        }) {
            progress = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
                let ext = UTType(type)?.preferredFilenameExtension ?? ""
                var name = suggestedName ?? "Import"
                if URL(fileURLWithPath: name).pathExtension.isEmpty { name += "." + ext }
                let result = Result { try Self.copyFile(url, suggestedName: name) }
                Task { @MainActor in
                    if let self { self.finish(result.map(Payload.file), token: token) }
                    else if case .success(let url) = result { Self.removeCopy(url) }
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            progress = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let result: Result<Payload, Error> = text.isEmpty || text.utf8.count > 2_000_000
                    ? .failure(DocumentImportError.emptyFile) : .success(.text(text))
                Task { @MainActor in self?.finish(result, token: token) }
            }
        } else {
            finish(.failure(DocumentImportError.unsupportedExtension("")), token: token)
        }
        return true
    }

    nonisolated private static func urlPayload(_ url: URL?, suggestedName: String?) throws -> Payload {
        guard let url else { throw DocumentImportError.invalidLocalURL }
        if url.isFileURL { return .file(try copyFile(url, suggestedName: suggestedName)) }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw DocumentImportError.invalidLocalURL }
        return .link(url)
    }

    nonisolated private static func copyFile(_ source: URL?, suggestedName: String?) throws -> URL {
        guard let source, source.isFileURL else { throw DocumentImportError.invalidLocalURL }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              Int64(size) <= maximumBytes else { throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge) }
        var name = URL(fileURLWithPath: suggestedName ?? source.lastPathComponent).lastPathComponent
        if URL(fileURLWithPath: name).pathExtension.isEmpty, !source.pathExtension.isEmpty { name += "." + source.pathExtension }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name.isEmpty ? source.lastPathComponent : name)
        do { try FileManager.default.copyItem(at: source, to: target); return target }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private func finish(_ result: Result<Payload, Error>, token: UUID) {
        guard generation == token, let boundary, AccountContentIsolation.isCurrent(boundary), review != nil else {
            if case .success(.file(let url)) = result { Self.removeCopy(url) }
            return
        }
        busy = false
        switch result {
        case .success(let payload):
            review?.payload = payload
            switch payload {
            case .file(let url): stagedFile = url; review?.title = url.lastPathComponent
            case .text(let text): review?.title = String(text.prefix(100))
            case .link(let url): review?.title = url.absoluteString
            }
        case .failure(let error):
            ReaderRunLog.write("DROP failure domain=\((error as NSError).domain) code=\((error as NSError).code)")
            review?.error = AppLocalized("无法导入此内容。请使用小于 50 MB 的支持文件或文本。")
        }
    }

    func importQueue() {
        guard !busy, !queued.isEmpty, let boundary,
              AccountContentIsolation.isCurrent(boundary) else { return }
        busy = true
        let token = generation
        parseTask = Task { [weak self] in
            guard let self else { return }
            for index in self.queued.indices {
                guard self.isCurrent(token, boundary: boundary) else { return }
                if self.queued[index].documentID != nil || self.queued[index].webLink != nil { continue }
                let loader = self.queued[index].loader
                self.queued[index].status = AppLocalized("正在导入…")
                while loader.busy, self.isCurrent(token, boundary: boundary) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard self.isCurrent(token, boundary: boundary) else { return }
                do {
                    guard let payload = loader.review?.payload else { throw DocumentImportError.fileReadFailed }
                    if case .link(let url) = payload, YouTubeURLParser.parse(url.absoluteString) != nil {
                        self.queued[index].webLink = url
                        self.queued[index].status = AppLocalized("等待打开读取字幕")
                    } else {
                        let document = try await Self.prepare(payload)
                        guard self.isCurrent(token, boundary: boundary) else { return }
                        let canonical = self.historyStore.canonicalDocument(document)
                        self.historyStore.record(canonical)
                        self.queued[index].documentID = canonical.id
                        self.queued[index].status = AppLocalized("已导入")
                    }
                } catch {
                    guard self.isCurrent(token, boundary: boundary) else { return }
                    self.queued[index].status = AppLocalized("导入失败，可重试")
                }
            }
            self.busy = false
        }
    }

    func openQueued(_ id: UUID, mode: ReaderMode, scene: ReaderSceneContext) {
        guard !busy, let item = queued.first(where: { $0.id == id }), let boundary,
              AccountContentIsolation.isCurrent(boundary) else { return }
        if let url = item.webLink {
            _ = scene.youtubeRoutes.open(url.absoluteString, entry: .share, autoplay: false)
            cancel(); return
        }
        guard let record = historyStore.records.first(where: { $0.id == item.documentID }) else { return }
        busy = true
        let token = generation
        parseTask = Task { [weak self, weak scene] in
            guard let self, let scene else { return }
            do {
                let document = try await self.historyStore.reopen(record)
                guard self.isCurrent(token, boundary: boundary), scene.window?.windowScene != nil else { return }
                guard let document else { throw DocumentImportError.emptyFile }
                scene.player.open(document, mode: mode, autoplay: false)
                self.cancel()
            } catch {
                guard self.isCurrent(token, boundary: boundary) else { return }
                self.busy = false
                self.review?.error = AppLocalized("内容暂时无法打开，请重试")
            }
        }
    }

    private static func prepare(_ payload: Payload) async throws -> ReadingDocument {
        let document: ReadingDocument?
        switch payload {
        case .text(let text): document = DocumentBuilder.fromPlainText(text, title: String(text.prefix(60)))
        case .link(let url): document = DocumentBuilder.fromWebURL(url.absoluteString)
        case .file(let url):
            if let format = SupportedDocumentFormat(fileExtension: url.pathExtension) {
                document = try await DocumentImportPipeline().importDocument(.init(localURL: url, expectedFormat: format)).document
            } else {
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { throw DocumentImportError.fileReadFailed }
                let capture = CaptureFlowViewModel()
                await capture.process(image: image)
                document = capture.document
            }
        }
        guard let document, !document.isEmpty || document.sourceKind.isWebRendered else { throw DocumentImportError.emptyFile }
        return document
    }

    func open(mode: ReaderMode, scene: ReaderSceneContext) {
        guard !busy, let payload = review?.payload, let boundary,
              AccountContentIsolation.isCurrent(boundary) else { return }
        busy = true
        let token = generation
        parseTask = Task { [weak self, weak scene] in
            guard let self, let scene else { return }
            do {
                if case .link(let url) = payload, YouTubeURLParser.parse(url.absoluteString) != nil {
                    guard self.isCurrent(token, boundary: boundary) else { return }
                    _ = scene.youtubeRoutes.open(url.absoluteString, entry: .share, autoplay: false)
                    self.cancel(); return
                }
                let document = try await Self.prepare(payload)
                guard self.isCurrent(token, boundary: boundary), scene.window?.windowScene != nil else { return }
                // Selecting a mode opens a paused reader. Play remains the same
                // explicit action used by the other import surfaces.
                scene.player.open(document, mode: mode, autoplay: false)
                self.cancel()
            } catch {
                guard self.isCurrent(token, boundary: boundary) else { return }
                self.busy = false
                self.review?.error = AppLocalized("内容暂时无法打开，请重试")
            }
        }
    }

    private func isCurrent(_ token: UUID, boundary: AccountContentBoundaryToken) -> Bool {
        generation == token && !Task.isCancelled && AccountContentIsolation.isCurrent(boundary)
    }
    func cancel() {
        generation = UUID()
        progress?.cancel(); progress = nil
        parseTask?.cancel(); parseTask = nil
        queued.forEach { $0.loader.cancel() }; queued = []
        review = nil; busy = false; boundary = nil
        if let stagedFile { Self.removeCopy(stagedFile) }
        stagedFile = nil
    }
    nonisolated private static func removeCopy(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent.hasPrefix("reader-drop-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

struct ReaderDropImport: ViewModifier {
    let scene: ReaderSceneContext
    @StateObject private var model = ReaderDropImportModel()
    @ObservedObject private var auth = AuthService.shared
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .onDrop(of: AdaptiveLayout.isPad ? ReaderDropImportModel.types : [], isTargeted: $targeted) { providers in
                guard scene.window?.rootViewController?.presentedViewController == nil,
                      !scene.voicePanel.isPresented else { return false }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-CastReaderDropQueueAcceptance") {
                    // The real drag supplies the first provider. These extra
                    // providers exercise the queue UI and mixed-result state.
                    let unsupported = NSItemProvider(item: Data([1, 2]) as NSData, typeIdentifier: "public.zip-archive")
                    return model.receive(providers + [unsupported, NSItemProvider(object: "Another public queue sample." as NSString)])
                }
                #endif
                return model.receive(providers)
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(AppTheme.primary, lineWidth: 4)
                        .padding(6).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .sheet(item: $model.review, onDismiss: model.cancel) { review in
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: "square.and.arrow.down").font(.largeTitle).foregroundStyle(AppTheme.primary)
                            Text(model.review?.title ?? review.title).font(.headline).textSelection(.enabled).multilineTextAlignment(.center)
                            if model.busy { ProgressView().accessibilityLabel(Text("正在导入…")) }
                            if let error = model.review?.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                            if !model.queued.isEmpty {
                                Text("逐项导入后保存在文库，选择一项打开。播放需手动开始。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if model.queued.contains(where: { ReaderDropImportModel.isYouTube($0.loader.review?.payload) }) {
                                    Text("YouTube 链接仅支持朗读，需单独打开读取字幕。关闭队列不会保存未打开的链接。")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                ForEach(model.queued) { item in
                                    ReaderDropQueueRow(item: item, busy: model.busy) { mode in
                                        model.openQueued(item.id, mode: mode, scene: scene)
                                    }
                                }
                                Button("导入全部") { model.importQueue() }
                                    .buttonStyle(.borderedProminent).disabled(model.busy)
                                    .accessibilityIdentifier("dropImportAll")
                            }
                            if model.review?.payload != nil {
                                Button("朗读") { model.open(mode: .read, scene: scene) }
                                    .buttonStyle(.borderedProminent).disabled(model.busy).accessibilityIdentifier("dropImportRead")
                                if !ReaderDropImportModel.isYouTube(model.review?.payload) {
                                    Button("解读") { model.open(mode: .explain, scene: scene) }
                                        .buttonStyle(.bordered).disabled(model.busy).accessibilityIdentifier("dropImportExplain")
                                }
                            }
                        }.padding(28).frame(maxWidth: 600).frame(maxWidth: .infinity)
                    }
                    .navigationTitle("导入内容").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: model.cancel) } }
                }.tint(AppTheme.primary).controlSize(.large).accessibilityIdentifier("dropImportReview")
            }
            .onChange(of: auth.accountBoundaryID) { _ in model.cancel() }
            .onDisappear { model.cancel() }
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-CastReaderDropAcceptance"), !scene.player.isReaderPresented {
                    Text("Drag sample text").padding(12).background(.yellow)
                        .accessibilityIdentifier("dropAcceptanceSource")
                        .onDrag { acceptanceProvider() }
                }
                #endif
            }
    }
    #if DEBUG
    private func acceptanceProvider() -> NSItemProvider {
        if ProcessInfo.processInfo.arguments.contains("-CastReaderDropPDF") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-drop-public-sample.pdf")
            let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { context in
                context.beginPage()
                ("A PDF dropped into CastReader.\nThis original page stays readable after rotation." as NSString)
                    .draw(in: CGRect(x: 40, y: 60, width: 520, height: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
            try? data.write(to: file, options: .atomic)
            let provider = NSItemProvider(contentsOf: file)!
            provider.suggestedName = file.lastPathComponent
            return provider
        }
        return NSItemProvider(object: "iPad drag import keeps this public sample in the receiving window." as NSString)
    }
    #endif

}

private struct ReaderDropQueueRow: View {
    let item: ReaderDropImportModel.QueueItem
    let busy: Bool
    let open: (ReaderMode) -> Void
    @ObservedObject private var loader: ReaderDropImportModel
    init(item: ReaderDropImportModel.QueueItem, busy: Bool, open: @escaping (ReaderMode) -> Void) {
        self.item = item; self.busy = busy; self.open = open; self.loader = item.loader
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loader.review?.title ?? AppLocalized("导入内容")).font(.headline).lineLimit(3)
            if loader.busy { ProgressView() }
            Text(loader.review?.error ?? item.status).font(.subheadline).foregroundStyle(.secondary)
            if item.documentID != nil || item.webLink != nil {
                HStack {
                    Button("朗读") { open(.read) }.buttonStyle(.borderedProminent).accessibilityIdentifier("dropQueuedRead")
                    if item.webLink == nil {
                        Button("解读") { open(.explain) }.buttonStyle(.bordered)
                    }
                }.disabled(busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
