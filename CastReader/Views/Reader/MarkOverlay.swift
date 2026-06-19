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
    var inkColor: Color = Color(red: 0.17, green: 0.24, blue: 0.31)   // 深墨蓝
    var highlightColor: Color = AppTheme.primary.opacity(0.4)

    @State private var progress: CGFloat = 0

    private var duration: Double { HandwrittenMark.duration(action: action, rects: rects) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shapeView
            if action == "number", let n = n {
                numberBadge(n)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: duration)) { progress = 1 }
        }
    }

    @ViewBuilder
    private var shapeView: some View {
        switch action {
        case "highlight":
            // 荧光笔：半透明 + 压在文字中下部，文字透出来不被遮盖
            MarkPathShape(absolutePath: HandwrittenMark.highlightPath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(highlightColor.opacity(0.28), style: StrokeStyle(lineWidth: lineHeight * 0.85, lineCap: .round, lineJoin: .round))
                .blendMode(.multiply)
        case "underline":
            MarkPathShape(absolutePath: HandwrittenMark.underlinePath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        case "circle", "number":
            MarkPathShape(absolutePath: HandwrittenMark.circlePath(around: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(action == "number" ? inkColor : AppTheme.primary,
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        default:
            MarkPathShape(absolutePath: HandwrittenMark.underlinePath(over: rects, seed: seed))
                .trim(from: 0, to: progress)
                .stroke(inkColor, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
        }
    }

    private func numberBadge(_ n: Int) -> some View {
        let ring = HandwrittenMark.numberRingRect(near: rects)
        return Text("\(n)")
            .font(.system(size: ring.height * 0.55, weight: .bold, design: .rounded))
            .foregroundColor(inkColor)
            .frame(width: ring.width, height: ring.height)
            .position(x: ring.midX, y: ring.midY)
            .opacity(Double(progress))
    }

    private var lineHeight: CGFloat {
        rects.map { $0.height }.max() ?? 18
    }
}
