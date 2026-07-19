//
//  ClipboardPromptView.swift
//  CastReader
//
//  剪贴板检测卡片：按探测到的类型（链接/文本/图片）提示 + 选朗读/解读/忽略。
//  **不预览具体内容**（探测阶段不读取剪贴板，避免触发系统弹框）；点朗读/解读后才读取（系统会请求一次粘贴授权）。
//

import SwiftUI

struct ClipboardPromptView: View {
    let kind: ClipboardImportViewModel.Kind
    let onRead: () -> Void
    let onExplain: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(AppTheme.mutedForeground.opacity(0.3))
                .frame(width: 40, height: 5)
                .padding(.top, 10)

            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(AppTheme.primary)
                Text(title)
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)
            }

            Text("要朗读还是解读？")
                .font(.subheadline)
                .foregroundColor(AppTheme.mutedForeground)

            HStack(spacing: 12) {
                actionButton(AppLocalized("朗读"), "speaker.wave.2.fill", AppTheme.primary, action: onRead)
                actionButton(AppLocalized("解读"), "sparkles", AppTheme.primaryDark, action: onExplain)
            }

            Text("选择后系统会请求一次「允许粘贴」")
                .font(.caption2)
                .foregroundColor(AppTheme.mutedForeground.opacity(0.8))
                .multilineTextAlignment(.center)

            Button(action: onIgnore) {
                Text("忽略")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.mutedForeground)
                    .padding(.vertical, 6)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var icon: String {
        switch kind {
        case .url: return "link"
        case .text: return "text.alignleft"
        case .image: return "photo"
        }
    }

    private var title: String {
        switch kind {
        case .url: return AppLocalized("剪贴板里有一个链接")
        case .text: return AppLocalized("剪贴板里有一段文本")
        case .image: return AppLocalized("剪贴板里有一张图片")
        }
    }

    private func actionButton(_ title: String, _ sysImage: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: sysImage)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
            .foregroundColor(.white)
        }
    }
}
