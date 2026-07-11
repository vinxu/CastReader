//
//  KindleLibraryView.swift
//  CastReader
//

import SwiftUI

struct KindleLibraryView: View {
    @ObservedObject private var store = KindleLibraryStore.shared
    @State private var query = ""
    @State private var sort: KindleLibrarySort = .recent
    @State private var page = 1
    @State private var showConnect = false

    private let pageSize = 24

    private var filteredBooks: [KindleBook] {
        store.sortedBooks(sort: sort, query: query)
    }

    private var visibleBooks: [KindleBook] {
        Array(filteredBooks.prefix(page * pageSize))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if visibleBooks.isEmpty {
                    emptyState
                } else {
                    bookList
                    if visibleBooks.count < filteredBooks.count {
                        loadMoreButton
                    }
                }
            }
            .padding(18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Kindle 书架")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConnect = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text("刷新 Kindle 书架"))
            }
        }
        .searchable(text: $query, prompt: "搜索 Kindle 书籍")
        .onChange(of: query) { _, _ in page = 1 }
        .onChange(of: sort) { _, _ in page = 1 }
        .sheet(isPresented: $showConnect) {
            KindleLibraryConnectView()
        }
    }

    private var controls: some View {
        HStack {
            Picker("排序", selection: $sort) {
                ForEach(KindleLibrarySort.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Button {
                showConnect = true
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.primary.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(Text("同步 Kindle 书架"))
        }
    }

    private var bookList: some View {
        LazyVStack(spacing: 12) {
            ForEach(visibleBooks) { book in
                KindleLibraryRow(
                    book: book,
                    open: { KindlePlaybackCenter.shared.open(book: book) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.needsConnection ? "books.vertical" : "magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(AppTheme.primary)
            Text(LocalizedStringKey(store.needsConnection ? "绑定 Kindle" : "没有匹配的书籍"))
                .font(.headline)
                .foregroundColor(AppTheme.foreground)
            Button(LocalizedStringKey(store.needsConnection ? "登录" : "刷新")) {
                showConnect = true
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private var loadMoreButton: some View {
        Button {
            page += 1
        } label: {
            Text("加载更多")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundColor(AppTheme.primary)
    }
}

private struct KindleLibraryRow: View {
    let book: KindleBook
    let open: () -> Void

    private var lastOpenedText: String {
        let date = book.lastOpenedAt ?? book.lastSyncedAt
        return date.formatted(.relative(presentation: .named))
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 14) {
                KindleCoverView(urlString: book.coverURL)
                    .frame(width: 64, height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border.opacity(0.65), lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                        .lineLimit(2)

                    Text(book.displayAuthor)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(book.displayProgress)
                        Text("·")
                        Text(lastOpenedText)
                    }
                    .font(.caption2)
                    .foregroundColor(AppTheme.mutedForeground)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.mutedForeground.opacity(0.8))
                .frame(width: 28)
        }
        .padding(12)
        .background(AppTheme.surface)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border.opacity(0.65), lineWidth: 1))
    }
}
