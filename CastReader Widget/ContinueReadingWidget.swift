import AppIntents
import SwiftUI
import WidgetKit

private enum ContinueWidgetConstants {
    static let kind = "CastReaderContinueWidget"
    static let importURL = URL(string: "castreader://import")!
    static let refreshInterval: TimeInterval = 15 * 60
}

struct ContinueWidgetEntry: TimelineEntry {
    let date: Date
    let items: [ContinueSnapshot]
}

struct ContinueWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWidgetEntry {
        placeholderEntry()
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ContinueWidgetEntry) -> Void
    ) {
        let entry = makeEntry()
        completion(context.isPreview && entry.items.isEmpty ? placeholderEntry() : entry)
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ContinueWidgetEntry>) -> Void
    ) {
        let entry = makeEntry()
        let nextRefresh = entry.date.addingTimeInterval(ContinueWidgetConstants.refreshInterval)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func makeEntry(at date: Date = Date()) -> ContinueWidgetEntry {
        let items = ContinueSnapshotStore.shared.snapshots()
            .sorted { $0.updatedAt > $1.updatedAt }
        return ContinueWidgetEntry(date: date, items: Array(items.prefix(3)))
    }

    private func placeholderEntry(at date: Date = Date()) -> ContinueWidgetEntry {
        ContinueWidgetEntry(
            date: date,
            items: [
                ContinueSnapshot(
                    id: "widget-placeholder",
                    title: String(localized: "widget_placeholder_title"),
                    sourceKind: "pdf",
                    updatedAt: date.addingTimeInterval(-12 * 60)
                )
            ]
        )
    }
}

struct ContinueReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: ContinueWidgetConstants.kind,
            provider: ContinueWidgetProvider()
        ) { entry in
            ContinueReadingWidgetView(entry: entry)
        }
        .configurationDisplayName("widget_name")
        .description("widget_description")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private struct ContinueReadingWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ContinueWidgetEntry

    var body: some View {
        Group {
            if let item = entry.items.first {
                switch family {
                case .systemMedium:
                    MediumContinueView(item: item)
                default:
                    SmallContinueView(item: item)
                }
            } else {
                EmptyContinueView(family: family)
            }
        }
        .containerBackground(for: .widget) {
            ContinueWidgetBackground()
        }
    }
}

private struct SmallContinueView: View {
    let item: ContinueSnapshot

    var body: some View {
        Button(intent: ContinueInCastReaderIntent(
            item: ReadingItemEntity(snapshot: item),
            mode: .read
        )) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CastReaderMark(size: 30)
                    Spacer(minLength: 8)
                    Image(systemName: sourceSymbol(for: item.sourceKind))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(item.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                    Text("widget_continue")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.castReaderOrange)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("widget_continue"))
        .accessibilityValue(Text(item.title))
    }
}

private struct MediumContinueView: View {
    let item: ContinueSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                CastReaderMark(size: 26)
                Text("widget_recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(item.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: sourceSymbol(for: item.sourceKind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.castReaderOrange)

                Text(item.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                WidgetIntentButton(
                    titleKey: "widget_read_aloud",
                    systemImage: "play.fill",
                    tint: .castReaderOrange,
                    intent: ContinueInCastReaderIntent(
                        item: ReadingItemEntity(snapshot: item),
                        mode: .read
                    )
                )

                WidgetIntentButton(
                    titleKey: "widget_explain",
                    systemImage: "sparkles",
                    tint: .indigo,
                    intent: ContinueInCastReaderIntent(
                        item: ReadingItemEntity(snapshot: item),
                        mode: .explain
                    )
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct WidgetIntentButton<Intent: AppIntent>: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let intent: Intent

    var body: some View {
        Button(intent: intent) {
            Label(titleKey, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyContinueView: View {
    let family: WidgetFamily

    var body: some View {
        Link(destination: ContinueWidgetConstants.importURL) {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 9 : 7) {
                HStack {
                    CastReaderMark(size: 30)
                    Spacer()
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.castReaderOrange)
                }

                Spacer(minLength: 0)

                Text("widget_empty_title")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("widget_empty_message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemSmall ? 2 : 1)

                Label("widget_import", systemImage: "doc.badge.plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.castReaderOrange)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("widget_import"))
    }
}

private struct CastReaderMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color.castReaderOrange.gradient)

            Image(systemName: "waveform")
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ContinueWidgetBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [Color.castReaderOrange.opacity(0.14), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private extension Color {
    static let castReaderOrange = Color(red: 0.96, green: 0.32, blue: 0.10)
}

private func sourceSymbol(for sourceKind: String) -> String {
    switch sourceKind.lowercased() {
    case "photo", "camera":
        return "camera.fill"
    case "pdf":
        return "doc.richtext.fill"
    case "epub", "book", "kindle", "kobo", "googlebooks", "oreilly", "weread":
        return "book.closed.fill"
    case "url", "web", "safari":
        return "safari.fill"
    default:
        return "doc.text.fill"
    }
}
