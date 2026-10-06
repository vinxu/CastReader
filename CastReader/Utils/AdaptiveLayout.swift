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
    /// Legacy name for the resizable-window layout shared by iPad and Mac.
    /// Catalyst's `.mac` idiom must not fall into fixed portrait phone forms.
    static var isPad: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
    static var readerTitleFont: Font {
        #if targetEnvironment(macCatalyst)
        return .system(size: 20, weight: .semibold)
        #else
        return .subheadline.weight(.semibold)
        #endif
    }
    static let pageWidth: CGFloat = 1100
    static let readingWidth: CGFloat = 800
    static func stacksPlaybackControls(in size: CGSize) -> Bool { isPad && size.width > 0 && size.width < 500 }
    static func playbackHeight(in size: CGSize) -> CGFloat { stacksPlaybackControls(in: size) ? 128 : 72 }
    static func consoleHeight(in size: CGSize) -> CGFloat { stacksPlaybackControls(in: size) ? 120 : 64 }

    static func usesCompactControls(size: CGSize, accessibility: Bool = false) -> Bool {
        !accessibility && size.width >= 600 && size.width > size.height && size.height < 600
    }
}

/// Catalyst's compact navigation buttons can truncate localized text to a
/// couple of letters. Keep an accessible, keyboard-operable dismissal control.
struct AdaptiveSheetDismissButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        #if targetEnvironment(macCatalyst)
        Button(action: action) {
            Label(title, systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(title)
        .keyboardShortcut(.cancelAction)
        #else
        Button(title, action: action)
        #endif
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

/// Custom reader headers share the system's actual window-control exclusion
/// region. Full-screen and older iPadOS versions contribute no extra margin.
private struct ReaderWindowControlInsets: ViewModifier {
    @State private var leading: CGFloat = 0
    @State private var trailing: CGFloat = 0
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // Keep reader controls inside the content safe area. Drawing underneath
        // the native titlebar makes them visible but intercepts mouse clicks.
        content
        #else
        content.padding(.leading, leading).padding(.trailing, trailing)
            .background(WindowControlProbe { start, end in
                if abs(leading - start) > 0.5 { leading = start }
                if abs(trailing - end) > 0.5 { trailing = end }
            })
        #endif
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
            override func layoutSubviews() {
                super.layoutSubviews()
                guard AdaptiveLayout.isPad, #available(iOS 26.0, *) else { return }
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

#if targetEnvironment(macCatalyst)
/// Mac has a sidebar, so it does not need UITabBarController's transitions or
/// adaptive toolbar layout. Retain each page's navigation/scroll state, while
/// only the selected page participates in the window's layout and lifecycle.
struct MacSidebarPages<Content: View>: UIViewControllerRepresentable {
    let selection: Int
    @ViewBuilder let content: (Int) -> Content

    func makeUIViewController(context: Context) -> MacSidebarPageController {
        MacSidebarPageController()
    }

    func updateUIViewController(_ controller: MacSidebarPageController, context: Context) {
        controller.select(selection) { tab in
            AnyView(content(tab).environment(\.self, context.environment))
        }
    }
}

final class MacSidebarPageController: UIViewController {
    private(set) var selectedTab: Int?
    private(set) var pages: [Int: UIHostingController<AnyView>] = [:]
    private var pendingLayoutLog: Int?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    func select(_ tab: Int, content: (Int) -> AnyView) {
        loadViewIfNeeded()
        if selectedTab == tab, let current = pages[tab] {
            current.rootView = content(tab)
            return
        }
        let previous = selectedTab.flatMap { pages[$0] }
        let previousTab = selectedTab
        let next = pages[tab] ?? UIHostingController(rootView: content(tab))
        if pages[tab] != nil { next.rootView = content(tab) }
        next.sizingOptions = []
        next.view.backgroundColor = .clear
        UIView.performWithoutAnimation {
            previous?.willMove(toParent: nil)
            previous?.view.removeFromSuperview()
            previous?.removeFromParent()
            // Deliver isSurfaceActive=false without laying out the old page.
            if let previous, let previousTab { previous.rootView = content(previousTab) }
            pages[tab] = next
            selectedTab = tab
            addChild(next)
            next.view.frame = view.bounds
            next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(next.view)
            next.didMove(toParent: self)
        }
        pendingLayoutLog = tab
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let tab = pendingLayoutLog {
            pendingLayoutLog = nil
            ReaderRunLog.write("SIDEBAR content laid out=\(tab)")
        }
    }
}

/// A retained reader owns its header. The underlying tab's promoted toolbar
/// must not leave a second, sidebar-aligned title row above it on Mac.
struct MacReaderTitlebar: UIViewRepresentable {
    let hidden: Bool
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.chromeHidden = hidden
        view.apply()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }
    final class Probe: UIView {
        var chromeHidden = false
        private var restoreTitlebar: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        override func layoutSubviews() { super.layoutSubviews(); apply() }
        func apply() {
            guard let titlebar = window?.windowScene?.titlebar else { return }
            guard chromeHidden else { restore(); return }
            if restoreTitlebar == nil {
                let toolbar = titlebar.toolbar
                let visibility = titlebar.titleVisibility
                restoreTitlebar = { [weak titlebar] in
                    guard let titlebar else { return }
                    titlebar.titleVisibility = visibility
                    if titlebar.toolbar == nil { titlebar.toolbar = toolbar }
                }
            }
            if titlebar.titleVisibility != .hidden { titlebar.titleVisibility = .hidden }
            if titlebar.toolbar != nil { titlebar.toolbar = nil }
        }
        func restore() {
            restoreTitlebar?()
            restoreTitlebar = nil
        }
    }
}
#endif
