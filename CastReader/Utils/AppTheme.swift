//
//  AppTheme.swift
//  CastReader
//
//  统一主题色。**支持深色/浅色自动切换**：每个语义色用 `dyn(light, dark)` 提供明暗两套值，
//  随系统 userInterfaceStyle 实时切换（品牌橙在两种模式下通用）。
//  历史上为浅色硬编码，现已全部动态化——新增颜色请一律走 dyn(...)，勿再硬编码 Color(red:)。
//

import SwiftUI
import UIKit

/// 明暗双色：随系统外观自动切换的动态 Color。
private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
}

// MARK: - App Theme Colors
enum AppTheme {
    // MARK: - Primary Colors (Brand) —— 品牌橙明暗通用（深色略提亮以保对比）
    static let primary = dyn(0xFD5F01, 0xFD6A14)            // #FD5F01
    static let primaryForeground = Color.white             // 橙底白字，两模式一致
    static let primaryLight = dyn(0xFF8A40, 0xFF9A55)      // #FF8A40
    static let primaryDark = dyn(0xD94E00, 0xFF7A2E)      // #D94E00

    // MARK: - Background Colors
    static let background = dyn(0xFAF9F6, 0x121212)        // 暖白 / 暖黑
    static let foreground = dyn(0x1C1B1F, 0xECEAE6)        // 主文字

    // MARK: - Surface/Card Colors
    static let surface = dyn(0xFFFFFF, 0x1E1E1E)           // 卡片背景
    static let surfaceVariant = dyn(0xF0EDE8, 0x2C2A28)
    static let card = surface
    static let cardForeground = foreground

    // MARK: - Secondary Colors
    static let secondary = surfaceVariant
    static let secondaryForeground = dyn(0x5C5C5C, 0xB9B5AE)

    // MARK: - Muted Colors (次要文字)
    static let muted = surfaceVariant
    static let mutedForeground = dyn(0x5C5C5C, 0x9E9A94)

    // MARK: - Accent Colors
    static let accent = secondary
    static let accentForeground = foreground

    // MARK: - Border/Outline Colors
    static let border = dyn(0xE0DCD5, 0x3A3836)
    static let outline = border

    // MARK: - Destructive Colors
    static let destructive = dyn(0xDC3545, 0xFF5A6A)
    static let destructiveForeground = Color.white

    // MARK: - Reader Specific Colors （基于动态 primary/foreground 的透明度叠加，自动适配明暗）
    static let readerHighlightBackground = primary.opacity(0.15)   // 当前段背景
    static let readerActiveWord = primary.opacity(0.50)            // 播放词高亮
    static let readerText = foreground
    static let readerDimmed = foreground.opacity(0.6)              // 未播放文本
    static let readerUnprocessed = foreground.opacity(0.6)         // TTS 未处理文本

    // MARK: - Progress Bar Colors
    static let progressBackground = dyn(0xDCDCDC, 0x3A3A3C)
    static let progressFill = dyn(0x000000, 0xFFFFFF)

    // MARK: - Input Colors
    static let input = dyn(0xBCB6AD, 0x4A4844)
    static let inputBackground = dyn(0xF5F3F0, 0x262422)

    // MARK: - System Colors (本就随外观自适配)
    static var systemBackground: Color { Color(UIColor.systemBackground) }
    static var systemGray6: Color { Color(UIColor.systemGray6) }
    static var systemGray5: Color { Color(UIColor.systemGray5) }
    static var systemGray4: Color { Color(UIColor.systemGray4) }

    // MARK: - Button Styles
    static let buttonPrimary = dyn(0x000000, 0xFFFFFF)
    static let buttonPrimaryForeground = dyn(0xFFFFFF, 0x000000)
    static let buttonSecondary = secondary
    static let buttonSecondaryForeground = foreground

    // MARK: - Tab Bar Colors
    static let tabBarBackground = background
    static let tabBarSelected = primary
    static let tabBarUnselected = mutedForeground
}

// MARK: - Color Extensions
extension Color {
    static let brandAccent = AppTheme.primary
    static let highlightGreen = AppTheme.readerActiveWord

    /// 从 "#RRGGBB" / "RRGGBB" / "#RRGGBBAA" 创建颜色（解析失败回退品牌色）。
    init(hexString: String) {
        self = Color(UIColor(hexString: hexString))
    }
}

// MARK: - UIColor hex / rgb
extension UIColor {
    /// 从 0xRRGGBB 整数创建（不含 alpha）。
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// 从 "#RRGGBB" / "RRGGBB" / "#RRGGBBAA" 创建颜色（解析失败回退品牌橙 #FD5F01）。
    convenience init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else {
            self.init(red: 253/255, green: 95/255, blue: 1/255, alpha: 1); return
        }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
