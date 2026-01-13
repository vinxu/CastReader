//
//  AppTheme.swift
//  CastReader
//
//  Unified theme colors based on CastReader Web (tweakcn configuration)
//  Converted from oklch to RGB values
//

import SwiftUI

// MARK: - App Theme Colors
enum AppTheme {
    // MARK: - Primary Colors (Brand)
    // Brand orange color
    static let primary = Color(red: 253/255, green: 95/255, blue: 1/255)          // #fd5f01
    static let primaryForeground = Color.white

    // MARK: - Background Colors
    // oklch(0.9818 0.0054 95.0986) → Warm white background
    static let background = Color(red: 250/255, green: 248/255, blue: 245/255)    // #faf8f5
    // oklch(0.3438 0.0269 95.7226) → Dark brown-gray foreground
    static let foreground = Color(red: 77/255, green: 68/255, blue: 58/255)       // #4d443a

    // MARK: - Card Colors
    static let card = background
    static let cardForeground = Color(red: 38/255, green: 35/255, blue: 30/255)   // Darker for card text

    // MARK: - Secondary Colors
    // oklch(0.9245 0.0138 92.9892) → Light beige
    static let secondary = Color(red: 234/255, green: 230/255, blue: 223/255)     // #eae6df
    static let secondaryForeground = Color(red: 100/255, green: 92/255, blue: 80/255)

    // MARK: - Muted Colors
    // oklch(0.9341 0.0153 90.239) → Soft gray
    static let muted = Color(red: 238/255, green: 234/255, blue: 227/255)         // #eeeae3
    // oklch(0.6059 0.0075 97.4233) → Gray text
    static let mutedForeground = Color(red: 153/255, green: 150/255, blue: 146/255) // #999692

    // MARK: - Accent Colors
    static let accent = secondary
    static let accentForeground = Color(red: 60/255, green: 52/255, blue: 40/255)

    // MARK: - Border Colors
    // oklch(0.8847 0.0069 97.3627) → Border gray
    static let border = Color(red: 222/255, green: 220/255, blue: 217/255)        // #dedcd9

    // MARK: - Destructive Colors
    static let destructive = Color(red: 220/255, green: 53/255, blue: 69/255)     // Red
    static let destructiveForeground = Color.white

    // MARK: - Reader Specific Colors
    // Current paragraph background - 15% opacity of brand color
    static let readerHighlightBackground = primary.opacity(0.15)
    // Active word highlight - 50% opacity of brand color
    static let readerActiveWord = primary.opacity(0.50)
    // Reader text color
    static let readerText = Color(red: 51/255, green: 51/255, blue: 51/255)       // #333333
    // Reader dimmed text
    static let readerDimmed = Color(red: 115/255, green: 115/255, blue: 115/255)  // #737373

    // MARK: - Progress Bar Colors
    static let progressBackground = Color(red: 220/255, green: 220/255, blue: 220/255)
    static let progressFill = Color.black

    // MARK: - Input Colors
    static let input = Color(red: 188/255, green: 182/255, blue: 173/255)
    static let inputBackground = Color(red: 245/255, green: 243/255, blue: 240/255)

    // MARK: - System Colors (for iOS compatibility)
    static var systemBackground: Color {
        Color(UIColor.systemBackground)
    }

    static var systemGray6: Color {
        Color(UIColor.systemGray6)
    }

    static var systemGray5: Color {
        Color(UIColor.systemGray5)
    }

    static var systemGray4: Color {
        Color(UIColor.systemGray4)
    }

    // MARK: - Button Styles
    static let buttonPrimary = Color.black
    static let buttonPrimaryForeground = Color.white
    static let buttonSecondary = secondary
    static let buttonSecondaryForeground = foreground

    // MARK: - Tab Bar Colors
    static let tabBarBackground = background
    static let tabBarSelected = primary
    static let tabBarUnselected = mutedForeground
}

// MARK: - Color Extensions
extension Color {
    // Brand accent color (same as primary)
    static let brandAccent = AppTheme.primary

    // Highlight green (legacy, replaced by readerActiveWord)
    static let highlightGreen = AppTheme.readerActiveWord
}
