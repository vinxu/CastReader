import SwiftUI

struct EpubTOCSheet: View {
    let navigation: EpubNavigation
    let currentParagraph: Int
    let select: (EpubNavigation.Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var entries: [EpubNavigation.Entry] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? navigation.entries : navigation.entries.filter { $0.title.localizedStandardContains(clean) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if navigation.source == .headings || navigation.source == .spine {
                        Text(AppLocalized("目录由正文结构生成"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        Group {
                            if entry.isGroup {
                                Text(entry.title).font(.headline)
                            } else {
                                Button {
                                    select(entry)
                                    dismiss()
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.title).foregroundStyle(.primary)
                                            if entry.paragraphIndex == nil {
                                                Text(AppLocalized("此目录位置无法打开"))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        if navigation.currentEntry(at: currentParagraph) == entry.id {
                                            Image(systemName: "checkmark").foregroundStyle(AppTheme.primaryText)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .disabled(entry.paragraphIndex == nil)
                                .accessibilityIdentifier("epubTOC.\(entry.id)")
                            }
                        }
                        .padding(.leading, CGFloat(min(entry.depth, 6)) * 14)
                        .id(entry.id)
                    }
                }
                .onAppear {
                    if let current = navigation.currentEntry(at: currentParagraph) {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
            .navigationTitle(AppLocalized("目录"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: AppLocalized("搜索目录"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("完成")) { dismiss() }.accessibilityIdentifier("epubTOCDone")
                }
            }
        }
        .accessibilityIdentifier("epubTOCSheet")
    }
}
