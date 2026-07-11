//
//  CastReaderTests.swift
//  CastReaderTests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
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

        let rawTurn = try await webView.evaluateJavaScript("window.__crKindleTurnPage('next')")
        let turnJSON = try XCTUnwrap(rawTurn as? String)
        let turnData = try XCTUnwrap(turnJSON.data(using: .utf8))
        let turn = try XCTUnwrap(JSONSerialization.jsonObject(with: turnData) as? [String: Any])
        XCTAssertEqual(turn["strategy"] as? String, "native-chevron")
        XCTAssertEqual(turn["controlVisible"] as? Bool, false)
        let clickCount = try await webView.evaluateJavaScript("window.hiddenChevronClickCount") as? Int
        XCTAssertEqual(clickCount, 1, "scrubber 不存在时应尝试 Kindle 的隐藏 chevron")
        let keyboardCount = try await webView.evaluateJavaScript("window.hiddenKeyboardTurnCount") as? Int
        XCTAssertEqual(keyboardCount, 0, "chevron 可用时不得提前发送 keyboard")

        _ = try await webView.evaluateJavaScript(
            """
            (function() {
              document.getElementById('kr-chevron-right').remove();
              document.body.style.minHeight = '700px';
              window.edgeTapCount = 0;
              document.body.addEventListener('click', function() { window.edgeTapCount += 1; });
            })()
            """
        )
        let rawTapTurn = try await webView.evaluateJavaScript("window.__crKindleTurnPage('next')")
        let tapJSON = try XCTUnwrap(rawTapTurn as? String)
        let tapData = try XCTUnwrap(tapJSON.data(using: .utf8))
        let tapTurn = try XCTUnwrap(JSONSerialization.jsonObject(with: tapData) as? [String: Any])
        XCTAssertEqual(tapTurn["strategy"] as? String, "native-tap-zone")
        let edgeTapCount = try await webView.evaluateJavaScript("window.edgeTapCount") as? Int
        XCTAssertEqual(edgeTapCount, 1)

        _ = try await webView.evaluateJavaScript(
            """
            (function() {
              var scrubber = document.createElement('ion-range');
              scrubber.id = 'kr-scrubber-bar';
              Object.defineProperty(scrubber, 'value', { value: 10, writable: true, configurable: true });
              window.scrubberInputCount = 0;
              window.scrubberChangeCount = 0;
              scrubber.addEventListener('ionInput', function() { window.scrubberInputCount += 1; });
              scrubber.addEventListener('ionChange', function() { window.scrubberChangeCount += 1; });
              document.body.appendChild(scrubber);
            })()
            """
        )
        let rawScrubberTurn = try await webView.evaluateJavaScript("window.__crKindleTurnPage('next')")
        let scrubberJSON = try XCTUnwrap(rawScrubberTurn as? String)
        let scrubberData = try XCTUnwrap(scrubberJSON.data(using: .utf8))
        let scrubberTurn = try XCTUnwrap(JSONSerialization.jsonObject(with: scrubberData) as? [String: Any])
        XCTAssertEqual(scrubberTurn["strategy"] as? String, "native-scrubber")
        XCTAssertEqual(scrubberTurn["dispatchCount"] as? Int, 1)
        let inputCount = try await webView.evaluateJavaScript("window.scrubberInputCount") as? Int
        let changeCount = try await webView.evaluateJavaScript("window.scrubberChangeCount") as? Int
        let keyboardCountAfterScrubber = try await webView.evaluateJavaScript("window.hiddenKeyboardTurnCount") as? Int
        XCTAssertEqual(inputCount, 1)
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(keyboardCountAfterScrubber, 0, "scrubber 可用时不得再发送 keyboard")
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

@MainActor
private final class KindleTestMessageCollector: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any] {
            messages.append(payload)
        }
    }
}
