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
        let target = try XCTUnwrap(descendants(host.view, as: ReaderUITextView.self).first { view in
            guard let rect = view.rects(forCharRange: NSRange(location: 0, length: 9)).first else { return false }
            let y = view.convert(rect, to: scroll).minY
            return y > visible.minY + visible.height * 0.90 && y < visible.maxY - 15
        })
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
}
