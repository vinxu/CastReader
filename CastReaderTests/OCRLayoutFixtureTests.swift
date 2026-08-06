//
//  OCRLayoutFixtureTests.swift
//  CastReaderTests
//
//  真实报纸照片的版面回归集。
//
//  fixture 里**只有几何**（Vision 行 bbox），文本不入库：报纸正文有版权，
//  而版面分析本来就只吃几何。样本图片同样不入 git，重新生成见
//  docs/照片OCR版面理解-产品与技术方案.md。
//

import XCTest
@testable import CastReader

final class OCRLayoutFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Line: Decodable {
            let id: Int
            let x: CGFloat
            let y: CGFloat
            let w: CGFloat
            let h: CGFloat
            /// 原始行的字符数（内容本身不保存）。
            let n: Int
        }
        let name: String
        let source: String
        let expectedColumns: Int
        let lines: [Line]
    }

    private func load(_ name: String) throws -> Fixture {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name).json not bundled")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func layoutLines(_ fixture: Fixture) -> [OCRLayoutLine] {
        fixture.lines.map {
            OCRLayoutLine(
                id: $0.id,
                text: String(repeating: "x", count: max(1, min($0.n, 60))),
                rect: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)
            )
        }
    }

    // MARK: - 三栏报纸

    func testRealThreeColumnNewspaperKeepsColumnStructure() throws {
        let fixture = try load("ocr-layout-three-column-newspaper")
        let analysis = OCRLayoutAnalyzer.analyze(lines: layoutLines(fixture))

        XCTAssertEqual(analysis.columnCount, fixture.expectedColumns,
                       "\(fixture.name): fallback=\(analysis.fallbackReason ?? "-")")
        XCTAssertGreaterThanOrEqual(analysis.confidence, OCRLayoutAnalyzer.Tuning.minColumnConfidence)
        XCTAssertEqual(analysis.orderedLineIDs.count, fixture.lines.count, "一行都不能丢")
        XCTAssertEqual(Set(analysis.orderedLineIDs).count, fixture.lines.count, "一行都不能重复输出")
    }

    /// 核心不变量：一个栏内块的所有行必须落在同一列里。
    /// 这正是修复前失败的地方 —— 左右栏的同高度行被并进一个块。
    func testNoBlockSpansTwoColumns() throws {
        let fixture = try load("ocr-layout-three-column-newspaper")
        let lines = layoutLines(fixture)
        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let columns = analysis.columnRanges
        XCTAssertEqual(columns.count, 3)

        for block in analysis.blocks where block.columnIndex >= 0 {
            let owners = Set(block.lineIDs.compactMap { id -> Int? in
                guard let rect = byID[id]?.rect else { return nil }
                let center = rect.midX
                return columns.firstIndex { $0.contains(center) }
                    ?? columns.indices.min {
                        abs(midpoint(columns[$0]) - center) < abs(midpoint(columns[$1]) - center)
                    }
            })
            XCTAssertEqual(owners.count, 1,
                           "块 col\(block.columnIndex)/\(block.role.rawValue) 横跨了 \(owners.count) 列")
        }
    }

    /// 栏内块的行必须自上而下 —— 顺序错了朗读就会来回跳。
    func testLinesInsideEachBlockRunTopDown() throws {
        let fixture = try load("ocr-layout-three-column-newspaper")
        let lines = layoutLines(fixture)
        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })

        for block in analysis.blocks {
            let tops = block.lineIDs.compactMap { byID[$0]?.rect.minY }
            XCTAssertEqual(tops, tops.sorted(), "块内行序必须自上而下：col\(block.columnIndex)")
        }
    }

    // MARK: - 倾斜单栏

    /// 手持拍摄、约 12° 倾斜的单栏页面不能被误判成多栏。
    func testSkewedSingleColumnIsNotSplit() throws {
        let fixture = try load("ocr-layout-skewed-single-column")
        let analysis = OCRLayoutAnalyzer.analyze(lines: layoutLines(fixture))

        XCTAssertEqual(analysis.columnCount, 1, "倾斜不该被当成分栏，fallback=\(analysis.fallbackReason ?? "-")")
        XCTAssertEqual(analysis.orderedLineIDs.count, fixture.lines.count)
    }

    private func midpoint(_ range: ClosedRange<CGFloat>) -> CGFloat {
        (range.lowerBound + range.upperBound) / 2
    }
}
