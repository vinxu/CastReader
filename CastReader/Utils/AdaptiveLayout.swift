import SwiftUI

/// The hosting window's available space, never the main display's dimensions.
/// Keep this outside conditional layout branches so resizing preserves readers.
private struct AppViewportKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

private struct BottomImportControlKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Some compact windows have a system-provided vertical navigation region.
    /// Observe its live placement rather than inferring it from width or model.
    var readerHasVerticalNavigation: Bool {
        if #available(iOS 27.1, *) { return toolbarVerticalEdge != nil }
        return false
    }

    var appViewport: CGSize {
        get { self[AppViewportKey.self] }
        set { self[AppViewportKey.self] = newValue }
    }

    var hasBottomImportControl: Bool {
        get { self[BottomImportControlKey.self] }
        set { self[BottomImportControlKey.self] = newValue }
    }
}

enum AdaptiveLayout {
    static let pageWidth: CGFloat = 1100
    static let readingWidth: CGFloat = 800
    // The compact playback and utility groups fit on one row at phone widths.
    // Stack only when their combined controls no longer fit the actual viewport.
    static func stacksPlaybackControls(in size: CGSize) -> Bool { size.width > 0 && size.width < 360 }
    static func playbackHeight(in size: CGSize) -> CGFloat { stacksPlaybackControls(in: size) ? 104 : 72 }
    static func consoleHeight(in size: CGSize) -> CGFloat { stacksPlaybackControls(in: size) ? 96 : 64 }

    static func usesCompactControls(size: CGSize, accessibility: Bool = false) -> Bool {
        !accessibility && size.width >= 600 && size.width > size.height && size.height < 600
    }
}

/// Small reader tools stay anchored to their trigger in regular iPad windows.
/// Compact windows use the system sheet adaptation so every row stays reachable.
private struct ReaderSettingsPresentation<Item: Identifiable, Panel: View>: ViewModifier {
    @Environment(\.appViewport) private var viewport
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var item: Item?
    let panel: (Item) -> Panel

    @ViewBuilder func body(content: Content) -> some View {
        // One presentation modifier preserves its source view and open panel
        // when the same scene moves between compact and regular width.
        content.popover(item: $item, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { value in
            panel(value)
                .frame(width: horizontalSizeClass == .regular ? min(420, viewport.width > 0 ? max(1, viewport.width - 32) : 420) : nil,
                       height: horizontalSizeClass == .regular ? min(600, viewport.height > 0 ? max(1, viewport.height - 140) : 600) : nil)
                .presentationCompactAdaptation(.sheet)
        }
    }
}

extension View {
    func readerSettingsPresentation<Item: Identifiable, Panel: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Panel
    ) -> some View {
        modifier(ReaderSettingsPresentation(item: item, panel: content))
    }
}

/// A form can grow beyond a short landscape window without hiding its actions.
struct AdaptiveFormScroll<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content()
                    .frame(maxWidth: horizontalSizeClass == .regular ? 680 : .infinity)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// Custom reader headers share the system's actual window-control exclusion
/// region. Full-screen and older iPadOS versions contribute no extra margin.
private struct ReaderWindowControlInsets: ViewModifier {
    @State private var leading: CGFloat = 0
    @State private var trailing: CGFloat = 0
    func body(content: Content) -> some View {
        content.padding(.leading, leading).padding(.trailing, trailing)
            .background(WindowControlProbe { start, end in
                if abs(leading - start) > 0.5 { leading = start }
                if abs(trailing - end) > 0.5 { trailing = end }
            })
    }
    private struct WindowControlProbe: UIViewRepresentable {
        let changed: (CGFloat, CGFloat) -> Void
        func makeUIView(context: Context) -> Probe { Probe(changed: changed) }
        func updateUIView(_ view: Probe, context: Context) { view.setNeedsLayout() }
        final class Probe: UIView {
            let changed: (CGFloat, CGFloat) -> Void
            init(changed: @escaping (CGFloat, CGFloat) -> Void) {
                self.changed = changed
                super.init(frame: .zero)
                isUserInteractionEnabled = false
                isAccessibilityElement = false
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
            override func safeAreaInsetsDidChange() {
                super.safeAreaInsetsDidChange()
                setNeedsLayout()
            }
            override func layoutSubviews() {
                super.layoutSubviews()
                guard #available(iOS 26.0, *) else { return }
                let insets = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
                // Header content already has a 14–16 point horizontal inset.
                let start = max(0, insets.leading - 14)
                let end = max(0, insets.trailing - 14)
                DispatchQueue.main.async { [weak self] in self?.changed(start, end) }
            }
        }
    }
}
extension View {
    func readerWindowControlInsets() -> some View { modifier(ReaderWindowControlInsets()) }
}
