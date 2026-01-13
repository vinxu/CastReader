//
//  CategoryListView.swift
//  CastReader
//

import SwiftUI

struct CategoryListView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel: CategoryListViewModel
    @ObservedObject private var playerViewModel = PlayerViewModel.shared
    @State private var selectedBook: Book?

    let initialGenre: String
    let allGenres: [String]

    init(initialGenre: String, allGenres: [String]) {
        self.initialGenre = initialGenre
        self.allGenres = allGenres
        _viewModel = StateObject(wrappedValue: CategoryListViewModel(
            initialGenre: initialGenre,
            allGenres: allGenres
        ))
    }

    // All tabs: "All" + all genres
    private var tabs: [String] {
        ["All"] + allGenres
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Tab bar
                genreTabBar

                Divider()

                // Content
                if viewModel.isLoading && viewModel.books.isEmpty {
                    loadingView
                } else if let error = viewModel.error, viewModel.books.isEmpty {
                    errorView(error)
                } else if viewModel.books.isEmpty {
                    emptyView
                } else {
                    bookList
                }
            }
            .navigationTitle(viewModel.selectedGenre.isEmpty ? "All Books" : viewModel.selectedGenre)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                await viewModel.loadInitial()
            }
            .fullScreenCover(item: $selectedBook) { book in
                BookDetailView(book: book)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Genre Tab Bar

    private var genreTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(tabs, id: \.self) { tab in
                        let genre = tab == "All" ? "" : tab
                        let isSelected = genre == viewModel.selectedGenre

                        Button {
                            Task {
                                await viewModel.switchGenre(genre)
                            }
                            // Scroll to selected tab
                            withAnimation {
                                proxy.scrollTo(tab, anchor: .center)
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Text(tab)
                                    .font(.subheadline)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundColor(isSelected ? AppTheme.primary : .secondary)

                                Rectangle()
                                    .fill(isSelected ? AppTheme.primary : Color.clear)
                                    .frame(height: 2)
                            }
                        }
                        .id(tab)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear {
                // Auto-scroll to initial selected tab
                let selectedTab = initialGenre.isEmpty ? "All" : initialGenre
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation {
                        proxy.scrollTo(selectedTab, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Book List

    private var bookList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.books) { book in
                    BookRow(book: book)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedBook = book
                        }
                        .onAppear {
                            Task {
                                await viewModel.loadMoreIfNeeded(currentBook: book)
                            }
                        }

                    Divider()
                        .padding(.leading, 88)
                }

                // Loading more indicator
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                }
            }
            .padding(.bottom, miniPlayerPadding)
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView("Loading...")
            Spacer()
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(error)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task {
                        await viewModel.loadInitial()
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No books found")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // Mini player padding
    private var miniPlayerPadding: CGFloat {
        playerViewModel.isPlaying || !playerViewModel.currentBookId.isEmpty
            ? Constants.UI.miniPlayerHeight + 8
            : 0
    }
}

// MARK: - Book Row

struct BookRow: View {
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

                if !book.description.isEmpty {
                    Text(book.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
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

struct CategoryListView_Previews: PreviewProvider {
    static var previews: some View {
        CategoryListView(
            initialGenre: "Fiction",
            allGenres: ["Fiction", "Nonfiction", "History", "Science"]
        )
    }
}
