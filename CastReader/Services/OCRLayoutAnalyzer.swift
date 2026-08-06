//
//  OCRLayoutAnalyzer.swift
//  CastReader
//
//  版面理解：把 OCR 行还原成「列 + 阅读顺序 + 角色」。
//  纯几何算法，不依赖 Vision / UIKit，可离线单测，也可 1:1 回译 Android。
//
//  为什么需要这一层：Vision 只给行，段落聚类此前按整幅图的 y 坐标做，
//  多栏版面上左右两栏的同高度行会被并成一行 —— 报纸/杂志/双栏论文必错。
//

import CoreGraphics
import Foundation

/// 版面块角色。只决定「是否朗读」与埋点，不改变 `ReadingParagraphType`。
enum OCRBlockRole: String, Equatable {
    case heading
    case body
    case caption
    /// 页眉 / 页脚 / 页码 / 版面号等版面家具，不进入朗读文本。
    case furniture

    var isReadable: Bool { self != .furniture }
}

/// 版面分析输入行。`rect` 是 layout 归一化坐标：**原点左上**，0...1。
/// Vision 的 bbox 原点在左下，调用方负责翻转（见 `OCRLayoutLine.fromVision`）。
struct OCRLayoutLine: Equatable {
    let id: Int
    let text: String
    let rect: CGRect

    init(id: Int, text: String, rect: CGRect) {
        self.id = id
        self.text = text
        self.rect = rect
    }

    /// Vision 归一化 bbox（原点左下）→ layout 行。
    static func fromVision(id: Int, text: String, visionBBox: CGRect) -> OCRLayoutLine {
        OCRLayoutLine(
            id: id,
            text: text,
            rect: CGRect(
                x: visionBBox.minX,
                y: 1 - visionBBox.maxY,
                width: visionBBox.width,
                height: visionBBox.height
            )
        )
    }
}

/// 一个版面块：同一列（或跨栏横幅）内在垂直方向连续的一组行。
/// 精细段落切分仍由 `OCRService` 在块内完成，这里只负责「哪些行属于一起、先读谁」。
struct OCRLayoutBlock: Equatable {
    /// 列序号；`-1` 表示跨栏横幅（大标题等）。
    let columnIndex: Int
    let role: OCRBlockRole
    let lineIDs: [Int]
    let rect: CGRect
}

struct OCRLayoutAnalysis: Equatable {
    let columnCount: Int
    let confidence: Double
    /// 回落到单栏的原因；`nil` 表示多栏结果可用。
    let fallbackReason: String?
    /// 已按阅读顺序排好：跨栏横幅 → 其下方各列（左→右），逐层交错。
    let blocks: [OCRLayoutBlock]
    /// 各列的 x 区间。调用方用它把「被 OCR 误连成一行的跨栏行」按词切开。
    let columnRanges: [ClosedRange<CGFloat>]

    var isMultiColumn: Bool { columnCount > 1 }

    /// 展平后的阅读顺序（行 id）。
    var orderedLineIDs: [Int] { blocks.flatMap(\.lineIDs) }

    /// 参与朗读的行 id（剔除版面家具）。
    var readableLineIDs: [Int] { blocks.filter { $0.role.isReadable }.flatMap(\.lineIDs) }

    var roleCounts: [String: Int] {
        blocks.reduce(into: [:]) { counts, block in
            counts[block.role.rawValue, default: 0] += 1
        }
    }
}

enum OCRLayoutAnalyzer {

    // MARK: - Tuning

    /// 所有阈值集中在此，Android 端必须使用同值。
    enum Tuning {
        /// 低于该置信度就回落单栏（保守 fail-safe）。
        static let minColumnConfidence: Double = 0.55
        static let maxColumns = 6
        /// 报纸栏缝只有约 1% 页宽，粗直方图会被 bin 舍入整条吞掉。
        static let projectionBins = 600
        /// 栏间空白的判据：覆盖计数低于最大覆盖的该比例即视为空白。
        /// 用比例而非「必须为 0」，是为了让跨栏标题穿过栏缝时不掩盖栏结构。
        static let coverageValleyRatio: CGFloat = 0.22
        /// 栏缝两侧必须都是实打实的正文，否则那只是页面里的一片稀疏区域。
        static let gapShoulderRatio: CGFloat = 0.30
        /// 判断「两侧是正文」时向外看多宽（页宽比例）。
        static let shoulderWindowRatio: CGFloat = 0.05
        /// 一行与某列重叠达到该列宽的此比例，才算「占据」了该列。
        static let columnOccupancyRatio: CGFloat = 0.45
        /// 页面顶部/底部的版面家具带。
        static let furnitureBandRatio: CGFloat = 0.06
        /// 每列至少这么多行，否则与相邻列合并（防误切）。
        static let minLinesPerColumn = 3
    }

    // MARK: - Entry

    static func analyze(lines rawLines: [OCRLayoutLine]) -> OCRLayoutAnalysis {
        let lines = rawLines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.rect.width > 0 && $0.rect.height > 0
                && $0.rect.width.isFinite && $0.rect.height.isFinite
        }
        guard lines.count >= 2 else {
            return singleColumn(lines: lines, reason: lines.isEmpty ? "no-lines" : "too-few-lines")
        }

        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)
        let gaps = columnGaps(lines: lines, medianHeight: medianHeight)
        guard !gaps.isEmpty else {
            return singleColumn(lines: lines, reason: nil)
        }

        var columns = columnRanges(from: gaps, lines: lines)
        columns = mergeUnderfilledColumns(columns, lines: lines)
        guard columns.count >= 2 else {
            return singleColumn(lines: lines, reason: "columns-merged-to-one")
        }
        guard columns.count <= Tuning.maxColumns else {
            return singleColumn(lines: lines, reason: "too-many-columns-\(columns.count)")
        }

        let confidence = score(columns: columns, gaps: gaps, lines: lines, medianHeight: medianHeight)
        guard confidence >= Tuning.minColumnConfidence else {
            return singleColumn(lines: lines, reason: "low-confidence-\(Int((confidence * 100).rounded()))")
        }

        let blocks = orderedBlocks(lines: lines, columns: columns, medianHeight: medianHeight)
        guard !blocks.isEmpty else {
            return singleColumn(lines: lines, reason: "no-blocks")
        }
        return OCRLayoutAnalysis(
            columnCount: columns.count,
            confidence: confidence,
            fallbackReason: nil,
            blocks: blocks,
            columnRanges: columns
        )
    }

    /// 单栏：仍然产出块与角色，让「页眉页脚不朗读」在单栏文档上同样生效。
    private static func singleColumn(lines: [OCRLayoutLine], reason: String?) -> OCRLayoutAnalysis {
        guard !lines.isEmpty else {
            return OCRLayoutAnalysis(
                columnCount: 1, confidence: 1, fallbackReason: reason,
                blocks: [], columnRanges: []
            )
        }
        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)
        let blocks = columnBlocks(
            lines: lines.sorted { $0.rect.minY < $1.rect.minY },
            columnIndex: 0,
            medianHeight: medianHeight,
            pageMedianHeight: medianHeight
        )
        return OCRLayoutAnalysis(
            columnCount: 1,
            confidence: 1,
            fallbackReason: reason,
            blocks: blocks,
            columnRanges: []
        )
    }

    // MARK: - Line rebuilding

    /// 词 → 视觉行。`rects` 为 layout 归一化坐标（原点左上）；返回按阅读顺序
    /// 排好的行，每行是 `rects` 的下标数组（行内已按 x 升序）。
    ///
    /// 两条铁律，都是真实照片踩出来的：
    /// 1. **纵向容差固定**取自页面中位词高，不随已聚成的行增高而放大 ——
    ///    否则一个行组会像雪球一样把下方整段都吞进来（倾斜照片上必现）。
    /// 2. **同一行的词必须在 x 方向邻接**。栏缝远宽于词距，这条约束让
    ///    左右栏的同高度词永远进不了同一行。
    ///
    /// 逐词以「该行最右侧的词」为锚比较，因此拍歪的照片上行基线可以持续漂移，
    /// 不会被一个全局基线切断。
    static func groupWordsIntoLines(_ rects: [CGRect]) -> [[Int]] {
        let valid = rects.enumerated().filter {
            $0.element.width > 0 && $0.element.height > 0
                && $0.element.width.isFinite && $0.element.height.isFinite
        }
        guard !valid.isEmpty else { return [] }

        let medianHeight = median(valid.map(\.element.height), fallback: 0.012)
        let yTolerance = max(0.004, medianHeight * 0.62)
        let maxHorizontalGap = max(0.008, medianHeight * 1.2)

        struct Row {
            var indexes: [Int]
            var anchor: CGRect
            var maxX: CGFloat
        }
        var rows: [Row] = []
        for item in valid.sorted(by: { $0.element.minX < $1.element.minX }) {
            let rect = item.element
            var bestRow = -1
            var bestCost = CGFloat.greatestFiniteMagnitude
            for index in rows.indices {
                let row = rows[index]
                guard abs(rect.midY - row.anchor.midY) <= max(yTolerance, rect.height * 0.6) else { continue }
                let gap = rect.minX - row.maxX
                guard gap <= maxHorizontalGap else { continue }
                let cost = max(0, gap)
                if cost < bestCost {
                    bestCost = cost
                    bestRow = index
                }
            }
            if bestRow >= 0 {
                rows[bestRow].indexes.append(item.offset)
                rows[bestRow].anchor = rect
                rows[bestRow].maxX = max(rows[bestRow].maxX, rect.maxX)
            } else {
                rows.append(Row(indexes: [item.offset], anchor: rect, maxX: rect.maxX))
            }
        }

        return rows
            .map { row in row.indexes.sorted { rects[$0].minX < rects[$1].minX } }
            .sorted { lhs, rhs in
                let lhsTop = lhs.map { rects[$0].minY }.min() ?? 0
                let rhsTop = rhs.map { rects[$0].minY }.min() ?? 0
                if abs(lhsTop - rhsTop) > max(0.004, medianHeight * 0.5) { return lhsTop < rhsTop }
                let lhsLeft = lhs.map { rects[$0].minX }.min() ?? 0
                let rhsLeft = rhs.map { rects[$0].minX }.min() ?? 0
                return lhsLeft < rhsLeft
            }
    }

    // MARK: - Column detection

    /// 一条栏缝。`depth` 是缝内覆盖相对两侧峰值的下降幅度（0…1），
    /// 比缝宽更能说明「这是不是真的栏缝」—— 报纸栏缝往往只有 1% 页宽。
    struct ColumnGap: Equatable {
        let range: ClosedRange<CGFloat>
        let depth: Double

        var width: CGFloat { range.upperBound - range.lowerBound }
    }

    /// 诊断用：暴露投影直方图与判定出的栏缝，供验证台/测试定位列检测行为。
    /// 生产路径不调用它。
    static func projectionDiagnostics(
        lines rawLines: [OCRLayoutLine]
    ) -> (coverage: [Int], gaps: [ColumnGap], medianHeight: CGFloat) {
        let lines = rawLines.filter { $0.rect.width > 0 && $0.rect.height > 0 }
        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)
        return (
            coverageHistogram(lines: lines),
            columnGaps(lines: lines, medianHeight: medianHeight),
            medianHeight
        )
    }

    /// 诊断用：列检测的分项打分。
    struct ColumnScoreDiagnostics {
        let columns: [ClosedRange<CGFloat>]
        let gaps: [ColumnGap]
        let gapQuality: Double
        let alignment: Double
        let occupancy: Double
        let balance: Double
        let total: Double
    }

    static func columnDiagnostics(lines rawLines: [OCRLayoutLine]) -> ColumnScoreDiagnostics? {
        let lines = rawLines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.rect.width > 0 && $0.rect.height > 0
        }
        guard lines.count >= 2 else { return nil }
        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)
        let gaps = columnGaps(lines: lines, medianHeight: medianHeight)
        guard !gaps.isEmpty else { return nil }
        let columns = mergeUnderfilledColumns(columnRanges(from: gaps, lines: lines), lines: lines)
        let parts = scoreParts(columns: columns, gaps: gaps, lines: lines, medianHeight: medianHeight)
        return ColumnScoreDiagnostics(
            columns: columns,
            gaps: gaps,
            gapQuality: parts.gapQuality,
            alignment: parts.alignment,
            occupancy: parts.occupancy,
            balance: parts.balance,
            total: parts.total
        )
    }

    private static func coverageHistogram(lines: [OCRLayoutLine]) -> [Int] {
        let bins = Tuning.projectionBins
        var coverage = [Int](repeating: 0, count: bins)
        for line in lines {
            // 只累计**完全**落在该行内的 bin。向外取整会让窄栏缝被两侧的 bin
            // 吃掉，报纸（栏缝约 1% 页宽）上直方图会变成一整片高台。
            let lo = clampBin(Int((line.rect.minX * CGFloat(bins)).rounded(.up)), bins: bins)
            let hi = clampBin(Int((line.rect.maxX * CGFloat(bins)).rounded(.down)) - 1, bins: bins)
            guard lo <= hi else { continue }
            for index in lo...hi { coverage[index] += 1 }
        }
        return coverage
    }

    /// 垂直投影找栏缝：统计每个 x bin 被多少行覆盖，取连续低覆盖区间。
    /// 触及页面左右边缘的低覆盖区间是页边距，不算栏缝。
    private static func columnGaps(lines: [OCRLayoutLine], medianHeight: CGFloat) -> [ColumnGap] {
        let bins = Tuning.projectionBins
        let coverage = coverageHistogram(lines: lines)
        guard let maxCoverage = coverage.max(), maxCoverage > 0 else { return [] }

        let threshold = CGFloat(maxCoverage) * Tuning.coverageValleyRatio
        let shoulder = CGFloat(maxCoverage) * Tuning.gapShoulderRatio
        let shoulderWindow = max(1, Int(Tuning.shoulderWindowRatio * CGFloat(bins)))
        // 栏缝可以只有一个 bin 宽：真正的保护是「覆盖率显著低于两侧」，不是宽度。
        // 行内词距不会形成贯穿整栏的低谷，因为同栏其他行会把它填上。
        let minGapWidth = max(0.0015, medianHeight * 0.15)
        let binWidth = 1 / CGFloat(bins)

        var gaps: [ColumnGap] = []
        var runStart: Int?
        for index in 0...bins {
            let isValley = index < bins && CGFloat(coverage[index]) <= threshold
            if isValley {
                if runStart == nil { runStart = index }
                continue
            }
            if let start = runStart {
                appendGap(&gaps, start: start, end: index - 1, coverage: coverage,
                          binWidth: binWidth, minGapWidth: minGapWidth,
                          shoulder: shoulder, shoulderWindow: shoulderWindow)
                runStart = nil
            }
        }
        return gaps
    }

    private static func appendGap(
        _ gaps: inout [ColumnGap],
        start: Int,
        end: Int,
        coverage: [Int],
        binWidth: CGFloat,
        minGapWidth: CGFloat,
        shoulder: CGFloat,
        shoulderWindow: Int
    ) {
        // 触及左右边缘 → 页边距，不是栏缝。
        guard start > 0, end < coverage.count - 1 else { return }
        let lower = CGFloat(start) * binWidth
        let upper = CGFloat(end + 1) * binWidth
        guard upper - lower >= minGapWidth else { return }
        // 两侧都得是正文，否则只是版面里的一片空地（插图周围、页面留白）。
        // 取邻域峰值而不是紧邻的单个 bin：栏边缘的覆盖天然衰减，而各栏的
        // 行数本就可以差一倍（一栏被插图截断、另一栏通到页底）。
        let leftPeak = coverage[max(0, start - shoulderWindow)..<start].max() ?? 0
        let rightPeak = coverage[(end + 1)..<min(coverage.count, end + 1 + shoulderWindow)].max() ?? 0
        guard CGFloat(leftPeak) >= shoulder, CGFloat(rightPeak) >= shoulder else { return }
        let floorCoverage = coverage[start...end].min() ?? 0
        let peak = max(1, min(leftPeak, rightPeak))
        let depth = max(0, 1 - Double(floorCoverage) / Double(peak))
        gaps.append(ColumnGap(range: lower...upper, depth: depth))
    }

    private static func columnRanges(
        from gaps: [ColumnGap],
        lines: [OCRLayoutLine]
    ) -> [ClosedRange<CGFloat>] {
        let left = lines.map(\.rect.minX).min() ?? 0
        let right = lines.map(\.rect.maxX).max() ?? 1
        var bounds: [CGFloat] = [left]
        for gap in gaps.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let mid = midpoint(gap.range)
            guard mid > left, mid < right else { continue }
            bounds.append(mid)
        }
        bounds.append(right)
        var ranges: [ClosedRange<CGFloat>] = []
        for pair in zip(bounds, bounds.dropFirst()) where pair.1 > pair.0 {
            ranges.append(pair.0...pair.1)
        }
        return ranges
    }

    /// 行数过少的列往往是误切（图注、单个短标题），并入相邻列。
    private static func mergeUnderfilledColumns(
        _ columns: [ClosedRange<CGFloat>],
        lines: [OCRLayoutLine]
    ) -> [ClosedRange<CGFloat>] {
        guard columns.count >= 2 else { return columns }
        var current = columns
        var didMerge = true
        while didMerge, current.count >= 2 {
            didMerge = false
            let counts = current.map { range in
                lines.filter { occupies(line: $0, column: range) }.count
            }
            guard let weakest = counts.indices.min(by: { counts[$0] < counts[$1] }),
                  counts[weakest] < Tuning.minLinesPerColumn else { break }
            let neighbor = weakest == 0 ? 1 : weakest - 1
            let lower = min(current[weakest].lowerBound, current[neighbor].lowerBound)
            let upper = max(current[weakest].upperBound, current[neighbor].upperBound)
            var merged = current
            merged.remove(at: max(weakest, neighbor))
            merged[min(weakest, neighbor)] = lower...upper
            current = merged
            didMerge = true
        }
        return current
    }

    private static func occupies(line: OCRLayoutLine, column: ClosedRange<CGFloat>) -> Bool {
        let width = column.upperBound - column.lowerBound
        guard width > 0 else { return false }
        let overlap = min(line.rect.maxX, column.upperBound) - max(line.rect.minX, column.lowerBound)
        guard overlap > 0 else { return false }
        // 行落在列内（窄行）或行覆盖了该列的主要宽度（满栏行），都算占据。
        return overlap >= min(line.rect.width, width) * Tuning.columnOccupancyRatio
    }

    // MARK: - Scoring

    private static func score(
        columns: [ClosedRange<CGFloat>],
        gaps: [ColumnGap],
        lines: [OCRLayoutLine],
        medianHeight: CGFloat
    ) -> Double {
        scoreParts(columns: columns, gaps: gaps, lines: lines, medianHeight: medianHeight).total
    }

    private static func scoreParts(
        columns: [ClosedRange<CGFloat>],
        gaps: [ColumnGap],
        lines: [OCRLayoutLine],
        medianHeight: CGFloat
    ) -> (gapQuality: Double, alignment: Double, occupancy: Double, balance: Double, total: Double) {
        // 缝的质量看「干净程度」为主、宽度为辅：报纸栏缝只有 1% 页宽，
        // 但缝内几乎无字；只按宽度打分会把真栏缝一律判低。
        let minDepth = gaps.map(\.depth).min() ?? 0
        let minWidth = gaps.map(\.width).min() ?? 0
        let widthScore = Double(clamp(minWidth / max(0.001, medianHeight * 0.8), 0, 1))
        let gapQuality = minDepth * 0.7 + widthScore * 0.3

        var alignments: [Double] = []
        var occupancies: [Double] = []
        var counts: [Double] = []
        for column in columns {
            let width = column.upperBound - column.lowerBound
            let members = lines.filter { occupies(line: $0, column: column) }
            counts.append(Double(members.count))
            guard members.count >= 2, width > 0 else {
                alignments.append(0)
                occupancies.append(0)
                continue
            }
            let lefts = members.map { max($0.rect.minX, column.lowerBound) }
            let deviation = medianAbsoluteDeviation(lefts)
            alignments.append(Double(1 - clamp(deviation / (width * 0.18), 0, 1)))
            let widths = members.map { min($0.rect.maxX, column.upperBound) - max($0.rect.minX, column.lowerBound) }
            let fill = median(widths, fallback: 0) / width
            occupancies.append(Double(clamp(fill / 0.75, 0, 1)))
        }

        let alignment = mean(alignments)
        let occupancy = mean(occupancies)
        let widths = columns.map { Double($0.upperBound - $0.lowerBound) }
        let balance = 1 - min(1, max(coefficientOfVariation(widths), coefficientOfVariation(counts)))
        let total = gapQuality * 0.35 + alignment * 0.30 + occupancy * 0.20 + balance * 0.15
        return (gapQuality, alignment, occupancy, balance, total)
    }

    // MARK: - Reading order

    private static func orderedBlocks(
        lines: [OCRLayoutLine],
        columns: [ClosedRange<CGFloat>],
        medianHeight: CGFloat
    ) -> [OCRLayoutBlock] {
        // 跨栏行：同时占据 2 列及以上（大标题、通栏图注）。
        var banner: [OCRLayoutLine] = []
        var columnar: [Int: [OCRLayoutLine]] = [:]
        for line in lines {
            let occupied = columns.indices.filter { occupies(line: line, column: columns[$0]) }
            if occupied.count >= 2 {
                banner.append(line)
            } else if let index = occupied.first {
                columnar[index, default: []].append(line)
            } else {
                // 落在栏缝里的孤立行：归到中心最近的列，绝不丢弃。
                let center = line.rect.midX
                let nearest = columns.indices.min {
                    abs(midpoint(columns[$0]) - center) < abs(midpoint(columns[$1]) - center)
                }
                if let nearest { columnar[nearest, default: []].append(line) }
            }
        }

        // 横幅按 y 聚成带，带之间的区域是一层「栏组」。
        let bands = bannerBands(banner.sorted { $0.rect.minY < $1.rect.minY }, medianHeight: medianHeight)
        var blocks: [OCRLayoutBlock] = []
        var consumed = Set<Int>()
        for (bandIndex, band) in bands.enumerated() {
            // 该横幅之上、尚未输出的栏内行先读（报纸偶有先于大标题的导语栏）。
            blocks.append(contentsOf: layerBlocks(
                columnar: columnar,
                columns: columns,
                from: bandIndex == 0 ? -.greatestFiniteMagnitude : bands[bandIndex - 1].rect.maxY,
                to: band.rect.minY,
                consumed: &consumed,
                medianHeight: medianHeight
            ))
            blocks.append(OCRLayoutBlock(
                columnIndex: -1,
                role: bannerRole(band, medianHeight: medianHeight),
                lineIDs: band.lines.map(\.id),
                rect: band.rect
            ))
        }
        // 收尾一次全域清扫：`consumed` 已排除前面输出过的行，
        // 因此夹在横幅带内部的栏行也会被捕获 —— 绝不丢内容。
        blocks.append(contentsOf: layerBlocks(
            columnar: columnar,
            columns: columns,
            from: -.greatestFiniteMagnitude,
            to: .greatestFiniteMagnitude,
            consumed: &consumed,
            medianHeight: medianHeight
        ))
        return blocks
    }

    private struct BannerBand {
        var lines: [OCRLayoutLine]
        var rect: CGRect
    }

    private static func bannerBands(_ lines: [OCRLayoutLine], medianHeight: CGFloat) -> [BannerBand] {
        var bands: [BannerBand] = []
        for line in lines {
            if var last = bands.last,
               line.rect.minY - last.rect.maxY <= medianHeight * 1.6 {
                last.lines.append(line)
                last.rect = last.rect.union(line.rect)
                bands[bands.count - 1] = last
            } else {
                bands.append(BannerBand(lines: [line], rect: line.rect))
            }
        }
        return bands
    }

    /// 一层栏组：各列从左到右，列内从上到下。
    private static func layerBlocks(
        columnar: [Int: [OCRLayoutLine]],
        columns: [ClosedRange<CGFloat>],
        from lowerY: CGFloat,
        to upperY: CGFloat,
        consumed: inout Set<Int>,
        medianHeight: CGFloat
    ) -> [OCRLayoutBlock] {
        var result: [OCRLayoutBlock] = []
        for index in columns.indices {
            let members = (columnar[index] ?? [])
                .filter { !consumed.contains($0.id) && $0.rect.midY >= lowerY && $0.rect.midY < upperY }
                .sorted { $0.rect.minY < $1.rect.minY }
            guard !members.isEmpty else { continue }
            members.forEach { consumed.insert($0.id) }
            result.append(contentsOf: columnBlocks(
                lines: members,
                columnIndex: index,
                medianHeight: median(members.map(\.rect.height), fallback: medianHeight),
                pageMedianHeight: medianHeight
            ))
        }
        return result
    }

    /// 列内按垂直间隙切粗块 → 判角色 → 相邻同为正文的粗块再合回去，
    /// 这样 `OCRService` 的段落聚类拿到的仍是连续正文，不被人为切碎。
    private static func columnBlocks(
        lines: [OCRLayoutLine],
        columnIndex: Int,
        medianHeight: CGFloat,
        pageMedianHeight: CGFloat
    ) -> [OCRLayoutBlock] {
        guard !lines.isEmpty else { return [] }
        var groups: [[OCRLayoutLine]] = [[lines[0]]]
        for pair in zip(lines, lines.dropFirst()) {
            let gap = pair.1.rect.minY - pair.0.rect.maxY
            let heightJump = abs(pair.1.rect.height - pair.0.rect.height) > pageMedianHeight * 0.45
            if gap > max(medianHeight * 1.6, pageMedianHeight * 1.2) || heightJump {
                groups.append([pair.1])
            } else {
                groups[groups.count - 1].append(pair.1)
            }
        }

        let blocks: [OCRLayoutBlock] = groups.compactMap { group in
            guard let rect = union(group.map(\.rect)) else { return nil }
            return OCRLayoutBlock(
                columnIndex: columnIndex,
                role: role(for: group, rect: rect, pageMedianHeight: pageMedianHeight),
                lineIDs: group.map(\.id),
                rect: rect
            )
        }

        var merged: [OCRLayoutBlock] = []
        for block in blocks {
            if let last = merged.last, last.role == .body, block.role == .body,
               block.rect.minY - last.rect.maxY <= pageMedianHeight * 3 {
                merged[merged.count - 1] = OCRLayoutBlock(
                    columnIndex: last.columnIndex,
                    role: .body,
                    lineIDs: last.lineIDs + block.lineIDs,
                    rect: last.rect.union(block.rect)
                )
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    // MARK: - Roles

    private static func bannerRole(_ band: BannerBand, medianHeight: CGFloat) -> OCRBlockRole {
        if isFurniture(lines: band.lines, rect: band.rect, pageMedianHeight: medianHeight) {
            return .furniture
        }
        return band.lines.count <= 3 ? .heading : .body
    }

    private static func role(
        for lines: [OCRLayoutLine],
        rect: CGRect,
        pageMedianHeight: CGFloat
    ) -> OCRBlockRole {
        if isFurniture(lines: lines, rect: rect, pageMedianHeight: pageMedianHeight) { return .furniture }
        let height = median(lines.map(\.rect.height), fallback: pageMedianHeight)
        if height > pageMedianHeight * 1.25, lines.count <= 4 { return .heading }
        if height < pageMedianHeight * 0.85, lines.count <= 4 { return .caption }
        return .body
    }

    /// 版面家具：顶部/底部窄带里的单行短文本（页码、日期、刊头、版面号）。
    /// 字号显著大于正文的行不算 —— 那是标题，用户要听。
    private static func isFurniture(lines: [OCRLayoutLine], rect: CGRect, pageMedianHeight: CGFloat) -> Bool {
        guard lines.count == 1, let line = lines.first else { return false }
        let band = Tuning.furnitureBandRatio
        guard rect.minY < band || rect.maxY > 1 - band else { return false }
        guard line.rect.height <= pageMedianHeight * 1.6 else { return false }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        if isPageNumber(text) { return true }
        return text.count <= 40
    }

    private static func isPageNumber(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !stripped.isEmpty, stripped.count <= 8 else { return false }
        if stripped.allSatisfy({ $0.isNumber }) { return true }
        return stripped.uppercased().allSatisfy { "IVXLCDM".contains($0) }
    }

    // MARK: - Math helpers

    private static func clampBin(_ value: Int, bins: Int) -> Int {
        max(0, min(bins - 1, value))
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(upper, max(lower, value))
    }

    private static func midpoint(_ range: ClosedRange<CGFloat>) -> CGFloat {
        (range.lowerBound + range.upperBound) / 2
    }

    private static func union(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }

    private static func median(_ values: [CGFloat], fallback: CGFloat) -> CGFloat {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return fallback }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func medianAbsoluteDeviation(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let center = median(values, fallback: 0)
        return median(values.map { abs($0 - center) }, fallback: 0)
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let average = mean(values)
        guard average > 0 else { return 1 }
        let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)
        return variance.squareRoot() / average
    }
}
