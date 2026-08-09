//
//  CastReaderAppIntents.swift
//  CastReader
//
//  System entry points only deposit a command. The app owns all UI, document
//  resolution, quota checks and playback side effects after it becomes active.
//

import AppIntents
import Foundation

/// Which binary deposited the action. `openAppWhenRun` intents may execute in
/// either the widget or the app process, so widget-vs-Siri is best effort; the
/// distinction that always holds — and the one analytics needs — is
/// "a system surface launched us" versus an ordinary icon tap.
#if CASTREADER_WIDGET
private let castReaderSystemActionOrigin: SystemActionOrigin = .widget
#else
private let castReaderSystemActionOrigin: SystemActionOrigin = .appIntent
#endif

#if !CASTREADER_WIDGET
struct ReadWithCastReaderIntent: AppIntent {
    static let title: LocalizedStringResource = "Read with CastReader"
    static let description = IntentDescription(
        "Open text or a web link in CastReader for read-aloud or explanation."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Text or URL",
        description: "The text or web address to open in CastReader."
    )
    var input: String

    @Parameter(title: "Mode", default: .read)
    var mode: CastReaderIntentMode

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$input) in \(\.$mode) mode")
    }

    init() {}

    init(input: String, mode: CastReaderIntentMode = .read) {
        self.input = input
        self.mode = mode
    }

    var systemAction: SystemAction {
        .read(input: input, mode: mode)
    }

    func perform() async throws -> some IntentResult {
        SystemActionStore.shared.enqueue(systemAction, origin: castReaderSystemActionOrigin)
        return .result()
    }
}

/// A distinct fixed-mode action keeps Siri's Explain phrase from inheriting
/// the configurable Read intent's `.read` default. The compiler does not encode
/// arbitrary initializer assignments as App Shortcut parameter presets.
struct ExplainWithCastReaderIntent: AppIntent {
    static let title: LocalizedStringResource = "Explain with CastReader"
    static let description = IntentDescription(
        "Open text or a web link in CastReader for read-aloud or explanation."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Text or URL",
        description: "The text or web address to open in CastReader."
    )
    var input: String

    static var parameterSummary: some ParameterSummary {
        Summary("Explain \(\.$input) with CastReader")
    }

    init() {}

    init(input: String) {
        self.input = input
    }

    var systemAction: SystemAction {
        .read(input: input, mode: .explain)
    }

    func perform() async throws -> some IntentResult {
        SystemActionStore.shared.enqueue(systemAction, origin: castReaderSystemActionOrigin)
        return .result()
    }
}
#endif

struct ContinueInCastReaderIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue in CastReader"
    static let description = IntentDescription(
        "Continue the latest item, or choose a recent CastReader item."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Recent Item")
    var item: ReadingItemEntity?

    @Parameter(title: "Mode", default: .read)
    var mode: CastReaderIntentMode

    static var parameterSummary: some ParameterSummary {
        Summary("Continue \(\.$item) in \(\.$mode) mode")
    }

    init() {}

    init(item: ReadingItemEntity? = nil, mode: CastReaderIntentMode = .read) {
        self.item = item
        self.mode = mode
    }

    func perform() async throws -> some IntentResult {
        SystemActionStore.shared.enqueue(
            .continueReading(itemID: item?.id, mode: mode),
            origin: castReaderSystemActionOrigin
        )
        return .result()
    }
}

// Only the containing app registers phrases. The widget compiles the intent
// types for buttons/links but must not advertise a duplicate shortcuts catalog.
#if !CASTREADER_WIDGET
struct CastReaderAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReadWithCastReaderIntent(),
            phrases: [
                "Read with \(.applicationName)"
            ],
            shortTitle: "Read with CastReader",
            systemImageName: "text.book.closed"
        )

        AppShortcut(
            intent: ExplainWithCastReaderIntent(),
            phrases: [
                "Explain with \(.applicationName)"
            ],
            shortTitle: "Explain with CastReader",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: ContinueInCastReaderIntent(),
            phrases: [
                "Continue in \(.applicationName)",
                "Keep reading with \(.applicationName)"
            ],
            shortTitle: "Continue Reading",
            systemImageName: "book.pages"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
#endif
