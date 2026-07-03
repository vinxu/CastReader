//
//  CastReaderTests.swift
//  CastReaderTests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
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
}
