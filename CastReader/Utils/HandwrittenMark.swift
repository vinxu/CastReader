//
//  HandwrittenMark.swift
//  CastReader
//
//  手写体标注的几何与时长。硬约束：手绘笔触 + 确定性抖动（同 mark 重绘形状不变）。
//  Path 由 reader 的 MarkOverlay 用 trimmedPath 动画描边。
//

import SwiftUI

enum HandwrittenMark {

    /// 绘制时长（秒）。circle 按周长估算，其余按宽度。
    static func duration(action: String, rects: [CGRect]) -> Double {
        let bounds = rects.reduce(CGRect.null) { $0.union($1) }
        let span: CGFloat
        if action == "circle" {
            span = .pi * (bounds.width + bounds.height) * 0.35
        } else {
            span = rects.reduce(0) { $0 + $1.width }
        }
        let ms = min(2200.0, max(450.0, Double(span) * 3.5))
        return ms / 1000.0
    }

    /// 马克笔高亮：沿每行中线的一条略带波动的粗笔（overlay 以高亮色半透明、圆头描边）。
    static func highlightPath(over rects: [CGRect], seed: UInt64) -> Path {
        var rng = SeededGenerator(seed: seed)
        var path = Path()
        for r in rects.sorted(by: { $0.minY < $1.minY }) {
            let midY = r.midY
            let amp = max(1.0, r.height * 0.06)
            let steps = max(2, Int(r.width / 22))
            path.move(to: CGPoint(x: r.minX + 2, y: midY + rng.nextDouble(in: -amp...amp)))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let x = r.minX + 2 + (r.width - 4) * t
                let y = midY + rng.nextDouble(in: -amp...amp)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    /// 下划线：沿每行底部略抖动的基线。
    static func underlinePath(over rects: [CGRect], seed: UInt64) -> Path {
        var rng = SeededGenerator(seed: seed)
        var path = Path()
        for r in rects.sorted(by: { $0.minY < $1.minY }) {
            let baseY = r.maxY - max(1.0, r.height * 0.08)
            let amp = max(0.8, r.height * 0.05)
            let steps = max(2, Int(r.width / 18))
            path.move(to: CGPoint(x: r.minX + 1, y: baseY + rng.nextDouble(in: -amp...amp)))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let x = r.minX + 1 + (r.width - 2) * t
                let y = baseY + rng.nextDouble(in: -amp...amp)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    /// 圈：围绕整组矩形包络画一个带抖动与“收尾不闭合”的椭圆。
    static func circlePath(around rects: [CGRect], seed: UInt64) -> Path {
        var rng = SeededGenerator(seed: seed)
        let b = rects.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -6, dy: -4)
        let cx = b.midX, cy = b.midY
        let rx = b.width / 2, ry = b.height / 2
        var path = Path()
        // 起点略偏移，终点 overshoot（手绘感）
        let start = rng.nextDouble(in: -0.3...0.3)
        let end = 2 * .pi + rng.nextDouble(in: 0.2...0.7)
        let segs = 36
        for i in 0...segs {
            let t = start + (end - start) * CGFloat(i) / CGFloat(segs)
            let jitter = rng.nextDouble(in: -0.04...0.04)
            let x = cx + (rx * (1 + jitter)) * cos(t)
            let y = cy + (ry * (1 + jitter)) * sin(t)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    /// 序号徽标的圆环（数字本身由 overlay 用 Text 叠加）。
    static func numberRingRect(near rects: [CGRect]) -> CGRect {
        let b = rects.reduce(CGRect.null) { $0.union($1) }
        let d: CGFloat = max(18, min(26, b.height * 1.1))
        // 放在该范围左上角外侧
        return CGRect(x: b.minX - d - 2, y: b.midY - d / 2, width: d, height: d)
    }
}
