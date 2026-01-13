//
//  MainTabView.swift
//  CastReader
//

import SwiftUI

// 用于控制 TabBar 显示/隐藏的全局状态
class TabBarVisibility: ObservableObject {
    static let shared = TabBarVisibility()
    @Published var isHidden = false
}

// 隐藏 TabBar 的 View Modifier
struct HideTabBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                TabBarVisibility.shared.isHidden = true
            }
            .onDisappear {
                TabBarVisibility.shared.isHidden = false
            }
    }
}

extension View {
    func hideTabBar() -> some View {
        modifier(HideTabBar())
    }
}

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var previousTab = 0
    @State private var showImportSheet = false
    @State private var showFullPlayer = false

    // Text input direct playback state
    @State private var pendingTextInputData: TextInputData?  // Stored during sheet, activated on dismiss
    @State private var textInputData: TextInputData?  // When set, triggers fullScreenCover

    // EPUB upload direct playback state
    @State private var pendingEPUBResult: EPUBUploadResult?  // Stored during sheet, activated on dismiss
    @State private var epubResult: EPUBUploadResult?  // When set, triggers fullScreenCover

    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    @ObservedObject private var tabBarVisibility = TabBarVisibility.shared

    init() {
        // 设置 TabBar 样式 - 使用主题色
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(AppTheme.background)

        // 未选中状态 - 灰色
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(AppTheme.mutedForeground)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(AppTheme.mutedForeground)]

        // 选中状态 - 主题色
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(AppTheme.primary)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(AppTheme.primary)]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                ExploreView()
                    .tabItem {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                        Text("Explore")
                    }
                    .tag(0)

                // + tab - 使用大号图标
                Color.clear
                    .tabItem {
                        Image(uiImage: createPlusTabImage())
                        Text(" ") // 增加一个空格占位，强制对齐基准线
                    }
                    .tag(1)

                LibraryView()
                    .tabItem {
                        Image(systemName: "headphones")
                        Text("Library")
                    }
                    .tag(2)
            }
            .onChange(of: selectedTab) { newValue in
                if newValue == 1 {
                    // + tab 被点击，弹出 sheet 并恢复之前的 tab
                    showImportSheet = true
                    selectedTab = previousTab
                } else {
                    previousTab = newValue
                }
            }

            // Mini Player Bar - shown when there's active playback and tab bar is visible
            if audioPlayer.hasActivePlayback && !tabBarVisibility.isHidden {
                MiniPlayerBar(
                    audioPlayer: audioPlayer,
                    onTap: { showFullPlayer = true }
                )
                .padding(.bottom, Constants.UI.tabBarHeight + 10)  // 向上移动 10px
            }
        }
        .overlay(
            // Custom half-screen import sheet
            ImportSheetOverlay(
                isPresented: $showImportSheet,
                onDismiss: {
                    // Check if we have pending text input data after ImportSheet dismisses
                    print("🟡 [MainTabView] onDismiss called, pendingTextInputData: \(self.pendingTextInputData?.id ?? "nil"), pendingEPUBResult: \(self.pendingEPUBResult?.bookId ?? "nil")")

                    if let data = self.pendingTextInputData {
                        print("🟡 [MainTabView] ImportSheet dismissed, waiting for animation (text)...")
                        self.pendingTextInputData = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            print("🟡 [MainTabView] Delay complete, setting textInputData for: \(data.id)")
                            self.textInputData = data
                        }
                    } else if let epub = self.pendingEPUBResult {
                        print("📗 [MainTabView] ImportSheet dismissed, waiting for animation (EPUB)...")
                        self.pendingEPUBResult = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            print("📗 [MainTabView] Delay complete, setting epubResult for: \(epub.bookId)")
                            self.epubResult = epub
                        }
                    } else {
                        print("🟡 [MainTabView] onDismiss: no pending data")
                    }
                },
                onTextSubmit: { inputData in
                    print("🟡 [MainTabView] Received TextInputData callback")
                    print("🟡 [MainTabView] inputData.id: \(inputData.id)")
                    print("🟡 [MainTabView] Storing as pendingTextInputData...")
                    self.pendingTextInputData = inputData
                },
                onEPUBUploaded: { epubResult in
                    print("📗 [MainTabView] Received EPUB upload callback")
                    print("📗 [MainTabView] bookId: \(epubResult.bookId)")
                    print("📗 [MainTabView] title: \(epubResult.title)")
                    print("📗 [MainTabView] Storing as pendingEPUBResult...")
                    self.pendingEPUBResult = epubResult
                }
            )
        )
        .fullScreenCover(isPresented: $showFullPlayer) {
            NavigationView {
                PlayerView()
            }
            .navigationViewStyle(.stack)
        }
        // Text input direct playback - uses item: pattern for proper state binding
        .fullScreenCover(item: $textInputData) { data in
            let _ = print("🟡 [MainTabView] fullScreenCover showing for: \(data.id)")
            TextPlayerContent(textInputData: data)
        }
        // EPUB direct playback - uses item: pattern for proper state binding
        .fullScreenCover(item: $epubResult) { result in
            let _ = print("📗 [MainTabView] fullScreenCover showing for EPUB: \(result.bookId)")
            EPUBPlayerContent(epubResult: result)
        }
        .onReceive(tabBarVisibility.$isHidden) { isHidden in
            // 使用 UIKit 隐藏/显示 TabBar
            setTabBarHidden(isHidden)
        }
    }

    private func setTabBarHidden(_ hidden: Bool) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let tabBarController = window.rootViewController as? UITabBarController
                ?? findTabBarController(in: window.rootViewController) else {
            return
        }

        UIView.animate(withDuration: 0.3) {
            tabBarController.tabBar.alpha = hidden ? 0 : 1
        }
        tabBarController.tabBar.isUserInteractionEnabled = !hidden
    }

    private func findTabBarController(in viewController: UIViewController?) -> UITabBarController? {
        if let tabBar = viewController as? UITabBarController {
            return tabBar
        }
        for child in viewController?.children ?? [] {
            if let tabBar = findTabBarController(in: child) {
                return tabBar
            }
        }
        return nil
    }

    // 创建 + 按钮图片（上下居中）
    private func createPlusTabImage() -> UIImage {
        let circleSize: CGFloat = 34
        // 增加总高度到 48，给顶部留出更多空白，迫使圆圈下移
        let totalHeight: CGFloat = 48
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: circleSize, height: totalHeight))

        return renderer.image { context in
            // 关键修改：手动设置 yOffset。
            // 原来是 (48-32)/2 = 8 (居中)。
            // 现在改为 12 或更大，让它在视觉上跟旁边的图标对齐。
            let yOffset: CGFloat = 12

            // 黑色圆形背景
            UIColor.black.setFill()
            let circlePath = UIBezierPath(ovalIn: CGRect(x: 0, y: yOffset, width: circleSize, height: circleSize))
            circlePath.fill()

            // 白色 + 号
            UIColor.white.setStroke()
            let plusPath = UIBezierPath()
            let padding: CGFloat = 9
            let centerX = circleSize / 2
            let centerY = yOffset + circleSize / 2

            plusPath.move(to: CGPoint(x: padding, y: centerY))
            plusPath.addLine(to: CGPoint(x: circleSize - padding, y: centerY))
            plusPath.move(to: CGPoint(x: centerX, y: yOffset + padding))
            plusPath.addLine(to: CGPoint(x: centerX, y: yOffset + circleSize - padding))

            plusPath.lineWidth = 2
            plusPath.lineCapStyle = .round
            plusPath.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerService
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Cover image
            BookCoverImage(
                url: audioPlayer.currentCoverUrl,
                width: 44,
                height: 44,
                cornerRadius: 4
            )

            // Title and subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(audioPlayer.currentBookTitle ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(audioPlayer.currentChapterTitle ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Progress indicator (circular)
            ZStack {
                Circle()
                    .stroke(AppTheme.border, lineWidth: 2)

                Circle()
                    .trim(from: 0, to: audioPlayer.progress)
                    .stroke(AppTheme.primary, lineWidth: 2)
                    .rotationEffect(.degrees(-90))

                // Play/Pause button
                Button(action: { audioPlayer.togglePlayPause() }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .foregroundColor(AppTheme.foreground)
                }
            }
            .frame(width: 36, height: 36)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.card)
                .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Text Player Content (for text input direct playback)
struct TextPlayerContent: View {
    let textInputData: TextInputData  // Non-optional since item: pattern guarantees non-nil

    // Compute playerData once and cache using StateObject wrapper
    @StateObject private var dataHolder: TextPlayerDataHolder

    init(textInputData: TextInputData) {
        self.textInputData = textInputData
        // Initialize with computed playerData
        _dataHolder = StateObject(wrappedValue: TextPlayerDataHolder(textInputData: textInputData))
    }

    var body: some View {
        NavigationView {
            PlayerView(
                bookId: textInputData.id,
                bookTitle: textInputData.title,
                coverUrl: nil,
                paragraphs: dataHolder.paragraphs,
                parsedParagraphs: dataHolder.parsedParagraphs,
                indices: dataHolder.indices
            )
        }
        .navigationViewStyle(.stack)
    }
}

// Helper class to hold computed playerData (computed once on init)
class TextPlayerDataHolder: ObservableObject {
    let paragraphs: [String]
    let parsedParagraphs: [ParsedParagraph]
    let indices: [BookIndex]

    init(textInputData: TextInputData) {
        print("🟡 [TextPlayerContent] Building PlayerView for id: \(textInputData.id)")
        print("🟡 [TextPlayerContent] title: \(textInputData.title)")
        print("🟡 [TextPlayerContent] content length: \(textInputData.content.count) chars")

        let playerData = textInputData.playerData
        print("🟡 [TextPlayerContent] playerData.paragraphs: \(playerData.paragraphs.count)")
        print("🟡 [TextPlayerContent] playerData.parsedParagraphs: \(playerData.parsedParagraphs.count)")
        print("🟡 [TextPlayerContent] playerData.indices: \(playerData.indices.count)")

        self.paragraphs = playerData.paragraphs
        self.parsedParagraphs = playerData.parsedParagraphs
        self.indices = playerData.indices
    }
}

// MARK: - EPUB Player Content (for EPUB upload direct playback)
struct EPUBPlayerContent: View {
    let epubResult: EPUBUploadResult

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var playerParagraphs: [String] = []
    @State private var playerParsedParagraphs: [ParsedParagraph] = []
    @State private var playerIndices: [BookIndex] = []

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading book content...")
                        .foregroundColor(.secondary)
                }
            } else if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Failed to load book")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                NavigationView {
                    PlayerView(
                        bookId: epubResult.bookId,
                        bookTitle: epubResult.title,
                        coverUrl: epubResult.coverUrl,
                        paragraphs: playerParagraphs,
                        parsedParagraphs: playerParsedParagraphs,
                        indices: playerIndices
                    )
                }
                .navigationViewStyle(.stack)
            }
        }
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
        print("📗 [EPUBPlayerContent] Loading content for: \(epubResult.bookId)")
        print("📗 [EPUBPlayerContent] mdUrl: \(epubResult.mdUrl)")

        guard !epubResult.mdUrl.isEmpty else {
            loadError = "No content URL available"
            isLoading = false
            return
        }

        do {
            // Fetch markdown content
            let mdContent = try await APIService.shared.fetchMarkdownContent(url: epubResult.mdUrl)
            print("📗 [EPUBPlayerContent] MD content loaded, length: \(mdContent.count) chars")

            // Parse markdown
            let parsed = MarkdownParser.parse(mdContent)
            let playerData = parsed.asPlayerData

            print("📗 [EPUBPlayerContent] Parsed: \(playerData.paragraphs.count) paragraphs, \(playerData.indices.count) indices")

            await MainActor.run {
                playerParagraphs = playerData.paragraphs
                playerParsedParagraphs = playerData.parsedParagraphs
                playerIndices = playerData.indices

                if playerParagraphs.isEmpty {
                    loadError = "No content found in book"
                }
                isLoading = false
            }
        } catch {
            print("📗 [EPUBPlayerContent] Error loading content: \(error)")
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
