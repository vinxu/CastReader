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
    /// 参与版面分析的最低要求。
    var isUsableForLayout: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rect.width > 0 && rect.height > 0
            && rect.width.isFinite && rect.height.isFinite
    }

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
        /// 低于该置信度就回落单栏。
        ///
        /// 不宜设太高：栏缝已经过「valley + 宽度 + 两侧肩部」三重检查，能走到
        /// 打分这步的本来就大概率是真多栏；而回落单栏会让整页按 y 排序，在多栏
        /// 页面上是彻底乱序 —— 错误代价远大于偶尔多切一栏。
        static let minColumnConfidence: Double = 0.45
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
        /// 少于这么多行时不做方向推断 —— 样本太少，判错的代价大于收益。
        static let minLinesForOrientation = 6
        /// 倾角搜索范围（度）。手持拍摄的页面通常在 ±10° 内。
        static let maxSkewDegrees: CGFloat = 12
        static let skewStepDegrees: CGFloat = 0.5
        /// 少于这么多行不做倾角估计 —— 投影统计不出可靠结构。
        static let minLinesForSkew = 16
        /// 水平分区带：高度至少这么多倍行高，才算「区与区之间的空白」而不是行距。
        static let zoneBandHeightRatio: CGFloat = 2.2
        /// 一个区至少这么多行，否则并入相邻区（避免把单个标题切成独立区）。
        static let minLinesPerZone = 4
        /// 行宽达到正文区宽度的这个比例即视为「跨栏元素」，判列时先剥离。
        static let fullWidthLineRatio: CGFloat = 0.75
        /// 递归分解的最大深度。报纸再复杂也就「区 → 栏 → 子区」几层。
        static let maxDecomposeDepth = 8
        /// 少于这么多行不再往下切 —— 切出来的碎块没有版面意义。
        static let minLinesToSplit = 6
        /// 切开后每一侧至少要有这么多行。
        /// 取 1：一个区完全可以只有一行 —— 跨栏大标题本身就是一个区，
        /// 门槛设成 2 会让它切不出来，标题被塞进第一栏的开头。
        static let minLinesPerRegion = 1
        /// 边缘窄栏：宽度不到正文区的这个比例，且贴着页面左右边。
        static let edgeStripWidthRatio: CGFloat = 0.22
        static let edgeStripMarginRatio: CGFloat = 0.18
        /// 少于这么多行不算边栏（零星角标不该被拆出去）。
        static let minLinesForEdgeStrip = 6
        /// 边栏的纵向跨度至少要达到主体的这个比例，才算「贯穿」。
        static let edgeStripCoverageRatio: CGFloat = 0.6
    }

    // MARK: - Entry

    /// 版面分解树。报纸不是「整页 → 列」的两层结构，而是**递归的矩形分割**：
    /// 区域里还有区域，并列的两篇文章各自再分栏。固定层数表达不了这件事 ——
    /// 侧边那篇独立文章会被当成主文的一栏，内容按层切碎后散插进主文的阅读流。
    indirect enum Node {
        case leaf([OCRLayoutLine])
        /// 上下排列的子区，已按 y 排序
        case stack([Node])
        /// 左右排列的子区，已按 x 排序
        case row([Node])
    }

    static func analyze(lines rawLines: [OCRLayoutLine]) -> OCRLayoutAnalysis {
        let lines = rawLines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.rect.width > 0 && $0.rect.height > 0
                && $0.rect.width.isFinite && $0.rect.height.isFinite
        }
        guard lines.count >= 2 else {
            return flatFallback(lines, reason: lines.isEmpty ? "no-lines" : "too-few-lines")
        }

        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)

        // 手持拍摄的页面斜几度，栏就不再垂直，投影会把栏缝整条抹平。
        // 先把行坐标转正再分解；**只用于分析**，输出的仍是原始行 id，
        // 所以 bbox 与画面依旧对得上。
        let skew = estimateSkewAngle(lines: lines, medianHeight: medianHeight)
        let straightened = skew == 0 ? lines : deskewed(lines, angle: skew)

        // 报纸边缘常有被裁切的另一篇文章：它贯穿全高，参与分解会被横切切碎，
        // 碎片散插进图注、标题与主文之间（实测主文开始前混进了 25 行碎片）。
        // 先整块拆成独立区域，按 x 排在主体之后 —— 主文才连贯。
        let tree: Node
        if let detached = detachEdgeStrip(straightened) {
            let body = decompose(detached.main, medianHeight: medianHeight, depth: 0)
            // 边栏自己也要分解：它可能是被裁切的另一篇文章的好几段，
            // 整块当叶子会让它内部的行按 y 混着读。
            let edge = decompose(detached.edge, medianHeight: medianHeight, depth: 0)
            let edgeIsLeft = (detached.edge.map(\.rect.minX).min() ?? 0)
                < (detached.main.map(\.rect.minX).min() ?? 0)
            tree = .row(edgeIsLeft ? [edge, body] : [body, edge])
        } else {
            tree = decompose(straightened, medianHeight: medianHeight, depth: 0)
        }
        let leaves = orderedLeaves(tree)
        guard !leaves.isEmpty else { return flatFallback(lines, reason: "no-leaves") }

        var blocks: [OCRLayoutBlock] = []
        for (index, leaf) in leaves.enumerated() {
            blocks += columnBlocks(
                lines: leaf.sorted { $0.rect.minY < $1.rect.minY },
                columnIndex: index,
                medianHeight: median(leaf.map(\.rect.height), fallback: medianHeight),
                pageMedianHeight: medianHeight
            )
        }
        guard !blocks.isEmpty else { return flatFallback(lines, reason: "no-blocks") }

        let widest = widestRowFanout(tree)
        return OCRLayoutAnalysis(
            columnCount: widest,
            confidence: widest > 1 ? treeConfidence(tree, medianHeight: medianHeight) : 1,
            fallbackReason: widest > 1 ? nil : "single-region",
            blocks: blocks,
            columnRanges: leafColumnRanges(tree)
        )
    }

    /// 分解不出结构时的兜底：整页当一个叶子，行序自上而下。
    private static func flatFallback(_ lines: [OCRLayoutLine], reason: String?) -> OCRLayoutAnalysis {
        guard !lines.isEmpty else {
            return OCRLayoutAnalysis(
                columnCount: 1, confidence: 1, fallbackReason: reason,
                blocks: [], columnRanges: []
            )
        }
        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)
        return OCRLayoutAnalysis(
            columnCount: 1,
            confidence: 1,
            fallbackReason: reason,
            blocks: columnBlocks(
                lines: lines.sorted { $0.rect.minY < $1.rect.minY },
                columnIndex: 0,
                medianHeight: medianHeight,
                pageMedianHeight: medianHeight
            ),
            columnRanges: []
        )
    }

    // MARK: - Recursive XY-cut

    /// 一条候选切割。
    private struct Cut {
        enum Axis { case horizontal, vertical }
        let axis: Axis
        let lower: CGFloat
        let upper: CGFloat
        /// 贯穿度：空白带内的最低覆盖相对两侧峰值的下降幅度（1 = 完全贯穿）。
        let depth: Double
        /// 带宽相对典型行高的倍数。
        let extent: Double

        var position: CGFloat { (lower + upper) / 2 }
        /// 显著性 = 贯穿度 × 带宽（平滑饱和）。
        ///
        /// **贯穿度是主项**：贯穿全高的竖缝（分隔并列的两篇文章）因此能排在
        /// 被跨栏标题打断的横缝之前 —— 这正是固定两层做不到的。
        ///
        /// 带宽用饱和函数而不是硬上限：`min(1.5, extent)` 会把「3.75 倍行高的
        /// 区间隔」和「2.5 倍行高的栏缝」压成同一个数，有意义的差异就丢了，
        /// 谁先谁后退化成看数组顺序 —— 实测因此把跨栏标题切进了第一栏。
        var score: Double { depth * (extent / (2 + extent)) }
    }

    /// 每次只在最显著处切一刀，再对两边递归 —— 经典 Recursive XY-Cut。
    /// 一次切成 N 份会退化回固定层数，无法表达「区域里还有区域」。
    private static func decompose(
        _ lines: [OCRLayoutLine],
        medianHeight: CGFloat,
        depth: Int
    ) -> Node {
        guard depth < Tuning.maxDecomposeDepth,
              lines.count >= Tuning.minLinesToSplit
        else { return .leaf(lines) }

        // 按显著性依次尝试，直到找到真正切得开的那一刀。
        // 只试最优的一条会漏掉这种情况：横切排在前面但切出来一侧太小，
        // 于是整个区域退化成叶子 —— 本该做的竖切根本没机会，正文就变成
        // 「同一行的三栏并排读」。
        for cut in rankedCuts(lines, medianHeight: medianHeight) {
            if cut.axis == .vertical {
                if let node = splitVertically(lines, by: cut, medianHeight: medianHeight, depth: depth) {
                    return node
                }
                continue
            }
            let (first, second) = split(lines, by: cut)
            guard first.count >= Tuning.minLinesPerRegion,
                  second.count >= Tuning.minLinesPerRegion else { continue }
            return .stack([
                decompose(first, medianHeight: medianHeight, depth: depth + 1),
                decompose(second, medianHeight: medianHeight, depth: depth + 1)
            ])
        }
        return .leaf(lines)
    }

    /// 竖切。**跨越切割线的通栏行不按 midX 硬分给某一栏**，而是提升到父层。
    ///
    /// 通栏元素（大标题、页脚地址、通栏图注）不属于任何一栏 —— 它在版面上
    /// 位于栏组的上方或下方，层级比栏更高。按 midX 分给某一栏，它就会黏在
    /// 那一栏尾巴上读出来（实测页脚被接到了最后一栏后面）。
    ///
    /// 这也修掉了原先的自相矛盾：找栏缝时剥离通栏行、执行切割时却又把它们切进去。
    private static func splitVertically(
        _ lines: [OCRLayoutLine],
        by cut: Cut,
        medianHeight: CGFloat,
        depth: Int
    ) -> Node? {
        let crossing = lines.filter { $0.rect.minX < cut.lower && $0.rect.maxX > cut.upper }
        let columnar = lines.filter { !($0.rect.minX < cut.lower && $0.rect.maxX > cut.upper) }
        let left = columnar.filter { $0.rect.midX < cut.position }
        let right = columnar.filter { $0.rect.midX >= cut.position }
        guard left.count >= Tuning.minLinesPerRegion,
              right.count >= Tuning.minLinesPerRegion else { return nil }

        let columnGroup = Node.row([
            decompose(left, medianHeight: medianHeight, depth: depth + 1),
            decompose(right, medianHeight: medianHeight, depth: depth + 1)
        ])
        guard !crossing.isEmpty else { return columnGroup }

        // 通栏行按它相对栏组的位置，落在栏组前面还是后面。
        let groupTop = columnar.map(\.rect.minY).min() ?? 0
        let groupBottom = columnar.map(\.rect.maxY).max() ?? 1
        let middle = (groupTop + groupBottom) / 2
        let above = crossing.filter { $0.rect.midY < middle }
        let below = crossing.filter { $0.rect.midY >= middle }

        var children: [Node] = []
        if !above.isEmpty { children.append(decompose(above, medianHeight: medianHeight, depth: depth + 1)) }
        children.append(columnGroup)
        if !below.isEmpty { children.append(decompose(below, medianHeight: medianHeight, depth: depth + 1)) }
        return children.count == 1 ? columnGroup : .stack(children)
    }

    private static func split(
        _ lines: [OCRLayoutLine],
        by cut: Cut
    ) -> ([OCRLayoutLine], [OCRLayoutLine]) {
        switch cut.axis {
        case .horizontal:
            return (lines.filter { $0.rect.midY < cut.position },
                    lines.filter { $0.rect.midY >= cut.position })
        case .vertical:
            return (lines.filter { $0.rect.midX < cut.position },
                    lines.filter { $0.rect.midX >= cut.position })
        }
    }

    /// 竖缝与横缝放在同一把尺子上比较，取最显著的一条。
    ///
    /// 两个轴各自要先剥掉会把自己那条缝填平的干扰项 —— 这是对称的：
    /// - 竖缝怕**跨栏元素**（大标题、通栏图注横穿每一条栏缝）
    /// - 横缝怕**贯穿全高的窄边栏**（报纸边缘那篇被裁切的文章从头通到尾，
    ///   任何横向区域分隔都会被它填平，层级就建立不起来）
    private static func bestCut(_ lines: [OCRLayoutLine], medianHeight: CGFloat) -> Cut? {
        rankedCuts(lines, medianHeight: medianHeight).first
    }

    /// 所有候选切割，按显著性从高到低。
    private static func rankedCuts(_ lines: [OCRLayoutLine], medianHeight: CGFloat) -> [Cut] {
        let columnar = columnarCandidates(lines)
        let vertical = columnar.count >= Tuning.minLinesToSplit
            ? cuts(in: columnar, axis: .vertical, medianHeight: medianHeight)
            : []
        let zonal = zoneCandidates(lines)
        let horizontal = zonal.count >= Tuning.minLinesToSplit
            ? cuts(in: zonal, axis: .horizontal, medianHeight: medianHeight)
            : []
        // 同分时**横切优先**：文档天然自上而下流动，先分区再分栏。
        // 这是 XY-cut 的标准取向 —— 不定这条规则，两者同分时结果取决于
        // 数组顺序，同一版面可能时而先分区、时而先分栏。
        return (vertical + horizontal).sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.001 { return lhs.score > rhs.score }
            return lhs.axis == .horizontal && rhs.axis == .vertical
        }
    }

    /// 把贴边且贯穿全高的窄栏拆出来（报纸边缘被裁切的另一篇文章）。
    ///
    /// 判据三条缺一不可：**窄**、**贴边**、**纵向跨度接近主体**。
    /// 只有零星几行、或纵向只占一小段的，不算边栏 —— 那多半是图注或角标，
    /// 拆出去反而会打乱阅读顺序。
    static func detachEdgeStrip(
        _ lines: [OCRLayoutLine]
    ) -> (main: [OCRLayoutLine], edge: [OCRLayoutLine])? {
        guard lines.count >= 12 else { return nil }
        let span = bodySpan(lines)
        let left = percentile(lines.map(\.rect.minX), p: 0.1, fallback: 0)
        let right = percentile(lines.map(\.rect.maxX), p: 0.9, fallback: 1)

        var edge: [OCRLayoutLine] = []
        var main: [OCRLayoutLine] = []
        for line in lines {
            let isNarrow = line.rect.width < span * Tuning.edgeStripWidthRatio
            let hugsLeft = line.rect.maxX <= left + span * Tuning.edgeStripMarginRatio
            let hugsRight = line.rect.minX >= right - span * Tuning.edgeStripMarginRatio
            if isNarrow && (hugsLeft || hugsRight) {
                edge.append(line)
            } else {
                main.append(line)
            }
        }
        guard edge.count >= Tuning.minLinesForEdgeStrip,
              main.count >= Tuning.minLinesToSplit else { return nil }

        let edgeTop = edge.map(\.rect.minY).min() ?? 0
        let edgeBottom = edge.map(\.rect.maxY).max() ?? 0
        let mainTop = main.map(\.rect.minY).min() ?? 0
        let mainBottom = main.map(\.rect.maxY).max() ?? 0
        let mainSpan = mainBottom - mainTop
        guard mainSpan > 0, (edgeBottom - edgeTop) >= mainSpan * Tuning.edgeStripCoverageRatio else {
            return nil
        }
        return (main, edge)
    }

    /// 判区时参与投影的行：剥掉贴边的窄栏。
    /// 全部行都贴边（正常的窄页文档）时原样返回，不做无谓剥离。
    static func zoneCandidates(_ lines: [OCRLayoutLine]) -> [OCRLayoutLine] {
        guard lines.count >= 8 else { return lines }
        let span = bodySpan(lines)
        let left = percentile(lines.map(\.rect.minX), p: 0.1, fallback: 0)
        let right = percentile(lines.map(\.rect.maxX), p: 0.9, fallback: 1)
        let kept = lines.filter { line in
            let isNarrow = line.rect.width < span * Tuning.edgeStripWidthRatio
            let hugsLeft = line.rect.maxX <= left + span * Tuning.edgeStripMarginRatio
            let hugsRight = line.rect.minX >= right - span * Tuning.edgeStripMarginRatio
            return !(isNarrow && (hugsLeft || hugsRight))
        }
        return kept.count >= Tuning.minLinesToSplit ? kept : lines
    }

    /// 沿指定轴做投影，找出所有合格的空白带。
    private static func cuts(
        in lines: [OCRLayoutLine],
        axis: Cut.Axis,
        medianHeight: CGFloat
    ) -> [Cut] {
        let bins = Tuning.projectionBins
        var coverage = [Int](repeating: 0, count: bins)
        for line in lines {
            let from = axis == .vertical ? line.rect.minX : line.rect.minY
            let to = axis == .vertical ? line.rect.maxX : line.rect.maxY
            // 只累计**完全**落在行内的 bin：向外取整会让 1% 页宽的栏缝被吃掉。
            let lo = clampBin(Int((from * CGFloat(bins)).rounded(.up)), bins: bins)
            let hi = clampBin(Int((to * CGFloat(bins)).rounded(.down)) - 1, bins: bins)
            guard lo <= hi else { continue }
            for index in lo...hi { coverage[index] += 1 }
        }
        guard let peak = coverage.max(), peak > 0 else { return [] }

        let threshold = CGFloat(peak) * Tuning.coverageValleyRatio
        // 两侧「有内容」的门槛，两个轴的语义不同：
        // - 竖切要求两侧都是**实打实的正文**，否则只是页面里的一片空地；
        // - 横切只要求两侧都有行 —— 一个区的厚度完全可以只有一行（大标题
        //   本身就是一个区），拿正文区的峰值去卡它，区永远分不出来。
        let shoulder: CGFloat = axis == .horizontal ? 1 : CGFloat(peak) * Tuning.gapShoulderRatio
        let window = max(1, Int(Tuning.shoulderWindowRatio * CGFloat(bins)))
        // 横切要跨过行距才算「区与区之间」；竖切只需比词距宽。
        let minExtent = axis == .horizontal
            ? medianHeight * Tuning.zoneBandHeightRatio
            : max(0.0015, medianHeight * 0.15)
        let binWidth = 1 / CGFloat(bins)

        var result: [Cut] = []
        var runStart = -1
        for index in 0...bins {
            let isValley = index < bins && CGFloat(coverage[index]) <= threshold
            if isValley {
                if runStart < 0 { runStart = index }
                continue
            }
            defer { runStart = -1 }
            guard runStart > 0, index - 1 < bins - 1 else { continue }
            let start = runStart
            let end = index - 1
            let lower = CGFloat(start) * binWidth
            let upper = CGFloat(end + 1) * binWidth
            guard upper - lower >= minExtent else { continue }
            // 两侧都得是实打实的内容，否则只是版面里的一片空地。
            let leftPeak = coverage[max(0, start - window)..<start].max() ?? 0
            let rightPeak = coverage[(end + 1)..<min(bins, end + 1 + window)].max() ?? 0
            guard CGFloat(leftPeak) >= shoulder, CGFloat(rightPeak) >= shoulder else { continue }

            let floorCoverage = coverage[start...end].min() ?? 0
            let localPeak = max(1, min(leftPeak, rightPeak))
            result.append(Cut(
                axis: axis,
                lower: lower,
                upper: upper,
                depth: max(0, 1 - Double(floorCoverage) / Double(localPeak)),
                extent: Double((upper - lower) / max(0.0001, medianHeight))
            ))
        }
        return result
    }

    /// 诊断用：列出某组行的候选切割及其分数。
    static func debugCuts(lines rawLines: [OCRLayoutLine]) -> String {
        let lines = rawLines.filter { $0.isUsableForLayout }
        guard lines.count >= 2 else { return "(too few lines)" }
        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)
        let columnar = columnarCandidates(lines)
        let vertical = columnar.count >= Tuning.minLinesToSplit
            ? cuts(in: columnar, axis: .vertical, medianHeight: medianHeight)
            : []
        let horizontal = cuts(in: lines, axis: .horizontal, medianHeight: medianHeight)
        var out = "medianHeight=\(String(format: "%.4f", medianHeight)) columnarLines=\(columnar.count)/\(lines.count)\n"
        for cut in (vertical + horizontal).sorted(by: { $0.score > $1.score }).prefix(8) {
            out += String(
                format: "  %@ at %.3f (%.3f-%.3f) depth=%.2f extent=%.2f → score=%.3f\n",
                cut.axis == .vertical ? "V" : "H",
                cut.position, cut.lower, cut.upper, cut.depth, cut.extent, cut.score
            )
        }
        return out
    }

    /// 诊断用：把分解树打印出来。定位版面问题时，看树比从结果反推快得多。
    static func debugTree(lines rawLines: [OCRLayoutLine]) -> String {
        let lines = rawLines.filter { $0.isUsableForLayout }
        guard lines.count >= 2 else { return "leaf(\(lines.count))" }
        let medianHeight = median(lines.map(\.rect.height), fallback: 0.014)
        let skew = estimateSkewAngle(lines: lines, medianHeight: medianHeight)
        let straightened = skew == 0 ? lines : deskewed(lines, angle: skew)
        var out = ""
        let tree: Node
        if let detached = detachEdgeStrip(straightened) {
            let body = decompose(detached.main, medianHeight: medianHeight, depth: 0)
            // 边栏自己也要分解：它可能是被裁切的另一篇文章的好几段，
            // 整块当叶子会让它内部的行按 y 混着读。
            let edge = decompose(detached.edge, medianHeight: medianHeight, depth: 0)
            let edgeIsLeft = (detached.edge.map(\.rect.minX).min() ?? 0)
                < (detached.main.map(\.rect.minX).min() ?? 0)
            tree = .row(edgeIsLeft ? [edge, body] : [body, edge])
        } else {
            tree = decompose(straightened, medianHeight: medianHeight, depth: 0)
        }
        describe(tree, indent: 0, into: &out)
        return out
    }

    private static func describe(_ node: Node, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        switch node {
        case .leaf(let lines):
            let sample = lines.sorted { $0.rect.minY < $1.rect.minY }
                .prefix(1).map { String($0.text.prefix(46)) }.joined()
            let x = lines.map(\.rect.minX).min() ?? 0
            let y = lines.map(\.rect.minY).min() ?? 0
            out += pad + String(format: "leaf(%d) x=%.2f y=%.2f  %@\n", lines.count, x, y, sample)
        case .stack(let children):
            out += pad + "stack ↓\n"
            for child in children { describe(child, indent: indent + 1, into: &out) }
        case .row(let children):
            out += pad + "row →\n"
            for child in children { describe(child, indent: indent + 1, into: &out) }
        }
    }

    // MARK: - Tree traversal

    /// 阅读顺序 = 深度优先遍历。
    ///
    /// **不再按 minX / minY 重排子节点**：`decompose` 切出来的 `[前, 后]`
    /// 顺序本来就对，而子树内部可以横跨很大范围 —— 拿它的 minX 去和兄弟
    /// 比较会把整棵子树排错位置（实测把正文第 2 栏甩到了最后读）。
    private static func orderedLeaves(_ node: Node) -> [[OCRLayoutLine]] {
        switch node {
        case .leaf(let lines):
            return lines.isEmpty ? [] : [lines]
        case .stack(let children), .row(let children):
            return children.flatMap(orderedLeaves)
        }
    }

    private static func allLines(_ node: Node) -> [OCRLayoutLine] {
        switch node {
        case .leaf(let lines): return lines
        case .stack(let children), .row(let children): return children.flatMap(allLines)
        }
    }

    private static func minY(_ node: Node) -> CGFloat {
        allLines(node).map(\.rect.minY).min() ?? 0
    }

    private static func minX(_ node: Node) -> CGFloat {
        allLines(node).map(\.rect.minX).min() ?? 0
    }

    /// 最宽的一层左右分栏有几支 —— 对外仍以「栏数」表达，供 P2 判断是否值得让用户选区。
    private static func widestRowFanout(_ node: Node) -> Int {
        switch node {
        case .leaf: return 1
        case .stack(let children):
            return children.map(widestRowFanout).max() ?? 1
        case .row(let children):
            let here = children.reduce(0) { $0 + leafCount($1) }
            return max(here, children.map(widestRowFanout).max() ?? 1)
        }
    }

    private static func leafCount(_ node: Node) -> Int {
        switch node {
        case .leaf: return 1
        case .stack(let children), .row(let children): return children.reduce(0) { $0 + leafCount($1) }
        }
    }

    /// 各栏的 x 区间，供调用方切分「被 OCR 误连成一行的跨栏行」。
    ///
    /// 取**叶子级**而不是最外层：递归分解后最外层往往只有两支，拿它当栏边界
    /// 会让误连行的切分判据失效。叶子才对应真正的一栏。
    /// 通栏叶子（标题、页脚、被误连的行）要排除 —— 它横跨的 x 区间会在合并时
    /// 把相邻两栏吞成一个。
    private static func leafColumnRanges(_ node: Node) -> [ClosedRange<CGFloat>] {
        let span = bodySpan(allLines(node))
        let raw = orderedLeaves(node).compactMap { lines -> (CGFloat, CGFloat)? in
            guard let lower = lines.map(\.rect.minX).min(),
                  let upper = lines.map(\.rect.maxX).max(),
                  upper > lower,
                  upper - lower <= span * Tuning.fullWidthLineRatio else { return nil }
            return (lower, upper)
        }.sorted { $0.0 < $1.0 }

        var merged: [(CGFloat, CGFloat)] = []
        for range in raw {
            if let last = merged.last, range.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, range.1))
            } else {
                merged.append(range)
            }
        }
        return merged.map { $0.0...$0.1 }
    }

    /// 树的可信度：用各次切割的显著性衡量分解质量。
    private static func treeConfidence(_ node: Node, medianHeight: CGFloat) -> Double {
        var scores: [Double] = []
        collectCutScores(node, medianHeight: medianHeight, into: &scores)
        guard !scores.isEmpty else { return 1 }
        return min(1, scores.reduce(0, +) / Double(scores.count))
    }

    private static func collectCutScores(
        _ node: Node,
        medianHeight: CGFloat,
        into scores: inout [Double]
    ) {
        switch node {
        case .leaf:
            return
        case .stack(let children), .row(let children):
            let lines = allLines(node)
            if let cut = bestCut(lines, medianHeight: medianHeight) {
                // 用贯穿度衡量可信度：切得干不干净，比缝有多宽更能说明问题。
                scores.append(min(1, cut.depth))
            }
            for child in children {
                collectCutScores(child, medianHeight: medianHeight, into: &scores)
            }
        }
    }

    // MARK: - Deskew

    /// 估计页面的细微倾角（弧度，顺时针为正），使栏缝在垂直投影上最清晰。
    ///
    /// 直接优化我们真正要的目标 —— 栏缝的可见度，而不是先去拟合文本基线。
    /// 角度为 0 时得分最高就返回 0，正投影的页面不会被无谓地转动。
    static func estimateSkewAngle(lines: [OCRLayoutLine], medianHeight: CGFloat) -> CGFloat {
        guard lines.count >= Tuning.minLinesForSkew else { return 0 }

        var bestAngle: CGFloat = 0
        var bestScore = skewScore(lines: lines, medianHeight: medianHeight)

        var degrees = -Tuning.maxSkewDegrees
        while degrees <= Tuning.maxSkewDegrees {
            defer { degrees += Tuning.skewStepDegrees }
            guard degrees != 0 else { continue }
            let angle = degrees * .pi / 180
            let score = skewScore(lines: deskewed(lines, angle: angle), medianHeight: medianHeight)
            if score > bestScore {
                bestScore = score
                bestAngle = angle
            }
        }
        return bestAngle
    }

    /// 栏缝清晰度：缝越深、越宽、越多，分越高。
    private static func skewScore(lines: [OCRLayoutLine], medianHeight: CGFloat) -> Double {
        let gaps = columnGaps(lines: lines, medianHeight: medianHeight)
        guard !gaps.isEmpty else { return 0 }
        return gaps.reduce(0) { $0 + $1.depth * Double($1.width) }
    }

    /// 把行绕页面中心旋转 `angle`（弧度）。小角度下保持行的宽高即可，
    /// 我们只需要让栏在投影上重新对齐。
    static func deskewed(_ lines: [OCRLayoutLine], angle: CGFloat) -> [OCRLayoutLine] {
        guard angle != 0 else { return lines }
        let cosA = cos(angle)
        let sinA = sin(angle)
        return lines.map { line in
            let dx = line.rect.midX - 0.5
            let dy = line.rect.midY - 0.5
            let x = dx * cosA - dy * sinA + 0.5
            let y = dx * sinA + dy * cosA + 0.5
            return OCRLayoutLine(
                id: line.id,
                text: line.text,
                rect: CGRect(
                    x: x - line.rect.width / 2,
                    y: y - line.rect.height / 2,
                    width: line.rect.width,
                    height: line.rect.height
                )
            )
        }
    }

    // MARK: - Page orientation

    /// 单次 OCR 的行几何 + Vision 返回顺序 → 页面需要**顺时针**旋转几个 90° 才正立。
    ///
    /// 为什么只需一次 OCR：Vision 会自己检测文本方向来识别，`orientation` 参数
    /// **只影响返回的 bbox 坐标系**，不影响识别出的文字（实测四个方向下文本逐字相同）。
    /// 所以把 bbox 按四种旋转变换一遍、选「行最横 + 阅读顺序最顺」的那个即可，
    /// 纯几何、零额外识别成本。
    ///
    /// - Parameter boxes: Vision 归一化 bbox（原点左下），**按 Vision 返回的阅读顺序**。
    /// - Returns: 0…3，顺时针 90° 的次数。
    static func quarterTurnsToUpright(visionBoxesInReadingOrder boxes: [CGRect]) -> Int {
        let valid = boxes.filter { $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite }
        guard valid.count >= Tuning.minLinesForOrientation else { return 0 }

        var bestTurns = 0
        var bestScore = -Double.greatestFiniteMagnitude
        for turns in 0..<4 {
            let rotated = valid.map { rotateVisionRect($0, quarterTurnsClockwise: turns) }
            // 正立的横排文本行是宽扁的；转了 90° 就变高瘦。这一项区分度极大
            // （实测正立 1.00 / 侧向 0.00），是主信号。
            let wideShare = Double(rotated.filter { $0.width > $0.height }.count) / Double(rotated.count)
            // Vision 按阅读顺序返回行：方向对了，返回顺序应与「从上到下」一致。
            // 这一项用来分开正立与倒置（两者行都是宽扁的）。
            var inversions = 0
            for index in 0..<(rotated.count - 1) {
                let current = 1 - rotated[index].maxY
                let next = 1 - rotated[index + 1].maxY
                if current > next + 0.01 { inversions += 1 }
            }
            let orderScore = 1 - Double(inversions) / Double(rotated.count - 1)

            let score = wideShare * 0.6 + orderScore * 0.4
            if score > bestScore {
                bestScore = score
                bestTurns = turns
            }
        }
        return bestTurns
    }

    /// Vision 归一化矩形（原点左下）绕图心顺时针旋转 n 个 90°。
    static func rotateVisionRect(_ rect: CGRect, quarterTurnsClockwise turns: Int) -> CGRect {
        var result = rect
        for _ in 0..<((turns % 4 + 4) % 4) {
            // 顺时针 90°：点 (x, y) → (y, 1 - x)
            result = CGRect(
                x: result.minY,
                y: 1 - result.maxX,
                width: result.height,
                height: result.width
            )
        }
        return result
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

    /// 判列时参与投影的行：剥掉跨栏元素（大标题、通栏图注、报头、页脚地址）。
    ///
    /// 这些行会把每一条栏缝都填满，投影上直接抹掉栏结构。实测一张报纸
    /// 正文每栏仅约 12 行、跨栏元素却有 5 行，占比 31% —— 远超「栏缝可容忍
    /// 的覆盖率」，于是栏缝根本不被认作空白，5 栏只判出 2 栏。
    ///
    /// 单栏文档的行本来就是满宽的，会被全部剥离，于是得不到栏缝、回落单栏 ——
    /// 正是想要的结果。
    static func columnarCandidates(_ lines: [OCRLayoutLine]) -> [OCRLayoutLine] {
        guard lines.count >= 4 else { return lines }
        let left = percentile(lines.map(\.rect.minX), p: 0.1, fallback: 0)
        let right = percentile(lines.map(\.rect.maxX), p: 0.9, fallback: 1)
        let span = right - left
        guard span > 0 else { return lines }
        return lines.filter { $0.rect.width < span * Tuning.fullWidthLineRatio }
    }

    private static func percentile(_ values: [CGFloat], p: CGFloat, fallback: CGFloat) -> CGFloat {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return fallback }
        let index = max(0, min(sorted.count - 1, Int((CGFloat(sorted.count - 1) * p).rounded())))
        return sorted[index]
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
    private static func columnGaps(lines rawLines: [OCRLayoutLine], medianHeight: CGFloat) -> [ColumnGap] {
        let bins = Tuning.projectionBins
        // 只用栏内行投影 —— 跨栏元素会把每条栏缝都填平（见 columnarCandidates）。
        let lines = columnarCandidates(rawLines)
        guard lines.count >= 4 else { return [] }
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

    /// 正文区宽度（剔除离群的左右边缘）。
    static func bodySpan(_ lines: [OCRLayoutLine]) -> CGFloat {
        guard !lines.isEmpty else { return 1 }
        let left = percentile(lines.map(\.rect.minX), p: 0.1, fallback: 0)
        let right = percentile(lines.map(\.rect.maxX), p: 0.9, fallback: 1)
        return max(0.001, right - left)
    }

    private static func overlapWidth(line: OCRLayoutLine, column: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(line.rect.maxX, column.upperBound) - max(line.rect.minX, column.lowerBound))
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
        //
        // 取**中位数**而不是最小值：报纸 5 栏有 4 条缝，只要一条被跨栏标题或
        // 插图压过，最小值就会把整体分拖垮，而其余几条缝可能非常干净。
        // （实测一张真实报纸因此只得 0.54，差 0.01 被判回单栏，整页读乱。）
        let depth = median(gaps.map { CGFloat($0.depth) }, fallback: 0)
        let width = median(gaps.map(\.width), fallback: 0)
        let widthScore = Double(clamp(width / max(0.001, medianHeight * 0.8), 0, 1))
        let gapQuality = Double(depth) * 0.7 + widthScore * 0.3

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
        // 跨栏行：**又跨列又满宽**才算（大标题、通栏图注、报头地址）。
        //
        // 只看「跨几列」会出事：栏数多时每栏很窄，一行正文很容易同时压到
        // 相邻两列，于是被误判成横幅；而横幅会把页面切成一层层，正文被切碎
        // 散落各层，读起来就在栏之间反复横跳（实测一栏的正文被切成 3 段）。
        let span = bodySpan(lines)
        var banner: [OCRLayoutLine] = []
        var columnar: [Int: [OCRLayoutLine]] = [:]
        for line in lines {
            let occupied = columns.indices.filter { occupies(line: line, column: columns[$0]) }
            let isBanner = occupied.count >= 2 && line.rect.width >= span * Tuning.fullWidthLineRatio
            if isBanner {
                banner.append(line)
            } else if let index = occupied.max(by: {
                overlapWidth(line: line, column: columns[$0]) < overlapWidth(line: line, column: columns[$1])
            }) {
                // 跨列但不够宽 → 归到重叠最多的那一列（多半是栏边界不准或 OCR 误连）
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
