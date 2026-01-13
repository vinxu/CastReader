//
//  CategoryListViewModel.swift
//  CastReader
//

import Foundation

@MainActor
class CategoryListViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var error: String?
    @Published var selectedGenre: String

    private var currentPage = 0
    private var totalCount = 0
    private var hasMore = true
    private let pageSize = 20

    let allGenres: [String]

    init(initialGenre: String, allGenres: [String]) {
        self.selectedGenre = initialGenre
        self.allGenres = allGenres
    }

    /// Load initial page of books
    func loadInitial() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil
        currentPage = 0
        hasMore = true

        do {
            let data = try await APIService.shared.fetchBooks(
                genre: selectedGenre,
                page: 0,
                pageSize: pageSize
            )
            books = data.list
            totalCount = data.count
            hasMore = books.count < totalCount
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    /// Load more books when scrolling to bottom
    func loadMoreIfNeeded(currentBook: Book) async {
        // Check if this is one of the last few items
        guard let index = books.firstIndex(where: { $0.id == currentBook.id }) else { return }

        // Trigger load when we're 3 items from the end
        let threshold = books.count - 3
        guard index >= threshold else { return }

        await loadMore()
    }

    /// Load next page
    private func loadMore() async {
        guard !isLoadingMore && !isLoading && hasMore else { return }

        isLoadingMore = true

        do {
            let nextPage = currentPage + 1
            let data = try await APIService.shared.fetchBooks(
                genre: selectedGenre,
                page: nextPage,
                pageSize: pageSize
            )

            // Append new books (avoid duplicates)
            let newBooks = data.list.filter { newBook in
                !books.contains(where: { $0.id == newBook.id })
            }
            books.append(contentsOf: newBooks)
            currentPage = nextPage
            totalCount = data.count
            hasMore = books.count < totalCount
            isLoadingMore = false
        } catch {
            // Silent fail for pagination, don't show error
            isLoadingMore = false
        }
    }

    /// Switch to a different genre
    func switchGenre(_ genre: String) async {
        guard genre != selectedGenre else { return }
        selectedGenre = genre
        await loadInitial()
    }
}
