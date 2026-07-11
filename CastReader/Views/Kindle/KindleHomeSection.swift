//
//  KindleHomeSection.swift
//  CastReader
//

import SwiftUI

struct KindleHomeSection: View {
    @ObservedObject var store: KindleLibraryStore
    @ObservedObject private var history = HistoryStore.shared
    @State private var showConnect = false

    private var recentKindleBookIDs: Set<String> {
        Set(history.records.compactMap { $0.sourceKind == .kindle ? $0.id : nil })
    }

    private var orderedHomeBooks: [KindleBook] {
        let storeByID = Dictionary(uniqueKeysWithValues: store.books.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [KindleBook] = []

        for record in history.records where record.sourceKind == .kindle {
            let book = storeByID[record.id] ?? history.kindleBook(for: record)
            guard let book, seen.insert(book.id).inserted else { continue }
            result.append(book)
        }

        for book in store.homeBooks where seen.insert(book.id).inserted {
            result.append(book)
        }

        return Array(result.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if store.needsConnection {
                connectCard
            } else if orderedHomeBooks.isEmpty {
                emptySyncedCard
            } else {
                bookRail
            }
        }
        .sheet(isPresented: $showConnect) {
            KindleLibraryConnectView()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Kindle")
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)
                Text("已同步的 Kindle 书架")
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
            }
            Spacer()
            if !store.needsConnection {
                NavigationLink(destination: KindleLibraryView()) {
                    Text("查看全部")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.primary)
                }
            }
        }
    }

    private var connectCard: some View {
        Button { showConnect = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.primary.opacity(0.12))
                    .cornerRadius(12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("绑定 Kindle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                    Text("登录后同步书架")
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.mutedForeground)
            }
            .padding(14)
            .background(AppTheme.surface)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connectKindleButton")
    }

    private var emptySyncedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .foregroundColor(AppTheme.primary)
            Text("还没有同步书籍")
                .font(.subheadline)
                .foregroundColor(AppTheme.foreground)
            Spacer()
            Button("同步") { showConnect = true }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.primary)
        }
        .padding(14)
        .background(AppTheme.surface)
        .cornerRadius(16)
    }

    private var bookRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(orderedHomeBooks) { book in
                    Button {
                        KindlePlaybackCenter.shared.open(book: book)
                    } label: {
                        KindleBookRailCard(
                            book: book,
                            isRecent: recentKindleBookIDs.contains(book.id)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, -2)
    }

}

private struct KindleBookRailCard: View {
    let book: KindleBook
    let isRecent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                KindleCoverView(urlString: book.coverURL)
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.65), lineWidth: 1))

                if isRecent {
                    Text("最近")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.primaryForeground)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(AppTheme.primary.opacity(0.82), in: Capsule())
                        .padding(6)
                }
            }

            Text(book.title)
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(2)
                .frame(width: 104, height: 34, alignment: .topLeading)

            Text(book.displayProgress)
                .font(.caption2)
                .foregroundColor(AppTheme.mutedForeground)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
        }
        .frame(width: 108, alignment: .topLeading)
    }
}

struct KindleCoverView: View {
    let urlString: String?

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    placeholder.overlay { ProgressView().scaleEffect(0.75) }
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [AppTheme.primary.opacity(0.18), AppTheme.surfaceVariant], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "book.closed")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(AppTheme.primary)
        }
    }
}
