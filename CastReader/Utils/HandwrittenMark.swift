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

    /// 绘制时长（秒）。circle 按周长估算，number 按一个行高序号估算，其余按宽度。
    static func duration(action: String, rects: [CGRect]) -> Double {
        let bounds = rects.reduce(CGRect.null) { $0.union($1) }
        let span: CGFloat
        if action == "circle" {
            span = .pi * (bounds.width + bounds.height) * 0.35
        } else if action == "number" {
            span = max(40, (rects.map { $0.height }.max() ?? 18) * 1.4)
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

    /// 序号徽标的圆环。
    static func numberRingRect(near rects: [CGRect]) -> CGRect {
        let sorted = rects.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        let first = sorted.first ?? rects.reduce(CGRect.null) { $0.union($1) }
        let lineH = max(14, first.height)
        let r = min(lineH * 0.6, 16)
        var cx = first.minX - r * 1.5
        if cx - r < 4 {
            cx = first.minX + r * 0.35
        }
        return CGRect(x: cx - r, y: first.minY + lineH / 2 - r, width: r * 2, height: r * 2)
    }

    /// 序号 1/2/3：手绘小圈 + 纯路径数字 + 内容下划线。对齐扩展 quickread 的 number tool。
    static func numberPath(near rects: [CGRect], n: Int, seed: UInt64) -> Path {
        let sorted = rects.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        guard let first = sorted.first else { return Path() }
        var rng = SeededGenerator(seed: seed &+ 29)
        let lineH = max(14, first.height)
        let r = min(lineH * 0.6, 16)
        let ccy = first.minY + lineH / 2
        var ccx = first.minX - r * 1.5
        if ccx - r < 4 {
            ccx = first.minX + r * 0.35
        }

        var path = Path()
        path.addPath(numberRingPath(cx: ccx, cy: ccy, r: r, rng: &rng))
        path.addPath(digitPath(n, cx: ccx, cy: ccy, size: r * 1.12, rng: &rng))
        for rect in sorted {
            let y = rect.maxY + 3
            path.addPath(handDrawnLinePath(x0: rect.minX - 2, y0: y, x1: rect.maxX + 4, y1: y, waviness: 1.5, rng: &rng))
        }
        return path
    }

    private static func jitter(_ value: CGFloat, amp: Double, rng: inout SeededGenerator) -> CGFloat {
        value + CGFloat(rng.nextDouble(in: -amp / 2...amp / 2))
    }

    private static func numberRingPath(cx: CGFloat, cy: CGFloat, r: CGFloat, rng: inout SeededGenerator) -> Path {
        let k: CGFloat = 0.5523
        func j(_ value: CGFloat) -> CGFloat { jitter(value, amp: 0.9, rng: &rng) }
        let x0 = cx - r
        let x1 = cx + r
        let y0 = cy - r
        let y1 = cy + r
        var path = Path()
        path.move(to: CGPoint(x: j(cx), y: j(y0)))
        path.addCurve(to: CGPoint(x: j(x1), y: j(cy)),
                      control1: CGPoint(x: j(cx + r * k), y: j(y0)),
                      control2: CGPoint(x: j(x1), y: j(cy - r * k)))
        path.addCurve(to: CGPoint(x: j(cx), y: j(y1)),
                      control1: CGPoint(x: j(x1), y: j(cy + r * k)),
                      control2: CGPoint(x: j(cx + r * k), y: j(y1)))
        path.addCurve(to: CGPoint(x: j(x0), y: j(cy)),
                      control1: CGPoint(x: j(cx - r * k), y: j(y1)),
                      control2: CGPoint(x: j(x0), y: j(cy + r * k)))
        path.addCurve(to: CGPoint(x: j(cx + r * 0.5), y: j(y0 + r * 0.15)),
                      control1: CGPoint(x: j(x0), y: j(cy - r * k)),
                      control2: CGPoint(x: j(cx - r * k), y: j(y0)))
        return path
    }

    private static func handDrawnLinePath(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, waviness: CGFloat, rng: inout SeededGenerator) -> Path {
        let dx = x1 - x0
        let dy = y1 - y0
        let len = sqrt(dx * dx + dy * dy)
        let segments = max(4, Int((len / 30).rounded()))
        var path = Path()
        path.move(to: CGPoint(x: jitter(x0, amp: 3, rng: &rng), y: jitter(y0, amp: Double(waviness), rng: &rng)))
        for i in 1...segments {
            let t = CGFloat(i) / CGFloat(segments)
            let x = x0 + dx * t
            let y = y0 + dy * t + CGFloat(rng.nextDouble(in: -Double(waviness)...Double(waviness)))
            let cpx = x0 + dx * (t - 0.5 / CGFloat(segments)) + CGFloat(rng.nextDouble(in: -4...4))
            let cpy = y0 + dy * (t - 0.5 / CGFloat(segments)) + CGFloat(rng.nextDouble(in: -Double(waviness)...Double(waviness)))
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpx, y: cpy))
        }
        return path
    }

    private static func loopPath(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, rng: inout SeededGenerator) -> Path {
        let k: CGFloat = 0.5523
        func j(_ value: CGFloat, _ amp: Double = 1.2) -> CGFloat { jitter(value, amp: amp, rng: &rng) }
        var path = Path()
        path.move(to: CGPoint(x: j(cx), y: j(cy - ry)))
        path.addCurve(to: CGPoint(x: j(cx + rx), y: j(cy)),
                      control1: CGPoint(x: j(cx + rx * k), y: j(cy - ry)),
                      control2: CGPoint(x: j(cx + rx), y: j(cy - ry * k)))
        path.addCurve(to: CGPoint(x: j(cx), y: j(cy + ry)),
                      control1: CGPoint(x: j(cx + rx), y: j(cy + ry * k)),
                      control2: CGPoint(x: j(cx + rx * k), y: j(cy + ry)))
        path.addCurve(to: CGPoint(x: j(cx - rx), y: j(cy)),
                      control1: CGPoint(x: j(cx - rx * k), y: j(cy + ry)),
                      control2: CGPoint(x: j(cx - rx), y: j(cy + ry * k)))
        path.addCurve(to: CGPoint(x: j(cx + rx * 0.22), y: j(cy - ry * 0.92)),
                      control1: CGPoint(x: j(cx - rx), y: j(cy - ry * k)),
                      control2: CGPoint(x: j(cx - rx * k), y: j(cy - ry)))
        return path
    }

    private static func digitPath(_ value: Int, cx: CGFloat, cy: CGFloat, size: CGFloat, rng: inout SeededGenerator) -> Path {
        func j(_ value: CGFloat, _ amp: Double = 0.7) -> CGFloat { jitter(value, amp: amp, rng: &rng) }
        let digit = ((value % 10) + 10) % 10
        let h = size
        let w = size * 0.58
        let top = cy - h / 2
        let bottom = cy + h / 2
        let left = cx - w / 2
        let right = cx + w / 2
        let midY = cy
        var path = Path()

        switch digit {
        case 1:
            path.move(to: CGPoint(x: j(cx - w * 0.28), y: j(top + h * 0.22)))
            path.addQuadCurve(to: CGPoint(x: j(cx), y: j(top)),
                              control: CGPoint(x: j(cx - w * 0.06), y: j(top + h * 0.05)))
            path.addQuadCurve(to: CGPoint(x: j(cx), y: j(bottom)),
                              control: CGPoint(x: j(cx), y: j(midY)))
        case 2:
            path.move(to: CGPoint(x: j(left + w * 0.08), y: j(top + h * 0.24)))
            path.addQuadCurve(to: CGPoint(x: j(cx + w * 0.2), y: j(top)),
                              control: CGPoint(x: j(cx - w * 0.05), y: j(top - h * 0.02)))
            path.addQuadCurve(to: CGPoint(x: j(cx + w * 0.1), y: j(midY + h * 0.05)),
                              control: CGPoint(x: j(right + w * 0.05), y: j(top + h * 0.12)))
            path.addQuadCurve(to: CGPoint(x: j(left), y: j(bottom)),
                              control: CGPoint(x: j(cx - w * 0.1), y: j(midY + h * 0.22)))
            path.addLine(to: CGPoint(x: j(right), y: j(bottom)))
        case 3:
            path.move(to: CGPoint(x: j(left + w * 0.05), y: j(top + h * 0.08)))
            path.addQuadCurve(to: CGPoint(x: j(cx + w * 0.1), y: j(midY - h * 0.02)),
                              control: CGPoint(x: j(cx + w * 0.35), y: j(top - h * 0.02)))
            path.addQuadCurve(to: CGPoint(x: j(cx + w * 0.1), y: j(midY + h * 0.24)),
                              control: CGPoint(x: j(right + w * 0.05), y: j(midY + h * 0.04)))
            path.addQuadCurve(to: CGPoint(x: j(left), y: j(bottom - h * 0.1)),
                              control: CGPoint(x: j(cx - w * 0.2), y: j(bottom + h * 0.02)))
        case 4:
            path.move(to: CGPoint(x: j(cx + w * 0.12), y: j(top)))
            path.addQuadCurve(to: CGPoint(x: j(left - w * 0.08), y: j(midY + h * 0.14)),
                              control: CGPoint(x: j(left - w * 0.05), y: j(midY + h * 0.08)))
            path.addLine(to: CGPoint(x: j(right + w * 0.05), y: j(midY + h * 0.14)))
            path.move(to: CGPoint(x: j(cx + w * 0.18), y: j(top + h * 0.15)))
            path.addQuadCurve(to: CGPoint(x: j(cx + w * 0.18), y: j(bottom)),
                              control: CGPoint(x: j(cx + w * 0.18), y: j(midY)))
        case 5:
            path.move(to: CGPoint(x: j(right), y: j(top + h * 0.02)))
            path.addLine(to: CGPoint(x: j(left + w * 0.08), y: j(top)))
            path.addQuadCurve(to: CGPoint(x: j(left + w * 0.05), y: j(midY + h * 0.05)),
                              control: CGPoint(x: j(left + w * 0.02), y: j(midY - h * 0.05)))
            path.addQuadCurve(to: CGPoint(x: j(cx + w * 0.3), y: j(midY + h * 0.18)),
                              control: CGPoint(x: j(cx + w * 0.4), y: j(midY - h * 0.04)))
            path.addQuadCurve(to: CGPoint(x: j(left), y: j(bottom - h * 0.08)),
                              control: CGPoint(x: j(cx + w * 0.1), y: j(bottom + h * 0.04)))
        case 6:
            path.move(to: CGPoint(x: j(cx + w * 0.28), y: j(top)))
            path.addQuadCurve(to: CGPoint(x: j(left), y: j(midY + h * 0.12)),
                              control: CGPoint(x: j(left - w * 0.02), y: j(midY - h * 0.08)))
            path.addQuadCurve(to: CGPoint(x: j(cx), y: j(bottom)),
                              control: CGPoint(x: j(left - w * 0.02), y: j(bottom)))
            path.addQuadCurve(to: CGPoint(x: j(right), y: j(midY + h * 0.14)),
                              control: CGPoint(x: j(right + w * 0.02), y: j(bottom)))
            path.addQuadCurve(to: CGPoint(x: j(left + w * 0.12), y: j(midY + h * 0.14)),
                              control: CGPoint(x: j(right - w * 0.05), y: j(midY)))
        case 7:
            path.move(to: CGPoint(x: j(left), y: j(top)))
            path.addLine(to: CGPoint(x: j(right), y: j(top)))
            path.addQuadCurve(to: CGPoint(x: j(cx - w * 0.12), y: j(bottom)),
                              control: CGPoint(x: j(cx + w * 0.05), y: j(midY)))
        case 8:
            path.addPath(loopPath(cx: cx, cy: cy - h * 0.26, rx: w * 0.4, ry: h * 0.24, rng: &rng))
            path.addPath(loopPath(cx: cx, cy: cy + h * 0.26, rx: w * 0.48, ry: h * 0.26, rng: &rng))
        case 9:
            path.addPath(loopPath(cx: cx, cy: cy - h * 0.2, rx: w * 0.46, ry: h * 0.28, rng: &rng))
            path.move(to: CGPoint(x: j(cx + w * 0.4), y: j(midY - h * 0.18)))
            path.addQuadCurve(to: CGPoint(x: j(cx - w * 0.05), y: j(bottom)),
                              control: CGPoint(x: j(cx + w * 0.28), y: j(midY + h * 0.2)))
        case 0:
            path.addPath(loopPath(cx: cx, cy: cy, rx: w * 0.5, ry: h * 0.48, rng: &rng))
        default:
            path.addPath(loopPath(cx: cx, cy: cy, rx: w * 0.5, ry: h * 0.48, rng: &rng))
        }
        return path
    }
}
