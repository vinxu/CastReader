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

    /// Extract paragraphs from HTML content
    func extractParagraphs() -> [String] {
        return extractParagraphsWithIds().map { $0.text }
    }

    /// Extract paragraphs from HTML content, preserving IDs
    /// Simulates web's DOMParser + ID relay pattern
    func extractParagraphsWithIds() -> [ParsedParagraph] {
        // Step 1: 收集所有 id/name 属性及其在 HTML 中的位置
        // 支持多种格式: id="x", id='x', id=x, name="x"
        var idPositions: [(position: Int, id: String)] = []
        let idPattern = #"(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        if let idRegex = try? NSRegularExpression(pattern: idPattern, options: [.caseInsensitive]) {
            let idMatches = idRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in idMatches {
                // 检查三个捕获组（双引号、单引号、无引号）
                var foundId: String? = nil
                for groupIndex in 1...3 {
                    if match.range(at: groupIndex).location != NSNotFound,
                       let idRange = Range(match.range(at: groupIndex), in: self) {
                        foundId = String(self[idRange])
                        break
                    }
                }
                if let id = foundId, !id.isEmpty {
                    idPositions.append((position: match.range.location, id: id))
                }
            }
        }

        // 按位置排序
        idPositions.sort { $0.position < $1.position }

        // Step 2: 匹配所有内容块（p, h1-h6, li, blockquote 等）
        let blockPattern = #"<(p|h[1-6]|li|pre|blockquote)[^>]*>(.*?)</\1>"#

        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return extractParagraphsFallback()
        }

        let blockMatches = blockRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))

        var paragraphs: [ParsedParagraph] = []
        var index = 0
        var pendingId: String? = nil  // ID 接力棒
        var lastBlockEnd = 0  // 上一个块的结束位置
        var idIndex = 0  // 当前处理到的 ID 索引

        for blockMatch in blockMatches {
            let blockStart = blockMatch.range.location
            let blockEnd = blockStart + blockMatch.range.length

            // Step 3: 收集从上一个块结束到当前块结束之间的所有 ID
            // 这些 ID 都会更新接力棒（最后一个生效）
            while idIndex < idPositions.count && idPositions[idIndex].position < blockEnd {
                let (pos, id) = idPositions[idIndex]
                // 只有在上一个块结束之后的 ID 才更新接力棒
                if pos >= lastBlockEnd {
                    pendingId = id
                }
                idIndex += 1
            }

            // Step 4: 提取完整的 HTML 块和内部内容
            guard let fullRange = Range(blockMatch.range, in: self),
                  blockMatch.range(at: 2).location != NSNotFound,
                  let innerRange = Range(blockMatch.range(at: 2), in: self) else {
                lastBlockEnd = blockEnd
                continue
            }

            // 保存原始 HTML（用于渲染）
            let rawHtml = String(self[fullRange])
            let innerHtml = String(self[innerRange])

            // Step 5: 提取文本内容，处理 <br> → \n
            // 参考 Web 版 html-parser.ts 的处理逻辑
            let text = innerHtml.extractTextWithLineBreaks()

            // Step 6: ID 接力棒逻辑
            // 如果是空内容，不生成段落，但保留 pendingId 给下一个
            guard !text.isEmpty else {
                lastBlockEnd = blockEnd
                continue
            }

            // 有内容的段落，使用接力棒中的 ID
            let paragraphId = pendingId
            pendingId = nil  // 接力棒交出去了，清空

            paragraphs.append(ParsedParagraph(id: paragraphId, text: text, html: rawHtml, index: index))
            index += 1
            lastBlockEnd = blockEnd
        }

        // If no blocks found, try fallback
        if paragraphs.isEmpty {
            return extractParagraphsFallback()
        }

        return paragraphs
    }

    /// Fallback method when no block tags found
    private func extractParagraphsFallback() -> [ParsedParagraph] {
        let text = self.extractTextWithLineBreaks()
        let lines = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.enumerated().map { idx, lineText in
            // 对于 fallback，html 就用简单的 <p> 包裹
            let html = "<p>\(lineText.replacingOccurrences(of: "\n", with: "<br>"))</p>"
            return ParsedParagraph(id: nil, text: lineText, html: html, index: idx)
        }
    }

    /// Extract text from HTML with <br> converted to \n
    /// 参考 Web 版 html-parser.ts 的处理逻辑
    func extractTextWithLineBreaks() -> String {
        var content = self

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

// MARK: - Image Cache
class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 100  // 最多缓存 100 张图片
    }

    func get(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func set(_ url: String, image: UIImage) {
        cache.setObject(image, forKey: url as NSString)
    }
}

// MARK: - Cached Async Image
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var isLoading = false

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
                    .onAppear {
                        loadImage()
                    }
            }
        }
    }

    private func loadImage() {
        guard let url = url else { return }
        let urlString = url.absoluteString

        // 先检查缓存
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
                    ImageCache.shared.set(urlString, image: uiImage)
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
