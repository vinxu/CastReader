#if DEBUG
import SwiftUI
import WebKit
import PDFKit
import ZIPFoundation

/// Real file/DOM/vision renderers with repeatable, content-derived speech.
/// Only network synthesis and the remote HTML response are substituted.
enum ReadingResumeScenario {
    @MainActor private static var resetDirectories: Set<String> = []
    @MainActor static func resetOnce(_ directory: URL) {
        guard ProcessInfo.processInfo.arguments.contains("-CastReaderResetResumeScenario"),
              resetDirectories.insert(directory.path).inserted else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    static let marker = "CheckpointDestination"
    static var kind: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-CastReaderResumeScenario"), args.indices.contains(i + 1) else { return "epub" }
        return args[i + 1]
    }
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-CastReaderResumeScenario") }
    static var usesLiveSpeech: Bool { ProcessInfo.processInfo.arguments.contains("-CastReaderResumeLiveSpeech") }
    static var longParagraph: String {
        ((0..<800).map { $0 == 600 ? marker : "context\($0)" }).joined(separator: " ") + "."
    }
    static var bodyParagraphs: [String] {
        (0..<600).map { index in
            if index == 450 {
                return ["epub-long", "text-long", "docx-long", "web-long", "youtube-long"].contains(kind)
                    ? longParagraph
                    : "\(marker) this is the remembered location in section four hundred fifty with enough words to pause and resume the narration precisely."
            }
            return "Section \(index). The reader should remember the actual listening position and keep every section in its original order."
        }
    }
    static var webHTML: String {
        if kind == "web-layout" {
            return "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:28px;font:22px Georgia}input,button{font-size:20px}p{line-height:1.7}</style></head><body><input aria-label='Search this book' placeholder='Search this book'><button onclick='document.querySelector(\"input\").blur()'>Close search</button><div class='wr_readerContent'><p>Reader height acceptance. Opening and dismissing search must retain the native playback controls at the bottom of the screen.</p><p>Pagination must remain stable when a temporary keyboard appears.</p></div></body></html>"
        }
        return "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:24px;font:22px/1.8 Georgia}p{margin:24px 0}</style></head><body><article><h1>Long reading acceptance</h1>" + bodyParagraphs.map { "<p>\($0)</p>" }.joined() + "</article></body></html>"
    }
    static func archive(_ entries: [(String, String)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, text) in entries {
            let bytes = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, count in
                bytes.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        return try archive.data ?? { throw CocoaError(.fileReadCorruptFile) }()
    }
    @MainActor static func build(directory: URL) async throws -> ReadingDocument {
        let paras = bodyParagraphs
        switch kind {
        case "document-images":
            guard let path = UserDefaults.standard.string(forKey: "CastReaderFixtureDocumentPath") else { throw CocoaError(.fileNoSuchFile) }
            let result = try await DocumentImportPipeline().importDocument(DocumentImportRequest(localURL: URL(fileURLWithPath: path)))
            return result.document
        case "epub", "epub-long":
            var entries: [(String, String)] = [
                ("mimetype", "application/epub+zip"),
                ("META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container' version='1.0'><rootfiles><rootfile full-path='OEBPS/content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>")]
            let manifest = (0..<120).map { "<item id='c\($0)' href='c\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
            let spine = (0..<120).map { "<itemref idref='c\($0)'/>" }.joined()
            entries.append(("OEBPS/content.opf", "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='id'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:identifier id='id'>resume-scenario</dc:identifier><dc:title>Long EPUB acceptance</dc:title><dc:language>en</dc:language></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"))
            for chapter in 0..<120 {
                let text = paras[(chapter * 5)..<(chapter * 5 + 5)].map { "<p>\($0)</p>" }.joined()
                entries.append(("OEBPS/c\(chapter).xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'><body><h1>Chapter \(chapter)</h1>\(text)</body></html>"))
            }
            guard let doc = DocumentBuilder.fromEPUB(data: try archive(entries), title: "Long EPUB") else { throw CocoaError(.fileReadCorruptFile) }
            return doc
        case "text", "text-long":
            return DocumentBuilder.fromPlainText(paras.joined(separator: "\n\n"), title: "Long text", language: "en")
        case "markdown":
            return DocumentBuilder.fromMarkdown(paras.enumerated().map { "## Section \($0.offset)\n\n\($0.element)" }.joined(separator: "\n\n"), title: "Long Markdown", sourceURL: nil, language: "en")
        case "docx", "docx-long":
            let xml = "<?xml version='1.0' encoding='UTF-8'?><w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>" + paras.map { "<w:p><w:r><w:t xml:space='preserve'>\($0)</w:t></w:r></w:p>" }.joined() + "</w:body></w:document>"
            let bytes = try archive([
                ("[Content_Types].xml", "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='xml' ContentType='application/xml'/><Override PartName='/word/document.xml' ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'/></Types>"),
                ("_rels/.rels", "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='word/document.xml'/></Relationships>"),
                ("word/document.xml", xml)])
            return ReadingDocument(title: "Long Word document", sourceKind: .docx, language: "en", paragraphs: [], fileData: bytes)
        case "web-layout":
            return ReadingDocument(id: "web-layout-scenario", title: "Web reader layout acceptance", sourceKind: .web, language: "en", paragraphs: [], sourceURL: "https://resume-scenario.invalid/layout")
        case "web", "web-long":
            return ReadingDocument(id: "long-web-scenario", title: "Long article", sourceKind: .web, language: "en", paragraphs: [], sourceURL: "https://resume-scenario.invalid/article")
        case "youtube", "youtube-long":
            let transcript = YouTubeTranscriptDocument(
                metadata: YouTubeVideoMetadata(videoId: "resumeQA001", title: "Long caption transcript",
                    channelName: "Resume acceptance", sourceURL: "https://www.youtube.com/watch?v=resumeQA001",
                    thumbnailURL: nil, durationMs: 10_800_000),
                track: YouTubeCaptionTrack(baseURL: "https://resume-scenario.invalid/captions", languageCode: "en"),
                cues: paras.enumerated().map { YouTubeTranscriptCue(text: $0.element, startMs: $0.offset * 18_000, durationMs: 17_000) })
            return YouTubeReadingDocumentBuilder.make(transcript: transcript, cacheHit: false)
        case "pdf", "pdf-ocr":
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            func drawPage(_ page: Int) {
                for line in 0..<12 {
                    let text = page == 90 && line == 8 ? "\(marker) this is the remembered sentence on page ninety." : "Page \(page), line \(line): repeated layout with unique content."
                    (text as NSString).draw(in: CGRect(x: 36, y: 40 + line * 54, width: 540, height: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
                }
            }
            let bytes = renderer.pdfData { context in
                for page in 0..<120 {
                    context.beginPage()
                    if kind == "pdf-ocr", page == 90 {
                        let format = UIGraphicsImageRendererFormat(); format.scale = 2
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 612, height: 792), format: format).image { ctx in
                            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
                            drawPage(page)
                        }
                        image.draw(in: CGRect(x: 0, y: 0, width: 612, height: 792))
                    } else {
                        drawPage(page)
                    }
                }
            }
            if kind == "pdf-ocr" {
                guard let doc = try await DocumentBuilder.fromPDFWithOCR(data: bytes, title: "120 page mixed PDF"),
                      doc.usesNativePDFRendering else { throw CocoaError(.fileReadCorruptFile) }
                return doc
            }
            let url = directory.appendingPathComponent("long.pdf")
            try bytes.write(to: url)
            guard let doc = DocumentBuilder.fromPDFNative(url: url, title: "120 page PDF") else { throw CocoaError(.fileReadCorruptFile) }
            return doc
        case "photo":
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 10000), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 10000))
                for line in 0..<100 {
                    let text = line == 75 ? "\(marker) remember this precise reading position" : "Section \(line) Keep the original location when reading again"
                    (text as NSString).draw(at: CGPoint(x: 35, y: 40 + line * 96), withAttributes: [.font: UIFont.systemFont(ofSize: 25), .foregroundColor: UIColor.black])
                }
            }
            return try await OCRService.shared.recognize(image: rendered, languages: ["en-US"], title: "Long OCR image", languageHint: "en")
        default: throw CocoaError(.featureUnsupported)
        }
    }
}

struct ReadingResumeScenarioSpeech: ParagraphSpeechGenerating {
    static let chunkSize = 40
    static func segments(paragraph: Int, text: String) -> [AudioSegment] {
        let ns = text as NSString
        let matches = (try? NSRegularExpression(pattern: #"\S+\s*"#).matches(in: text, range: NSRange(location: 0, length: ns.length))) ?? []
        let tokens = matches.map { ns.substring(with: $0.range) }
        let audio = ReadingResumeMVPFixtureSpeechAudio.bytes
        return stride(from: 0, to: tokens.count, by: chunkSize).enumerated().map { index, start in
            let words = Array(tokens[start..<min(tokens.count, start + chunkSize)])
            return AudioSegment(paragraphIndex: paragraph, segmentIndex: index, audioData: audio,
                timestamps: words.enumerated().map { TTSTimestamp(word: $0.element.trimmingCharacters(in: .whitespacesAndNewlines), startTime: Double($0.offset) * 0.25, endTime: Double($0.offset) * 0.25 + 0.22) },
                duration: 16, text: words.joined(), isWavFormat: true)
        }
    }
    func generateTTSForParagraph(paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void) async throws {
        for segment in Self.segments(paragraph: paragraphIndex, text: text) {
            try Task.checkCancellation()
            await onSegmentReady(segment)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
private enum ReadingResumeMVPFixtureSpeechAudio { static let bytes = ReadingResumeFixtureSpeech.wav() }

@MainActor
struct ReadingResumeScenarioFixtureView: View {
    @StateObject private var coordinator: PlayerCoordinator
    private let store: HistoryStore
    private let directory: URL
    @State private var error: String?
    @State private var probe = "visible=false"
    @State private var targetIndex = -1
    @State private var targetText = ""
    @State private var loading = false
    @State private var probeLayoutSize = CGSize.zero
    @State private var stableLayoutSamples = 0

    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResumeScenarioAcceptance", isDirectory: true)
            .appendingPathComponent(ReadingResumeScenario.kind, isDirectory: true)
        ReadingResumeScenario.resetOnce(root)
        let history = HistoryStore(directory: root)
        directory = root; store = history
        let speech: any ParagraphSpeechGenerating = ReadingResumeScenario.usesLiveSpeech
            ? TTSService.shared : ReadingResumeScenarioSpeech()
        _coordinator = StateObject(wrappedValue: PlayerCoordinator(historyStore: history, speechGenerator: speech))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Read target") { seekTarget() }.disabled(targetIndex < 0).accessibilityIdentifier("scenarioSeekTarget")
                Button("Reopen") { Task { await reopen() } }.accessibilityIdentifier("scenarioReopen")
                Button("Expand") { coordinator.expand() }.accessibilityIdentifier("scenarioExpand")
                Button("Follow off") { coordinator.session?.readVM.autoScrollEnabled = false }.accessibilityIdentifier("scenarioFollowOff")
                Button("Show marks") { showGeometryMarks() }.disabled(targetIndex < 0).accessibilityIdentifier("scenarioShowMarks")
            }.font(.caption)
            if let s = coordinator.session {
                ReadingResumeScenarioStatus(vm: s.readVM, explainVM: s.explainVM, target: targetIndex, probe: probe)
                ZStack(alignment: .bottom) {
                    if coordinator.showsMiniPlayer { MiniPlayerView(coordinator: coordinator) }
                    ReaderHostView(readVM: s.readVM, explainVM: s.explainVM, coordinator: coordinator, document: s.document)
                        .id(s.instanceID)
                        .offset(y: coordinator.isReaderPresented ? 0 : UIScreen.main.bounds.height)
                        .accessibilityHidden(!coordinator.isReaderPresented)
                }.clipped()
            } else if let error { Text(error).accessibilityIdentifier("scenarioError") }
            else { ProgressView() }
        }
        .task {
            AppSettings.shared.autoPlay = false
            AppSettings.shared.speed = 1
            if ReadingResumeScenario.usesLiveSpeech {
                _ = AppSettings.shared.setVoice("af_heart", for: "en")
            }
            if coordinator.session == nil { await reopen() }
            while !Task.isCancelled {
                refreshTarget()
                let measurement = await ReadingResumeViewportProbe.inspect(document: coordinator.session?.document, vm: coordinator.session?.readVM)
                let size = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first(where: { $0.isKeyWindow })?.bounds.size ?? .zero
                if size == probeLayoutSize { stableLayoutSamples += 1 }
                else { probeLayoutSize = size; stableLayoutSamples = 0 }
                probe = measurement + ";viewportWidth=\(Int(size.width));viewportHeight=\(Int(size.height));layoutStable=\(stableLayoutSamples >= 3)"
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    private func refreshTarget() {
        guard let s = coordinator.session else { return }
        let texts = s.document.sourceKind.isWebRendered ? s.readVM.stagedLiveWebParagraphTexts : s.document.paragraphs.map(\.text)
        if let index = texts.firstIndex(where: { $0.localizedCaseInsensitiveContains(ReadingResumeScenario.marker) }) {
            targetIndex = index; targetText = texts[index]
        }
    }
    private func seekTarget() {
        ReaderRunLog.write("SCENARIO seek requested kind=\(ReadingResumeScenario.kind) target=\(targetIndex) textChars=\(targetText.count)")
        guard let s = coordinator.session, targetIndex >= 0 else { return }
        if ReadingResumeScenario.usesLiveSpeech {
            s.readVM.discardReadingResumeForConfirmedNavigation()
            s.readVM.jump(to: targetIndex)
            return
        }
        let segments = ReadingResumeScenarioSpeech.segments(paragraph: targetIndex, text: targetText)
        guard let segment = segments.first(where: { $0.text.localizedCaseInsensitiveContains(ReadingResumeScenario.marker) }),
              let word = segment.timestamps.first(where: { $0.word.localizedCaseInsensitiveContains(ReadingResumeScenario.marker) }) else { return }
        // Simulate an explicit seek into a long paragraph through the same
        // public VM/AVPlayer path; no checkpoint is prewritten by the fixture.
        s.readVM.discardReadingResumeForConfirmedNavigation()
        s.readVM.startWithCachedSegments(segments, paragraphIndex: targetIndex, segmentID: segment.id,
                                        progress: word.startTime / segment.duration, isReplayEligible: false)
        ReaderRunLog.write("SCENARIO seek dispatched target=\(targetIndex) actual=\(s.readVM.currentParagraphIndex)")
    }
    private func showGeometryMarks() {
        guard let session = coordinator.session,
              let range = targetText.range(of: ReadingResumeScenario.marker) else { return }
        coordinator.mode = .explain
        let lower = targetText.distance(from: targetText.startIndex, to: range.lowerBound)
        let upper = targetText.distance(from: targetText.startIndex, to: range.upperBound)
        // Wait for the production mode transition, then exercise the actual
        // native/DOM mark renderers without another paid explanation request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            session.explainVM.activeMarks = [ResolvedMark(id: UUID(), paragraphIndex: targetIndex,
                charRange: lower..<upper, action: "underline", n: nil, seed: 42)]
            session.explainVM.scrollTarget = targetIndex
        }
    }
    private func reopen() async {
        guard !loading else { return }; loading = true
        defer { loading = false }
        coordinator.close()
        targetIndex = -1
        do {
            if let record = store.records.first, let doc = try await store.reopen(record) { coordinator.open(doc) }
            else { coordinator.open(try await ReadingResumeScenario.build(directory: directory)) }
            refreshTarget()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ReadingResumeScenarioStatus: View {
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    @ObservedObject private var audio = AudioPlayerService.shared
    let target: Int
    let probe: String
    var body: some View {
        Text(verbatim: "target=\(target);paragraph=\(vm.currentParagraphIndex);segment=\(audio.currentSegment?.segmentIndex ?? -1);time=\(String(format: "%.2f", audio.currentTime));playing=\(vm.isPlaying);first=\(vm.debugResumeFirstPlaybackSeconds.map { String(format: "%.3f", $0) } ?? "-1");marks=\(explainVM.activeMarks.count);markID=\(explainVM.activeMarks.last?.id.uuidString ?? "none");\(probe)")
            .font(.system(size: 9)).lineLimit(4).frame(height: 44).accessibilityIdentifier("scenarioStatus")
    }
}

@MainActor
enum ReadingResumeViewportProbe {
    static func inspect(document: ReadingDocument?, vm: ReadAloudViewModel?) async -> String {
        guard let document else { return "visible=false;surface=none" }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter { !$0.isHidden }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = windows.flatMap(descendants)
        let needle = ReadingResumeScenario.marker
        func visible(_ rect: CGRect, in view: UIView) -> Bool {
            guard let window = view.window, !rect.isNull else { return false }
            let global = view.convert(rect, to: window)
            var clip = window.bounds
            var parent: UIView? = view
            while let current = parent {
                if current.isHidden || current.alpha < 0.01 { return false }
                if current.clipsToBounds { clip = clip.intersection(current.convert(current.bounds, to: window)) }
                parent = current.superview
            }
            let intersection = clip.intersection(global)
            return !intersection.isNull && intersection.width >= min(5, global.width) && intersection.height >= global.height * 0.85
        }
        if document.sourceKind == .pdf, let pdf = views.compactMap({ $0 as? PDFView }).first,
           let paragraph = document.paragraphs.first(where: { $0.text.localizedCaseInsensitiveContains(needle) }),
           let pageIndex = paragraph.pdfPageIndex, let page = pdf.document?.page(at: pageIndex) {
            if let scroll = descendants(pdf).compactMap({ $0 as? UIScrollView }).first,
               scroll.isZooming || scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
                return "visible=false;surface=pdf;zoom=\(scroll.zoomScale / max(0.001, (pdf.superview as? PDFReaderContainerView)?.fitScale ?? 1));page=\(pageIndex)"
            }
            // A measurement must not rescan all 120 pages on every player tick.
            let rect: CGRect
            if paragraph.pdfRange == nil, let index = paragraph.words.firstIndex(where: { $0.text.localizedCaseInsensitiveContains(needle) }) {
                rect = pdf.convert(PDFOCRGeometry.pageRect(paragraph.words[index].bboxNorm, page: page), from: page)
            } else {
                let range = ((page.string ?? "") as NSString).range(of: needle, options: .caseInsensitive)
                rect = range.location == NSNotFound ? .null
                    : pdf.convert(page.selection(for: range)?.bounds(for: page) ?? .null, from: page)
            }
            let center = CGPoint(x: pdf.bounds.midX, y: pdf.bounds.midY)
            let centerPage = pdf.page(for: center, nearest: true)
            let centerY = centerPage.map { pdf.convert(center, to: $0).y } ?? -1
            let activePage = vm.flatMap { document.paragraphs.indices.contains($0.currentParagraphIndex) ? document.paragraphs[$0.currentParagraphIndex].pdfPageIndex : nil }.flatMap { pdf.document?.page(at: $0) }
            let active = activePage.flatMap { page in page.annotations.last.map { visible(pdf.convert($0.bounds, from: page), in: pdf) } } ?? false
            return "visible=\(visible(rect, in: pdf));activeVisible=\(active);surface=pdf;centerPage=\(centerPage.flatMap { pdf.document?.index(for: $0) } ?? -1);centerY=\(centerY);zoom=\(pdf.scaleFactor / max(0.001, (pdf.superview as? PDFReaderContainerView)?.fitScale ?? 1));page=\(pdf.currentPage.flatMap { pdf.document?.index(for: $0) } ?? -1)"
        }
        if document.sourceKind == .photo,
           let paragraph = document.paragraphs.first(where: { $0.text.localizedCaseInsensitiveContains(needle) }),
           let index = paragraph.words.firstIndex(where: { $0.text.localizedCaseInsensitiveContains(needle) }),
           let scroll = views.compactMap({ $0 as? UIScrollView }).first(where: { $0.accessibilityIdentifier == "photoReaderCanvas" }),
           let host = scroll.subviews.first {
            let rects = PhotoAnchorResolver(document: document, fitted: host.bounds).rectsForWord(paragraphIndex: paragraph.id, wordIndex: index)
            let activeRects = PhotoAnchorResolver(document: document, fitted: host.bounds).rectsForWord(paragraphIndex: vm?.currentParagraphIndex ?? -1, wordIndex: vm?.photoHighlightWordIndex ?? -1)
            return "visible=\(rects.contains { visible($0, in: host) });activeVisible=\(activeRects.contains { visible($0, in: host) });surface=photo;zoom=\(scroll.zoomScale)"
        }
        if document.sourceKind.isWebRendered, let web = views.compactMap({ $0 as? WKWebView }).first {
            let saved = vm?.initialResumeViewportRange
            let script = """
            (()=>{
              const visible=r=>r.width>0&&r.top>=0&&r.bottom<=innerHeight&&r.right>0&&r.left<innerWidth;
              let activeVisible=[...document.querySelectorAll('.cr-hl-ov')].some(e=>visible(e.getBoundingClientRect()));
              const e=document.querySelector('[data-cr-para="\(vm?.currentParagraphIndex ?? -1)"]');
              const a=\(saved?.location ?? -1), b=\(saved.map { NSMaxRange($0) } ?? -1);
              if(e&&a>=0&&b>a){
                const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);let n,p=0,s=null,z=null;
                while(n=walker.nextNode()){const end=p+n.length;if(a>=p&&a<end)s=[n,a-p];if(b>p&&b<=end)z=[n,b-p];p=end;}
                if(s&&z){const r=document.createRange();r.setStart(...s);r.setEnd(...z);activeVisible=visible(r.getBoundingClientRect());}
              }
              const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;
              while(n=w.nextNode()){
                if(n.parentElement.closest('script,style'))continue;
                const i=n.textContent.toLowerCase().indexOf('checkpointdestination');if(i<0)continue;
                const r=document.createRange();r.setStart(n,i);r.setEnd(n,i+21);const rect=r.getBoundingClientRect();
                return {activeVisible,visible:visible(rect),top:rect.top,height:innerHeight};
              }
              return {activeVisible,visible:false};
            })()
            """
            if let value = try? await web.evaluateJavaScript(script) as? [String: Any] {
                return "visible=\(value["visible"] as? Bool ?? false);activeVisible=\(value["activeVisible"] as? Bool ?? false);surface=web;y=\(value["top"] ?? -1)"
            }
        }
        let textViews = views.compactMap { $0 as? ReaderUITextView }
        let active = textViews.contains { text in
            guard let range = text.viewportFocusRange else { return false }
            return text.rects(forCharRange: range).contains { visible($0, in: text) }
        }
        for text in textViews {
            let range = (text.text as NSString? ?? "").range(of: needle, options: .caseInsensitive)
            if range.location != NSNotFound {
                return "visible=\(text.rects(forCharRange: range).contains { visible($0, in: text) });activeVisible=\(active);surface=text"
            }
        }
        return "visible=false;activeVisible=\(active);surface=unresolved"
    }
}
#endif
