import SwiftUI
import UIKit

final class ReaderAppearanceSettings: ObservableObject {
    static let shared = ReaderAppearanceSettings()
    private let defaults: UserDefaults
    @Published var textSize: Double { didSet { defaults.set(textSize, forKey: "readerTextSize") } }
    @Published var lineSpacing: Double { didSet { defaults.set(lineSpacing, forKey: "readerLineSpacing") } }
    @Published var usesSerif: Bool { didSet { defaults.set(usesSerif, forKey: "readerUsesSerif") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        textSize = min(32, max(14, defaults.object(forKey: "readerTextSize") as? Double ?? 18))
        lineSpacing = min(16, max(2, defaults.object(forKey: "readerLineSpacing") as? Double ?? 8))
        usesSerif = defaults.object(forKey: "readerUsesSerif") as? Bool ?? true
    }

    func reset() {
        textSize = 18
        lineSpacing = 8
        usesSerif = true
    }
}

enum ReaderAppearanceSource {
    case text, webText, fixedLayout
    case web(openSettings: @MainActor () async -> Bool)
}

private struct ReaderAppearanceSourceKey: EnvironmentKey {
    static let defaultValue: ReaderAppearanceSource = .text
}

extension EnvironmentValues {
    var readerAppearanceSource: ReaderAppearanceSource {
        get { self[ReaderAppearanceSourceKey.self] }
        set { self[ReaderAppearanceSourceKey.self] = newValue }
    }
}
