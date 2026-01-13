//
//  ExploreView.swift
//  CastReader
//

import SwiftUI

struct ExploreView: View {
    @StateObject private var viewModel = ExploreViewModel()
    @ObservedObject private var playerViewModel = PlayerViewModel.shared
    @State private var showLoginAlert = false
    @State private var showSearchView = false

    private let headerHeight: CGFloat = 56

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Fixed header
                HStack {
                    Text("Explore")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Spacer()

                    // Search button
                    Button(action: { showSearchView = true }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundColor(.primary)
                    }
                    .padding(.trailing, 12)

                    // Avatar button
                    Button(action: { showLoginAlert = true }) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(height: headerHeight)
                .background(Color(.systemBackground))

                // Content
                if viewModel.isLoading && viewModel.genres.isEmpty {
                    VStack {
                        Spacer()
                        ProgressView("Loading...")
                        Spacer()
                    }
                } else if let error = viewModel.error {
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
                                    await viewModel.loadGenres()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(viewModel.visibleGenres, id: \.self) { genre in
                                CategorySection(
                                    title: genre,
                                    books: viewModel.booksByGenre[genre] ?? [],
                                    allGenres: viewModel.genres
                                )
                                .onAppear {
                                    // Lazy load books when category becomes visible
                                    Task {
                                        await viewModel.loadBooksIfNeeded(for: genre)
                                    }
                                }
                            }

                            // Load more categories trigger
                            if viewModel.hasMoreGenres {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .onAppear {
                                            viewModel.loadMoreCategories()
                                        }
                                    Spacer()
                                }
                                .padding()
                            }
                        }
                        .padding(.vertical, 16)
                        .padding(.bottom, miniPlayerPadding)
                    }
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationBarHidden(true)
            .alert("Coming Soon", isPresented: $showLoginAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Login feature coming soon")
            }
            .fullScreenCover(isPresented: $showSearchView) {
                SearchView()
            }
            .task {
                await viewModel.loadGenres()
            }
        }
        .navigationViewStyle(.stack)
    }

    // 计算底部留空（迷你播放器高度 + 间距）
    private var miniPlayerPadding: CGFloat {
        playerViewModel.isPlaying || !playerViewModel.currentBookId.isEmpty
            ? Constants.UI.miniPlayerHeight + 8
            : 0
    }
}

struct ExploreView_Previews: PreviewProvider {
    static var previews: some View {
        ExploreView()
    }
}
