import XCTest
import SwiftUI
import PDFKit
@testable import CastReader

@MainActor
final class ReaderViewportTests: XCTestCase {
    private var testWindow: UIWindow?
    private var previousWindow: UIWindow?
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    override func tearDown() async throws {
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        testWindow = nil
        previousWindow?.makeKeyAndVisible()
        try? FileManager.default.removeItem(at: directory)
    }

    private func show(_ controller: UIViewController) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        testWindow = window
        try await settle()
        controller.view.layoutIfNeeded()
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 450_000_000) }

    private func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants($0, as: type) }
    }

    func testStreamingSentencesKeepWholeParagraphAndFollowingRowInPlace() async throws {
        let sentences = [
            "大屏幕能够容纳舒适的文字行宽和清楚的操作区域。",
            "设备旋转时，文字会重新排版，但当前句子的含义没有改变。",
            "应用需要重新找到同一句话，把阅读位置、高亮和原文标注放回正确的地方。",
            "调整字号时也需要遵守同样的原则。"
        ]
        let text = sentences.joined()
        let next = "下面的内容在分句加载时不能上下跳动。"
        let document = ReadingDocument(title: "Streaming layout", sourceKind: .text, language: "zh",
            paragraphs: [ReadingParagraph(id: 0, text: text), ReadingParagraph(id: 1, text: next)])
        let vm = ReadAloudViewModel(document: document, historyStore: HistoryStore(directory: directory))
        defer { vm.stop() }
        vm.currentParagraphIndex = 0
        vm.autoScrollEnabled = false
        let host = UIHostingController(rootView: TextReaderView(document: document, readVM: vm,
            explainVM: ExplainViewModel(document: document), mode: .read, refocusToken: 0))
        try await show(host)
        let first = try XCTUnwrap(descendants(host.view, as: ReaderUITextView.self).first { $0.text == text })
        let following = try XCTUnwrap(descendants(host.view, as: ReaderUITextView.self).first { $0.text == next })
        let originalHeight = first.bounds.height
        let originalNextY = following.convert(following.bounds, to: host.view).minY
        var prefix = ""
        for sentence in sentences {
            let offset = prefix.utf16.count
            prefix += sentence
            vm.processedDisplayText = prefix
            vm.highlightRange = NSRange(location: offset, length: sentence.utf16.count)
            try await settle()
            XCTAssertEqual(first.text, text, "Pending sentences must stay visible")
            XCTAssertEqual(first.bounds.height, originalHeight, accuracy: 0.5)
            XCTAssertEqual(following.convert(following.bounds, to: host.view).minY, originalNextY, accuracy: 0.5)
            let range = try XCTUnwrap(vm.displayHighlightRange(for: 0))
            XCTAssertEqual((text as NSString).substring(with: range), sentence)
        }
        vm.currentParagraphIndex = 1
        vm.processedDisplayText = next
        try await settle()
        XCTAssertEqual(first.text, text)
        XCTAssertEqual(first.bounds.height, originalHeight, accuracy: 0.5)
    }

    func testNativeHighlightProjectionPreservesRepeatedWordsUnicodeAndNormalization() throws {
        let source = "Café 👩🏽‍💻 said: ‘read   it’.\nThen read it again. 中文继续。"
        let output = "Café 👩🏽‍💻 said: 'read it'.Then read it again.中文继续。"
        let projection = NativeReadingTextProjection(source: source, output: output)
        for word in ["Café", "again", "中文继续"] {
            let range = (output as NSString).range(of: word)
            let result = try XCTUnwrap(projection.sourceRange(for: range))
            XCTAssertEqual((source as NSString).substring(with: result), word)
        }
        let repeated = (output as NSString).range(of: "read", options: .backwards)
        XCTAssertEqual(try XCTUnwrap(projection.sourceRange(for: repeated)),
                       (source as NSString).range(of: "read", options: .backwards))
        let decomposed = "Cafe\u{301} then continue."
        let composed = "Café then continue."
        let accents = NativeReadingTextProjection(source: composed, output: decomposed)
        XCTAssertEqual(try XCTUnwrap(accents.sourceRange(for: (decomposed as NSString).range(of: "then"))),
                       (composed as NSString).range(of: "then"))
        XCTAssertNil(projection.sourceRange(for: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(projection.sourceRange(for: NSRange(location: 0, length: output.utf16.count + 1)))
        let mismatch = NativeReadingTextProjection(source: "A different paragraph.", output: "Unrelated text.")
        XCTAssertNil(mismatch.sourceRange(for: NSRange(location: 0, length: 9)))
    }

    func testBottomReservationIncludesCustomTabWithoutPlayerAndUsesUnionWithPlayer() {
        XCTAssertEqual(BottomOverlayMetrics.requiredInset(contentBottom: 800, playerTop: nil, tabBarTop: 746), 54)
        XCTAssertEqual(BottomOverlayMetrics.requiredInset(contentBottom: 800, playerTop: 662, tabBarTop: 746), 138)
        XCTAssertEqual(BottomOverlayMetrics.requiredInset(contentBottom: 800, playerTop: 662, tabBarTop: nil), 138)
        XCTAssertEqual(BottomOverlayMetrics.requiredInset(contentBottom: 800, playerTop: nil, tabBarTop: nil), 0)
        XCTAssertEqual(BottomOverlayMetrics.requiredInset(contentBottom: 720, playerTop: nil, tabBarTop: 800), 0)
    }

    func testEPUBParagraphTransitionDoesNotVisitTopBeforeWordFocus() async throws {
        try await verifyNativeTransition(source: .epub)
    }

    func testPlaybackFollowAnimatesOneMonotonicMovementAcrossWordTicks() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("System Reduce Motion disables scrolling animations") }
        let controller = UIViewController()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 390, height: 500))
        scroll.contentSize = CGSize(width: 390, height: 2000)
        scroll.contentInsetAdjustmentBehavior = .never
        controller.view.addSubview(scroll)
        try await show(controller)
        var offsets: [CGFloat] = []
        let observation = scroll.observe(\.contentOffset, options: [.new]) { scroll, _ in offsets.append(scroll.contentOffset.y) }
        defer { observation.invalidate() }
        let target = CGRect(x: 20, y: 500, width: 80, height: 20)
        ReaderViewportFollow.reveal(target, in: scroll, source: "animation-test")
        let immediate = scroll.contentOffset.y
        try await Task.sleep(nanoseconds: 60_000_000)
        let intermediate = scroll.contentOffset.y
        for _ in 0..<10 {
            ReaderViewportFollow.reveal(target, in: scroll, source: "animation-test")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await settle()
        let final = scroll.contentOffset.y
        XCTAssertEqual(immediate, 0, accuracy: 1, "Following should start an animation instead of snapping")
        XCTAssertGreaterThan(intermediate, 0)
        XCTAssertLessThan(intermediate, final - 1, "Observe a real intermediate frame")
        XCTAssertGreaterThan(offsets.count, 4)
        XCTAssertTrue(zip(offsets, offsets.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }, "Word ticks must not restart/reverse the animation: \(offsets)")
        XCTAssertTrue(scroll.bounds.insetBy(dx: 0, dy: scroll.bounds.height * 0.18).contains(target))
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        XCTAssertEqual((target.minY - visible.minY) / visible.height, 0.25, accuracy: 0.005,
                       "Narration must land 75% above the bottom, or 25% from the top")
        ReaderViewportFollow.reveal(target, in: scroll, source: "animation-test")
        try await settle()
        XCTAssertEqual(scroll.contentOffset.y, final, accuracy: 1, "The upper-quarter destination must not retrigger the lower-edge threshold")
    }

    func testNativeTextHostKeepsIntermediateAnimationFrames() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { throw XCTSkip("System Reduce Motion disables animations") }
        let paragraphs = (0..<45).map { ReadingParagraph(id: $0, text: "Paragraph \($0) contains enough words to wrap across two lines in the native reader.") }
        let doc = ReadingDocument(id: UUID().uuidString, title: "Animated text host", sourceKind: .epub,
                                  language: "en", paragraphs: paragraphs)
        let vm = ReadAloudViewModel(document: doc, historyStore: HistoryStore(directory: directory))
        defer { vm.stop() }
        vm.currentParagraphIndex = 0
        let host = UIHostingController(rootView: TextReaderView(document: doc, readVM: vm,
            explainVM: ExplainViewModel(document: doc), mode: .read, refocusToken: 0))
        try await show(host)
        let scroll = try XCTUnwrap(descendants(host.view, as: UIScrollView.self).first(where: { $0.isScrollEnabled }))
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        // A paragraph need not naturally start in the bottom 10% on every
        // iPad size/font. Arrange a real visible paragraph at that position
        // before testing playback follow; do not depend on line-height luck.
        let candidates = descendants(host.view, as: ReaderUITextView.self).compactMap { view -> (ReaderUITextView, CGFloat)? in
            guard let rect = view.rects(forCharRange: NSRange(location: 0, length: 9)).first else { return nil }
            let y = view.convert(rect, to: scroll).minY
            return y > visible.midY ? (view, y) : nil
        }
        let (target, targetY) = try XCTUnwrap(candidates.min {
            abs($0.1 - visible.maxY) < abs($1.1 - visible.maxY)
        })
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
            y: scroll.contentOffset.y + targetY - visible.minY - visible.height * 0.93), animated: false)
        try await settle()
        let arrangedRect = try XCTUnwrap(target.rects(forCharRange: NSRange(location: 0, length: 9)).first)
        let arrangedVisible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        let arrangedY = target.convert(arrangedRect, to: scroll).minY
        XCTAssertGreaterThan(arrangedY, arrangedVisible.minY + arrangedVisible.height * 0.90)
        XCTAssertLessThan(arrangedY, arrangedVisible.maxY - 15)
        let index = try XCTUnwrap(Int(target.text.split(separator: " ")[1]))
        let start = scroll.contentOffset.y
        var offsets: [CGFloat] = []
        let observation = scroll.observe(\.contentOffset, options: [.new]) { scroll, _ in offsets.append(scroll.contentOffset.y) }
        defer { observation.invalidate() }
        vm.currentParagraphIndex = index
        vm.highlightRange = nil
        try await Task.sleep(nanoseconds: 80_000_000)
        vm.highlightRange = NSRange(location: 0, length: 9)
        try await settle()
        let end = scroll.contentOffset.y
        XCTAssertGreaterThan(end, start + 50)
        XCTAssertGreaterThan(offsets.filter { $0 > start + 1 && $0 < end - 1 }.count, 3,
                             "Real SwiftUI text layout must preserve animation frames: \(offsets)")
        XCTAssertTrue(zip(offsets, offsets.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }, "Native layout must not reverse scrolling: \(offsets)")
    }

    func testReflowPDFParagraphTransitionDoesNotVisitTopBeforeWordFocus() async throws {
        try await verifyNativeTransition(source: .pdf)
    }

    func testDistantLazyParagraphMaterializesAtReadingBand() async throws {
        let paragraphs = (0..<90).map { ReadingParagraph(id: $0, text: "Distant paragraph \($0). " + String(repeating: "Text wrapping across several lines. ", count: 5)) }
        let doc = ReadingDocument(id: UUID().uuidString, title: "Lazy viewport", sourceKind: .epub,
                                  language: "en", paragraphs: paragraphs)
        let vm = ReadAloudViewModel(document: doc, historyStore: HistoryStore(directory: directory))
        let explain = ExplainViewModel(document: doc)
        defer { vm.stop() }
        vm.currentParagraphIndex = 0
        let host = UIHostingController(rootView: TextReaderView(document: doc, readVM: vm, explainVM: explain,
                                                              mode: .read, refocusToken: 0))
        try await show(host)
        let scroll = try XCTUnwrap(descendants(host.view, as: UIScrollView.self).first(where: { $0.isScrollEnabled }))
        vm.currentParagraphIndex = 70
        vm.highlightRange = nil
        try await settle()
        try await settle()
        let target = try XCTUnwrap(descendants(host.view, as: ReaderUITextView.self).first(where: { $0.text.hasPrefix("Distant paragraph 70.") }))
        let rect = target.convert(try XCTUnwrap(target.rects(forCharRange: NSRange(location: 0, length: 7)).first), to: scroll)
        XCTAssertTrue(scroll.bounds.insetBy(dx: 0, dy: scroll.bounds.height * 0.18).contains(rect), "Distant start must be readable before audio starts: \(rect), \(scroll.bounds)")
        let beforeWord = scroll.contentOffset.y
        vm.highlightRange = NSRange(location: 0, length: 7)
        try await settle()
        XCTAssertEqual(scroll.contentOffset.y, beforeWord, accuracy: 2)
    }

    func testLongParagraphFollowsWordAfterFontReflow() async throws {
        let text = (0..<80).map { "Line \($0) has a distinct destination and several spoken words." }.joined(separator: "\n")
        let doc = ReadingDocument(id: UUID().uuidString, title: "Long paragraph", sourceKind: .epub,
                                  language: "en", paragraphs: [ReadingParagraph(id: 0, text: text)])
        let vm = ReadAloudViewModel(document: doc, historyStore: HistoryStore(directory: directory))
        let explain = ExplainViewModel(document: doc)
        let originalSize = ReaderAppearanceSettings.shared.textSize
        defer { vm.stop(); ReaderAppearanceSettings.shared.textSize = originalSize }
        vm.currentParagraphIndex = 0
        let host = UIHostingController(rootView: TextReaderView(document: doc, readVM: vm, explainVM: explain,
                                                              mode: .read, refocusToken: 0))
        try await show(host)
        let scroll = try XCTUnwrap(descendants(host.view, as: UIScrollView.self).first(where: { $0.isScrollEnabled }))
        let range = (text as NSString).range(of: "Line 60")
        vm.highlightRange = range
        try await settle()
        func assertVisible() throws {
            let target = try XCTUnwrap(descendants(host.view, as: ReaderUITextView.self).first)
            let rect = target.convert(try XCTUnwrap(target.rects(forCharRange: range).first), to: scroll)
            XCTAssertTrue(scroll.bounds.insetBy(dx: 0, dy: scroll.bounds.height * 0.18).contains(rect), "Active word must remain in the reading band: \(rect), \(scroll.bounds)")
        }
        try assertVisible()
        ReaderAppearanceSettings.shared.textSize = originalSize + 4
        try await settle()
        try await settle()
        try assertVisible()
        let stable = scroll.contentOffset.y
        vm.highlightRange = NSRange(location: range.location + 8, length: 3)
        try await settle()
        XCTAssertEqual(scroll.contentOffset.y, stable, accuracy: 2, "Next word on the same line must not reset the paragraph position")
    }

    func testRestoredEPUBParagraphWithUnequalRowHeightsSettlesAndKeepsFollowingWords() async throws {
        let lengths = [1, 7, 9, 4, 19, 10, 21, 10, 23, 23, 1, 5, 2]
        let paragraphs = lengths.enumerated().map { index, count in
            ReadingParagraph(id: index, text: "Avsnitt \(index). " +
                String(repeating: "Nye ord fører leseren videre. ", count: count))
        }
        let document = ReadingDocument(id: UUID().uuidString, title: "Restored EPUB layout",
            sourceKind: .epub, language: "nb", paragraphs: paragraphs)
        let vm = ReadAloudViewModel(document: document, historyStore: HistoryStore(directory: directory))
        defer { vm.stop() }
        vm.currentParagraphIndex = 7
        let host = UIHostingController(rootView: TextReaderView(document: document, readVM: vm,
            explainVM: ExplainViewModel(document: document), mode: .read, refocusToken: 0))
        try await show(host)
        try await settle()
        let scroll = try XCTUnwrap(descendants(host.view, as: UIScrollView.self).first { $0.isScrollEnabled })
        for index in [7, 8, 9] {
            vm.currentParagraphIndex = index
            vm.processedDisplayText = paragraphs[index].text
            vm.highlightRange = NSRange(location: 0, length: 7)
            try await settle()
            let view = try XCTUnwrap(descendants(host.view, as: ReaderUITextView.self).first {
                $0.text.hasPrefix("Avsnitt \(index).")
            })
            let rect = view.convert(try XCTUnwrap(view.rects(forCharRange: NSRange(location: 0, length: 7)).first), to: scroll)
            XCTAssertTrue(scroll.bounds.insetBy(dx: 0, dy: scroll.bounds.height * 0.18).contains(rect))
            let height = view.bounds.height
            let offset = scroll.contentOffset.y
            for _ in 0..<3 { view.setNeedsLayout(); view.layoutIfNeeded() }
            try await settle()
            XCTAssertEqual(view.bounds.height, height, accuracy: 0.5)
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 2)
        }
    }

    private func verifyNativeTransition(source: ReadingSourceKind) async throws {
        let paragraphs = (0..<45).map { ReadingParagraph(id: $0, text: "Paragraph \($0) contains enough words to wrap across two lines in the native reader.") }
        let doc = ReadingDocument(id: UUID().uuidString, title: "Viewport regression", sourceKind: source,
                                  language: "en", paragraphs: paragraphs)
        let vm = ReadAloudViewModel(document: doc, historyStore: HistoryStore(directory: directory))
        let explain = ExplainViewModel(document: doc)
        defer { vm.stop() }
        vm.currentParagraphIndex = 0
        vm.highlightRange = NSRange(location: 0, length: 9)
        let host = UIHostingController(rootView: TextReaderView(document: doc, readVM: vm, explainVM: explain,
                                                              mode: .read, refocusToken: 0))
        try await show(host)
        let scroll = try XCTUnwrap(descendants(host.view, as: UIScrollView.self).first(where: { $0.isScrollEnabled }))
        // Pick a paragraph in the actual reading band: paragraph 2 is above
        // that band on an iPad, where more paragraphs fit on screen.
        let comfortable = scroll.bounds.insetBy(dx: 0, dy: scroll.bounds.height * 0.18)
        let target = try XCTUnwrap(descendants(host.view, as: ReaderUITextView.self).first { view in
            guard view.text.hasPrefix("Paragraph "), let rect = view.rects(forCharRange: NSRange(location: 0, length: 9)).first else { return false }
            return comfortable.contains(view.convert(rect, to: scroll))
        })
        let targetIndex = try XCTUnwrap(Int(target.text.split(separator: " ")[1]))
        let targetRect = target.convert(try XCTUnwrap(target.rects(forCharRange: NSRange(location: 0, length: 9)).first), to: scroll)
        XCTAssertTrue(scroll.bounds.insetBy(dx: 0, dy: scroll.bounds.height * 0.18).contains(targetRect), "Fixture target must already be comfortable")
        let initialOffset = scroll.contentOffset.y
        var offsets: [CGFloat] = []
        let observation = scroll.observe(\.contentOffset, options: [.new]) { scroll, _ in offsets.append(scroll.contentOffset.y) }
        defer { observation.invalidate() }

        // The real prefetch promotion clears the previous word before the new
        // AVPlayerItem reports its first timestamp. Exercise both render passes.
        vm.currentParagraphIndex = targetIndex
        vm.processedDisplayText = paragraphs[targetIndex].text
        vm.highlightRange = nil
        try await settle()
        vm.highlightRange = NSRange(location: 0, length: 9)
        try await settle()
        for location in [10, 12, 21] {
            vm.highlightRange = NSRange(location: location, length: 3)
            try await settle()
        }
        XCTAssertLessThanOrEqual(offsets.map { abs($0 - initialOffset) }.max() ?? 0, 2,
                                 "A visible paragraph must not jump to the top then back: \(offsets)")
    }

    func testNativePDFSentenceAndWordShareOneViewportTarget() async throws {
        let lines = (0..<22).map { "Sentence \($0) contains words for viewport tracking." }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 420, height: 1000)).pdfData { context in
            context.beginPage()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 24, y: 50 + index * 38), withAttributes: [.font: UIFont.systemFont(ofSize: 13)])
            }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let pageText = try XCTUnwrap(page.string) as NSString
        let paragraphs = lines.enumerated().map { index, line in
            var p = ReadingParagraph(id: index, text: line)
            p.pdfPageIndex = 0; p.pdfRange = pageText.range(of: line)
            return p
        }
        let doc = ReadingDocument(id: UUID().uuidString, title: "PDF viewport", sourceKind: .pdf,
                                  language: "en", paragraphs: paragraphs, fileData: data)
        let vm = ReadAloudViewModel(document: doc, historyStore: HistoryStore(directory: directory))
        let explain = ExplainViewModel(document: doc)
        defer { vm.stop() }
        let controller = UIViewController()
        let pdfView = PDFView(frame: CGRect(x: 0, y: 90, width: 390, height: 430))
        pdfView.displayMode = .singlePageContinuous; pdfView.displayDirection = .vertical
        pdfView.document = pdf; pdfView.autoScales = false; pdfView.scaleFactor = 1
        controller.view.addSubview(pdfView)
        let coordinator = PDFReaderView.Coordinator()
        coordinator.pdfView = pdfView
        coordinator.setMode(.read)
        coordinator.attach(readVM: vm, explainVM: explain, doc: doc)
        try await show(controller)
        let scroll = try XCTUnwrap(descendants(pdfView, as: UIScrollView.self).first(where: { $0.isScrollEnabled }))
        let initialOffset = scroll.contentOffset.y
        var offsets: [CGFloat] = []
        let observation = scroll.observe(\.contentOffset, options: [.new]) { scroll, _ in offsets.append(scroll.contentOffset.y) }
        defer { observation.invalidate() }
        vm.currentParagraphIndex = 4
        try await settle()
        vm.pdfHighlight = PDFWordHighlight(paragraphIndex: 4, words: lines[4].components(separatedBy: " "), wordIndex: 0)
        try await settle()
        XCTAssertLessThanOrEqual(offsets.map { abs($0 - initialOffset) }.max() ?? 0, 2,
                                 "The sentence is visible; neither sentence nor word should scroll: \(offsets)")
        XCTAssertFalse(page.annotations.isEmpty, "Following must retain highlight annotations")

        vm.pdfHighlight = nil
        vm.currentParagraphIndex = 18
        try await settle()
        let range = try XCTUnwrap(paragraphs[18].pdfRange)
        let firstWord = try XCTUnwrap(page.selection(for: NSRange(location: range.location, length: 8)))
        let wordRect = pdfView.convert(firstWord.bounds(for: page), from: page)
        XCTAssertTrue(pdfView.bounds.insetBy(dx: 0, dy: pdfView.bounds.height * 0.18).contains(wordRect), "Offscreen PDF sentence must go directly into the reading band: \(wordRect)")
        let beforeWord = scroll.contentOffset.y
        vm.pdfHighlight = PDFWordHighlight(paragraphIndex: 18, words: lines[18].components(separatedBy: " "), wordIndex: 0)
        try await settle()
        XCTAssertEqual(scroll.contentOffset.y, beforeWord, accuracy: 2, "First word must not cause a second correction")
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertGreaterThan(offsets.filter { $0 > initialOffset + 1 && $0 < beforeWord - 1 }.count, 3,
                                 "PDFKit must preserve smooth intermediate frames: \(offsets)")
        }
        _ = coordinator
    }

    func testFinnishPDFWordHighlightRendersOverSentence() async throws {
        guard let path = ProcessInfo.processInfo.environment["CASTREADER_PDF_WORD_FIXTURE"] else {
            throw XCTSkip("Opt-in public Finnish PDF fixture required")
        }
        let document = try XCTUnwrap(DocumentBuilder.fromPDFNative(url: URL(fileURLWithPath: path)))
        let paragraph = try XCTUnwrap(document.paragraphs.first { $0.text.contains("Konrad Gesner") })
        let vm = ReadAloudViewModel(document: document, historyStore: HistoryStore(directory: directory))
        defer { vm.stop() }
        let controller = UIViewController()
        let pdfView = PDFView(frame: CGRect(x: 0, y: 90, width: 390, height: 600))
        pdfView.document = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.fileData)))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        controller.view.addSubview(pdfView)
        let coordinator = PDFReaderView.Coordinator()
        coordinator.pdfView = pdfView
        coordinator.setMode(.read)
        coordinator.attach(readVM: vm, explainVM: ExplainViewModel(document: document), doc: document)
        try await show(controller)
        vm.currentParagraphIndex = paragraph.id
        try await settle()
        let words = ["Konrad", "Gesner", "John", "Ray", "ja", "Joseph", "Pitton", "de", "Tournefort",
                     "olivat", "ensimmäisiä", "jotka", "pääosin", "kehittivät", "kasvien", "mutta", "myös", "eläinten", "luokittelua."]
        vm.pdfHighlight = PDFWordHighlight(paragraphIndex: paragraph.id, words: words, wordIndex: 16)
        try await settle()
        try await settle()
        let page = try XCTUnwrap(pdfView.document?.page(at: XCTUnwrap(paragraph.pdfPageIndex)))
        let word = try XCTUnwrap(page.annotations.first { abs($0.color.cgColor.alpha - 0.5) < 0.01 },
                                "A distinct word annotation must survive beside the sentence highlight")
        XCTAssertGreaterThan(word.bounds.width, 1)
        XCTAssertLessThan(word.bounds.width, page.bounds(for: .mediaBox).width / 3)
        XCTAssertTrue(page.annotations.contains { abs($0.color.cgColor.alpha - 0.33) < 0.01 })
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "fi-pdf-word-overlay"; attachment.lifetime = .keepAlways; add(attachment)
        _ = coordinator
    }

    func testCzechPDFUsesFontLineHeightForOversizedSelections() throws {
        guard let path = ProcessInfo.processInfo.environment["CASTREADER_PDF_WORD_FIXTURE"] else {
            throw XCTSkip("Opt-in public PDF fixtures required")
        }
        let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("cs.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 8))
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: "Dávno")
        XCTAssertNotEqual(range.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: range))
        let original = selection.bounds(for: page)
        XCTAssertGreaterThan(original.height, 40, "Retain the publisher fixture that exposed the oversized box")
        let corrected = PDFSelectionGeometry.bounds(of: selection, on: page)
        XCTAssertLessThan(corrected.height, 20)
        XCTAssertGreaterThan(corrected.width, 10)
        XCTAssertTrue(original.contains(corrected))
        XCTAssertTrue(corrected.contains(page.characterBounds(at: range.location)))

        // The original report also crosses synthetic line breaks. Individual
        // character indexes drift there, so a single-word fixture is insufficient.
        let nextPage = try XCTUnwrap(document.page(at: 9))
        let nextText = try XCTUnwrap(nextPage.string) as NSString
        let start = nextText.range(of: "Babička měla").location
        XCTAssertNotEqual(start, NSNotFound)
        let multiLine = try XCTUnwrap(nextPage.selection(for: NSRange(location: start, length: 240)))
        let lines = multiLine.selectionsByLine()
        XCTAssertGreaterThan(lines.count, 2)
        let rectangles = lines.map { PDFSelectionGeometry.bounds(of: $0, on: nextPage) }
        for (line, rect) in zip(lines, rectangles) {
            XCTAssertLessThan(rect.height, 16, "A sentence line must not paint neighboring rows")
            XCTAssertEqual(rect.midY, line.bounds(for: nextPage).midY, accuracy: 0.1)
        }
        for (first, second) in zip(rectangles, rectangles.dropFirst()) {
            XCTAssertFalse(first.intersects(second), "Separate text rows must not overlap")
        }

        let finnish = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        let normalPage = try XCTUnwrap(finnish.page(at: 0))
        let normalText = try XCTUnwrap(normalPage.string) as NSString
        let normal = try XCTUnwrap(normalPage.selection(for: normalText.range(of: "Biologia")))
        XCTAssertEqual(PDFSelectionGeometry.bounds(of: normal, on: normalPage), normal.bounds(for: normalPage),
                       "Normal font selection geometry must stay unchanged")
    }

    func testPDFNumeralsFollowSourceDirectionForNativeAndOCRText() async throws {
        let text = "Source words for a numbered explanation"
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 420, height: 300)).pdfData { context in
            context.beginPage()
            (text as NSString).draw(at: CGPoint(x: 80, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 13)])
        }
        for language in ["en", "ar", "he"] {
            for ocr in [false, true] {
                let pdf = try XCTUnwrap(PDFDocument(data: data))
                let page = try XCTUnwrap(pdf.page(at: 0))
                var paragraph = ReadingParagraph(id: 0, text: text)
                paragraph.pdfPageIndex = 0
                if ocr {
                    paragraph.words = [OCRWord(id: 0, text: text, bboxNorm: CGRect(x: 0.2, y: 0.5, width: 0.5, height: 0.05))]
                } else {
                    paragraph.pdfRange = (try XCTUnwrap(page.string) as NSString).range(of: text)
                }
                let document = ReadingDocument(title: "Direction", sourceKind: .pdf, language: language,
                                               paragraphs: [paragraph], fileData: data)
                let read = ReadAloudViewModel(document: document, historyStore: HistoryStore(directory: directory))
                read.autoScrollEnabled = false
                let explain = ExplainViewModel(document: document)
                let view = PDFView(); view.document = pdf
                let coordinator = PDFReaderView.Coordinator(); coordinator.pdfView = view
                coordinator.setMode(.explain)
                coordinator.attach(readVM: read, explainVM: explain, doc: document)
                explain.activeMarks = [.init(id: UUID(), paragraphIndex: 0, charRange: 0..<6,
                                             action: "number", n: 2, seed: 42)]
                try await settle()
                let annotation = try XCTUnwrap(page.annotations.compactMap { $0 as? HandwrittenPDFAnnotation }.first)
                XCTAssertEqual(annotation.markRightToLeft, language != "en", "\(language), OCR=\(ocr)")
                read.stop()
                _ = coordinator
            }
        }
    }

    func testPDFNumeralsAndStarsRenderOutsideWordsWithoutClipping() throws {
        let rect = CGRect(x: 110, y: 60, width: 100, height: 16)
        let size = CGSize(width: 320, height: 140)
        for action in ["number", "star"] {
            for rtl in [false, true] {
                let bounds = HandwrittenPDFAnnotation.annotationBounds(for: [rect], action: action)
                let annotation = HandwrittenPDFAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)
                annotation.markRects = [rect]; annotation.markAction = action
                annotation.markN = 2; annotation.markSeed = 42; annotation.markRightToLeft = rtl
                annotation.inkColor = .blue
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                    UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
                    let context = renderer.cgContext
                    context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                    context.clip(to: bounds)
                    annotation.draw(with: .mediaBox, in: context)
                }
                let cg = try XCTUnwrap(image.cgImage)
                var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                var left = 0, right = 0, minX = cg.width, maxX = 0
                pixels.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(cg, in: CGRect(origin: .zero, size: size))
                    let p = bytes.bindMemory(to: UInt8.self)
                    for y in 0..<cg.height { for x in 0..<cg.width {
                        let i = (y * cg.width + x) * 4
                        if Int(p[i + 2]) - Int(p[i]) > 100 {
                            minX = min(minX, x); maxX = max(maxX, x)
                            // Exclude the hand-drawn underline's small endpoint overshoot.
                            if CGFloat(x) < rect.minX - 6 { left += 1 }
                            if CGFloat(x) > rect.maxX + 6 { right += 1 }
                        }
                    } }
                }
                let expectedRight = action == "number" ? rtl : !rtl
                XCTAssertGreaterThan(expectedRight ? right : left, 30, "\(action) RTL=\(rtl): marker outside word")
                XCTAssertEqual(expectedRight ? left : right, 0, "No marker on the opposite edge")
                XCTAssertGreaterThan(CGFloat(minX), bounds.minX + 2, "Ink must not be clipped at the left edge")
                XCTAssertLessThan(CGFloat(maxX), bounds.maxX - 2, "Ink must not be clipped at the right edge")
                let attachment = XCTAttachment(image: image)
                attachment.name = "pdf-\(action)-rtl-\(rtl)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testPDFReadingFollowMovesBeforeWordReachesBottomControls() async throws {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        scroll.contentSize = CGSize(width: 390, height: 2400)
        let word = CGRect(x: 30, y: 450, width: 45, height: 14)
        ReaderViewportFollow.reveal(word, in: scroll, source: "pdf", lowerBoundary: 0.70)
        try await settle()
        XCTAssertEqual(word.minY - scroll.contentOffset.y, 150, accuracy: 2,
                       "A word at 75% of the viewport should move to the upper quarter")
    }
}
