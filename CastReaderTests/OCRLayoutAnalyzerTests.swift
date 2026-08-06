//
//  OCRLayoutAnalyzerTests.swift
//  CastReaderTests
//
//  照片版面理解的离线回归集：列检测、阅读顺序、角色、行重建。
//  全部用合成 bbox，不依赖 Vision，确定性可重跑。
//
//  用例来自真实报纸照片实测（见 docs/照片OCR版面理解-产品与技术方案.md）。
//

import XCTest
@testable import CastReader

final class OCRLayoutAnalyzerTests: XCTestCase {

    // MARK: - Fixtures

    /// layout 坐标（原点左上）。
    private func line(
        _ id: Int,
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 0.012
    ) -> OCRLayoutLine {
        OCRLayoutLine(id: id, text: text, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    /// 三栏报纸：列 [0.10,0.35] [0.38,0.63] [0.66,0.91]，栏缝 0.03 宽。
    private func threeColumnLines(rowsPerColumn: Int = 20) -> [OCRLayoutLine] {
        let columnX: [CGFloat] = [0.10, 0.38, 0.66]
        var lines: [OCRLayoutLine] = []
        var id = 0
        for (columnIndex, x) in columnX.enumerated() {
            for row in 0..<rowsPerColumn {
                lines.append(line(
                    id,
                    "c\(columnIndex)r\(row)",
                    x: x,
                    y: 0.20 + CGFloat(row) * 0.03,
                    width: 0.25
                ))
                id += 1
            }
        }
        return lines
    }

    private func texts(_ analysis: OCRLayoutAnalysis, in lines: [OCRLayoutLine]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.text) })
        return analysis.orderedLineIDs.compactMap { byID[$0] }
    }

    // MARK: - 列检测

    func testThreeColumnNewspaperIsDetected() {
        let lines = threeColumnLines()
        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)

        XCTAssertEqual(analysis.columnCount, 3, "三栏报纸必须识别为 3 栏，fallback=\(analysis.fallbackReason ?? "-")")
        XCTAssertNil(analysis.fallbackReason)
        XCTAssertGreaterThanOrEqual(analysis.confidence, OCRLayoutAnalyzer.Tuning.minColumnConfidence)
    }

    /// 阅读顺序必须是「栏内自上而下 → 栏间自左而右」，绝不能横穿栏缝。
    func testThreeColumnReadingOrderIsColumnMajor() {
        let lines = threeColumnLines()
        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        let ordered = texts(analysis, in: lines)

        XCTAssertEqual(ordered.count, lines.count, "不能丢行")
        let expected = (0..<3).flatMap { column in (0..<20).map { "c\(column)r\($0)" } }
        XCTAssertEqual(ordered, expected, "阅读顺序必须逐栏推进")
    }

    /// 单栏正文绝不能被误判成多栏 —— 这是零退化的底线。
    func testSingleColumnBodyStaysSingleColumn() {
        var lines: [OCRLayoutLine] = []
        for row in 0..<30 {
            lines.append(line(row, "row\(row)", x: 0.12, y: 0.10 + CGFloat(row) * 0.025, width: 0.76))
        }
        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)

        XCTAssertEqual(analysis.columnCount, 1)
        XCTAssertEqual(texts(analysis, in: lines), (0..<30).map { "row\($0)" })
    }

    /// 行数过少的「列」是误切（图注、单个短标题），必须并回相邻列。
    func testStrayShortLinesDoNotCreateColumn() {
        var lines: [OCRLayoutLine] = []
        for row in 0..<24 {
            lines.append(line(row, "body\(row)", x: 0.10, y: 0.10 + CGFloat(row) * 0.03, width: 0.55))
        }
        // 右侧只有两行零星文字，不足以成栏
        lines.append(line(100, "stray-a", x: 0.75, y: 0.20, width: 0.15))
        lines.append(line(101, "stray-b", x: 0.75, y: 0.26, width: 0.15))

        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        XCTAssertEqual(analysis.columnCount, 1, "两行零星文字不构成一栏")
    }

    func testEmptyAndTinyInputFallsBackSafely() {
        let empty = OCRLayoutAnalyzer.analyze(lines: [])
        XCTAssertEqual(empty.columnCount, 1)
        XCTAssertTrue(empty.blocks.isEmpty)
        XCTAssertEqual(empty.fallbackReason, "no-lines")

        let single = OCRLayoutAnalyzer.analyze(lines: [line(0, "only", x: 0.1, y: 0.1, width: 0.5)])
        XCTAssertEqual(single.columnCount, 1)
        XCTAssertEqual(single.orderedLineIDs, [0])
    }

    // MARK: - 跨栏横幅

    /// 跨栏大标题必须排在它所覆盖的栏组之前，而不是按 y 混进某一栏。
    func testFullWidthHeadlineLeadsTheColumnGroup() {
        var lines = threeColumnLines()
        lines.append(line(900, "HEADLINE", x: 0.10, y: 0.12, width: 0.81, height: 0.035))

        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        XCTAssertEqual(analysis.columnCount, 3)

        let ordered = texts(analysis, in: lines)
        XCTAssertEqual(ordered.first, "HEADLINE", "跨栏标题必须先读")

        guard let banner = analysis.blocks.first(where: { $0.columnIndex == -1 }) else {
            return XCTFail("跨栏标题必须成为 banner 块")
        }
        XCTAssertEqual(banner.role, .heading)
        XCTAssertEqual(banner.lineIDs, [900])
    }

    // MARK: - 角色

    /// 页码 / 页眉不进入朗读文本。
    func testPageFurnitureIsExcludedFromReadableLines() {
        var lines: [OCRLayoutLine] = []
        for row in 0..<20 {
            lines.append(line(row, "body\(row)", x: 0.12, y: 0.15 + CGFloat(row) * 0.03, width: 0.76))
        }
        lines.append(line(800, "The Daily Times", x: 0.12, y: 0.02, width: 0.30))
        lines.append(line(801, "12", x: 0.48, y: 0.965, width: 0.04))

        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        let readable = Set(analysis.readableLineIDs)

        XCTAssertFalse(readable.contains(800), "页眉不该朗读")
        XCTAssertFalse(readable.contains(801), "页码不该朗读")
        XCTAssertTrue(readable.contains(0), "正文必须保留")
        XCTAssertEqual(analysis.orderedLineIDs.count, lines.count, "家具行只是不朗读，不能从版面里消失")
    }

    /// 页面中间的短行不是版面家具 —— 家具判定只作用于顶/底窄带。
    func testShortLineInBodyIsNotFurniture() {
        var lines: [OCRLayoutLine] = []
        for row in 0..<20 {
            lines.append(line(row, "body\(row)", x: 0.12, y: 0.15 + CGFloat(row) * 0.03, width: 0.76))
        }
        lines.append(line(700, "ok", x: 0.12, y: 0.45, width: 0.05))

        let analysis = OCRLayoutAnalyzer.analyze(lines: lines)
        XCTAssertTrue(analysis.readableLineIDs.contains(700))
    }

    // MARK: - 行重建（groupWordsIntoLines）

    /// 左右两栏同高度的词永远不能并进同一行。
    func testWordsAcrossColumnGutterNeverShareALine() {
        let height: CGFloat = 0.012
        var rects: [CGRect] = []
        // 左栏三个词
        for index in 0..<3 {
            rects.append(CGRect(x: 0.10 + CGFloat(index) * 0.07, y: 0.30, width: 0.06, height: height))
        }
        // 右栏三个词，同一高度
        for index in 0..<3 {
            rects.append(CGRect(x: 0.55 + CGFloat(index) * 0.07, y: 0.30, width: 0.06, height: height))
        }

        let rows = OCRLayoutAnalyzer.groupWordsIntoLines(rects)
        XCTAssertEqual(rows.count, 2, "跨栏缝必须断成两行")
        XCTAssertEqual(rows[0], [0, 1, 2])
        XCTAssertEqual(rows[1], [3, 4, 5])
    }

    /// 回归：容差曾随行组累积高度增长，一个行组会像雪球一样把整段吞掉。
    /// 拍歪的报纸照片上这会把整页读成一串乱序词流。
    func testLineRebuildDoesNotSnowballAcrossRows() {
        let height: CGFloat = 0.012
        var rects: [CGRect] = []
        for row in 0..<12 {
            for column in 0..<5 {
                rects.append(CGRect(
                    x: 0.10 + CGFloat(column) * 0.07,
                    y: 0.10 + CGFloat(row) * 0.02,
                    width: 0.06,
                    height: height
                ))
            }
        }

        let rows = OCRLayoutAnalyzer.groupWordsIntoLines(rects)
        XCTAssertEqual(rows.count, 12, "12 行必须还原成 12 行，不能被吞并")
        XCTAssertTrue(rows.allSatisfy { $0.count == 5 }, "每行 5 个词")
    }

    /// 倾斜到「一行右端低于下一行左端」时，仍要按视觉行还原。
    /// 手持拍摄的报纸倾斜 10° 以上就会出现这种情况。
    func testSkewedRowsAreRebuiltPerVisualLine() {
        let height: CGFloat = 0.012
        let rowGap: CGFloat = 0.02
        let skewPerWord: CGFloat = 0.006   // 每个词下沉，累计超过行距
        var rects: [CGRect] = []
        for row in 0..<6 {
            for column in 0..<6 {
                rects.append(CGRect(
                    x: 0.10 + CGFloat(column) * 0.07,
                    y: 0.10 + CGFloat(row) * rowGap + CGFloat(column) * skewPerWord,
                    width: 0.06,
                    height: height
                ))
            }
        }

        let rows = OCRLayoutAnalyzer.groupWordsIntoLines(rects)
        XCTAssertEqual(rows.count, 6, "倾斜不该改变行数")
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row, Array((index * 6)..<(index * 6 + 6)), "第 \(index) 行的词必须完整且有序")
        }
    }

    /// 输入乱序时，行按 top 升序、行内按 x 升序还原。
    func testGroupWordsIntoLinesSortsRowsTopDownAndWordsLeftRight() {
        let height: CGFloat = 0.012
        let rects: [CGRect] = [
            CGRect(x: 0.17, y: 0.50, width: 0.06, height: height),   // 第二行右词（与左词邻接）
            CGRect(x: 0.10, y: 0.50, width: 0.06, height: height),   // 第二行左词
            CGRect(x: 0.10, y: 0.20, width: 0.06, height: height)    // 第一行
        ]
        let rows = OCRLayoutAnalyzer.groupWordsIntoLines(rects)
        XCTAssertEqual(rows, [[2], [1, 0]])
    }

    /// 同一行里出现远超词距的空白（制表、目录点线、栏缝）时必须断开，
    /// 高亮才不会把中间的空白一起涂上。
    func testWideIntraLineGapBreaksTheRow() {
        let height: CGFloat = 0.012
        let rects: [CGRect] = [
            CGRect(x: 0.10, y: 0.50, width: 0.06, height: height),
            CGRect(x: 0.60, y: 0.50, width: 0.06, height: height)
        ]
        XCTAssertEqual(OCRLayoutAnalyzer.groupWordsIntoLines(rects), [[0], [1]])
    }
}
