//
//  BoundLibraryOnboardingComponents.swift
//  CastReader
//
//  绑定书库首启引导的共享类型与 UI 组件。
//
//  这些原本是 `KindleFirstLaunchFlowView.swift` 里的私有类型；中国区的微信读书
//  引导要用同一套视觉与状态语义，所以提到这里共享。Kindle 侧通过 typealias
//  保持原有名字，调用点零改动。
//

import SwiftUI

// MARK: - 连接状态机

/// 绑定书库在首启引导中的连接进度。
///
/// 与具体书库无关：Kindle 由 `KindleLibrarySyncViewModel` 驱动，微信读书由
/// `WeReadLibrarySyncViewModel` 驱动，两边映射到同一组语义，引导界面因此可以
/// 共用同一套呈现逻辑与埋点阶段。
enum BoundLibraryOnboardingConnectionState: Equatable {
    /// 尚未开始，或引导离开了连接屏。
    case idle
    /// 等待用户在书库官方页面完成登录。
    case awaitingLogin
    /// 已登录，正在扫描书架；`found` 是当前已发现的书籍数。
    case scanning(found: Int)
    /// 书架就绪且至少有一本可朗读的书。
    case ready
    /// 登录成功但书架为空。
    case empty
    /// 连接失败，`message` 可直接展示给用户。
    case failed(message: String)
}

// MARK: - 布局

enum BoundLibraryOnboardingLayout {
    static let maxContentWidth: CGFloat = 520
    static let horizontalPadding: CGFloat = 24
}

// MARK: - 组件

struct OnboardingHeroTitle: View {
    let title: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            singleLine(size: 34)
            singleLine(size: 32)
            singleLine(size: 30)
            singleLine(size: 28)

            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.foreground)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func singleLine(size: CGFloat) -> some View {
        Text(title)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct OnboardingAdaptiveTitle: View {
    let title: String
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 32

    var body: some View {
        Text(title)
            .font(.system(size: titleSize, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.foreground)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .foregroundStyle(AppTheme.buttonPrimaryForeground)
                .background(AppTheme.buttonPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
    }
}

struct OnboardingStepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index == current ? AppTheme.mutedForeground : Color.clear)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.mutedForeground, lineWidth: 1.5)
                    }
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}
