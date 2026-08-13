//
//  LastUsedBubble.swift
//  CastReader
//
//  登录墙上的「上次登录」气泡。
//

import SwiftUI

/// 挂在圆形通道图标（Apple / 邮箱）右上角的「上次登录」小气泡。
///
/// 主推的 Google 是大按钮，标签直接排在文字后面；次要通道是 44pt 圆形图标，
/// 塞不下同样的标签，所以用浮在角上的气泡。
///
/// 样式取轻量描边而非实心填充：这里只是「上次用的是这个」的提示，实心主色块
/// 太抢眼，会盖过它旁边的主推按钮。也不改图标本身的配色——那会被误读成选中态。
private struct LastUsedBubble: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if isVisible {
                Text(AppLocalized("上次登录"))
                    .font(.system(size: 7, weight: .semibold))
                    // 行高比字号更决定气泡高度：中文字形自带的行距会把胶囊撑高。
                    .lineSpacing(0)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 0.5)
                    .foregroundColor(AppTheme.primary)
                    .background(AppTheme.background, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.primary, lineWidth: 0.8))
                    .fixedSize()
                    // 往圆的右上角外侧顶出去，压在描边上会显得居中、不像角标。
                    .offset(x: 26, y: -10)
            }
        }
    }
}

extension View {
    func lastUsedBubble(_ isVisible: Bool) -> some View {
        modifier(LastUsedBubble(isVisible: isVisible))
    }
}
