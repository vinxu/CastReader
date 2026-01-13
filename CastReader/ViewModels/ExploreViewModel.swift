//
//  ExploreViewModel.swift
//  CastReader
//

import Foundation

@MainActor
class ExploreViewModel: ObservableObject {
    @Published var genres: [String] = []
    @Published var booksByGenre: [String: [Book]] = [:]
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var error: String?

    // Frontend pagination
    @Published var visibleGenresCount = 10
    private let genresPerPage = 10
    private let booksPageSize = 10

    // Track which genres are currently loading books
    private var loadingGenres: Set<String> = []

    // Visible genres (for frontend pagination)
    var visibleGenres: [String] {
        Array(genres.prefix(visibleGenresCount))
    }

    // Check if there are more genres to show
    var hasMoreGenres: Bool {
        visibleGenresCount < genres.count
    }

    /// Load all genres (no books yet)
    func loadGenres() async {
        guard genres.isEmpty else { return }

        isLoading = true
        error = nil

        do {
            genres = try await APIService.shared.fetchGenres(number: 100)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Refresh all data (pull to refresh)
    func refresh() async {
        error = nil

        // Fetch new data first, then replace (don't clear before fetch)
        do {
            let newGenres = try await APIService.shared.fetchGenres(number: 100)

            // Success - now replace cached data
            genres = newGenres
            booksByGenre = [:]
            loadingGenres = []
            visibleGenresCount = genresPerPage
        } catch {
            // Only show error if we have no data at all
            if genres.isEmpty {
                self.error = error.localizedDescription
            }
            // Otherwise silently fail and keep existing data
        }
    }

    /// Load more categories (frontend pagination)
    func loadMoreCategories() {
        guard hasMoreGenres && !isLoadingMore else { return }
        isLoadingMore = true
        visibleGenresCount = min(visibleGenresCount + genresPerPage, genres.count)
        isLoadingMore = false
    }

    /// Load books for a specific genre (lazy loading)
    func loadBooksIfNeeded(for genre: String) async {
        // Skip if already loaded or currently loading
        guard booksByGenre[genre] == nil && !loadingGenres.contains(genre) else { return }

        loadingGenres.insert(genre)

        do {
            let data = try await APIService.shared.fetchBooks(genre: genre, page: 0, pageSize: booksPageSize)
            booksByGenre[genre] = data.list
        } catch {
            // Silent fail for individual genre loading
            print("Failed to load books for genre \(genre): \(error.localizedDescription)")
        }

        loadingGenres.remove(genre)
    }
}
