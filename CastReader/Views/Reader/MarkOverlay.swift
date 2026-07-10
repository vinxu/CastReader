//
//  MarkOverlay.swift
//  CastReader
//
//  手写标注的绘制 View。rects 为内容坐标系（photo 画布 / 文本段落）内的绝对矩形。
//  用 Shape.trim 做“落笔”动画；同 mark 用确定性 seed，重绘不抖。
//

import SwiftUI

/// 把 HandwrittenMark 生成的绝对路径包成 Shape（忽略布局 rect，使用绝对坐标）。
private struct MarkPathShape: Shape {
    let absolutePath: Path
    func path(in rect: CGRect) -> Path { absolutePath }
}

struct MarkInkView: View {
    let rects: [CGRect]
    let action: String
    let seed: UInt64
    let n: Int?
    var inkColor: Color = Color(red: 253/255, green: 95/255, blue: 1/255)        // #FD5F01 统一橙（深浅都清晰）
    var highlightColor: Color = Color(red: 253/255, green: 95/255, blue: 1/255)  // 同基色，绘制时各自叠 alpha
    var weight: String? = nil   // P1：重要度分层 → 笔触粗细倍率（nil = 普通，零回归）

    @State private var progress: CGFloat = 0

    private var duration: Double { HandwrittenMark.duration(action: action, rects: rects) }
    private var wMul: CGFloat { HandwrittenMark.weightMultiplier(weight) }

    var body: some View {
        shapeView
        .allowsHitTesting(false)
        .onAppear {
            guard progress == 0 else { return }   // 复用/重绘时不重播已画完的 mark
            // 延迟一帧让 progress=0（落笔起点）先渲染，再动画到 1——否则 SwiftUI 在 overlay/LazyVStack
            // 里常首帧直接画终值、看不到落笔过程（常驻阅读器不重建后此问题暴露）。对齐 Chrome 扩展落笔。
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: duration)) { progress = 1 }
            }
        }
    }

    @ViewBuilder
    private var shapeView: some View {
        switch action {
        case "highlight":
            // 荧光笔：半透明压在文字中下部，文字透出不被遮盖。不用 multiply（深色背景×橙=黑，荧光会消失）。
            MarkPathShape(absolutePath: HandwrittenMark.highlightPath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(highlightColor.opacity(0.35), style: StrokeStyle(lineWidth: lineHeight * 0.85 * wMul, lineCap: .round, lineJoin: .round))
        case "underline":
            MarkPathShape(absolutePath: HandwrittenMark.underlinePath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor.opacity(0.85), style: StrokeStyle(lineWidth: 2.4 * wMul, lineCap: .round, lineJoin: .round))
        case "wave":
            // 波浪线：风险/警示语义（P1）。
            MarkPathShape(absolutePath: HandwrittenMark.wavePath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor.opacity(0.9), style: StrokeStyle(lineWidth: 2.2 * wMul, lineCap: .round, lineJoin: .round))
        case "strike":
            MarkPathShape(absolutePath: HandwrittenMark.strikePath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor.opacity(0.85), style: StrokeStyle(lineWidth: 2.2 * wMul, lineCap: .round, lineJoin: .round))
        case "star":
            MarkPathShape(absolutePath: HandwrittenMark.starPath(near: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor.opacity(0.9), style: StrokeStyle(lineWidth: 2.2 * wMul, lineCap: .round, lineJoin: .round))
        case "circle":
            MarkPathShape(absolutePath: HandwrittenMark.circlePath(around: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2.4 * wMul, lineCap: .round, lineJoin: .round))
        case "number":
            MarkPathShape(absolutePath: HandwrittenMark.numberPath(near: rects, n: n ?? 1, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2.5 * wMul, lineCap: .round, lineJoin: .round))
        default:
            MarkPathShape(absolutePath: HandwrittenMark.underlinePath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor.opacity(0.85), style: StrokeStyle(lineWidth: 2.2 * wMul, lineCap: .round))
        }
    }

    private var lineHeight: CGFloat {
        rects.map { $0.height }.max() ?? 18
    }
}
