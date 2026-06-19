//
//  Extensions.swift
//  CastReader
//

import SwiftUI

// MARK: - View Extensions
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - String Extensions
extension String {
    var isNotEmpty: Bool {
        !isEmpty
    }

    func truncated(to length: Int, trailing: String = "...") -> String {
        if count > length {
            return String(prefix(length)) + trailing
        }
        return self
    }


    /// Extract text from HTML with <br> converted to \n
    /// 参考 Web 版 html-parser.ts 的处理逻辑
    /// 与 Android HtmlParser.extractText 保持一致
    func extractTextWithLineBreaks() -> String {
        var content = self

        // Step 0: 移除行号标记（与 Android HtmlParser.extractText 一致）
        // Remove: .linenum, span.linenum
        content = content.replacingOccurrences(
            of: #"<span\s+[^>]*class\s*=\s*"[^"]*linenum[^"]*"[^>]*>.*?</span>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Step 0b: 移除页码标记（与 Android HtmlParser.extractText 一致）
        // Remove: .pageno, .x-ebookmaker-pageno
        content = content.replacingOccurrences(
            of: #"<[^>]+class\s*=\s*"[^"]*(?:pageno|x-ebookmaker-pageno)[^"]*"[^>]*>.*?</[^>]+>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Step 0c: 移除装饰性首字母图片（与 Android HtmlParser.extractText 一致）
        // Remove: img.dropcap and images with single-char alt
        content = content.replacingOccurrences(
            of: #"<img\s+[^>]*class\s*=\s*"[^"]*dropcap[^"]*"[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Step A: <br> 替换为占位符（保护换行）
        content = content.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "___BR___",
            options: .regularExpression
        )

        // Step B: 去除其他 HTML 标签
        content = content.stripHtmlTags()

        // Step C: 折叠空白（多个空白合并为单个空格，但不处理占位符）
        content = content.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )

        // Step D: 处理连续换行（源码中的换行，非 <br>）
        content = content.replacingOccurrences(
            of: "\\s*\\n\\s*",
            with: " ",
            options: .regularExpression
        )

        // Step E: 占位符还原为 \n
        content = content.replacingOccurrences(of: "___BR___", with: "\n")

        // Step F: trim
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove HTML tags from string
    func stripHtmlTags() -> String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Remove non-content elements to match Web/Android parser behavior
    /// 确保段落索引与 Web 解析器一致，以便 Protocol JSON 中的对话能正确关联
    func removeNonContentElements() -> String {
        var result = self

        // 1. 移除非内容标签及其内容（与 Android HtmlParser 一致）
        // Skip tags: script, style, nav, header, footer, table, tbody, tr, td, th, noscript, iframe, svg
        let skipTags = ["script", "style", "nav", "header", "footer", "table", "tbody", "tr", "td", "th", "noscript", "iframe", "svg"]
        for tag in skipTags {
            // 匹配开闭标签及其内容
            let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)>"
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            // 匹配自闭合标签
            let selfClosingPattern = "<\(tag)\\b[^>]*/>"
            result = result.replacingOccurrences(of: selfClosingPattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        // 2. 移除包含特定 class 的元素（与 Android HtmlParser 一致）
        // Skip classes: toc, table-of-contents, navigation, nav, footer, header, pageno, x-ebookmaker-pageno
        let skipClassPatterns = [
            // 匹配包含 toc 相关 class 的 div/section/nav
            #"<(?:div|section|nav|span|p)\s+[^>]*class\s*=\s*"[^"]*(?:toc|table-of-contents|navigation)[^"]*"[^>]*>.*?</(?:div|section|nav|span|p)>"#,
            // 匹配 pageno 相关元素
            #"<(?:span|p|div)\s+[^>]*class\s*=\s*"[^"]*(?:pageno|x-ebookmaker-pageno)[^"]*"[^>]*>.*?</(?:span|p|div)>"#,
            // 匹配行号标记
            #"<span\s+[^>]*class\s*=\s*"[^"]*linenum[^"]*"[^>]*>.*?</span>"#
        ]

        for pattern in skipClassPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(location: 0, length: (result as NSString).length),
                    withTemplate: ""
                )
            }
        }

        return result
    }

    /// Normalize whitespace - collapse multiple spaces/newlines into single space
    func normalizeWhitespace() -> String {
        // 将多个空白字符（空格、换行、制表符）合并为单个空格
        let components = self.components(separatedBy: .whitespacesAndNewlines)
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }

}


// MARK: - Date Extensions
extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - Double Extensions
extension Double {
    var timeString: String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var durationString: String {
        let hours = Int(self) / 3600
        let minutes = (Int(self) % 3600) / 60
        let seconds = Int(self) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - COS Image URL Helper

/// 腾讯云 COS 图片处理 URL 生成器
/// 参考 Web 实现: getCOSImageUrl()
enum COSImageSize: String {
    case small = "small"      // 150x150
    case medium = "medium"    // 300x300
    case original = "original" // 原图
}

extension String {
    /// 生成带 COS 图片处理参数的 URL
    /// - Parameters:
    ///   - size: 图片尺寸 (small: 150x150, medium: 300x300, original: 原图)
    ///   - format: 图片格式 (默认 webp)
    /// - Returns: 处理后的 URL 字符串
    func cosImageUrl(size: COSImageSize = .original, format: String = "webp") -> String {
        guard !self.isEmpty else { return self }

        // 如果已经有查询参数，跳过
        if self.contains("?") { return self }

        var params: [String] = []

        switch size {
        case .small:
            params.append("thumbnail/150x150")
        case .medium:
            params.append("thumbnail/300x300")
        case .original:
            break
        }

        params.append("format/\(format)")

        if !params.isEmpty {
            return "\(self)?imageMogr2/\(params.joined(separator: "/"))"
        }
        return self
    }
}

// MARK: - Image Cache (with Disk Cache)

final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheKey(for url: String) -> String {
        url.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-") ?? url
    }

    private func fileURL(for url: String) -> URL {
        cacheDirectory.appendingPathComponent(cacheKey(for: url))
    }

    func get(_ url: String) -> UIImage? {
        let key = cacheKey(for: url) as NSString

        // 先查内存
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        // 再查磁盘
        let fileURL = fileURL(for: url)
        if fileManager.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            // 加载到内存
            memoryCache.setObject(image, forKey: key)
            return image
        }

        return nil
    }

    func set(_ url: String, image: UIImage, data: Data? = nil) {
        let key = cacheKey(for: url) as NSString

        // 保存到内存
        memoryCache.setObject(image, forKey: key)

        // 保存到磁盘
        if let imageData = data ?? image.jpegData(compressionQuality: 0.8) {
            try? imageData.write(to: fileURL(for: url))
        }
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - Cached Async Image

struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var isLoading = false

    init(url: URL?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
                    .onAppear {
                        loadImage()
                    }
            }
        }
        .onChange(of: url) { _ in
            image = nil
            loadImage()
        }
    }

    private func loadImage() {
        guard let url = url else { return }
        let urlString = url.absoluteString

        // 先检查缓存（内存 + 磁盘）
        if let cached = ImageCache.shared.get(urlString) {
            self.image = cached
            return
        }

        guard !isLoading else { return }
        isLoading = true

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let uiImage = UIImage(data: data) {
                    // 保存到缓存（内存 + 磁盘）
                    ImageCache.shared.set(urlString, image: uiImage, data: data)
                    await MainActor.run {
                        self.image = uiImage
                    }
                }
            } catch {
                // 加载失败，保持 placeholder
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }
}
