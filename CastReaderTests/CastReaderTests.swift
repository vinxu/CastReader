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

    func testSpanishWordTimestampCapabilityAndPerSegmentFallback() {
        XCTAssertEqual(SupportedTTSLanguage.spanish.timestampMode, "word")
        XCTAssertEqual(SupportedTTSLanguage.english.timestampMode, "word")
        for language in [SupportedTTSLanguage.chinese, .japanese, .french, .brazilianPortuguese, .italian, .hindi] {
            XCTAssertEqual(language.timestampMode, "segment")
        }

        func timestamps(_ words: [String]) -> [TTSTimestamp] {
            words.enumerated().map {
                TTSTimestamp(word: $0.element, startTime: Double($0.offset), endTime: Double($0.offset + 1))
            }
        }
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "El rápido zorro español",
            timestamps: timestamps(["El", "rápido", "zorro", "español"])
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "El rápido zorro español",
            timestamps: timestamps(["El", "rápido"])
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "Esta respuesta contiene muchas palabras diferentes",
            timestamps: timestamps(["Esta respuesta contiene"])
        ))
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
