import SwiftUI

/// The hosting window's available space, never the main display's dimensions.
/// Keep this outside conditional layout branches so resizing preserves readers.
private struct AppViewportKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    var appViewport: CGSize {
        get { self[AppViewportKey.self] }
        set { self[AppViewportKey.self] = newValue }
    }
}

enum AdaptiveLayout {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static let pageWidth: CGFloat = 1100
    static let readingWidth: CGFloat = 800

    static func usesCompactControls(size: CGSize, accessibility: Bool = false) -> Bool {
        !accessibility && size.width > size.height && size.height < 600
    }
}
