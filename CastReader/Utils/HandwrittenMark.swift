//
//  HandwrittenMark.swift
//  CastReader
//
//  手写体标注的几何与时长。硬约束：手绘笔触 + 确定性抖动（同 mark 重绘形状不变）。
//  Path 由 reader 的 MarkOverlay 用 trimmedPath 动画描边。
//

import SwiftUI

enum HandwrittenMark {

    /// 重要度（weight）→ 笔触粗细倍率（P1 轴 1「划得准·分层」：核心论点粗笔 / 支撑细节细线）。
    /// 后端未给 weight 时返回 1.0（与历史一致，零回归）。
    static func weightMultiplier(_ weight: String?) -> CGFloat {
        switch weight {
        case "primary", "high":   return 1.6
        case "tertiary", "low":   return 0.65
        default:                  return 1.0   // secondary / normal / nil
        }
    }

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

    /// 波浪下划线（P1：风险/警示语义）：沿每行底部画正弦波浪。
    static func wavePath(over rects: [CGRect], seed: UInt64) -> Path {
        var rng = SeededGenerator(seed: seed)
        var path = Path()
        for r in rects.sorted(by: { $0.minY < $1.minY }) {
            let baseY = r.maxY - max(1.0, r.height * 0.06)
            let amp = max(1.6, r.height * 0.12)
            let wavelength = max(7.0, r.height * 0.55)
            let phase = CGFloat(rng.nextDouble(in: 0...Double.pi))
            let steps = max(4, Int(r.width / 3))
            path.move(to: CGPoint(x: r.minX + 1, y: baseY))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let x = r.minX + 1 + (r.width - 2) * t
                let y = baseY + amp * sin((x - r.minX) / wavelength * 2 * CGFloat.pi + phase)
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    /// 删除线：沿每行中线略抖动的横线（P1）。
    static func strikePath(over rects: [CGRect], seed: UInt64) -> Path {
        var rng = SeededGenerator(seed: seed)
        var path = Path()
        for r in rects.sorted(by: { $0.minY < $1.minY }) {
            let midY = r.midY + rng.nextDouble(in: -0.6...0.6)
            let amp = max(0.5, r.height * 0.03)
            let steps = max(2, Int(r.width / 20))
            path.move(to: CGPoint(x: r.minX + 1, y: midY + rng.nextDouble(in: -amp...amp)))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let x = r.minX + 1 + (r.width - 2) * t
                path.addLine(to: CGPoint(x: x, y: midY + rng.nextDouble(in: -amp...amp)))
            }
        }
        return path
    }

    /// 星标（P1）：画在该范围右侧外的一颗手绘五角星。
    static func starPath(near rects: [CGRect], seed: UInt64) -> Path {
        var rng = SeededGenerator(seed: seed)
        let b = rects.reduce(CGRect.null) { $0.union($1) }
        let radius = max(7.0, min(12.0, b.height * 0.5))
        let cx = b.maxX + radius + 6
        let cy = b.midY
        var path = Path()
        for i in 0...10 {
            let isOuter = i % 2 == 0
            let jitter = CGFloat(rng.nextDouble(in: -0.06...0.06))
            let rr = (isOuter ? radius : radius * 0.42) * (1 + jitter)
            let ang = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
            let p = CGPoint(x: cx + rr * cos(ang), y: cy + rr * sin(ang))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
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
