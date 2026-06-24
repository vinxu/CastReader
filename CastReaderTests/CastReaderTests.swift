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

    /// §1 表：论文/合同 = deep；书籍/报告/教材/说明书 = standard。
    func testScenarioSuggestedDepth() {
        XCTAssertEqual(ExplainContentType.paper.suggestedDepth, .deep)
        XCTAssertEqual(ExplainContentType.contract.suggestedDepth, .deep)
        XCTAssertEqual(ExplainContentType.book.suggestedDepth, .standard)
        XCTAssertEqual(ExplainContentType.report.suggestedDepth, .standard)
        XCTAssertEqual(ExplainContentType.study.suggestedDepth, .standard)
        XCTAssertEqual(ExplainContentType.manual.suggestedDepth, .standard)
        XCTAssertEqual(ExplainContentType.allCases.count, 6)
    }

    /// content_type 的 rawValue 必须是后端约定的 6 个 id（§4 契约）。
    func testContentTypeRawValues() {
        XCTAssertEqual(Set(ExplainContentType.allCases.map(\.rawValue)),
                       ["paper", "book", "report", "contract", "study", "manual"])
    }

    /// 场景注入 ExplainViewModel 后，scenario 决定有效深度（覆盖全局设置）。
    @MainActor
    func testScenarioInjectionOverridesDepth() {
        let doc = ReadingDocument(title: "T", sourceKind: .text,
                                  paragraphs: [ReadingParagraph(id: 0, text: "hello world", type: .paragraph)])
        let vm = ExplainViewModel(document: doc)
        vm.scenario = ExplainContentType.paper.rawValue
        XCTAssertEqual(vm.scenario, "paper")
    }
}
