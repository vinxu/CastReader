//
//  LibraryView.swift
//  CastReader
//

import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()

    // Direct navigation to PlayerView state
    @State private var isLoadingDocument = false
    @State private var loadingDocumentId: String?
    @State private var showPlayer = false
    @State private var selectedDocument: Document?
    @State private var playerParagraphs: [String] = []
    @State private var playerParsedParagraphs: [ParsedParagraph] = []
    @State private var playerIndices: [BookIndex] = []
    @State private var loadError: String?
    @State private var showErrorAlert = false

    // Settings navigation
    @State private var showSettings = false

    private let headerHeight: CGFloat = 56

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Fixed header (same style as ExploreView)
                HStack {
                    Text("Library")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Spacer()

                    // Settings button
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20))
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(height: headerHeight)
                .background(Color(.systemBackground))

                // Content
                if viewModel.isLoading && viewModel.documents.isEmpty {
                    // Initial loading state
                    VStack {
                        Spacer()
                        ProgressView("Loading...")
                        Spacer()
                    }
                } else {
                    // Main content with pull-to-refresh
                    List {
                        if viewModel.documents.isEmpty {
                            // Empty state inside List for pull-to-refresh support
                            Section {
                                VStack(spacing: 12) {
                                    Image(systemName: "books.vertical")
                                        .font(.system(size: 48))
                                        .foregroundColor(.secondary)
                                    Text("No documents yet")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    Text("Upload files or paste text to get started")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            }
                            .listRowBackground(Color.clear)
                        } else {
                            // Processing section
                            if !viewModel.processingDocuments.isEmpty {
                                Section("Processing") {
                                    ForEach(viewModel.processingDocuments) { document in
                                        DocumentRow(document: document, isLoading: false)
                                    }
                                }
                            }

                            // Ready section
                            if !viewModel.savedDocuments.isEmpty {
                                Section("Ready") {
                                    ForEach(viewModel.savedDocuments) { document in
                                        Button {
                                            openDocument(document)
                                        } label: {
                                            DocumentRow(
                                                document: document,
                                                isLoading: loadingDocumentId == document.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isLoadingDocument)
                                    }
                                }
                            }

                            // Failed section
                            if !viewModel.failedDocuments.isEmpty {
                                Section("Failed") {
                                    ForEach(viewModel.failedDocuments) { document in
                                        DocumentRow(document: document, isLoading: false)
                                    }
                                }
                            }
                        }

                        // Error message if any
                        if let error = viewModel.error {
                            Section {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    TTSModelSettingsView()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") {
                                    showSettings = false
                                }
                            }
                        }
                }
            }
            .task {
                await viewModel.loadDocuments()
            }
            .fullScreenCover(isPresented: $showPlayer) {
                if let doc = selectedDocument {
                    NavigationView {
                        PlayerView(
                            bookId: doc.id,
                            bookTitle: doc.name,
                            coverUrl: doc.thumbnail,
                            paragraphs: playerParagraphs,
                            parsedParagraphs: playerParsedParagraphs,
                            indices: playerIndices,
                            language: doc.language ?? "en"  // 使用文档的语言
                        )
                    }
                    .navigationViewStyle(.stack)
                }
            }
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK") {
                    loadError = nil
                }
            } message: {
                Text(loadError ?? "Unknown error occurred")
            }
        }
    }

    private func openDocument(_ document: Document) {
        guard let mdUrl = document.mdUrl else {
            loadError = "No content URL available"
            showErrorAlert = true
            return
        }

        isLoadingDocument = true
        loadingDocumentId = document.id
        selectedDocument = document

        Task {
            do {
                // Fetch MD content
                let mdContent = try await APIService.shared.fetchMarkdownContent(url: mdUrl)

                // Parse MD
                let parsed = MarkdownParser.parse(mdContent)
                let playerData = parsed.asPlayerData

                await MainActor.run {
                    playerParagraphs = playerData.paragraphs
                    playerParsedParagraphs = playerData.parsedParagraphs
                    playerIndices = playerData.indices
                    isLoadingDocument = false
                    loadingDocumentId = nil

                    if playerParagraphs.isEmpty {
                        loadError = "No content found in document"
                        showErrorAlert = true
                    } else {
                        showPlayer = true
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingDocument = false
                    loadingDocumentId = nil
                    loadError = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
}

// MARK: - Document Row
struct DocumentRow: View {
    let document: Document
    var isLoading: Bool = false

    // Check if thumbnail URL is valid (URL encode first, then validate)
    private var thumbnailURL: URL? {
        guard let thumbnail = document.thumbnail, !thumbnail.isEmpty else { return nil }
        // URL encode to handle spaces and special characters
        guard let encoded = thumbnail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            Group {
                if let url = thumbnailURL {
                    CachedAsyncImage(url: url) {
                        thumbnailPlaceholder
                    }
                } else {
                    thumbnailPlaceholder
                }
            }
            .frame(width: 50, height: 65)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let wordCount = document.wordCount {
                        Text("\(wordCount) words")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let chapterCount = document.chapterCount, chapterCount > 0 {
                        Text("\(chapterCount) chapters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Status badge
                if let status = document.processingStatus, !status.isReady {
                    Text(status.displayText)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(statusColor(for: status).opacity(0.2))
                        .foregroundColor(statusColor(for: status))
                        .cornerRadius(4)
                }
            }

            Spacer()

            // Loading indicator
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }
        }
        .padding(.vertical, 4)
    }

    // Gradient fallback placeholder (matches BookCard style)
    private var thumbnailPlaceholder: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: gradientColors(for: document.name),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 2) {
                Spacer()
                Text(document.name)
                    .font(.system(size: 8))
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
        }
    }

    // Generate gradient colors based on document name (matches BookCard)
    private func gradientColors(for name: String) -> [Color] {
        let gradients: [[Color]] = [
            [Color(red: 251/255, green: 113/255, blue: 133/255), Color(red: 253/255, green: 186/255, blue: 116/255)],
            [Color(red: 96/255, green: 165/255, blue: 250/255), Color(red: 129/255, green: 140/255, blue: 248/255)],
            [Color(red: 52/255, green: 211/255, blue: 153/255), Color(red: 34/255, green: 211/255, blue: 238/255)],
            [Color(red: 252/255, green: 211/255, blue: 77/255), Color(red: 234/255, green: 179/255, blue: 8/255)],
            [Color(red: 217/255, green: 70/255, blue: 239/255), Color(red: 236/255, green: 72/255, blue: 153/255)],
            [Color(red: 100/255, green: 116/255, blue: 139/255), Color(red: 30/255, green: 41/255, blue: 59/255)],
        ]

        var hash = 0
        for char in name.unicodeScalars {
            hash = Int(char.value) &+ ((hash << 5) &- hash)
        }
        let index = abs(hash) % gradients.count
        return gradients[index]
    }

    private func statusColor(for status: ProcessingStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .processing: return AppTheme.primary
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Document Detail View
struct DocumentDetailView: View {
    let document: Document

    @ObservedObject private var audioPlayer = AudioPlayerService.shared

    // Loading and navigation state
    @State private var isLoading = false
    @State private var showPlayer = false
    @State private var playerParagraphs: [String] = []
    @State private var playerParsedParagraphs: [ParsedParagraph] = []
    @State private var playerIndices: [BookIndex] = []
    @State private var loadError: String?
    @State private var showErrorAlert = false

    // Mini player 高度 + tab bar 高度 + 额外间距
    private var bottomPadding: CGFloat {
        audioPlayer.hasActivePlayback ? (Constants.UI.miniPlayerHeight + Constants.UI.tabBarHeight + 20) : 0
    }

    // Check if thumbnail URL is valid (URL encode first, then validate)
    private var thumbnailURL: URL? {
        guard let thumbnail = document.thumbnail, !thumbnail.isEmpty else { return nil }
        guard let encoded = thumbnail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Thumbnail
                Group {
                    if let url = thumbnailURL {
                        CachedAsyncImage(url: url) {
                            detailThumbnailPlaceholder
                        }
                    } else {
                        detailThumbnailPlaceholder
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Title
                Text(document.name)
                    .font(.title)
                    .fontWeight(.bold)

                // Stats
                HStack(spacing: 16) {
                    if let wordCount = document.wordCount {
                        Label("\(wordCount) words", systemImage: "text.word.spacing")
                    }
                    if let chapterCount = document.chapterCount {
                        Label("\(chapterCount) chapters", systemImage: "list.bullet")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                // Play button
                Button(action: startReading) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(isLoading ? "Loading..." : "Start Reading")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isLoading || document.mdUrl == nil ? Color.gray : AppTheme.primary)
                    .cornerRadius(12)
                }
                .disabled(isLoading || document.mdUrl == nil)
                .padding(.top, 16)

                Spacer()
            }
            .padding()
            .padding(.bottom, bottomPadding)  // 为 mini player 留出空间
        }
        .navigationTitle(document.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(
            NavigationLink(
                destination: PlayerView(
                    bookId: document.id,
                    bookTitle: document.name,
                    coverUrl: document.thumbnail,
                    paragraphs: playerParagraphs,
                    parsedParagraphs: playerParsedParagraphs,
                    indices: playerIndices,
                    language: document.language ?? "en"  // 使用文档的语言
                ),
                isActive: $showPlayer
            ) {
                EmptyView()
            }
        )
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {
                loadError = nil
            }
        } message: {
            Text(loadError ?? "Unknown error occurred")
        }
    }

    private func startReading() {
        guard let mdUrl = document.mdUrl else {
            loadError = "No content URL available"
            showErrorAlert = true
            return
        }

        isLoading = true

        Task {
            do {
                // 1. Fetch MD content
                let mdContent = try await APIService.shared.fetchMarkdownContent(url: mdUrl)

                // 2. Parse MD
                let parsed = MarkdownParser.parse(mdContent)
                let playerData = parsed.asPlayerData

                await MainActor.run {
                    playerParagraphs = playerData.paragraphs
                    playerParsedParagraphs = playerData.parsedParagraphs
                    playerIndices = playerData.indices
                    isLoading = false

                    if playerParagraphs.isEmpty {
                        loadError = "No content found in document"
                        showErrorAlert = true
                    } else {
                        showPlayer = true
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    loadError = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }

    // Gradient fallback placeholder for detail view
    private var detailThumbnailPlaceholder: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: gradientColors(for: document.name),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(document.name)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    // Generate gradient colors based on document name
    private func gradientColors(for name: String) -> [Color] {
        let gradients: [[Color]] = [
            [Color(red: 251/255, green: 113/255, blue: 133/255), Color(red: 253/255, green: 186/255, blue: 116/255)],
            [Color(red: 96/255, green: 165/255, blue: 250/255), Color(red: 129/255, green: 140/255, blue: 248/255)],
            [Color(red: 52/255, green: 211/255, blue: 153/255), Color(red: 34/255, green: 211/255, blue: 238/255)],
            [Color(red: 252/255, green: 211/255, blue: 77/255), Color(red: 234/255, green: 179/255, blue: 8/255)],
            [Color(red: 217/255, green: 70/255, blue: 239/255), Color(red: 236/255, green: 72/255, blue: 153/255)],
            [Color(red: 100/255, green: 116/255, blue: 139/255), Color(red: 30/255, green: 41/255, blue: 59/255)],
        ]

        var hash = 0
        for char in name.unicodeScalars {
            hash = Int(char.value) &+ ((hash << 5) &- hash)
        }
        let index = abs(hash) % gradients.count
        return gradients[index]
    }
}

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
