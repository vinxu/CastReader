//
//  KindleLibraryConnectView.swift
//  CastReader
//

import SwiftUI
import WebKit

struct KindleLibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = KindleLibrarySyncViewModel()
    @ObservedObject private var store = KindleLibraryStore.shared

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                KindleWebView(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)

                statusBar
            }
            .navigationTitle("绑定 Kindle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("同步") { Task { await model.syncLibrary() } }
                        .disabled(model.isSyncing)
                }
            }
            .onAppear { model.loadIfNeeded() }
        }
        .navigationViewStyle(.stack)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if model.isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: store.books.isEmpty ? "book.closed" : "checkmark.circle.fill")
                        .foregroundColor(store.books.isEmpty ? AppTheme.primary : .green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                        .lineLimit(2)
                    Text(model.secondaryStatusText(bookCount: store.books.count))
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                }
                Spacer()
                if !store.books.isEmpty {
                    Button("完成") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.primary)
                }
            }

            if model.currentReaderBook != nil {
                HStack(spacing: 10) {
                    Text("当前是 Kindle 书籍页面，请回到书架后同步。")
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(2)
                    Spacer()
                    Button("Kindle 书架") {
                        model.loadLibrary()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.primary, in: Capsule())
                }
            }

            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundColor(AppTheme.destructive)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

struct KindleViewportCrop: Equatable {
    var scale: CGFloat
    var heightScale: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat

    init(scale: CGFloat, heightScale: CGFloat? = nil, offsetX: CGFloat, offsetY: CGFloat) {
        self.scale = scale
        self.heightScale = heightScale ?? scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    static let identity = KindleViewportCrop(scale: 1, heightScale: 1, offsetX: 0, offsetY: 0)

    var isIdentity: Bool {
        abs(scale - 1) < 0.001 &&
            abs(heightScale - 1) < 0.001 &&
            abs(offsetX) < 0.5 &&
            abs(offsetY) < 0.5
    }
}

final class KindleWebViewContainer: UIView {
    let webView: WKWebView
    var crop: KindleViewportCrop = .identity {
        didSet {
            if crop != oldValue {
                setNeedsLayout()
            }
        }
    }

    init(webView: WKWebView, crop: KindleViewportCrop = .identity) {
        self.webView = webView
        self.crop = crop
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        webView.transform = .identity
        if crop.isIdentity {
            webView.frame = bounds
            return
        }

        let widthScale = max(1, min(crop.scale, 2.4))
        let heightScale = max(1, min(crop.heightScale, 2.4))
        webView.frame = CGRect(
            x: crop.offsetX,
            y: crop.offsetY,
            width: size.width * widthScale,
            height: size.height * heightScale
        )
    }
}

struct KindleWebView: UIViewRepresentable {
    let webView: WKWebView
    var crop: KindleViewportCrop = .identity

    func makeUIView(context: Context) -> KindleWebViewContainer {
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        return KindleWebViewContainer(webView: webView, crop: crop)
    }

    func updateUIView(_ uiView: KindleWebViewContainer, context: Context) {
        uiView.crop = crop
    }
}

@MainActor
final class KindleLibrarySyncViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isSyncing = false
    @Published var statusText = String(localized: "打开 Amazon Kindle 并登录。")
    @Published var errorText: String?
    @Published var currentReaderBook: KindleBook?

    let webView: WKWebView
    private var didLoad = false
    private let store = KindleLibraryStore.shared

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        webView.load(URLRequest(url: KindleWebScripts.libraryURL))
    }

    func loadLibrary() {
        currentReaderBook = nil
        statusText = String(localized: "打开 Kindle 书架，然后点同步。")
        webView.load(URLRequest(url: KindleWebScripts.libraryURL))
    }

    func secondaryStatusText(bookCount: Int) -> String {
        if currentReaderBook != nil {
            return String(localized: "返回 Kindle 书架后再同步。")
        }
        if bookCount > 0 {
            return String(format: String(localized: "已在本机同步 %d 本书。"), bookCount)
        }
        return String(localized: "登录后点同步。")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusText = String(localized: "如果已经看到 Kindle 书架，请点同步。")
        Task { await refreshPageState() }
    }

    func syncLibrary(lightPass: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        errorText = nil
        defer { isSyncing = false }

        do {
            statusText = String(localized: "正在扫描 Kindle 书架…")
            var byID: [String: KindleBook] = [:]
            let maxPasses = lightPass ? 2 : 12
            var idlePasses = 0
            var sawAuthRequired = false
            var sawReaderPage = false
            var sawLibrarySignals = false
            var accountInfo: KindleAccountInfo?

            for pass in 0..<maxPasses {
                let payload = try await scrapeCurrentViewport()
                print("[KindleSync] pass=\(pass) url=\(payload.url ?? "") books=\(payload.books.count) auth=\(payload.authRequired == true) reader=\(payload.isReaderPage == true) signals=\(payload.hasReaderSignals == true)")
                sawAuthRequired = sawAuthRequired || payload.authRequired == true
                sawReaderPage = sawReaderPage || payload.isReaderPage == true
                sawLibrarySignals = sawLibrarySignals || payload.hasReaderSignals == true || !payload.books.isEmpty
                if let account = payload.account, accountInfo == nil || account.email?.isEmpty == false {
                    accountInfo = account
                }
                let scraped = payload.books
                let before = byID.count
                for book in scraped { byID[book.id] = book }
                if byID.count == before {
                    idlePasses += 1
                } else {
                    idlePasses = 0
                }
                if payload.authRequired == true {
                    statusText = String(localized: "请登录 Amazon Kindle，然后点同步。")
                } else if payload.isReaderPage == true {
                    statusText = String(localized: "当前打开的是 Kindle 书籍页面，请返回 Kindle 书架后同步。")
                } else if byID.isEmpty && payload.hasReaderSignals != true {
                    statusText = String(localized: "打开 Kindle 书架，然后点同步。")
                } else {
                    statusText = String(format: String(localized: "已找到 %d 本 Kindle 书…"), byID.count)
                }
                if pass >= 2 && idlePasses >= 2 { break }
                try await scrollLibraryForward()
                try await Task.sleep(nanoseconds: 650_000_000)
            }

            let books = Array(byID.values)
            if books.isEmpty {
                if sawReaderPage {
                    statusText = String(localized: "当前打开的是 Kindle 书籍页面，请返回 Kindle 书架后同步。")
                } else if sawAuthRequired {
                    statusText = String(localized: "请登录 Amazon Kindle，然后点同步。")
                } else if sawLibrarySignals {
                    statusText = String(localized: "请滚动 Kindle 书架后再点同步。")
                } else {
                    statusText = String(localized: "打开 Kindle 书架，然后点同步。")
                }
                if !lightPass {
                    errorText = String(localized: "当前页面暂时没有找到 Kindle 书籍。")
                }
            } else {
                store.mergeScrapedBooks(books, account: accountInfo)
                statusText = String(localized: "Kindle 书架已同步。")
                _ = try? await evaluate("window.scrollTo(0, 0);")
            }
        } catch {
            statusText = String(localized: "同步需要处理。")
            errorText = error.localizedDescription
        }
    }

    private func scrapeCurrentViewport() async throws -> KindleScrapeResult {
        let result = try await evaluate(KindleWebScripts.scrapeLibrary)
        let data = try jsonData(from: result)
        let payload = try JSONDecoder().decode(KindleScrapePayload.self, from: data)
        if payload.isReaderPage == true {
            await refreshPageState()
        }
        return KindleScrapeResult(
            books: payload.books.map(\.book).filter(\.isLikelyLibraryBook),
            authRequired: payload.authRequired,
            hasReaderSignals: payload.hasReaderSignals,
            isReaderPage: payload.isReaderPage,
            account: payload.account,
            url: payload.url
        )
    }

    private func refreshPageState() async {
        do {
            let result = try await evaluate(KindleWebScripts.currentPageState)
            let data = try jsonData(from: result)
            let state = try JSONDecoder().decode(KindleCurrentPageState.self, from: data)
            guard state.isReaderPage else {
                currentReaderBook = nil
                return
            }
            let id = state.asin?.isEmpty == false ? (state.asin ?? state.url) : state.url
            let book = KindleBook(
                id: id,
                asin: state.asin?.isEmpty == false ? state.asin : nil,
                title: state.title.isEmpty ? "Kindle" : state.title,
                author: "",
                coverURL: nil,
                readerURL: state.url,
                progressLabel: "",
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastReadPageKey: nil,
                lastReadURL: state.url
            )
            currentReaderBook = book.isLikelyLibraryBook ? book : nil
        } catch {
            currentReaderBook = nil
        }
    }

    private func scrollLibraryForward() async throws {
        _ = try await evaluate("""
        (function() {
          var all = Array.from(document.querySelectorAll('*')).concat([document.scrollingElement, document.body, document.documentElement]).filter(Boolean);
          all.sort(function(a,b){ return ((b.scrollHeight||0)-(b.clientHeight||0))-((a.scrollHeight||0)-(a.clientHeight||0)); });
          var delta = Math.max(520, Math.floor((window.innerHeight || 700) * 0.82));
          for (var i=0; i<Math.min(8, all.length); i++) {
            try { all[i].scrollTop = (all[i].scrollTop || 0) + delta; } catch(e) {}
          }
          try { window.scrollBy(0, delta); } catch(e) {}
          return true;
        })();
        """)
    }

    @discardableResult
    private func evaluate(_ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as Any)
                }
            }
        }
    }

    private func jsonData(from value: Any) throws -> Data {
        if let string = value as? String, let data = string.data(using: .utf8) {
            return data
        }
        if JSONSerialization.isValidJSONObject(value) {
            return try JSONSerialization.data(withJSONObject: value)
        }
        throw NSError(domain: "KindleLibrary", code: -1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Kindle 书架响应异常。")])
    }
}

private struct KindleScrapePayload: Decodable {
    let books: [ScrapedKindleBook]
    let authRequired: Bool?
    let hasReaderSignals: Bool?
    let isReaderPage: Bool?
    let account: KindleAccountInfo?
    let url: String?
}

private struct KindleScrapeResult {
    let books: [KindleBook]
    let authRequired: Bool?
    let hasReaderSignals: Bool?
    let isReaderPage: Bool?
    let account: KindleAccountInfo?
    let url: String?
}

private struct KindleCurrentPageState: Decodable {
    let url: String
    let title: String
    let asin: String?
    let isReaderPage: Bool
}

private struct ScrapedKindleBook: Decodable {
    let id: String
    let asin: String?
    let title: String
    let author: String?
    let coverURL: String?
    let readerURL: String
    let progressLabel: String?

    var book: KindleBook {
        KindleBook(
            id: id,
            asin: asin?.isEmpty == false ? asin : nil,
            title: title,
            author: author ?? "",
            coverURL: coverURL?.isEmpty == false ? coverURL : nil,
            readerURL: readerURL,
            progressLabel: progressLabel ?? "",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
    }
}
