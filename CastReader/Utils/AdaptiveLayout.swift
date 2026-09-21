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

/// Small reader tools stay anchored to their trigger in regular iPad windows.
/// Compact windows use the system sheet adaptation so every row stays reachable.
private struct ReaderSettingsPresentation<Item: Identifiable, Panel: View>: ViewModifier {
    @Environment(\.appViewport) private var viewport
    @Binding var item: Item?
    let panel: (Item) -> Panel

    @ViewBuilder func body(content: Content) -> some View {
        if AdaptiveLayout.isPad {
            content.popover(item: $item, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { value in
                panel(value)
                    .frame(width: min(420, viewport.width > 0 ? max(1, viewport.width - 32) : 420),
                           height: min(600, viewport.height > 0 ? max(1, viewport.height - 140) : 600))
                    .presentationCompactAdaptation(.sheet)
            }
        } else {
            content.sheet(item: $item, content: panel)
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
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content()
                    .frame(maxWidth: AdaptiveLayout.isPad ? 680 : .infinity)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// Overlays do not participate in their host's keyboard avoidance. Measure the
/// docked keyboard in this view's own window and reserve its intersection once,
/// instead of letting a fixed-height nested NavigationStack subtract it again.
struct WindowKeyboardInsetReader: UIViewRepresentable {
    @Binding var inset: CGFloat
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.changed = { value in
            DispatchQueue.main.async { if abs(inset - value) > 0.5 { inset = value } }
        }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        var changed: ((CGFloat) -> Void)?
        private var keyboardFrame: CGRect?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func layoutSubviews() { super.layoutSubviews(); measure() }
        @objc private func keyboardChanged(_ note: Notification) {
            guard let window, containsFirstResponder(window) else { return }
            keyboardFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            measure()
        }
        @objc private func keyboardHidden(_ note: Notification) { keyboardFrame = nil; changed?(0) }
        private func containsFirstResponder(_ view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains(where: containsFirstResponder)
        }
        private func measure() {
            guard let window, let keyboardFrame else { changed?(0); return }
            let keyboard = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let container = convert(bounds, to: window)
            let intersection = container.intersection(keyboard)
            // Floating keyboards are movable and must not collapse the whole panel.
            let docked = keyboard.maxY >= window.bounds.maxY - 1 &&
                intersection.width >= container.width * 0.8
            changed?(docked && !intersection.isNull ? max(0, intersection.height) : 0)
        }
    }
}
