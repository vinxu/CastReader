import SwiftUI

struct KindleReadingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let fontValue: Double?
    let canDecrease: Bool
    let canIncrease: Bool
    let isBusy: Bool
    let error: String?
    @Binding var skipsFootnotes: Bool
    let changeFont: (Int) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalized("Kindle 字号"))
                        HStack(spacing: 16) {
                        Button { changeFont(-1) } label: {
                            Image(systemName: "textformat.size.smaller")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(AppLocalized("减小字号"))
                        .accessibilityIdentifier("kindleFontDecrease")
                        .disabled(isBusy || !canDecrease)
                        Spacer(minLength: 4)
                        if isBusy {
                            ProgressView().accessibilityLabel(AppLocalized("正在应用阅读设置…"))
                        } else {
                            Text(fontValue.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—")
                                .monospacedDigit()
                                .accessibilityIdentifier("kindleFontValue")
                        }
                        Spacer(minLength: 4)
                        Button { changeFont(1) } label: {
                            Image(systemName: "textformat.size.larger")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(AppLocalized("增大字号"))
                        .accessibilityIdentifier("kindleFontIncrease")
                        .disabled(isBusy || !canIncrease)
                        }
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text(AppLocalized("调整后将重新排版当前页。点击播放，从当前页开始朗读。"))
                }
                Section {
                    Toggle(AppLocalized("跳过脚注引用编号"), isOn: $skipsFootnotes)
                        .accessibilityIdentifier("kindleSkipFootnotes")
                        .disabled(isBusy)
                } footer: {
                    Text(AppLocalized("仅跳过可明确识别的上标脚注编号，保留正文数字和脚注内容。"))
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                        .accessibilityIdentifier("kindleReadingSettingsError")
                }
            }
            .navigationTitle(AppLocalized("阅读设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("完成")) { dismiss() }
                        .accessibilityIdentifier("kindleReadingSettingsDone")
                        .disabled(isBusy)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy)
    }
}

#if DEBUG
/// UI-layout fixture only. The independent WKWebView tests exercise Amazon's
/// range bridge; this screen never accesses a shelf, account or network.
struct KindleReadingSettingsFixtureView: View {
    @State private var skips = true
    @State private var value: Double = 6

    private var requestedAppearance: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-CastReaderFixtureAppearance"), index + 1 < args.count else { return nil }
        return args[index + 1] == "Dark" ? .dark : .light
    }

    var body: some View {
        KindleReadingSettingsView(
            fontValue: value, canDecrease: value > 1, canIncrease: value < 10,
            isBusy: false, error: nil, skipsFootnotes: $skips,
            changeFont: { value = min(10, max(1, value + Double($0))) }
        )
        .overlay(alignment: .bottomLeading) { KindleFixtureAppearanceProbe() }
        .preferredColorScheme(requestedAppearance)
    }
}

private struct KindleFixtureAppearanceProbe: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Effective fixture appearance")
            .accessibilityValue(Text(verbatim: colorScheme == .dark ? "dark" : "light"))
            .accessibilityIdentifier("kindleFixtureColorScheme")
            .allowsHitTesting(false)
    }
}
#endif
