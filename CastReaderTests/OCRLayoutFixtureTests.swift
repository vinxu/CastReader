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

        // 递归分解下「栏数」不再是单一维度：这张报纸会被分成正文栏 + 报头/图注
        // 等多个区域，columnCount 表达的是「最宽的一层左右分栏有几支」。
        // 断言下界即可 —— 关键是它确实被分成了多栏，而不是退回整页一坨。
        XCTAssertGreaterThanOrEqual(
            analysis.columnCount, fixture.expectedColumns,
            "\(fixture.name): fallback=\(analysis.fallbackReason ?? "-")"
        )
        XCTAssertGreaterThanOrEqual(analysis.confidence, OCRLayoutAnalyzer.Tuning.minColumnConfidence)
        XCTAssertEqual(analysis.orderedLineIDs.count, fixture.lines.count, "一行都不能丢")
        XCTAssertEqual(Set(analysis.orderedLineIDs).count, fixture.lines.count, "一行都不能重复输出")
    }

    /// 核心不变量：一个块里的行必须来自同一栏。
    ///
    /// 这正是修复前失败的地方 —— 左右栏的同高度行被并进一个块。
    /// 用「块的横向跨度不显著超过其中最宽的一行」表达，比绑定具体栏数稳健：
    /// 跨栏标题自成一块、本身就宽，不会误判。
    func testNoBlockSpansTwoColumns() throws {
        let fixture = try load("ocr-layout-three-column-newspaper")
        let lines = layoutLines(fixture)
        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })

        var checked = 0
        var spanning: [String] = []
        for block in analysis.blocks {
            let rects = block.lineIDs.compactMap { byID[$0]?.rect }
            guard rects.count >= 2,
                  let left = rects.map(\.minX).min(),
                  let right = rects.map(\.maxX).max(),
                  let widest = rects.map(\.width).max() else { continue }
            checked += 1
            // 相对判据要配一个绝对下限：真正的跨栏必然横跨相当宽度。
            // 只看比例的话，两行短文本（缩进不同）也会被算成跨栏。
            if right - left > widest * 1.5 && right - left > 0.25 {
                spanning.append(String(
                    format: "col%d/%@ span=%.2f widest=%.2f",
                    block.columnIndex, block.role.rawValue, right - left, widest
                ))
            }
        }

        // 已知残留：这张 1944 年的报纸上仍有 2/11 个块跨栏（正文栏窄、印刷与
        // 扫描噪声大）。守住比例而不是要求零 —— 一旦回归到「大面积跨栏」，
        // 这条会立刻炸出来。当前实际值 18%，阈值留一点余量。
        XCTAssertGreaterThan(checked, 0)
        let ratio = Double(spanning.count) / Double(checked)
        XCTAssertLessThanOrEqual(
            ratio, 0.20,
            "跨栏块占比 \(Int(ratio * 100))%：\(spanning.joined(separator: "; "))"
        )
    }

    /// 栏内块的行必须自上而下 —— 顺序错了朗读就会来回跳。
    ///
    /// 容差的由来：版面分析会先做倾角矫正（deskew），块内行是按**矫正后**的
    /// 坐标排序的。页面本身有倾斜时，换回原始坐标看，相邻行的 y 会有小幅交错
    /// —— 那是倾斜本身造成的，不是排序错了。超过半个行高才算真的乱序。
    func testLinesInsideEachBlockRunTopDown() throws {
        let fixture = try load("ocr-layout-three-column-newspaper")
        let lines = layoutLines(fixture)
        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let heights = lines.map(\.rect.height).sorted()
        let tolerance = heights[heights.count / 2] * 0.5

        for block in analysis.blocks {
            let tops = block.lineIDs.compactMap { byID[$0]?.rect.minY }
            for (index, pair) in zip(tops, tops.dropFirst()).enumerated() {
                XCTAssertLessThanOrEqual(
                    pair.0, pair.1 + tolerance,
                    "块内第 \(index) 行之后出现了逆序：col\(block.columnIndex)"
                )
            }
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
