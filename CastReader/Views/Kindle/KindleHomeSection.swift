//
//  KindleHomeSection.swift
//  CastReader
//

import SwiftUI

struct KindleHomeSection: View {
    @ObservedObject var store: KindleLibraryStore
    @ObservedObject private var history = HistoryStore.shared

    private var recentKindleBookIDs: Set<String> {
        Set(history.records.compactMap { $0.sourceKind == .kindle ? $0.id : nil })
    }

    private var orderedHomeBooks: [KindleBook] {
        let activeStoreBooks = store.boundBooks
        let storeByID = Dictionary(uniqueKeysWithValues: activeStoreBooks.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [KindleBook] = []

        for record in history.records where record.sourceKind == .kindle {
            let book = storeByID[record.id] ?? history.kindleBook(for: record)
            guard let book,
                  belongsToBoundStorefront(book),
                  seen.insert(book.id).inserted else { continue }
            result.append(book)
        }

        for book in activeStoreBooks where seen.insert(book.id).inserted {
            result.append(book)
        }

        return Array(
            result
                .sorted {
                    ($0.lastOpenedAt ?? $0.lastSyncedAt)
                        > ($1.lastOpenedAt ?? $1.lastSyncedAt)
                }
                .prefix(8)
        )
    }

    private func belongsToBoundStorefront(_ book: KindleBook) -> Bool {
        let storefrontID = book.storefrontID
            ?? KindleStorefront.storefront(rawURL: book.lastReadURL)?.id
            ?? KindleStorefront.storefront(rawURL: book.readerURL)?.id
            ?? KindleStorefront.us.id
        return storefrontID == store.boundStorefrontID
    }

    var body: some View {
        Group {
            if !store.needsConnection && !orderedHomeBooks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    bookRail
                }
                .accessibilityIdentifier("homeShelfSection.kindle")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Kindle")
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)
                Text("\(store.boundStorefront.flag) \(store.boundStorefront.displayName)")
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
            }
            Spacer()
            NavigationLink(destination: KindleLibraryView()) {
                Text("查看全部")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
            }
            .accessibilityIdentifier("homeShelfViewAll.kindle")
        }
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
                    .accessibilityIdentifier("homeShelfBook.kindle.\(book.id)")
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
        // `AsyncImage` keeps no persistent cache: it re-downloads on every
        // appearance, so returning to Home re-fetched the whole shelf and left
        // every cover blank until the network came back. `CachedAsyncImage` is
        // backed by ImageCache (memory + disk), the same one the rest of the app
        // already uses.
        if let urlString, let url = URL(string: urlString) {
            CachedAsyncImage(url: url, contentMode: .fill) {
                placeholder.overlay { ProgressView().scaleEffect(0.75) }
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
