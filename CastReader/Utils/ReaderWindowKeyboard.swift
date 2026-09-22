import SwiftUI
import UIKit

/// Registered by the visible surface in each window, so a hidden reader cannot
/// consume a shortcut intended for another document or a text editor.
enum ReaderWindowCommand: String, CaseIterable {
    case home, library, voices, settings, importContent, newWindow, playPause, dismiss, previous, next
    var input: String {
        switch self {
        case .home: return "1"
        case .library: return "2"
        case .voices: return "3"
        case .settings: return "4"
        case .importContent: return "o"
        case .newWindow: return "n"
        case .playPause: return " "
        case .dismiss: return UIKeyCommand.inputEscape
        case .previous: return UIKeyCommand.inputLeftArrow
        case .next: return UIKeyCommand.inputRightArrow
        }
    }
    var modifiers: UIKeyModifierFlags {
        switch self {
        case .playPause, .dismiss: return []
        case .previous, .next: return .alternate
        default: return .command
        }
    }
    var title: String {
        switch self {
        case .home: return AppLocalized("首页")
        case .library: return AppLocalized("文库")
        case .voices: return AppLocalized("音色")
        case .settings: return AppLocalized("设置")
        case .importContent: return AppLocalized("导入内容")
        case .newWindow: return AppLocalized("新窗口")
        case .playPause: return AppLocalized("播放 / 暂停")
        case .dismiss: return AppLocalized("关闭")
        case .previous: return AppLocalized("后退 / 上一页")
        case .next: return AppLocalized("前进 / 下一页")
        }
    }
    static func matching(_ key: UIKeyCommand) -> Self? {
        allCases.first { $0.input == key.input && $0.modifiers == key.modifierFlags }
    }
}

@MainActor
final class ReaderWindowKeyboard: ObservableObject {
    private var observers: [NSObjectProtocol] = []
    init() {
        for name in [UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification, UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification, UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    struct Registration {
        let priority: Int
        let actions: [ReaderWindowCommand: () -> Void]
    }
    var registrations: [UUID: Registration] = [:] {
        didSet { DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() } }
    }
    func action(_ command: ReaderWindowCommand) -> (() -> Void)? {
        registrations.values.sorted { $0.priority > $1.priority }.compactMap { $0.actions[command] }.first
    }
    static func hasTextEditor(in view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        if view.isFirstResponder {
            if let text = view as? UITextView { return text.isEditable }
            if view is UIControl { return true }
            // WebKit and system editors participate in UITextInput too. Native
            // reader UITextViews are explicitly read-only and handled above.
            if let input = view as? any UITextInput {
                // WebKit keeps its content view as first responder even when
                // no field is being edited. A nil selection means there is no
                // editing insertion point; keep reader shortcuts available.
                return input.selectedTextRange != nil
            }
        }
        return view.subviews.contains(where: hasTextEditor)
    }
}

/// Keeps registrations synchronized with SwiftUI state without stealing focus.
struct ReaderKeyboardRegistration: UIViewRepresentable {
    let scene: ReaderSceneContext
    var priority = 0
    let actions: [ReaderWindowCommand: () -> Void]
    func makeUIView(context: Context) -> Probe { Probe(scene: scene) }
    func updateUIView(_ view: Probe, context: Context) {
        scene.keyboard.registrations[view.id] = .init(priority: priority, actions: actions)
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.scene?.keyboard.registrations[view.id] = nil
    }
    final class Probe: UIView {
        let id = UUID()
        weak var scene: ReaderSceneContext?
        init(scene: ReaderSceneContext) {
            self.scene = scene
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    }
}

private struct ReaderKeyboardSceneKey: FocusedValueKey { typealias Value = ReaderSceneContext }
extension FocusedValues {
    var readerKeyboardScene: ReaderSceneContext? {
        get { self[ReaderKeyboardSceneKey.self] }
        set { self[ReaderKeyboardSceneKey.self] = newValue }
    }
}

struct ReaderAppKeyboardCommands: Commands {
    @FocusedValue(\.readerKeyboardScene) private var scene
    @FocusedObject private var keyboard: ReaderWindowKeyboard?

    private var available: Bool {
        guard AdaptiveLayout.isPad, let window = scene?.window, window.isKeyWindow,
              window.rootViewController?.presentedViewController == nil else { return false }
        return !ReaderWindowKeyboard.hasTextEditor(in: window)
    }
    var body: some Commands {
        CommandMenu("CastReader") {
            ForEach(ReaderWindowCommand.allCases, id: \.rawValue) { command in
                Button(command.title) {
                    guard available else { return }
                    keyboard?.action(command)?()
                }
                .disabled(!available || keyboard?.action(command) == nil)
                .keyboardShortcut(key(command), modifiers: modifiers(command))
            }
        }
    }
    private func key(_ command: ReaderWindowCommand) -> KeyEquivalent {
        switch command {
        case .dismiss: return .escape
        case .previous: return .leftArrow
        case .next: return .rightArrow
        case .playPause: return .space
        default: return KeyEquivalent(Character(command.input))
        }
    }
    private func modifiers(_ command: ReaderWindowCommand) -> EventModifiers {
        switch command {
        case .dismiss, .playPause: return []
        case .previous, .next: return .option
        default: return .command
        }
    }
}
