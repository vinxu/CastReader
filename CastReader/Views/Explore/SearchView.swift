//
//  SearchView.swift
//  CastReader
//

import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var searchResults: [Book] = []
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var selectedBook: Book?
    @State private var currentPage = 0
    @State private var hasMore = true
    @State private var currentQuery = ""

    private let pageSize = 20

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search books...", text: $searchText)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                            .onSubmit {
                                performSearch()
                            }
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)

                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(AppTheme.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                // Content
                if isSearching {
                    Spacer()
                    ProgressView("Searching...")
                    Spacer()
                } else if let error = errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else if hasSearched && searchResults.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No results found")
                            .foregroundColor(.secondary)
                        Text("Try different keywords")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if !searchResults.isEmpty {
                    // Search results
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(searchResults) { book in
                                SearchResultRow(book: book)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedBook = book
                                    }
                                    .onAppear {
                                        loadMoreIfNeeded(currentBook: book)
                                    }
                                Divider()
                                    .padding(.leading, 80)
                            }

                            // Loading more indicator
                            if isLoadingMore {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .padding()
                                    Spacer()
                                }
                            }
                        }
                    }
                } else {
                    // Initial state - search tips
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Search for books")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Enter a title, author, or keyword")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .navigationBarHidden(true)
            .fullScreenCover(item: $selectedBook) { book in
                BookDetailView(book: book)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // Reset pagination state for new search
        currentQuery = query
        currentPage = 0
        hasMore = true
        isSearching = true
        errorMessage = nil

        Task {
            do {
                let results = try await APIService.shared.searchBooks(query: query, page: 0, pageSize: pageSize)
                await MainActor.run {
                    searchResults = results
                    hasSearched = true
                    isSearching = false
                    hasMore = results.count >= pageSize
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    hasSearched = true
                    isSearching = false
                }
            }
        }
    }

    private func loadMoreIfNeeded(currentBook: Book) {
        // Check if this is one of the last few items
        guard let index = searchResults.firstIndex(where: { $0.id == currentBook.id }) else { return }

        // Trigger load when we're 3 items from the end
        let threshold = searchResults.count - 3
        guard index >= threshold else { return }

        loadMore()
    }

    private func loadMore() {
        guard !isLoadingMore && !isSearching && hasMore && !currentQuery.isEmpty else { return }

        isLoadingMore = true

        Task {
            do {
                let nextPage = currentPage + 1
                let results = try await APIService.shared.searchBooks(query: currentQuery, page: nextPage, pageSize: pageSize)

                await MainActor.run {
                    // Append new books (avoid duplicates)
                    let newBooks = results.filter { newBook in
                        !searchResults.contains(where: { $0.id == newBook.id })
                    }
                    searchResults.append(contentsOf: newBooks)
                    currentPage = nextPage
                    hasMore = results.count >= pageSize
                    isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    // Silent fail for pagination
                    isLoadingMore = false
                }
            }
        }
    }
}

// MARK: - Search Result Row
struct SearchResultRow: View {
    let book: Book

    private var hasCover: Bool {
        guard let cover = book.coverUrl, !cover.isEmpty else { return false }
        return URL(string: cover) != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // Cover
            Group {
                if hasCover, let coverUrl = URL(string: book.coverUrl!) {
                    AsyncImage(url: coverUrl) { phase in
                        switch phase {
                        case .empty:
                            coverPlaceholder
                                .overlay(ProgressView().scaleEffect(0.5))
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            coverPlaceholder
                        @unknown default:
                            coverPlaceholder
                        }
                    }
                } else {
                    coverPlaceholder
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(book.author)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let rating = book.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", rating))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundColor(.gray)
            )
    }
}

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView()
    }
}
