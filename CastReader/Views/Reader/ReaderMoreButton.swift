import SwiftUI

struct ReaderOfflineAction {
    let title: String.LocalizationValue
    let open: () -> Void
}

private struct ReaderOfflineActionKey: EnvironmentKey {
    static let defaultValue: ReaderOfflineAction? = nil
}

extension EnvironmentValues {
    var readerOfflineAction: ReaderOfflineAction? {
        get { self[ReaderOfflineActionKey.self] }
        set { self[ReaderOfflineActionKey.self] = newValue }
    }
}

enum ReaderMoreFormatting {
    static func stopTime(_ date: Date, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}

struct ReaderMoreButton: View {
    @Environment(\.readerAppearanceSource) private var appearanceSource
    @Environment(\.readerOfflineAction) private var offlineAction
    @ObservedObject private var timer = AudioPlayerService.shared.sleepTimer
    @State private var panel: Panel?
    @State private var settingsUnavailable = false

    private enum Panel: String, Identifiable {
        case timer, appearance
        var id: String { rawValue }
    }

    var body: some View {
        Menu {
            if let offlineAction {
                Button(action: offlineAction.open) {
                    Label(AppLocalized(offlineAction.title), systemImage: "arrow.down.circle")
                }.accessibilityIdentifier("readerOfflineMenuItem")
            }
            Button { panel = .timer } label: {
                Label(timer.isActive
                    ? AppLocalized("定时停止") + " · " + timer.countdown
                    : AppLocalized("定时停止"), systemImage: "moon.zzz")
            }
            .accessibilityIdentifier("readerSleepTimerMenuItem")
            Button {
                if case .web(let openSettings) = appearanceSource {
                    Task { @MainActor in settingsUnavailable = !(await openSettings()) }
                }
                else { panel = .appearance }
            } label: {
                // Letter-based SF Symbols localize to words such as “格式”.
                // Keep the menu icon pictographic in every system language.
                Label(AppLocalized("阅读设置"), systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("readerAppearanceMenuItem")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: AdaptiveLayout.isPad ? 44 : 36, height: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if timer.isActive {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.primary)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(Text(AppLocalized("更多")))
        .accessibilityValue(Text(timer.isActive ? timer.countdown : AppLocalized("未开启")))
        .accessibilityIdentifier("readerMoreButton")
        .alert(AppLocalized("阅读设置暂不可用"), isPresented: $settingsUnavailable) {
            Button(AppLocalized("完成"), role: .cancel) {}
        } message: {
            Text(AppLocalized("请等待阅读页面加载完成后重试，或使用原阅读器的 Aa 设置。"))
        }
        .readerSettingsPresentation(item: $panel) { item in
            switch item {
            case .timer: SleepTimerSheet(timer: timer)
            case .appearance: ReaderAppearanceSheet(source: appearanceSource)
            }
        }
    }
}

struct SleepTimerSheet: View {
    @ObservedObject var timer: PlaybackSleepTimer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var customMinutes = 20
    @State private var stopTime = Date().addingTimeInterval(1800)
    @State private var customMode = 0

    var body: some View {
        NavigationStack {
            Form {
                if let deadline = timer.deadline {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(timer.countdown)
                                .font(.largeTitle.monospacedDigit().weight(.semibold))
                                .accessibilityIdentifier("sleepTimerCountdown")
                            Text(AppLocalized("停止时间") + " · " + ReaderMoreFormatting.stopTime(deadline, locale: locale))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Button(AppLocalized("取消定时"), role: .destructive) {
                            timer.cancel()
                            dismiss()
                        }.accessibilityIdentifier("sleepTimerCancel")
                    }
                }
                Section(AppLocalized("在此之后停止")) {
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                        Button {
                            timer.start(after: Double(minutes * 60))
                            dismiss()
                        } label: {
                            HStack {
                                Text(String(format: AppLocalized("%lld 分钟"), locale: locale, Int64(minutes)))
                                Spacer()
                                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("sleepTimerPreset.\(minutes)")
                    }
                }
                Section(AppLocalized("自定义")) {
                    Picker(AppLocalized("定时方式"), selection: $customMode) {
                        Text(AppLocalized("时长")).tag(0)
                        Text(AppLocalized("指定时间")).tag(1)
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("sleepTimerCustomMode")
                    if customMode == 0 {
                        Picker(AppLocalized("时长"), selection: $customMinutes) {
                            ForEach(1...180, id: \.self) { minutes in
                                Text(String(format: AppLocalized("%lld 分钟"), locale: locale, Int64(minutes))).tag(minutes)
                            }
                        }.accessibilityIdentifier("sleepTimerCustomDuration")
                    } else {
                        DatePicker(AppLocalized("停止时间"), selection: $stopTime, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("sleepTimerStopTimePicker")
                        Text(ReaderMoreFormatting.stopTime(PlaybackSleepTimer.nextStopTime(stopTime), locale: locale))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(AppLocalized("开始计时")) {
                        if customMode == 0 { timer.start(after: Double(customMinutes * 60)) }
                        else { timer.start(until: PlaybackSleepTimer.nextStopTime(stopTime)) }
                        dismiss()
                    }.accessibilityIdentifier("sleepTimerStartCustom")
                }
                Section {
                    Text(AppLocalized("到时间自动暂停并保留进度。锁屏、暂停或切换模式不会重置倒计时。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(AppLocalized("定时停止"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("完成")) { dismiss() }
                        .accessibilityIdentifier("readerSettingsDone")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct ReaderAppearanceSheet: View {
    let source: ReaderAppearanceSource
    @ObservedObject private var settings = ReaderAppearanceSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if case .fixedLayout = source {
                    Section {
                        Label(AppLocalized("此内容保留原始版式"), systemImage: "doc.richtext")
                        Text(AppLocalized("图片和 PDF 的字号由原稿决定。"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text(AppLocalized("让阅读更舒适"))
                            .font(.system(size: settings.textSize, design: settings.usesSerif ? .serif : .default))
                            .lineSpacing(settings.lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                    Section(AppLocalized("字号")) {
                        HStack {
                            Button {
                                settings.textSize = max(14, settings.textSize - 1)
                            } label: { Image(systemName: "textformat.size.smaller") }
                                .accessibilityLabel(Text(AppLocalized("缩小字号")))
                                .accessibilityIdentifier("readerTextSizeDecrease")
                            Slider(value: $settings.textSize, in: 14...32, step: 1)
                                .accessibilityLabel(Text(AppLocalized("字号")))
                            Button {
                                settings.textSize = min(32, settings.textSize + 1)
                            } label: { Image(systemName: "textformat.size.larger") }
                                .accessibilityLabel(Text(AppLocalized("增大字号")))
                                .accessibilityIdentifier("readerTextSizeIncrease")
                        }.buttonStyle(.borderless)
                        Text("\(Int(settings.textSize)) pt").font(.caption.monospacedDigit())
                            .accessibilityIdentifier("readerTextSizeValue")
                    }
                    if case .text = source {
                        Section(AppLocalized("字体")) {
                            Picker(AppLocalized("字体"), selection: $settings.usesSerif) {
                                Text(AppLocalized("衬线")).tag(true)
                                Text(AppLocalized("系统")).tag(false)
                            }.pickerStyle(.segmented)
                        }
                        Section(AppLocalized("行距")) {
                            Slider(value: $settings.lineSpacing, in: 2...16, step: 1)
                                .accessibilityLabel(Text(AppLocalized("行距")))
                        }
                    }
                    Button(AppLocalized("恢复默认")) { settings.reset() }
                        .accessibilityIdentifier("readerAppearanceReset")
                }
            }
            .navigationTitle(AppLocalized("阅读设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("完成")) { dismiss() }
                        .accessibilityIdentifier("readerSettingsDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
