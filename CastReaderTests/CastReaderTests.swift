//
//  CastReaderTests.swift
//  CastReaderTests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
import UIKit
import WebKit
@testable import CastReader

class CastReaderTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

    // MARK: - 场景化「划重点·批注」content_type 全链路自检（PRD P0）

    private func encodedJSON<T: Encodable>(_ v: T) throws -> String {
        let data = try JSONEncoder().encode(v)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// §7.2：场景进入时 extract-plan 请求体须含 content_type，且 nil 时字段省略（§2.1 向后兼容、零回归）。
    func testExtractPlanEncodesContentType() throws {
        let withCT = ExtractPlanRequest(
            source_url: "castreader://doc/x", title: "T", lang: nil, depth: "deep",
            text: "t", fullText: "t", paragraphs: [], prev_summary: nil, content_type: "paper")
        let json = try encodedJSON(withCT)
        XCTAssertTrue(json.contains("\"content_type\":\"paper\""), "content_type 应被编码: \(json)")

        let general = ExtractPlanRequest(
            source_url: "castreader://doc/x", title: "T", lang: nil, depth: "standard",
            text: "t", fullText: "t", paragraphs: [], prev_summary: nil, content_type: nil)
        XCTAssertFalse(try encodedJSON(general).contains("content_type"), "nil content_type 应省略字段（零回归）")
    }

    /// 快道 fast-block0 同样带 content_type。
    func testFastBlock0EncodesContentType() throws {
        let req = FastBlock0Request(
            title: "T", openingParas: [FastBlock0OpeningPara(text: "a")],
            lang: nil, depth: "deep", prev_summary: nil, content_type: "contract")
        XCTAssertTrue(try encodedJSON(req).contains("\"content_type\":\"contract\""))
    }

    /// content_type 与 depth 正交：场景**不**覆盖用户深度。设深度=速览，进「论文」场景，requestDepth 仍=速览。
    @MainActor
    func testScenarioDoesNotOverrideDepth() {
        let prev = AppSettings.shared.explainDepth
        defer { AppSettings.shared.explainDepth = prev }

        let doc = ReadingDocument(title: "T", sourceKind: .text,
                                  paragraphs: [ReadingParagraph(id: 0, text: "hello world", type: .paragraph)])
        let vm = ExplainViewModel(document: doc)

        AppSettings.shared.explainDepth = QuickreadDepth.overview.rawValue
        vm.scenario = ExplainContentType.paper.rawValue   // 论文（旧逻辑会强制 deep）
        XCTAssertEqual(vm.requestDepth, "overview", "场景不应覆盖用户深度")

        AppSettings.shared.explainDepth = QuickreadDepth.deep.rawValue
        XCTAssertEqual(vm.requestDepth, "deep", "深度始终跟随用户设置")

        XCTAssertEqual(ExplainContentType.allCases.count, 6)
    }

    /// content_type 的 rawValue 必须是后端约定的 6 个 id（§4 契约）。
    func testContentTypeRawValues() {
        XCTAssertEqual(Set(ExplainContentType.allCases.map(\.rawValue)),
                       ["paper", "book", "report", "contract", "study", "manual"])
    }

    /// 场景只改变导入来源排序，不限制来源能力；尤其说明书 / Git 文档必须支持 Web 链接。
    func testScenarioImportSourcesAreRecommendationsOnly() {
        let allSources = Set(ImportSource.allCases)
        for ct in ExplainContentType.allCases {
            XCTAssertEqual(Set(ImportSource.sources(for: ct)), allSources, "\(ct.rawValue) 不应缺导入来源")
        }

        XCTAssertEqual(ImportSource.sources(for: .manual).first, .url, "说明书 / 文档场景应优先支持 Web 链接")
        XCTAssertEqual(ImportSource.general.first, .url, "底部 + 快速导入应优先支持 Web 链接")
    }

    /// 场景注入 ExplainViewModel：scenario 被正确设置（驱动 content_type，不动深度）。
    @MainActor
    func testScenarioInjection() {
        let doc = ReadingDocument(title: "T", sourceKind: .text,
                                  paragraphs: [ReadingParagraph(id: 0, text: "hello world", type: .paragraph)])
        let vm = ExplainViewModel(document: doc)
        vm.scenario = ExplainContentType.paper.rawValue
        XCTAssertEqual(vm.scenario, "paper")
    }

    // MARK: - P1 分层标注：weight → 笔触粗细

    func testWeightMultiplier() {
        XCTAssertEqual(HandwrittenMark.weightMultiplier("primary"), 1.6)
        XCTAssertEqual(HandwrittenMark.weightMultiplier("tertiary"), 0.65)
        XCTAssertEqual(HandwrittenMark.weightMultiplier("secondary"), 1.0)
        XCTAssertEqual(HandwrittenMark.weightMultiplier(nil), 1.0)   // 后端没给 → 零回归
    }

    /// mark 事件解码出 weight/role（后端 P1 字段；缺省时为 nil）。
    func testQuickreadEventDecodesWeightRole() throws {
        let json = #"{"action":"wave","text":"风险","weight":"primary","role":"caution"}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(QuickreadEvent.self, from: json)
        XCTAssertEqual(ev.action, "wave")
        XCTAssertEqual(ev.weight, "primary")
        XCTAssertEqual(ev.role, "caution")

        let bare = #"{"action":"underline","text":"x"}"#.data(using: .utf8)!
        let ev2 = try JSONDecoder().decode(QuickreadEvent.self, from: bare)
        XCTAssertNil(ev2.weight)
    }

    /// fast-block0 同样要接住场景化标注的样式与分层字段；否则首块会把 wave/star 等新 mark 丢薄。
    func testFastBlock0MarkDecodesScenarioFields() throws {
        let json = #"{"style":"star","text":"a key sentence","n":2,"weight":"primary","role":"key","note":"why it matters"}"#.data(using: .utf8)!
        let mark = try JSONDecoder().decode(FastBlock0Mark.self, from: json)
        XCTAssertEqual(mark.style, "star")
        XCTAssertEqual(mark.text, "a key sentence")
        XCTAssertEqual(mark.n, 2)
        XCTAssertEqual(mark.weight, "primary")
        XCTAssertEqual(mark.role, "key")
        XCTAssertEqual(mark.note, "why it matters")
    }

    // MARK: - 封面 + 标题：网页元数据解析

    func testLinkMetadataParsesOGTitleAndImage() {
        let html = """
        <html><head>
        <title>Fallback Title</title>
        <meta property="og:title" content="Real Article Title &amp; More">
        <meta property="og:image" content="https://cdn.example.com/cover.jpg">
        </head><body></body></html>
        """
        let r = LinkMetadata.parse(html: html, baseURL: URL(string: "https://example.com/post")!)
        XCTAssertEqual(r.title, "Real Article Title & More")   // og 优先 + 实体解码
        XCTAssertEqual(r.imageURL, "https://cdn.example.com/cover.jpg")
    }

    func testLinkMetadataResolvesRelativeImageAndFallsBackToTitleTag() {
        let html = """
        <head><title>Only Title Tag</title>
        <meta name="twitter:image" content="/img/cover.png"></head>
        """
        let r = LinkMetadata.parse(html: html, baseURL: URL(string: "https://blog.example.com/a/b")!)
        XCTAssertEqual(r.title, "Only Title Tag")                          // 无 og:title → 回退 <title>
        XCTAssertEqual(r.imageURL, "https://blog.example.com/img/cover.png") // 相对路径解析为绝对
    }

    func testLinkMetadataNoMetaReturnsNilImage() {
        let r = LinkMetadata.parse(html: "<html><head></head><body>hi</body></html>",
                                   baseURL: URL(string: "https://x.com")!)
        XCTAssertNil(r.imageURL)
    }

    // MARK: - Kindle 书架扫描防误判

    private func kindleBook(
        id: String,
        asin: String? = nil,
        title: String,
        url: String
    ) -> KindleBook {
        KindleBook(
            id: id,
            asin: asin,
            title: title,
            author: "",
            coverURL: nil,
            readerURL: url,
            progressLabel: "",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
    }

    func testKindleBookValidatorRejectsAmazonMarketingLinks() {
        let fakeBooks = [
            kindleBook(id: "download", title: "在应用商店中下载", url: "https://read.amazon.com/kindle-library"),
            kindleBook(id: "learn-more", title: "了解更多有关 Kindle APP 的信息", url: "https://read.amazon.com/landing"),
            kindleBook(id: "any-device", title: "在任何设备上阅读 read.amazon.com", url: "https://read.amazon.com/kindle-library"),
            kindleBook(id: "app", title: "Download the Kindle App", url: "https://read.amazon.com/download")
        ]

        for book in fakeBooks {
            XCTAssertFalse(book.isLikelyLibraryBook, "不应把 Kindle 引导/营销链接当成书：\(book.title)")
        }
    }

    func testKindleBookValidatorAcceptsReaderBooks() {
        XCTAssertTrue(
            kindleBook(
                id: "B012345678",
                asin: "B012345678",
                title: "A Real Kindle Book",
                url: "https://read.amazon.com/?asin=B012345678"
            ).isLikelyLibraryBook
        )

        XCTAssertTrue(
            kindleBook(
                id: "reader",
                title: "Another Real Kindle Book",
                url: "https://read.amazon.com/reader/B012345678"
            ).isLikelyLibraryBook
        )
    }

    // MARK: - 文件标题推导（PDF/DOCX 不再只用文件名）

    func testPDFTitlePrefersMeaningfulMetadata() {
        // 有意义的元数据标题 → 直接用
        XCTAssertEqual(DocumentBuilder.derivePDFTitle(meta: "Attention Is All You Need",
                                                      firstText: "arXiv:1706.03762 Provided proper...", fallback: "1706.03762"),
                       "Attention Is All You Need")
        // 垃圾元数据（Office 导出）→ 回退首段文本（截断）
        XCTAssertEqual(DocumentBuilder.derivePDFTitle(meta: "Microsoft Word - doc1.docx",
                                                      firstText: "季度财务报告与风险提示", fallback: "doc1"),
                       "季度财务报告与风险提示")
        // 无元数据、首段太短 → 文件名兜底
        XCTAssertEqual(DocumentBuilder.derivePDFTitle(meta: nil, firstText: "x", fallback: "report"), "report")
    }

    func testIsMeaningfulTitle() {
        XCTAssertTrue(DocumentBuilder.isMeaningfulTitle("Deep Residual Learning"))
        XCTAssertFalse(DocumentBuilder.isMeaningfulTitle("untitled"))
        XCTAssertFalse(DocumentBuilder.isMeaningfulTitle("Microsoft Word - Document1"))
        XCTAssertFalse(DocumentBuilder.isMeaningfulTitle(" "))
    }

    // MARK: - Kindle Audiobook sentence resume anchor

    private func anchorParagraph(id: Int, _ text: String) -> ReadingParagraph {
        let words = text.split(whereSeparator: { $0.isWhitespace }).enumerated().map {
            OCRWord(id: $0.offset, text: String($0.element), bboxNorm: .zero)
        }
        return ReadingParagraph(id: id, text: text, words: words, pageIndex: 0)
    }

    private func listeningAnchor(
        paragraphs: [ReadingParagraph],
        targetParagraph: Int,
        targetWord: Int,
        pageKey: String = "page-real-1",
        schemaVersion: Int = KindleListeningAnchor.currentSchemaVersion,
        readerVersion: Int = KindleListeningAnchor.currentReaderImplementationVersion
    ) -> KindleListeningAnchor {
        let paragraph = paragraphs.first(where: { $0.id == targetParagraph })!
        let charOffset = KindleListeningAnchorResolver.charOffset(in: paragraph, wordIndex: targetWord)
        let phrase = KindleListeningAnchorResolver.anchorPhrase(in: paragraph.text, charOffset: charOffset)
        return KindleListeningAnchor(
            bookId: "book-1",
            pageKey: pageKey,
            pageTextHash: KindleListeningAnchorResolver.pageTextHash(paragraphs: paragraphs),
            paragraphIndex: targetParagraph,
            wordIndex: targetWord,
            charOffset: charOffset,
            anchorPhrase: phrase.phrase,
            anchorWordOffset: phrase.anchorWordOffset,
            voice: "af_heart",
            speed: 1.5,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schemaVersion: schemaVersion,
            readerImplementationVersion: readerVersion
        )
    }

    func testKindleListeningAnchorExactSamePageMatch() {
        let paragraphs = [
            anchorParagraph(id: 0, "An opening paragraph establishes the scene for this page."),
            anchorParagraph(id: 1, "The narrator now reaches the exact sentence that should continue after reopening the book.")
        ]
        let anchor = listeningAnchor(paragraphs: paragraphs, targetParagraph: 1, targetWord: 6)
        let result = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: paragraphs
        )
        XCTAssertEqual(result.match, .exact)
        XCTAssertEqual(result.paragraphIndex, 1)
        XCTAssertEqual(result.wordIndex, 6)
    }

    func testKindleListeningAnchorRelocatesAfterSmallTextChange() {
        let original = [
            anchorParagraph(id: 0, "An opening paragraph establishes the scene for this page."),
            anchorParagraph(id: 1, "The narrator now reaches the exact sentence that should continue after reopening the book.")
        ]
        let anchor = listeningAnchor(paragraphs: original, targetParagraph: 1, targetWord: 6)
        let changed = [
            anchorParagraph(id: 0, "A newly recognized heading appears before the original OCR text."),
            anchorParagraph(id: 1, original[0].text),
            anchorParagraph(id: 2, original[1].text)
        ]
        let result = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: changed
        )
        XCTAssertEqual(result.match, .relocated)
        XCTAssertEqual(result.paragraphIndex, 2)
        XCTAssertEqual(result.reason, "anchor-fuzzy")
    }

    func testKindleListeningAnchorInvalidPageAndHashFallBackSafely() {
        let original = [
            anchorParagraph(id: 0, "Original words locate a unique sentence in the captured Kindle page."),
            anchorParagraph(id: 1, "Another readable paragraph follows it for the rest of the page.")
        ]
        let anchor = listeningAnchor(paragraphs: original, targetParagraph: 1, targetWord: 3)
        let pageMismatch = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "different-real-page",
            paragraphs: original
        )
        XCTAssertEqual(pageMismatch.match, .fallback)
        XCTAssertEqual(pageMismatch.paragraphIndex, 0)
        XCTAssertEqual(pageMismatch.reason, "page-key-mismatch")

        let unrelated = [anchorParagraph(id: 0, "Completely unrelated replacement content without the saved token window.")]
        let hashMismatch = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: unrelated
        )
        XCTAssertEqual(hashMismatch.match, .fallback)
        XCTAssertEqual(hashMismatch.paragraphIndex, 0)
    }

    func testKindleListeningAnchorOldSchemaFallsBack() {
        let paragraphs = [anchorParagraph(id: 0, "A valid page still rejects an anchor written by an obsolete schema.")]
        let anchor = listeningAnchor(
            paragraphs: paragraphs,
            targetParagraph: 0,
            targetWord: 4,
            schemaVersion: 0
        )
        let result = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: paragraphs
        )
        XCTAssertEqual(result.match, .fallback)
        XCTAssertEqual(result.reason, "schema-mismatch")
    }

    func testKindleContinueListeningAutoplayGateConsumesOncePerBook() {
        let gate = KindleAutoplayRequestGate()
        XCTAssertEqual(gate.request(for: "book-a"), 1)
        XCTAssertEqual(gate.consume(for: "book-a"), 1)
        XCTAssertNil(gate.consume(for: "book-a"), "同一请求的重复 WebKit ready 回调不得再次 autoplay")

        XCTAssertEqual(gate.request(for: "book-b"), 1)
        XCTAssertEqual(gate.request(for: "book-b"), 2)
        XCTAssertEqual(gate.consume(for: "book-b"), 2, "连续点击应合并为最新一次 ensurePlaying 请求")
        XCTAssertNil(gate.consume(for: "book-b"))
    }

    func testKindleSyncDialogEventParsesLocationsWithoutBodyText() throws {
        let event = try XCTUnwrap(KindleSyncDialogEvent(payload: [
            "type": "kindle-sync-dialog",
            "visible": true,
            "localLocation": 1097,
            "cloudLocation": "1088"
        ]))
        XCTAssertTrue(event.isVisible)
        XCTAssertEqual(event.localLocation, 1097)
        XCTAssertEqual(event.cloudLocation, 1088)
        XCTAssertNil(event.choice)
    }

    func testKindleSyncDialogChoiceIsSeparateFromPageTruth() throws {
        let event = try XCTUnwrap(KindleSyncDialogEvent(payload: [
            "type": "kindle-sync-dialog-choice",
            "visible": true,
            "choice": "no",
            "localLocation": 1097,
            "cloudLocation": 1088
        ]))
        XCTAssertEqual(event.choice, .no)
        XCTAssertEqual(event.localLocation, 1097)
        XCTAssertEqual(event.cloudLocation, 1088)
    }

    @MainActor
    func testKindleSyncDialogBootstrapDetectsDialogAndChoice() async throws {
        let collector = KindleTestMessageCollector()
        let controller = WKUserContentController()
        controller.add(collector, name: "castReaderKindle")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        let window = UIWindow(frame: webView.frame)
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadHTMLString(
            """
            <!doctype html><html><body>
            <div role="dialog" aria-modal="true" style="position:fixed;left:30px;top:120px;width:330px;height:240px">
              <h2>Most Recent Page Read</h2>
              <p>You're on location 1097. The most recent location is 1088. Go to location 1088?</p>
              <button id="no">No</button><button id="yes">Yes</button>
            </div>
            <button id="kr-chevron-right" aria-label="Next page" style="opacity:0;pointer-events:none">Next</button>
            <script>
              window.hiddenChevronClickCount = 0;
              window.hiddenKeyboardTurnCount = 0;
              document.getElementById('kr-chevron-right').addEventListener('click', function() {
                window.hiddenChevronClickCount += 1;
              });
              window.addEventListener('keydown', function(event) {
                if (event.key === 'ArrowRight') window.hiddenKeyboardTurnCount += 1;
              });
            </script>
            </body></html>
            """,
            baseURL: URL(string: "https://read.amazon.com")
        )
        for _ in 0..<30 {
            if let loaded = try? await webView.evaluateJavaScript("!!document.querySelector('[role=dialog]')") as? Bool,
               loaded { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await webView.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap)

        for _ in 0..<30 where !collector.messages.contains(where: { ($0["type"] as? String) == "kindle-sync-dialog" }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let shownPayload = try XCTUnwrap(collector.messages.first(where: { ($0["type"] as? String) == "kindle-sync-dialog" }))
        let shown = try XCTUnwrap(KindleSyncDialogEvent(payload: shownPayload))
        XCTAssertEqual(shown.localLocation, 1097)
        XCTAssertEqual(shown.cloudLocation, 1088)

        _ = try await webView.evaluateJavaScript("document.getElementById('no').click()")
        for _ in 0..<20 where !collector.messages.contains(where: { ($0["type"] as? String) == "kindle-sync-dialog-choice" }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let choicePayload = try XCTUnwrap(collector.messages.first(where: { ($0["type"] as? String) == "kindle-sync-dialog-choice" }))
        XCTAssertEqual(KindleSyncDialogEvent(payload: choicePayload)?.choice, .no)

        _ = try await webView.evaluateJavaScript(
            """
            (function() {
              var leaf = document.createElement('span');
              document.getElementById('kr-chevron-right').appendChild(leaf);
              window.leftActionCount = 0;
              window.rightActionCount = 0;
              var root = { memoizedProps:{}, pendingProps:{
                leftAction:function(){ window.leftActionCount += 1; },
                rightAction:function(){ window.rightActionCount += 1; },
                pageProgressionDirection:'ltr'
              }, return:null, type:{name:'KindlePagination'} };
              var fiber = root;
              for (var i = 0; i < 24; i++) fiber = { memoizedProps:{ onClick:function(){} }, pendingProps:{}, return:fiber };
              leaf.__reactFiber$test = fiber;
            })()
            """
        )
        let rawTurn = try await webView.evaluateJavaScript("window.__crKindleSemanticPageTurn('next')")
        let turnJSON = try XCTUnwrap(rawTurn as? String)
        let turnData = try XCTUnwrap(turnJSON.data(using: .utf8))
        let turn = try XCTUnwrap(JSONSerialization.jsonObject(with: turnData) as? [String: Any])
        XCTAssertEqual(turn["strategy"] as? String, "react-paired-action")
        XCTAssertEqual(turn["propsSource"] as? String, "pendingProps")
        XCTAssertEqual(turn["fiberDepth"] as? Int, 24)
        XCTAssertEqual(turn["dispatchCount"] as? Int, 1)
        let rightActionCount = try await webView.evaluateJavaScript("window.rightActionCount") as? Int
        let leftActionCount = try await webView.evaluateJavaScript("window.leftActionCount") as? Int
        let hiddenChevronClickCount = try await webView.evaluateJavaScript("window.hiddenChevronClickCount") as? Int
        let hiddenKeyboardTurnCount = try await webView.evaluateJavaScript("window.hiddenKeyboardTurnCount") as? Int
        XCTAssertEqual(rightActionCount, 1)
        XCTAssertEqual(leftActionCount, 0)
        XCTAssertEqual(hiddenChevronClickCount, 0)
        XCTAssertEqual(hiddenKeyboardTurnCount, 0)

        let rtlFallbackRaw = try await webView.evaluateJavaScript(
            """
            (function() {
              var leaf = document.querySelector('#kr-chevron-right span');
              leaf.__reactFiber$test = { memoizedProps:{
                leftAction:function(){ window.leftActionCount += 1; },
                rightAction:function(){ window.rightActionCount += 1; }
              }, pendingProps:{}, return:null, type:{name:'KindlePagination'} };
              return window.__crKindleSemanticPageTurn('next', 'rtl');
            })()
            """
        )
        let rtlFallbackData = try XCTUnwrap((rtlFallbackRaw as? String)?.data(using: .utf8))
        let rtlFallback = try XCTUnwrap(JSONSerialization.jsonObject(with: rtlFallbackData) as? [String: Any])
        XCTAssertEqual(rtlFallback["semanticAction"] as? String, "leftAction")
        XCTAssertEqual(rtlFallback["progressionSource"] as? String, "language-fallback")
        let rtlLeftActionCount = try await webView.evaluateJavaScript("window.leftActionCount") as? Int
        XCTAssertEqual(rtlLeftActionCount, 1)

        let compatibilityRaw = try await webView.evaluateJavaScript(
            "[window.__crKindleDirectPage('right'), window.__crKindleForceAdjacentPage('left')]"
        )
        let compatibility = try XCTUnwrap(compatibilityRaw as? [String])
        XCTAssertEqual(compatibility.count, 2)
        for raw in compatibility {
            let data = try XCTUnwrap(raw.data(using: .utf8))
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(result["strategy"] as? String, "react-paired-action")
            XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        }
        let compatibilityRightCount = try await webView.evaluateJavaScript("window.rightActionCount") as? Int
        let compatibilityLeftCount = try await webView.evaluateJavaScript("window.leftActionCount") as? Int
        XCTAssertEqual(compatibilityRightCount, 2)
        XCTAssertEqual(compatibilityLeftCount, 2)

        let singleHandlerRaw = try await webView.evaluateJavaScript(
            """
            (function() {
              var leaf = document.querySelector('#kr-chevron-right span');
              leaf.__reactFiber$test = { memoizedProps:{ onClick:function(){} }, pendingProps:{}, return:null };
              return window.__crKindleSemanticPageTurn('next');
            })()
            """
        )
        let singleHandlerData = try XCTUnwrap((singleHandlerRaw as? String)?.data(using: .utf8))
        let singleHandler = try XCTUnwrap(JSONSerialization.jsonObject(with: singleHandlerData) as? [String: Any])
        XCTAssertEqual(singleHandler["ok"] as? Bool, false, "单个 click handler 不能冒充 paired pagination actions")
    }

    func testKindleEightLanguageAndPageEvidenceContracts() throws {
        let expected = [
            "en-US":"en", "zh-CN":"zh", "ja-JP":"ja", "es-ES":"es",
            "fr-FR":"fr", "pt-BR":"pt", "it-IT":"it", "hi-IN":"hi",
            "pt-PT":"pt", "por":"pt"
        ]
        for (input, language) in expected {
            XCTAssertEqual(KindleLanguageContract.profile(language: input)?.language, language)
        }
        XCTAssertEqual(KindleLanguageContract.profile(language: "pt-PT")?.visionLocale, "pt-BR")
        XCTAssertEqual(KindleLanguageContract.profile(language: "zh")?.visionLocale, "zh-Hans")
        XCTAssertEqual(KindleLanguageContract.profile(language: "zh")?.tesseractModel, "chi_sim")
        XCTAssertEqual(KindleLanguageContract.profile(language: "hi")?.tesseractModel, "hin")
        XCTAssertEqual(
            ["en", "zh", "ja", "es", "fr", "pt", "it", "hi"].compactMap {
                KindleLanguageContract.profile(language: $0)?.tesseractModel
            },
            ["eng", "chi_sim", "jpn", "spa", "fra", "por", "ita", "hin"]
        )
        XCTAssertEqual(KindleLanguageContract.profile(language: "ja")?.readingDirection, .rtl)
        XCTAssertFalse(
            try XCTUnwrap(KindleLanguageContract.profile(language: "ja", writingMode: .vertical)).isSupported,
            "日语竖排必须在生产 OCR/TTS 前阻止"
        )
        XCTAssertEqual(KindleLanguageContract.profile(language: "ja", writingMode: .vertical)?.tesseractModel, "jpn_vert")
        XCTAssertEqual(
            KindleOCRRoutingContract.route(for: try XCTUnwrap(KindleLanguageContract.profile(language: "zh"))),
            KindleOCRRoute(primary: .vision, fallback: .tesseract)
        )
        XCTAssertEqual(
            KindleOCRRoutingContract.route(for: try XCTUnwrap(KindleLanguageContract.profile(language: "hi"))),
            KindleOCRRoute(primary: .tesseract, fallback: nil)
        )
        XCTAssertEqual(
            KindleOCRRoutingContract.route(
                for: try XCTUnwrap(KindleLanguageContract.profile(language: "ja", writingMode: .vertical))
            ),
            KindleOCRRoute(primary: .tesseract, fallback: nil)
        )
        XCTAssertEqual(
            KindleOCRTextContract.tokens(in: "研究哲学、文学", language: "zh"),
            ["研", "究", "哲", "学", "、", "文", "学"]
        )
        XCTAssertEqual(
            KindleOCRTextContract.tokens(in: "Kindle reader", language: "en"),
            ["Kindle", "reader"]
        )
        XCTAssertEqual(
            KindleOCRTextContract.tokens(in: "हिन्दी भाषा", language: "hi"),
            ["हिन्दी", "भाषा"],
            "天城文组合附标必须保留在完整词内"
        )
        XCTAssertEqual(KindleLanguageContract.alignmentText("人 間"), KindleLanguageContract.alignmentText("人間"))
        XCTAssertEqual(KindleLanguageContract.alignmentText("café"), KindleLanguageContract.alignmentText("cafe\u{301}"))
        XCTAssertEqual(KindleLanguageContract.alignmentText("हिन्दी"), KindleLanguageContract.alignmentText("हि न्दी"))
        XCTAssertTrue(KindleLanguageContract.endsWithHardTerminal("समाप्त॥”"))
        XCTAssertTrue(KindleLanguageContract.startsWithListMarker("1) पहला बिंदु"))
        XCTAssertTrue(KindleLanguageContract.startsWithListMarker("२) दूसरा बिंदु"))
        XCTAssertTrue(KindleLanguageContract.startsWithListMarker("• गोदान का परिचय"))
        XCTAssertTrue(KindleLanguageContract.endsWithHeadingDelimiter("मुख्य पात्र："))
        XCTAssertFalse(KindleLanguageContract.startsWithListMarker("सामान्य अनुच्छेद"))
        XCTAssertEqual(KindleLanguageContract.join(["人", "間"], language: "ja"), "人間")
        XCTAssertTrue(KindleLanguageContract.shouldPreferRawParagraphs(language: "hi", raw: 4, visualLines: 5, rebuilt: 1))
        XCTAssertFalse(KindleLanguageContract.isVerified(language: "ja", source: nil), "旧缓存语言没有证据来源，必须重新确认")
        XCTAssertTrue(KindleLanguageContract.isVerified(language: "ja", source: "renderer-metadata"))
        XCTAssertTrue(KindlePlaybackLifecycleContract.shouldKeepPlayback(
            surfaceAttached: true,
            explicitlyClosed: false
        ))
        XCTAssertFalse(KindlePlaybackLifecycleContract.shouldKeepPlayback(
            surfaceAttached: false,
            explicitlyClosed: false
        ))
        XCTAssertTrue(KindlePlaybackLifecycleContract.requiresImmediateVisualSync(
            readerPresented: true,
            applicationActive: true
        ))
        XCTAssertFalse(KindlePlaybackLifecycleContract.requiresImmediateVisualSync(
            readerPresented: false,
            applicationActive: true
        ))
        XCTAssertFalse(KindlePlaybackLifecycleContract.requiresImmediateVisualSync(
            readerPresented: true,
            applicationActive: false
        ))
        XCTAssertTrue(KindleContinuousPageHandoffContract.shouldArm(
            isReadMode: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            hasPreparedPage: true,
            hasPreparedAudio: true,
            audioIsPlaying: true
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldArm(
            isReadMode: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            hasPreparedPage: true,
            hasPreparedAudio: false,
            audioIsPlaying: true
        ))
        XCTAssertTrue(KindleContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "current-tail",
            predecessorSegmentID: "current-tail",
            remainingAudioSeconds: 2.6,
            playbackRate: 2.0
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "earlier-segment",
            predecessorSegmentID: "current-tail",
            remainingAudioSeconds: 0.2,
            playbackRate: 1.0
        ))
        XCTAssertTrue(KindleContinuousPageHandoffContract.shouldReleaseAudioGate(
            hasConfirmedVisibleSurface: true,
            textFingerprintMatches: true
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldReleaseAudioGate(
            hasConfirmedVisibleSurface: true,
            textFingerprintMatches: false
        ))
        XCTAssertEqual(
            KindleWritingModeContract.infer(from: [CGSize(width: 0.8, height: 0.1), CGSize(width: 0.7, height: 0.12)]),
            .horizontal
        )
        XCTAssertEqual(
            KindleWritingModeContract.infer(from: [CGSize(width: 0.08, height: 0.8), CGSize(width: 0.1, height: 0.7)]),
            .vertical
        )

        let englishFragment = LanguageDetector.Evidence(language: "en", confidence: 0.91, readableCharacterCount: 15)
        let japanesePage = LanguageDetector.Evidence(language: "ja", confidence: 0.96, readableCharacterCount: 180)
        let japaneseTitle = LanguageDetector.evidence(for: "人間失格 日本語版")
        let bad = KindleOCRConsensus.score(page: englishFragment, requestedLanguage: "en", title: japaneseTitle)
        let good = KindleOCRConsensus.score(page: japanesePage, requestedLanguage: "ja", title: japaneseTitle)
        XCTAssertEqual(good.language, "ja")
        XCTAssertGreaterThan(good.value, bad.value * 3, "完整日语 OCR 必须压过少量英文模型噪声")

        XCTAssertTrue(KindleColumnLayoutContract.isDualColumn(aspect: 1.01, pixelsReadable: true, centerGutter: true))
        XCTAssertTrue(KindleColumnLayoutContract.isDualColumn(aspect: 1.12, pixelsReadable: true, centerGutter: true))
        XCTAssertFalse(KindleColumnLayoutContract.isDualColumn(aspect: 1.70, pixelsReadable: true, centerGutter: false))
        XCTAssertTrue(KindleColumnLayoutContract.isDualColumn(aspect: 1.70, pixelsReadable: false, centerGutter: false))
        XCTAssertNil(KindleColumnLayoutContract.cacheSignature(contentKey: "same", pixelFingerprint: nil, pixelSize: CGSize(width: 100, height: 100)))
        XCTAssertNotEqual(
            KindleColumnLayoutContract.cacheSignature(contentKey: "same", pixelFingerprint: "a", pixelSize: CGSize(width: 100, height: 100)),
            KindleColumnLayoutContract.cacheSignature(contentKey: "same", pixelFingerprint: "b", pixelSize: CGSize(width: 100, height: 100))
        )

        XCTAssertTrue(KindleTurnContract.confirms(progress: .unchanged, beforeFingerprint: "a", afterFingerprint: "b", semanticActionDispatched: true, stableVisualSamples: 2))
        XCTAssertFalse(KindleTurnContract.confirms(progress: .unchanged, beforeFingerprint: "a", afterFingerprint: "b", semanticActionDispatched: true, stableVisualSamples: 1))
        XCTAssertFalse(KindleTurnContract.confirms(progress: .forward, beforeFingerprint: "a", afterFingerprint: "a", semanticActionDispatched: true, stableVisualSamples: 2))
        XCTAssertFalse(KindleTurnContract.confirms(progress: .backward, beforeFingerprint: "a", afterFingerprint: "b", semanticActionDispatched: true, stableVisualSamples: 2))
        XCTAssertEqual(KindleTurnContract.progress(beforeLocation: 2, afterLocation: 2, beforeRenderer: 10, afterRenderer: 11), .forward)
        XCTAssertEqual(KindleTurnContract.progressNumber("स्थान १२३"), 123)
        XCTAssertTrue(KindleWebScripts.pageCaptureBootstrap.contains("crKindleOcrMaxWidth = 2048"))
        XCTAssertTrue(KindleWebScripts.pageCaptureBootstrap.contains("toDataURL('image/png')"))
        XCTAssertFalse(KindleWebScripts.pageCaptureBootstrap.contains("toDataURL('image/jpeg', quality)"))
    }

    func testKindleReadPageCompletionHasSingleSessionOwner() {
        let pageA = KindleReadPageSession(generation: 41, documentID: "doc-a")
        let pageB = KindleReadPageSession(generation: 42, documentID: "doc-b")

        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: true,
                activeSession: pageA,
                eventSession: pageA,
                consumedGeneration: nil,
                currentPageKey: "page-a"
            ),
            .accept
        )
        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: true,
                activeSession: pageA,
                eventSession: pageA,
                consumedGeneration: pageA.generation,
                currentPageKey: "page-a"
            ),
            .duplicate,
            "同一页的第二个完成信号不得再次触发翻页"
        )
        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: false,
                activeSession: pageB,
                eventSession: pageA,
                consumedGeneration: nil,
                currentPageKey: "page-b"
            ),
            .staleOwner,
            "上一页迟到的 VM 回调不得消费新页"
        )
        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: true,
                activeSession: pageB,
                eventSession: pageA,
                consumedGeneration: nil,
                currentPageKey: "page-b"
            ),
            .staleSession,
            "即使页内段落 ID 都从零开始，会话代际不同也必须拒绝"
        )
    }

    func testKindleContinuousHandoffRequiresFreshTargetDocumentOwner() {
        XCTAssertTrue(KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
            previousOwnerDocumentID: "doc-a",
            activeOwnerDocumentID: "doc-b",
            targetDocumentID: "doc-b"
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
            previousOwnerDocumentID: "doc-a",
            activeOwnerDocumentID: "doc-a",
            targetDocumentID: "doc-b"
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
            previousOwnerDocumentID: "doc-a",
            activeOwnerDocumentID: "doc-c",
            targetDocumentID: "doc-b"
        ))
    }

    func testKindleContinuousFallbackCommitsWhenAudioAlreadyReachedBoundary() {
        XCTAssertTrue(
            KindleContinuousPageHandoffContract.shouldCommitConfirmedFallbackAtBoundary(
                hasConfirmedVisibleSurface: true,
                textFingerprintMatches: false,
                isQueuedSegmentGated: true
            ),
            "真实页确认晚于音频边界时必须立即接管并生成真实页音频"
        )
        XCTAssertFalse(
            KindleContinuousPageHandoffContract.shouldCommitConfirmedFallbackAtBoundary(
                hasConfirmedVisibleSurface: true,
                textFingerprintMatches: false,
                isQueuedSegmentGated: false
            ),
            "旧页仍在播放时不能提前截断，继续等待自然音频边界"
        )
        XCTAssertFalse(
            KindleContinuousPageHandoffContract.shouldCommitConfirmedFallbackAtBoundary(
                hasConfirmedVisibleSurface: true,
                textFingerprintMatches: true,
                isQueuedSegmentGated: true
            ),
            "预加载命中时继续使用正常的无缝队列恢复路径"
        )
    }

    func testKindleContinuousVisualTurnNeverRetriesSemanticActionAfterMismatch() {
        let old = "page-10"
        let speculative = "held-surface-a"

        XCTAssertTrue(KindleContinuousVisualTurnContract.shouldDispatchSemanticAction(
            expectedKey: speculative,
            visibleKey: old,
            semanticActionAttempted: false,
            confirmedTargetKey: nil
        ))

        let actual = "page-11"
        XCTAssertFalse(KindleContinuousVisualTurnContract.shouldDispatchSemanticAction(
            expectedKey: speculative,
            visibleKey: actual,
            semanticActionAttempted: true,
            confirmedTargetKey: actual
        ), "预加载 key 与真实下一页不一致时不得重发翻页动作")
        XCTAssertEqual(
            KindleContinuousVisualTurnContract.stagingTargetKey(
                oldKey: old,
                expectedKey: speculative,
                visibleKey: actual,
                semanticActionAttempted: true,
                confirmedTargetKey: actual
            ),
            actual,
            "翻页成功后应改为接管真实可见页，而不是为了命中猜测缓存继续翻页"
        )

        XCTAssertFalse(KindleContinuousVisualTurnContract.shouldDispatchSemanticAction(
            expectedKey: speculative,
            visibleKey: actual,
            semanticActionAttempted: true,
            confirmedTargetKey: nil
        ), "即使动作确认超时，已尝试过的非幂等动作也不能重发")
        XCTAssertEqual(
            KindleContinuousVisualTurnContract.stagingTargetKey(
                oldKey: old,
                expectedKey: speculative,
                visibleKey: actual,
                semanticActionAttempted: true,
                confirmedTargetKey: nil
            ),
            actual
        )
    }

    @MainActor
    func testKindleChineseVisionOCRUsesGraphemeGeometry() async throws {
        let size = CGSize(width: 1400, height: 560)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 18
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Songti SC", size: 54) ?? UIFont.systemFont(ofSize: 54),
                .foregroundColor: UIColor.black,
                .paragraphStyle: style
            ]
            let text = "王国维字静安，号观堂，浙江海宁人，是我国近代享有国际盛誉的著名学者。\n他中过秀才，早年学习英、日文，研究哲学、文学。"
            text.draw(in: CGRect(x: 60, y: 60, width: 1280, height: 440), withAttributes: attributes)
        }
        let profile = try XCTUnwrap(KindleLanguageContract.profile(language: "zh"))
        let document = try await OCRService.shared.recognizeKindle(
            image: image,
            profile: profile,
            title: "中文 OCR 契约",
            paragraphStrategy: .kindleLayout
        )
        XCTAssertTrue(document.fullText.contains("研究哲学、文学"))
        let words = document.paragraphs.flatMap(\.words)
        XCTAssertTrue(words.contains(where: { $0.text == "研" }))
        XCTAssertTrue(words.contains(where: { $0.text == "究" }))
        XCTAssertTrue(words.allSatisfy { !$0.bboxNorm.isNull && $0.bboxNorm.width > 0 && $0.bboxNorm.height > 0 })
    }

    @MainActor
    func testKindleRendererMetadataLanguageAuthority() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        webView.loadHTMLString("<!doctype html><html><body>reader</body></html>", baseURL: URL(string: "https://read.amazon.com"))
        for _ in 0..<40 {
            let body = try? await webView.evaluateJavaScript("document.body && document.body.textContent") as? String
            if body?.contains("reader") == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try await webView.evaluateJavaScript(KindleWebScripts.metadataBootstrap)
        let raw = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__crKindleExtractMetadataProfile({renderer:{book:{book_locale:'jpn'},layout:{orientation:'vertical'},pagination:{page_turn_direction:'rtl'}}}))"
        )
        let data = try XCTUnwrap((raw as? String)?.data(using: .utf8))
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(profile["language"] as? String, "ja")
        XCTAssertEqual(profile["writingMode"] as? String, "horizontal", "generic orientation 不能冒充日语竖排")
        XCTAssertEqual(profile["pageProgressionDirection"] as? String, "rtl")
        XCTAssertEqual(profile["source"] as? String, "renderer-metadata")
    }

    @MainActor
    func testKindleRendererTokenGeometryBuildsVerticalJapaneseColumns() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        webView.loadHTMLString("<!doctype html><html><body>reader</body></html>", baseURL: URL(string: "https://read.amazon.com"))
        for _ in 0..<40 {
            let body = try? await webView.evaluateJavaScript("document.body && document.body.textContent") as? String
            if body?.contains("reader") == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try await webView.evaluateJavaScript(KindleWebScripts.metadataBootstrap)
        let raw = try await webView.evaluateJavaScript(
            """
            (function() {
              var page = {pageIndex:4, children:[
                {startPositionId:100,endPositionId:109,x:300,y:20,width:20,height:300,words:[
                  {startPositionId:100,endPositionId:104,x:300,y:20,width:20,height:130},
                  {startPositionId:105,endPositionId:109,x:300,y:170,width:20,height:150}
                ]},
                {startPositionId:110,endPositionId:119,x:250,y:20,width:20,height:300,words:[
                  {startPositionId:110,endPositionId:114,x:250,y:20,width:20,height:130},
                  {startPositionId:115,endPositionId:119,x:250,y:170,width:20,height:150}
                ]}
              ]};
              return JSON.stringify(window.__crKindleExtractRendererFiles([
                {name:'metadata.json',value:{book_locale:'jpn',writingMode:'horizontal'}},
                {name:'tokens_1_1.json',value:[page]}
              ], 'https://read.amazon.com/renderer/render?startingPosition=100', null));
            })()
            """
        )
        let data = try XCTUnwrap((raw as? String)?.data(using: .utf8))
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(profile["language"] as? String, "ja")
        XCTAssertEqual(profile["writingMode"] as? String, "vertical")
        XCTAssertEqual(profile["writingModeSource"] as? String, "token-geometry")
        let hints = try XCTUnwrap(profile["verticalColumnHints"] as? [[String: Any]])
        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(hints.first?["startPositionId"] as? Int, 100)
    }

    func testKindleParagraphVisualFragmentsStaySeparatedAcrossGutter() {
        let paragraph = ReadingParagraph(
            id: 0,
            text: "one continued paragraph",
            words: [],
            bboxNorm: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            visualFragments: [
                OCRVisualFragment(column: .left, bboxNorm: CGRect(x: 0.1, y: 0.1, width: 0.35, height: 0.1), wordIDs: [0]),
                OCRVisualFragment(column: .right, bboxNorm: CGRect(x: 0.55, y: 0.8, width: 0.35, height: 0.1), wordIDs: [1])
            ]
        )
        XCTAssertEqual(paragraph.visualFragments.count, 2)
        XCTAssertLessThan(paragraph.visualFragments[0].bboxNorm.maxX, paragraph.visualFragments[1].bboxNorm.minX)
    }

    func testTimestampQualityIsLanguageNeutralAndFallsBackPerSegment() {
        func timestamps(_ words: [String]) -> [TTSTimestamp] {
            words.enumerated().map {
                TTSTimestamp(word: $0.element, startTime: Double($0.offset), endTime: Double($0.offset + 1))
            }
        }
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "El rápido zorro español",
            timestamps: timestamps(["El", "rápido", "zorro", "español"]),
            duration: 4
        ))
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "La lettura segue ogni parola",
            timestamps: timestamps(["La", "lettura", "segue", "ogni", "parola"]),
            duration: 5
        ), "Italian word timing must not be blocked by a language allowlist")
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "中文逐词高亮测试",
            timestamps: timestamps(["中文", "逐词", "高亮", "测试"]),
            duration: 4
        ), "Any future valid compact-script word timing should be accepted")
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "中文整句时间戳不能伪装成一个单词。",
            timestamps: [TTSTimestamp(word: "中文整句时间戳不能伪装成一个单词。", startTime: 0, endTime: 3)],
            duration: 3
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "日本語の文全体を一語として扱わない。",
            timestamps: [TTSTimestamp(word: "日本語の文全体を一語として扱わない。", startTime: 0, endTime: 3)],
            duration: 3
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "El rápido zorro español",
            timestamps: timestamps(["El", "rápido"]),
            duration: 2
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "Esta respuesta contiene muchas palabras diferentes",
            timestamps: timestamps(["Esta respuesta contiene"]),
            duration: 1
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "time must move forward",
            timestamps: [
                TTSTimestamp(word: "time", startTime: 0, endTime: 1),
                TTSTimestamp(word: "must", startTime: 0.7, endTime: 0.9),
                TTSTimestamp(word: "move", startTime: 1.1, endTime: 2),
                TTSTimestamp(word: "forward", startTime: 2, endTime: 3)
            ],
            duration: 3
        ), "timestamp ends must be monotonic")
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "timestamps stay inside audio",
            timestamps: timestamps(["timestamps", "stay", "inside", "audio"]),
            duration: 2
        ), "timestamps outside the actual audio duration must fall back")
        let chineseWords = "一二三四五六七八九十".map(String.init)
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: chineseWords,
                segmentTexts: ["一二三四五"],
                segPos: 0
            ),
            0..<5
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: chineseWords,
                segmentTexts: ["一二三四五", "六七八九十"],
                segPos: 0
            ),
            0..<5,
            "后续流式 segment 到达时，当前 segment 的高亮范围不得重新分配"
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: chineseWords,
                segmentTexts: ["一二三四五", "六七八九十"],
                segPos: 1
            ),
            5..<10
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: ["你", "好", "你", "好"],
                segmentTexts: ["你好", "你好"],
                segPos: 1
            ),
            2..<4,
            "重复文本必须沿 OCR 游标单调向前"
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: ["Le", "lecteur", "Kindle", "avance"],
                segmentTexts: ["Le lecteur", "Kindle avance"],
                segPos: 1
            ),
            2..<4
        )
        let japaneseWords = [
            "明", "智", "君", "は", "枕", "を", "ぎゅっと", "抱きしめ", "、",
            "目", "を", "つぶった", "が", "、", "どうしても", "涙", "が", "にじんでくる", "。"
        ]
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: japaneseWords,
                segmentTexts: ["明智君は枕をぎゅっと抱きしめ、目をつぶったが、どうしても涙がにじんでくる。"],
                segPos: 0
            ),
            0..<japaneseWords.count,
            "日语句子必须忽略 OCR 分词与标点差异并覆盖完整视觉句子"
        )
        XCTAssertNil(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: japaneseWords,
                segmentTexts: ["OCRに存在しない文章です。"],
                segPos: 0
            ),
            "匹配失败不能退回句首并错误高亮第一个字"
        )
    }

    func testJapaneseNaturalSentenceRequestsMatchAndroidAndExtension() {
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "良くフリーエネルギーと言えば、多いと思います。物質に永久はありません。",
                language: "ja-JP"
            ),
            [
                "良くフリーエネルギーと言えば、多いと思います。",
                "物質に永久はありません。"
            ]
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "一文目です！「本当ですか？」三文目です。",
                language: "ja"
            ),
            ["一文目です！", "「本当ですか？」", "三文目です。"]
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "これは同じ文が画面の幅で\n折り返されただけです。",
                language: "ja"
            ),
            ["これは同じ文が画面の幅で折り返されただけです。"]
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "First sentence. Second sentence.",
                language: "en"
            ).count,
            1
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "Primera frase. Segunda frase.",
                language: "es-ES"
            ).count,
            1
        )
    }

    func testKindleListeningHashAndAnchorTokenContract() {
        let a = [anchorParagraph(id: 0, "Hello,  WORLD!  Kindle 123")]
        let b = [anchorParagraph(id: 0, "hello world kindle 123")]
        XCTAssertEqual(
            KindleListeningAnchorResolver.pageTextHash(paragraphs: a),
            KindleListeningAnchorResolver.pageTextHash(paragraphs: b)
        )

        let paragraph = anchorParagraph(id: 0, "zero one two three four five six seven eight nine ten eleven twelve")
        let offset = KindleListeningAnchorResolver.charOffset(in: paragraph, wordIndex: 6)
        let phrase = KindleListeningAnchorResolver.anchorPhrase(in: paragraph.text, charOffset: offset)
        XCTAssertLessThanOrEqual(phrase.phrase.split(separator: " ").count, 11)
        XCTAssertEqual(phrase.anchorWordOffset, 5)
    }

    func testKindleListeningAnchorUsesSharedPageTextHashFieldAndMigratesLegacyKey() throws {
        let paragraphs = [anchorParagraph(id: 0, "A stable sentence used for cross-platform resume metadata.")]
        let anchor = listeningAnchor(paragraphs: paragraphs, targetParagraph: 0, targetWord: 3)
        let encoded = try JSONEncoder().encode(anchor)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["pageTextHash"] as? String, anchor.pageTextHash)
        XCTAssertNil(json["textHash"])

        json["textHash"] = json.removeValue(forKey: "pageTextHash")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let migrated = try JSONDecoder().decode(KindleListeningAnchor.self, from: legacyData)
        XCTAssertEqual(migrated.pageTextHash, anchor.pageTextHash)
    }
}

final class LocalizationCatalogTests: XCTestCase {
    private let appLocales = ["en", "zh-Hans", "ja", "es", "fr", "pt-BR", "it", "hi"]
    private let translatedLocales = ["en", "zh-Hans", "ja", "es", "fr", "pt-BR", "it", "hi"]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func catalog(named name: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("CastReader/\(name).xcstrings")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Source catalog checks run on the host build machine")
        }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func formatSignature(_ value: String) throws -> [String] {
        let pattern = #"%(?:\d+\$)?[-+0 #']*(?:\d+|\*)?(?:\.\d+)?(?:hh|ll|h|l|z|t|j)?([@diuoxXfFeEgGaAcCsSp])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let scalarRange = Range(match.range(at: 1), in: value) else { return nil }
            let scalar = String(value[scalarRange])
            if "diuoxXc".contains(scalar) { return "integer" }
            if "fFeEgGaA".contains(scalar) { return "float" }
            if scalar == "@" { return "object" }
            return scalar
        }.sorted()
    }

    func testAppLanguagePickerContainsSystemAndAllEightLanguages() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "en", "zh-Hans", "ja", "es", "fr", "pt-BR", "it", "hi"]
        )
    }

    func testAppLanguageOverrideChangesRuntimeLocalizedStrings() {
        let manager = AppLanguageManager.shared
        let previousLanguage = manager.selectedLanguage
        defer { manager.select(previousLanguage) }

        manager.select(.english)
        XCTAssertEqual(AppLocalized("首页"), "Home")
        XCTAssertEqual(AppLocalized("跟随系统"), "Follow System")

        manager.select(.japanese)
        XCTAssertEqual(AppLocalized("首页"), "ホーム")
        XCTAssertEqual(AppLocalized("跟随系统"), "システム設定に従う")

        manager.select(.simplifiedChinese)
        XCTAssertEqual(AppLocalized("首页"), "首页")
        XCTAssertEqual(AppLocalized("论文 / 学术"), "论文 / 学术")
        XCTAssertEqual(AppLocalized("书籍 / 长篇"), "书籍 / 长篇")
        XCTAssertEqual(AppLocalized("报告 / 研报"), "报告 / 研报")
        XCTAssertEqual(AppLocalized("合同 / 条款"), "合同 / 条款")
        XCTAssertEqual(AppLocalized("教材 / 学习"), "教材 / 学习")
        XCTAssertEqual(AppLocalized("说明书 / 文档"), "说明书 / 文档")
    }

    func testHomeProCardPurchaseContractRoutesWithoutAnIntermediatePaywall() {
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: true,
                hasYearlyProduct: true,
                hasEmailAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .none
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasEmailAccount: true,
                isLoadingProducts: true,
                isPurchaseInFlight: false
            ),
            .none
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: false,
                hasEmailAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .showPlans
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasEmailAccount: false,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .requireLogin
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasEmailAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .purchaseYearly
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasEmailAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: true
            ),
            .none
        )
    }

    func testShareInboxExtractsThePageURLFromSharedCaptionText() {
        let text = "Worth reading today — https://example.com/articles/focus?source=share"
        XCTAssertEqual(
            ShareInboxLinkExtractor.firstWebURL(in: text)?.absoluteString,
            "https://example.com/articles/focus?source=share"
        )
        XCTAssertNil(ShareInboxLinkExtractor.firstWebURL(in: "A useful note with no page link"))
        XCTAssertNil(ShareInboxLinkExtractor.firstWebURL(in: "Contact reader@example.com"))
    }

    func testShareInboxBadgeCountsOnlyItemsCreatedAfterLastSeenDate() {
        let seenAt = Date(timeIntervalSince1970: 2_000)
        func record(id: UUID = UUID(), createdAt: Date) -> ShareInboxRecord {
            ShareInboxRecord(
                id: id,
                createdAt: createdAt,
                kind: .url,
                mode: .read,
                title: "Shared article",
                payloadFilename: nil,
                sourceURL: "https://example.com",
                previewImageFilename: nil,
                linkMetadataFetchedAt: nil
            )
        }
        let records = [
            record(createdAt: Date(timeIntervalSince1970: 1_000)),
            record(createdAt: seenAt),
            record(createdAt: Date(timeIntervalSince1970: 3_000))
        ]

        XCTAssertEqual(ShareInboxStore.unreadCount(in: records, lastSeenAt: nil), 3)
        XCTAssertEqual(ShareInboxStore.unreadCount(in: records, lastSeenAt: seenAt), 1)
    }

    func testDynamicWebExtractionRejectsTitleOnlyPayloadButAcceptsArticleBody() throws {
        func paragraph(_ index: Int, _ text: String) throws -> WebRenderedParagraph {
            try XCTUnwrap(WebRenderedParagraph([
                "paragraphIndex": index,
                "text": text,
                "type": "paragraph"
            ]))
        }

        let weak = [try paragraph(0, "人民日报文章标题")]
        XCTAssertTrue(WebExtractionReadiness.isWeak(weak))

        let body = [
            try paragraph(0, String(repeating: "正文第一段内容。", count: 12)),
            try paragraph(1, String(repeating: "正文第二段内容。", count: 12)),
            try paragraph(2, String(repeating: "正文第三段内容。", count: 12))
        ]
        XCTAssertFalse(WebExtractionReadiness.isWeak(body))
    }

    func testShareInboxRecordRemainsBackwardCompatibleBeforeLinkPreviewFields() throws {
        let id = UUID()
        let legacyJSON = """
        {
          "id": "\(id.uuidString)",
          "createdAt": 0,
          "kind": "url",
          "mode": "read",
          "title": "example.com",
          "sourceURL": "https://example.com"
        }
        """
        let record = try JSONDecoder().decode(ShareInboxRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(record.id, id)
        XCTAssertNil(record.fallbackTitle)
        XCTAssertNil(record.previewImageFilename)
        XCTAssertNil(record.linkMetadataFetchedAt)
    }

    func testHomeProCardWeeklyPriceUsesAnnualPriceDividedByFiftyTwo() throws {
        var weekly = HomeProPricing.weeklyPrice(from: try XCTUnwrap(Decimal(string: "34.99")))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &weekly, 2, .plain)
        XCTAssertEqual(rounded, Decimal(string: "0.67"))
    }

    func testHomeProCardCopyFollowsAllEightRuntimeLanguages() {
        let manager = AppLanguageManager.shared
        let previousLanguage = manager.selectedLanguage
        defer { manager.select(previousLanguage) }

        for language in AppLanguage.allCases where language != .system {
            manager.select(language)
            let headline = AppLocalized("让每本 Kindle 都开口说话")
            let benefits = AppLocalized("Kindle 连续朗读 · 100+ 专业音色 · 8 种语言")
            let cta = String(format: AppLocalized("以 %@/年成为 Pro"), "PRICE")
            XCTAssertFalse(headline.isEmpty, "Missing headline for \(language.rawValue)")
            XCTAssertFalse(benefits.isEmpty, "Missing benefits for \(language.rawValue)")
            XCTAssertTrue(cta.contains("PRICE"), "Missing price placeholder for \(language.rawValue): \(cta)")
        }
    }

    func testKindlePlaybackAccessGateCoversReadAndExplainQuota() {
        XCTAssertFalse(
            KindlePlaybackAccessGate.canStart(
                mode: .read,
                isPro: false,
                listenRemaining: 0,
                explainRemaining: 3
            )
        )
        XCTAssertTrue(
            KindlePlaybackAccessGate.canStart(
                mode: .read,
                isPro: false,
                listenRemaining: 1,
                explainRemaining: 0
            )
        )
        XCTAssertFalse(
            KindlePlaybackAccessGate.canStart(
                mode: .explain,
                isPro: false,
                listenRemaining: 1200,
                explainRemaining: 0
            )
        )
        XCTAssertTrue(
            KindlePlaybackAccessGate.canStart(
                mode: .explain,
                isPro: true,
                listenRemaining: 0,
                explainRemaining: 0
            )
        )
    }

    func testEightLanguageCatalogIsCompleteAndFormatSafe() throws {
        let root = try catalog(named: "Localizable")
        XCTAssertEqual(root["sourceLanguage"] as? String, "zh-Hans")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let protectedTokens = ["CastReader", "Apple", "Google", "Safari", "StoreKit", "WebView", "Xcode", "Amazon", "EPUB", "PDF", "DOCX", "TXT", "URL", "SLA", "API", "HTTP"]

        for (key, rawEntry) in strings where !key.isEmpty {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], "Invalid entry: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "No localizations: \(key)")
            let expectedSignature = try formatSignature(key)

            for locale in translatedLocales {
                let rawLocalization = try XCTUnwrap(localizations[locale], "Missing \(locale): \(key)")
                let localization = try XCTUnwrap(rawLocalization as? [String: Any])
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(locale): \(key)")
                XCTAssertEqual(unit["state"] as? String, "translated", "Untranslated \(locale): \(key)")
                XCTAssertEqual(try formatSignature(value), expectedSignature, "Format mismatch \(locale): \(key) => \(value)")

                for token in protectedTokens where key.contains(token) {
                    XCTAssertTrue(value.contains(token), "Protected token \(token) changed in \(locale): \(key) => \(value)")
                }
            }
        }
    }

    func testInfoPlistCatalogCoversAllAppLocales() throws {
        let root = try catalog(named: "InfoPlist")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertEqual(Set(strings.keys), [
            "CFBundleName", "NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription"
        ])

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for locale in appLocales {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing \(locale): \(key)")
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(locale): \(key)")
            }
        }
    }

    func testCoreNavigationTerminologyIsNativeAndStable() throws {
        let root = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expected: [String: [String: String]] = [
            "首页": ["en": "Home", "zh-Hans": "首页", "ja": "ホーム", "es": "Inicio", "fr": "Accueil", "pt-BR": "Início", "it": "Home", "hi": "होम"],
            "文库": ["en": "Library", "zh-Hans": "文库", "ja": "ライブラリ", "es": "Biblioteca", "fr": "Bibliothèque", "pt-BR": "Biblioteca", "it": "Libreria", "hi": "लाइब्रेरी"],
            "设置": ["en": "Settings", "zh-Hans": "设置", "ja": "設定", "es": "Ajustes", "fr": "Réglages", "pt-BR": "Ajustes", "it": "Impostazioni", "hi": "सेटिंग्स"],
            "朗读": ["en": "Read Aloud", "zh-Hans": "朗读", "ja": "読み上げ", "es": "Leer en voz alta", "fr": "Lire à voix haute", "pt-BR": "Ler em voz alta", "it": "Leggi ad alta voce", "hi": "ज़ोर से पढ़ें"],
            "解读": ["en": "Explain", "zh-Hans": "解读", "ja": "解説", "es": "Explicar", "fr": "Expliquer", "pt-BR": "Explicar", "it": "Spiega", "hi": "व्याख्या"],
            "Kindle": ["en": "Kindle", "zh-Hans": "Kindle", "ja": "Kindle", "es": "Kindle", "fr": "Kindle", "pt-BR": "Kindle", "it": "Kindle", "hi": "Kindle"]
        ]

        for (key, locales) in expected {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for (locale, expectedValue) in locales {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertEqual(unit["value"] as? String, expectedValue, "Unexpected \(locale) term for \(key)")
            }
        }
    }

    func testProjectDeclaresAllEightKnownRegions() throws {
        let projectURL = repositoryRoot.appendingPathComponent("CastReader.xcodeproj/project.pbxproj")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw XCTSkip("Project source checks run on the host build machine")
        }
        let project = try String(
            contentsOf: projectURL,
            encoding: .utf8
        )
        for locale in appLocales {
            XCTAssertTrue(project.contains(locale), "Project does not declare \(locale)")
        }
    }

    // MARK: - Player control deck / Kindle surface stability

    func testKindleReaderSurfaceFreezesWhilePlayerVoiceOverlayIsPresented() {
        let stable = CGSize(width: 430, height: 690)
        let transient = CGSize(width: 453, height: 690)

        XCTAssertEqual(
            KindleReaderSurfaceContract.renderSize(
                measured: transient,
                stable: stable,
                isPlayerOverlayPresented: true
            ),
            stable,
            "Voice UI must not resize the Kindle WebView"
        )
        XCTAssertEqual(
            KindleReaderSurfaceContract.renderSize(
                measured: transient,
                stable: stable,
                isPlayerOverlayPresented: false
            ),
            transient,
            "Real reader layout changes still need to propagate"
        )
    }

    func testKindleVisualCandidateDriftCannotRestartPlaybackWithoutSemanticNavigation() {
        XCTAssertFalse(
            KindleExternalNavigationContract.shouldBeginResume(
                semanticSequenceAdvanced: false,
                hasActivePlayback: true,
                isReaderStable: true,
                isInternalTurnInFlight: false
            ),
            "OCR/preload candidate changes are not user page turns"
        )
        XCTAssertTrue(
            KindleExternalNavigationContract.shouldBeginResume(
                semanticSequenceAdvanced: true,
                hasActivePlayback: true,
                isReaderStable: true,
                isInternalTurnInFlight: false
            )
        )
        XCTAssertFalse(
            KindleExternalNavigationContract.shouldBeginResume(
                semanticSequenceAdvanced: true,
                hasActivePlayback: true,
                isReaderStable: true,
                isInternalTurnInFlight: true
            ),
            "An internal turn already in flight owns the transition"
        )
    }

    func testCachedAsyncImageRejectsStaleVoiceAvatarCompletion() {
        XCTAssertTrue(
            CachedAsyncImageLoadContract.shouldCommit(
                activeRequest: "https://cdn.example/voice-b.png",
                completedRequest: "https://cdn.example/voice-b.png",
                isCancelled: false
            )
        )
        XCTAssertFalse(
            CachedAsyncImageLoadContract.shouldCommit(
                activeRequest: "https://cdn.example/voice-b.png",
                completedRequest: "https://cdn.example/voice-a.png",
                isCancelled: false
            )
        )
        XCTAssertFalse(
            CachedAsyncImageLoadContract.shouldCommit(
                activeRequest: "https://cdn.example/voice-b.png",
                completedRequest: "https://cdn.example/voice-b.png",
                isCancelled: true
            )
        )
    }

    @MainActor
    func testPlaybackVoicePanelUsesOneNormalizedRootRequest() {
        let center = PlaybackVoicePanelCenter.shared
        center.dismiss()
        center.present(language: "ja-JP")
        XCTAssertTrue(center.isPresented)
        XCTAssertEqual(center.request?.language, "ja")
        center.dismiss()
        XCTAssertFalse(center.isPresented)
    }

    @MainActor
    func testExplainVoiceUsesTargetLanguageInsteadOfSourceLanguage() {
        let settings = AppSettings.shared
        let previous = settings.explainLanguage
        defer { settings.explainLanguage = previous }
        settings.explainLanguage = "es"

        let document = ReadingDocument(
            title: "Japanese source",
            sourceKind: .text,
            language: "ja",
            paragraphs: [ReadingParagraph(id: 0, text: "十分な長さの日本語本文です。", type: .paragraph)]
        )
        let vm = ExplainViewModel(document: document)
        XCTAssertEqual(vm.playbackLanguage, "es")
    }

    // MARK: - Unified eight-language import contract

    func testReadingSentenceContractCoversAllEightLanguages() {
        let samples: [String: String] = [
            "en": "First sentence. Second sentence!",
            "zh": "第一句话。第二句话！",
            "ja": "最初の文です。次の文です！",
            "es": "Primera frase. Segunda frase!",
            "fr": "Première phrase. Deuxième phrase !",
            "pt": "Primeira frase. Segunda frase!",
            "it": "Prima frase. Seconda frase!",
            "hi": "यह पहला वाक्य है। यह दूसरा वाक्य है॥"
        ]
        XCTAssertEqual(Set(samples.keys), Set(SupportedTTSLanguage.allCases.map(\.rawValue)))
        for (language, text) in samples {
            XCTAssertEqual(
                ReadingSentenceContract.segments(text).count,
                2,
                "\(language) must preserve both sentence units"
            )
        }
    }

    func testReadingSentenceContractPreservesJapaneseAndChineseVisualWraps() {
        XCTAssertEqual(
            ReadingSentenceContract.normalizeWhitespace("日\n本\n語です。", language: "ja"),
            "日本語です。"
        )
        XCTAssertEqual(
            ReadingSentenceContract.normalizeWhitespace("中\n文内容。", language: "zh"),
            "中文内容。"
        )
        XCTAssertEqual(
            ReadingSentenceContract.normalizeWhitespace("hello\nworld.", language: "en"),
            "hello world."
        )
    }

    func testImportedOCRHindiSelectionRequiresStrongIndependentEvidence() {
        let weakVision = LanguageDetector.Evidence(language: "en", confidence: 0.31, readableCharacterCount: 9)
        let hindi = LanguageDetector.Evidence(language: "hi", confidence: 0.98, readableCharacterCount: 48)
        XCTAssertTrue(ImportedOCRLanguageSelection.shouldRunHindiProbe(vision: weakVision))
        XCTAssertTrue(ImportedOCRLanguageSelection.shouldPreferHindi(
            vision: weakVision,
            hindi: hindi,
            hindiMeanConfidence: 82
        ))

        let strongEnglish = LanguageDetector.Evidence(language: "en", confidence: 0.97, readableCharacterCount: 180)
        XCTAssertFalse(ImportedOCRLanguageSelection.shouldRunHindiProbe(vision: strongEnglish))
        XCTAssertFalse(ImportedOCRLanguageSelection.shouldPreferHindi(
            vision: strongEnglish,
            hindi: LanguageDetector.Evidence(language: "hi", confidence: 0.7, readableCharacterCount: 10),
            hindiMeanConfidence: 42
        ))
    }

    func testPDFRenderingModeSeparatesTextLayerFromOCRReflow() {
        let native = ReadingDocument(
            title: "Native PDF",
            sourceKind: .pdf,
            paragraphs: [ReadingParagraph(
                id: 0,
                text: "Searchable text.",
                pdfPageIndex: 0,
                pdfRange: NSRange(location: 0, length: 16)
            )]
        )
        XCTAssertTrue(native.usesNativePDFRendering)
        XCTAssertFalse(native.usesNativeTextRendering)

        let scanned = ReadingDocument(
            title: "Scanned PDF",
            sourceKind: .pdf,
            language: "hi",
            paragraphs: [ReadingParagraph(id: 0, text: "यह स्कैन किया गया पाठ है।", pdfPageIndex: 0)]
        )
        XCTAssertFalse(scanned.usesNativePDFRendering)
        XCTAssertTrue(scanned.usesNativeTextRendering)
    }

    // MARK: - 微信读书 live Canvas 合同

    func testWeReadAvailabilityIsGlobalWithoutLocaleRestrictions() {
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .simplifiedChinese,
            systemLanguageCode: "en",
            timeZoneIdentifier: "America/Los_Angeles"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .system,
            systemLanguageCode: "zh-Hans",
            timeZoneIdentifier: "Europe/Paris"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .english,
            systemLanguageCode: "en",
            timeZoneIdentifier: "Asia/Shanghai"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .japanese,
            systemLanguageCode: "ja",
            timeZoneIdentifier: "Asia/Tokyo"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .french,
            systemLanguageCode: "fr",
            timeZoneIdentifier: "Europe/Paris"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .hindi,
            systemLanguageCode: "hi",
            timeZoneIdentifier: "Asia/Kolkata"
        ))
    }

    func testDedicatedBookRailsDoNotDuplicateInHomeContinue() {
        XCTAssertFalse(HomeContinueContract.includes(.kindle))
        XCTAssertFalse(HomeContinueContract.includes(.weread))
        XCTAssertTrue(HomeContinueContract.includes(.web))
        XCTAssertTrue(HomeContinueContract.includes(.pdf))
    }

    func testWeReadBookAndSingleTurnContracts() {
        let readerURL = "https://weread.qq.com/web/reader/abcdef"
        XCTAssertEqual(WeReadBookValidator.usableReaderURL(readerURL), readerURL)
        XCTAssertNil(WeReadBookValidator.usableReaderURL("https://weread.qq.com/web/shelf"))
        XCTAssertNil(WeReadBookValidator.usableReaderURL("https://example.com/web/reader/a"))
        XCTAssertEqual(
            WeReadBookValidator.stableID(bookID: "abcdef", readerURL: readerURL, title: "Book"),
            "weread:abcdef"
        )

        let before = WeReadPageFingerprint.make(first: "第一页", last: "结尾", progress: "10%", route: readerURL)
        let after = WeReadPageFingerprint.make(first: "第二页", last: "新结尾", progress: "11%", route: readerURL)
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(WeReadPageTurnContract.canCommit(previous: before, next: after, actionID: "one-semantic-click"))
        XCTAssertFalse(WeReadPageTurnContract.canCommit(previous: before, next: before, actionID: "one-semantic-click"))
        XCTAssertFalse(WeReadPageTurnContract.canCommit(previous: before, next: after, actionID: ""))
        XCTAssertEqual(WeReadPageTurnContract.semanticNextLabels(), ["下一页"])
        XCTAssertEqual(WeReadPageTurnContract.manualRestartDelayNanoseconds, 600_000_000)

        let evidenceBefore = WeReadPageEvidence(
            contentFingerprint: before,
            layoutFingerprint: "layout-a",
            columnFingerprint: "0:0|1:900",
            canvasEpoch: 4
        )
        XCTAssertFalse(WeReadPageTurnContract.canCommit(
            previous: evidenceBefore,
            next: evidenceBefore,
            actionID: "one-semantic-click"
        ))
        XCTAssertTrue(WeReadPageTurnContract.canCommit(
            previous: evidenceBefore,
            next: WeReadPageEvidence(
                contentFingerprint: before,
                layoutFingerprint: "layout-a",
                columnFingerprint: "0:1800|1:2700",
                canvasEpoch: 5
            ),
            actionID: "one-semantic-click"
        ))
        XCTAssertFalse(WeReadPageTurnContract.canCommit(
            previous: evidenceBefore,
            next: WeReadPageEvidence(
                contentFingerprint: before,
                layoutFingerprint: "layout-b",
                columnFingerprint: "0:0|1:900",
                canvasEpoch: 5
            ),
            actionID: ""
        ))

        XCTAssertTrue(WeReadContinuousPageHandoffContract.shouldArm(
            sourceFingerprint: before,
            currentFingerprint: before,
            hasPreparedAudio: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            audioIsPlaying: true
        ))
        XCTAssertFalse(WeReadContinuousPageHandoffContract.shouldArm(
            sourceFingerprint: before,
            currentFingerprint: after,
            hasPreparedAudio: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            audioIsPlaying: true
        ))
        XCTAssertTrue(WeReadContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "tail",
            predecessorSegmentID: "tail",
            remainingAudioSeconds: 0.9,
            playbackRate: 1.5
        ))
        XCTAssertFalse(WeReadContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "other",
            predecessorSegmentID: "tail",
            remainingAudioSeconds: 0,
            playbackRate: 1
        ))
        XCTAssertTrue(WeReadContinuousPageHandoffContract.canReleasePreparedAudio(
            sourceFingerprint: before,
            previousFingerprint: before,
            predictedContentFingerprint: after,
            visibleContentFingerprint: after,
            predictedText: ["下一页正文"],
            visibleText: ["下一页正文"],
            preparedVoiceID: "zf_xiaobei",
            selectedVoiceID: "zf_xiaobei"
        ))
        XCTAssertFalse(WeReadContinuousPageHandoffContract.canReleasePreparedAudio(
            sourceFingerprint: before,
            previousFingerprint: before,
            predictedContentFingerprint: after,
            visibleContentFingerprint: "unexpected-page",
            predictedText: ["这是预测的下一页内容，连续文字必须能够对应。"],
            visibleText: ["这是完全不同的一页，不能释放错误的预加载音频。"],
            preparedVoiceID: "zf_xiaobei",
            selectedVoiceID: "zf_xiaobei"
        ))

        let mapped = WeReadCrossPageSpeechContract.boundarySegment(
            segmentTexts: ["第一句。", "这句话从本页开始并跨到下一页才结束。"],
            boundaryUTF16Offset: ("第一句。这句话从本页开始" as NSString).length
        )
        XCTAssertEqual(mapped?.sequence, 1)
        XCTAssertEqual(
            mapped?.fraction ?? -1,
            Double(("这句话从本页开始" as NSString).length) /
                Double(("这句话从本页开始并跨到下一页才结束。" as NSString).length),
            accuracy: 0.0001
        )
        let cue = WeReadBoundaryAudioCue(
            segmentID: "boundary-sentence",
            segmentSequence: 1,
            boundaryTime: 2.4,
            segmentDuration: 4.8
        )
        XCTAssertTrue(WeReadCrossPageSpeechContract.shouldRequestTurn(
            currentSegmentID: "boundary-sentence",
            cue: cue,
            currentTime: 1.9,
            playbackRate: 1,
            leadSeconds: 0.6
        ))
        XCTAssertFalse(WeReadCrossPageSpeechContract.shouldRequestTurn(
            currentSegmentID: "another-sentence",
            cue: cue,
            currentTime: 2.4,
            playbackRate: 1,
            leadSeconds: 0.6
        ))

        // The source-DOM cursor, not speculative audio readiness, is the
        // authority for exactly-once speech across a visual page boundary.
        // The first four UTF-16 code units on the confirmed page were already
        // spoken by the old page's complete natural-sentence audio item.
        let partiallyConsumed = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 20,
                    sourceUTF16End: 29,
                    text: "已经读过的新页内容。"
                ),
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 1,
                    sourceParagraphIndex: 8,
                    sourceUTF16Start: 0,
                    sourceUTF16End: 5,
                    text: "下一段。"
                ),
            ],
            through: WeReadConsumedTextCursor(sourceParagraphIndex: 7, sourceUTF16End: 24)
        )
        XCTAssertEqual(partiallyConsumed.texts, ["的新页内容。", "下一段。"])
        XCTAssertEqual(partiallyConsumed.carryParagraphIndex, 0)
        XCTAssertEqual(partiallyConsumed.carryUTF16Length, 4)

        // Preserve visual paragraph indices even when the carry sentence has
        // consumed the entire first slice. The next TTS request must begin at
        // paragraph 1 rather than rebuilding the page from paragraph 0.
        let fullyConsumed = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 24,
                    sourceUTF16End: 28,
                    text: "已读完。"
                ),
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 1,
                    sourceParagraphIndex: 8,
                    sourceUTF16Start: 0,
                    sourceUTF16End: 5,
                    text: "真正新句。"
                ),
            ],
            through: WeReadConsumedTextCursor(sourceParagraphIndex: 7, sourceUTF16End: 28)
        )
        XCTAssertEqual(fullyConsumed.texts, ["", "真正新句。"])
        XCTAssertEqual(fullyConsumed.carryParagraphIndex, 0)
        XCTAssertEqual(fullyConsumed.carryUTF16Length, 4)
    }

    func testWeReadExplainOwnsItsPageLifecycle() {
        // QuickRead annotations and status updates can repaint the Canvas, but
        // they are not navigation and must not restart the explanation.
        for reason in ["canvas", "resize", "mutation", "foreground"] {
            XCTAssertFalse(WeReadExplainPageEventContract.shouldHandleVisualChange(
                isReadMode: false,
                reason: reason,
                hasPendingSemanticTurn: false,
                hasPendingManualTurn: false,
                refreshActive: false
            ))
        }

        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "manual-intent",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: false,
            refreshActive: false
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "canvas",
            hasPendingSemanticTurn: true,
            hasPendingManualTurn: false,
            refreshActive: false
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "canvas",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: true,
            refreshActive: false
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "theme",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: false,
            refreshActive: true
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: true,
            reason: "canvas",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: false,
            refreshActive: false
        ))

        XCTAssertFalse(WeReadExplainPageEventContract.shouldResumeExplanation(isAutomaticTurn: false))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldResumeExplanation(isAutomaticTurn: true))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldResumeExplanation(
            isAutomaticTurn: false,
            resumeAlreadyArmed: true
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldResumeExplanation(
            isAutomaticTurn: false,
            wasLiveExplaining: true
        ))
    }

    func testWeReadExplainPrefetchRequiresExactVisiblePageAndCurrentSettings() {
        let baseline = (
            source: "page-a",
            predicted: "page-b-content",
            voice: "zf_xiaoxiao",
            depth: "standard"
        )
        XCTAssertTrue(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: baseline.predicted,
            predictedText: ["预测页面正文"],
            visibleText: ["预测页面正文"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        let predictedPage = "下一页从这一句开始。" + String(repeating: "微信读书分页正文连续内容。", count: 12)
        let visiblePage = predictedPage + String(repeating: "真实页面尾部多出的正文。", count: 3)
        let boundaryMatch = WeReadSpeculativeTextContract.evaluate(
            predicted: [predictedPage],
            visible: [visiblePage]
        )
        XCTAssertTrue(boundaryMatch.isCompatible)
        XCTAssertEqual(boundaryMatch.predictedCoverage, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(boundaryMatch.visibleCoverage, 0.70)
        XCTAssertTrue(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: "different-boundary-fingerprint",
            predictedText: [predictedPage],
            visibleText: [visiblePage],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        XCTAssertFalse(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: "a-different-page",
            predictedText: ["预测页面包含一段足够长的连续正文，用于验证下一页。"],
            visibleText: ["错误页面包含完全不同的内容，不允许命中推测缓存。"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        XCTAssertFalse(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: baseline.predicted,
            predictedText: ["预测页面正文"],
            visibleText: ["预测页面正文"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: "zf_xiaoyi",
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        XCTAssertFalse(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: baseline.predicted,
            predictedText: ["预测页面正文"],
            visibleText: ["预测页面正文"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: "deep"
        ))
    }

    func testWeReadViewportCropIsPredictedBeforeLoadAndCalibratedFromVisibleText() {
        let phone = CGSize(width: 390, height: 700)
        let predicted = WeReadViewportCrop.predicted(for: phone)
        XCTAssertEqual(predicted.widthScale, 1.19, accuracy: 0.001)
        XCTAssertEqual(predicted.offsetX, -37.05, accuracy: 0.01)
        let initialFrame = predicted.webViewFrame(for: phone)
        XCTAssertEqual(initialFrame.origin.x, predicted.offsetX, accuracy: 0.001)
        XCTAssertEqual(initialFrame.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(initialFrame.width, phone.width * 1.19, accuracy: 0.001)
        XCTAssertEqual(initialFrame.height, phone.height, accuracy: 0.001)
        XCTAssertEqual(WeReadViewportCrop.compactReaderBreakpoint, 700)
        XCTAssertEqual(WeReadViewportCrop.compactPageHorizontalPadding, 50)
        XCTAssertEqual(WeReadViewportCrop.compactOpeningWidthScale, 1.19)

        let calibrated = WeReadViewportCrop.calibrated(
            for: phone,
            layoutWidthScale: predicted.widthScale,
            contentLeftRatio: 0.16,
            contentRightRatio: 0.84
        )
        XCTAssertNotNil(calibrated)
        // Runtime text bounds are diagnostics only and must never resize or
        // translate WKWebView after the opening navigation.
        XCTAssertEqual(calibrated?.widthScale ?? 0, predicted.widthScale, accuracy: 0.001)
        XCTAssertEqual(calibrated?.offsetX ?? 1, predicted.offsetX, accuracy: 0.01)

        XCTAssertNil(WeReadViewportCrop.calibrated(
            for: phone,
            layoutWidthScale: predicted.widthScale,
            contentLeftRatio: 0.49,
            contentRightRatio: 0.51
        ))
        XCTAssertEqual(WeReadInitialPlaybackContract.stabilityDelayNanoseconds, 1_800_000_000)
    }

    func testWeReadPlaybackResumeFindsCurrentSentenceAcrossViewportReflow() {
        let anchor = WeReadPlaybackResumeAnchor(
            segmentText: "所谓的“社会话题性”，在她的作品里并不是目的。",
            sourceParagraphText: "但金爱烂的可贵之处在于，所谓的社会话题性，在她的作品里并不是目的，而是场景中的一个因素。",
            segmentProgress: 0.43,
            wasPlaying: true
        )
        let paragraphs = [
            ReadingParagraph(id: 0, text: "上一段已经结束。", type: .paragraph),
            ReadingParagraph(id: 1, text: "所谓的社会话题性，在她的作品里并不是目的。", type: .paragraph),
            ReadingParagraph(id: 2, text: "而是场景中的一个因素。", type: .paragraph),
        ]
        XCTAssertEqual(WeReadPlaybackResumeContract.paragraphIndex(in: paragraphs, anchor: anchor), 1)
        XCTAssertTrue(WeReadPlaybackResumeContract.segmentMatches(
            "所谓的社会话题性，在她的作品里并不是目的。",
            anchor: anchor
        ))
        XCTAssertFalse(WeReadPlaybackResumeContract.segmentMatches("完全不同的一句话。", anchor: anchor))
    }

    func testWeReadBackgroundLifecycleNeverReloadsForTransientForegroundProbeFailure() {
        XCTAssertFalse(WeReadBackgroundLifecycleContract.shouldReload(
            probeSucceeded: false,
            webContentProcessTerminationObserved: false
        ))
        XCTAssertFalse(WeReadBackgroundLifecycleContract.shouldReload(
            probeSucceeded: true,
            webContentProcessTerminationObserved: false
        ))
        XCTAssertTrue(WeReadBackgroundLifecycleContract.shouldReload(
            probeSucceeded: false,
            webContentProcessTerminationObserved: true
        ))
        XCTAssertFalse(WeReadBackgroundLifecycleContract.shouldScheduleRefreshFallback(
            applicationIsActive: false
        ))
        XCTAssertTrue(WeReadBackgroundLifecycleContract.shouldScheduleRefreshFallback(
            applicationIsActive: true
        ))
        XCTAssertEqual(WeReadBackgroundLifecycleContract.foregroundProbeDelays.count, 3)
        XCTAssertEqual(WeReadBackgroundLifecycleContract.foregroundProbeTimeout, 0.8)
    }

    func testWeReadRejectsGenericCoverAltAsBookTitle() {
        let generic = WeReadBook(
            id: "weread:bad",
            title: "书籍封面",
            author: "",
            coverURL: nil,
            readerURL: "https://weread.qq.com/web/reader/abcdef",
            progressLabel: "",
            bookID: "abcdef",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastPageFingerprint: nil,
            lastReaderURL: nil
        )
        XCTAssertFalse(WeReadBookValidator.isLikelyLibraryBook(generic))
        XCTAssertTrue(WeReadWebScripts.libraryScan.contains("bookData.author"))
        XCTAssertTrue(WeReadWebScripts.libraryScan.contains(":scope > .title"))
    }

    func testWeReadBookEntryRecoveryRetriesCanonicalBeforeShelfScan() {
        let canonical = "https://weread.qq.com/web/reader/book123"
        let resume = "https://weread.qq.com/web/reader/book123?chapter=9"

        XCTAssertEqual(
            WeReadBookEntryRecoveryContract.localFallbackURL(
                failedURL: resume,
                canonicalURL: canonical,
                resumeURL: resume
            ),
            canonical
        )
        XCTAssertNil(WeReadBookEntryRecoveryContract.localFallbackURL(
            failedURL: canonical,
            canonicalURL: canonical,
            resumeURL: resume
        ))
        XCTAssertFalse(WeReadBookEntryRecoveryContract.shouldDiscardResumeURL(
            oldCanonicalURL: canonical,
            newCanonicalURL: canonical,
            resumeURL: resume
        ))
        XCTAssertTrue(WeReadBookEntryRecoveryContract.shouldDiscardResumeURL(
            oldCanonicalURL: canonical,
            newCanonicalURL: "https://weread.qq.com/web/reader/book123-new",
            resumeURL: resume
        ))
    }

    func testWeReadBridgePreservesNoPrivateAPIBoundary() {
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("preRenderContainer"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("renderTargetContainer"))
        XCTAssertTrue(WeReadWebScripts.canvasIntercept.contains("CanvasRenderingContext2D.prototype.clearRect"))
        XCTAssertTrue(WeReadWebScripts.canvasIntercept.contains("effectiveArea>=area*.45"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("han/sample.length>=.45"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains(".readerFooter_button:last-child"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("clean(candidate.textContent)==='下一页'"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("contentFingerprint"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("resolveSegmentRange"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("computeSourceSpan"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("manualTurnIntent"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("wereadLayoutStable"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("resumeAfterForeground"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("relayout(a)"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("document.addEventListener('pointerdown',manualTurnIntent,true)"))
        XCTAssertFalse(WeReadWebScripts.readerBridge.contains("${columns}|${progress}"))
        XCTAssertFalse(WeReadWebScripts.readerBridge.contains("chapterInfos"))
        XCTAssertFalse(WeReadWebScripts.readerBridge.contains("decodeChapterResponse"))
    }

    func testWeReadUIStringsCoverAllEightRuntimeLanguages() {
        let keys = [
            "已同步的微信读书书架",
            "绑定微信读书",
            "登录后同步书架与阅读进度",
            "正在扫描微信读书书架…（%d）",
            "请先登录微信读书，再点同步。",
            "微信读书书籍链接已失效，请重新登录并同步书架。",
            "微信读书登录已失效，请重新登录后继续。",
            "书架中没有找到这本书，请重新同步微信读书书架。"
        ]
        for language in AppLanguage.allCases where language != .system {
            guard let localization = language.bundleLocalization,
                  let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return XCTFail("Missing runtime bundle for \(language.rawValue)")
            }
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertFalse(value.isEmpty, "Empty WeRead translation for \(language.rawValue): \(key)")
                if language != .simplifiedChinese {
                    XCTAssertNotEqual(value, key, "Missing WeRead translation for \(language.rawValue): \(key)")
                }
            }
        }
    }
}

@MainActor
private final class KindleTestMessageCollector: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any] {
            messages.append(payload)
        }
    }
}
