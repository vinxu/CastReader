//
//  CategorySection.swift
//  CastReader
//

import SwiftUI

struct CategorySection: View {
    let title: String
    let books: [Book]
    let allGenres: [String]

    @State private var selectedBook: Book?
    @State private var showCategoryList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: { showCategoryList = true }) {
                    Text("See All")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.primary)
                }
            }
            .padding(.horizontal, 16)

            // Horizontal scroll of books
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(books) { book in
                        Button {
                            selectedBook = book
                        } label: {
                            BookCard(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .fullScreenCover(item: $selectedBook) { book in
            BookDetailView(book: book)
        }
        .fullScreenCover(isPresented: $showCategoryList) {
            CategoryListView(initialGenre: title, allGenres: allGenres)
        }
    }
}

// MARK: - Book Detail View
struct BookDetailView: View {
    let book: Book

    @Environment(\.dismiss) var dismiss
    @State private var isLoadingContent = false
    @State private var showPlayer = false
    @State private var bookParagraphs: [String] = []
    @State private var bookParsedParagraphs: [ParsedParagraph] = []
    @State private var bookIndices: [BookIndex] = []
    @State private var bookCoverUrl: String?  // 从 BookDetail.metadata.cover 获取
    @State private var bookLanguage: String = "en"  // 从 BookDetail.metadata.language 获取
    @State private var loadError: String?
    @State private var showErrorAlert = false

    // 封面 URL（book.coverUrl 已包含编码）
    private var coverURL: URL? {
        guard let cover = book.coverUrl, !cover.isEmpty else { return nil }
        return URL(string: cover)
    }

    var body: some View {
        ZStack {
            // Background gradient - using theme colors
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [AppTheme.secondary, AppTheme.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 400)

                AppTheme.background
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Navigation Bar
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 36, height: 36)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Scrollable Content
                ScrollView {
                    VStack(spacing: 0) {
                        // Cover Image
                        Group {
                            if let url = coverURL {
                                CachedAsyncImage(url: url) {
                                    coverPlaceholder
                                }
                            } else {
                                coverPlaceholder
                            }
                        }
                        .frame(width: 180, height: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 8)
                        .padding(.top, 16)

                        // Title - ALL CAPS
                        Text(book.title.uppercased())
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.top, 24)

                        // Author
                        HStack(spacing: 4) {
                            Text("by")
                                .foregroundColor(.primary)
                            Text(book.author.uppercased())
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                        .padding(.top, 8)

                        // Summary Section
                        if !book.description.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Summary")
                                    .font(.headline)
                                    .fontWeight(.bold)

                                Text(book.description)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .lineSpacing(4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                        }

                        // Details Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Details")
                                .font(.headline)
                                .fontWeight(.bold)

                            // Rating
                            if let rating = book.rating {
                                DetailRow(label: "Rating") {
                                    HStack(spacing: 2) {
                                        ForEach(0..<5) { index in
                                            Image(systemName: index < Int(rating) ? "star.fill" : "star")
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                        }
                                        Text(String(format: "(%.1f)", rating))
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }

                            // Genre
                            if let genres = book.genre, !genres.isEmpty {
                                DetailRow(label: "Genre") {
                                    Text(genres.joined(separator: ", "))
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }

                            // Language
                            DetailRow(label: "Language") {
                                Text("English")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }

                            // Publish Date
                            if let date = book.date, !date.isEmpty {
                                DetailRow(label: "Publish date") {
                                    Text(date)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 120)
                    }
                }

                Spacer(minLength: 0)
            }

            // Bottom Button
            VStack {
                Spacer()
                Button(action: { startReading() }) {
                    HStack(spacing: 8) {
                        if isLoadingContent {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                        }
                        Text(isLoadingContent ? "Loading..." : "Start Reading")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(AppTheme.buttonPrimaryForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isLoadingContent ? AppTheme.mutedForeground : AppTheme.buttonPrimary)
                    .cornerRadius(12)
                }
                .disabled(isLoadingContent)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .background(
                    LinearGradient(
                        colors: [AppTheme.background.opacity(0), AppTheme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 100)
                    .allowsHitTesting(false)
                    , alignment: .bottom
                )
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showPlayer) {
            NavigationView {
                PlayerView(
                    bookId: book.uid,
                    bookTitle: book.title,
                    coverUrl: bookCoverUrl,  // 使用从 BookDetail.metadata.cover 获取的封面
                    paragraphs: bookParagraphs,
                    parsedParagraphs: bookParsedParagraphs,
                    indices: bookIndices,
                    language: bookLanguage  // 使用从 BookDetail.metadata.language 获取的语言
                )
            }
            .navigationViewStyle(.stack)
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {
                loadError = nil
            }
        } message: {
            Text(loadError ?? "Unknown error occurred")
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray5))
            .overlay(
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.gray)
            )
    }

    private func startReading() {
        isLoadingContent = true
        Task {
            do {
                let detail = try await APIService.shared.fetchBookDetail(uid: book.uid)

                // Debug: Print metadata and language
                NSLog("📚 [CategorySection] Book detail loaded: uid=%@", detail.uid)
                NSLog("📚 [CategorySection] metadata: %@", String(describing: detail.metadata))
                NSLog("📚 [CategorySection] metadata.language: %@", detail.metadata?.language ?? "nil")

                guard let contentUrl = detail.content, !contentUrl.isEmpty else {
                    throw APIError.invalidURL
                }

                let htmlContent = try await APIService.shared.fetchHtmlContent(url: contentUrl)
                let parsedParagraphs = htmlContent.extractParagraphsWithIds()
                let paragraphs = parsedParagraphs.map { $0.text }
                let indices = detail.indices ?? []

                await MainActor.run {
                    bookParagraphs = paragraphs
                    bookParsedParagraphs = parsedParagraphs
                    bookIndices = indices
                    bookCoverUrl = detail.coverUrl  // 使用 metadata.cover
                    bookLanguage = detail.metadata?.language ?? "en"  // 使用 metadata.language
                    isLoadingContent = false

                    if paragraphs.isEmpty {
                        loadError = "No content found in this book"
                        showErrorAlert = true
                    } else {
                        showPlayer = true
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingContent = false
                    loadError = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
}

// MARK: - Detail Row
private struct DetailRow<Content: View>: View {
    let label: String
    let content: () -> Content

    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            content()

            Spacer()
        }
    }
}

struct CategorySection_Previews: PreviewProvider {
    static var previews: some View {
        CategorySection(
            title: "Epic & Heroic",
            books: [
                Book(uid: "1", cover: nil, name: "Sample Book", genre: ["Fantasy"], metadata: BookMetadata(title: "Sample Book", author: "Author Name", rating: 4.5, description: "A great book"))
            ],
            allGenres: ["Fiction", "Nonfiction", "History"]
        )
    }
}
