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
    var animateOnAppear = true

    @State private var progress: CGFloat = 0

    private var ink: HandwrittenMark.Stroke {
        HandwrittenMark.stroke(action: action, rects: rects, seed: seed, n: n, weight: weight)
    }

    var body: some View {
        shapeView
        .allowsHitTesting(false)
        .onAppear {
            guard progress == 0 else { return }   // 复用/重绘时不重播已画完的 mark
            guard animateOnAppear else { progress = 1; return }
            // 延迟一帧让 progress=0（落笔起点）先渲染，再动画到 1——否则 SwiftUI 在 overlay/LazyVStack
            // 里常首帧直接画终值、看不到落笔过程（常驻阅读器不重建后此问题暴露）。对齐 Chrome 扩展落笔。
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: ink.duration)) { progress = 1 }
            }
        }
    }

    private var shapeView: some View {
        let stroke = ink
        return MarkPathShape(absolutePath: stroke.path)
            .trim(from: 0, to: progress)
            .stroke((action == "highlight" ? highlightColor : inkColor).opacity(stroke.opacity),
                    style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round))
    }
}
