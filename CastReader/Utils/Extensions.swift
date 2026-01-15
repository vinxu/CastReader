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
    /// 支持复杂结构：图片容器、诗歌结构、递归处理、智能过滤、去重
    func extractParagraphsWithIds() -> [ParsedParagraph] {
        // 使用元组存储位置和段落数据，便于排序
        var paragraphsWithPos: [(position: Int, paragraph: ParsedParagraph)] = []
        var processedRanges: [NSRange] = []  // 已处理的范围，用于去重

        // Step 1: 收集所有 id/name 属性及其在 HTML 中的位置
        var idPositions: [(position: Int, id: String)] = []
        let idPattern = #"(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        if let idRegex = try? NSRegularExpression(pattern: idPattern, options: [.caseInsensitive]) {
            let idMatches = idRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in idMatches {
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
        idPositions.sort { $0.position < $1.position }

        // Helper: 检查范围是否已处理（去重）
        func isRangeProcessed(_ range: NSRange) -> Bool {
            for processed in processedRanges {
                // 如果新范围完全在已处理范围内，跳过
                if range.location >= processed.location &&
                   range.location + range.length <= processed.location + processed.length {
                    return true
                }
            }
            return false
        }

        // Helper: 找到范围内最近的 ID
        func findIdForRange(_ range: NSRange) -> String? {
            var bestId: String? = nil
            for (pos, id) in idPositions {
                if pos < range.location + range.length {
                    bestId = id
                } else {
                    break
                }
            }
            return bestId
        }

        // Step 2: 首先处理图片容器
        // 支持: div.figure, div.figcenter, div.figright, div.figleft, div.figfull, div.illustration, div.image
        let figurePattern = #"<div\s+[^>]*class\s*=\s*"[^"]*(?:figure|figcenter|figright|figleft|figfull|illustration|image)[^"]*"[^>]*>(.*?)</div>"#
        if let figureRegex = try? NSRegularExpression(pattern: figurePattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = figureRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in matches {
                guard !isRangeProcessed(match.range),
                      let fullRange = Range(match.range, in: self) else { continue }

                let figureHtml = String(self[fullRange])
                // 使用高级图片提取，传入容器 HTML 以获取对齐和宽度信息
                let images = figureHtml.extractImagesAdvanced(containerHtml: figureHtml)

                // 跳过空图片容器
                guard !images.isEmpty else { continue }

                // 提取描述文字：优先 caption，其次 alt
                let altText = images.first?.caption ?? images.first?.alt ?? ""

                processedRanges.append(match.range)
                paragraphsWithPos.append((
                    position: match.range.location,
                    paragraph: ParsedParagraph(
                        id: findIdForRange(match.range),
                        text: altText,
                        html: figureHtml,
                        index: 0,
                        type: .image,
                        images: images
                    )
                ))
            }
        }

        // Step 3: 处理诗歌结构 <div class="poem">
        // 匹配完整的 poem div（包含所有 stanza）
        let poemPattern = #"<div\s+class\s*=\s*"poem"[^>]*>(.+?)</div>\s*</div>"#
        if let poemRegex = try? NSRegularExpression(pattern: poemPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = poemRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in matches {
                guard !isRangeProcessed(match.range),
                      let fullRange = Range(match.range, in: self) else { continue }

                let poemHtml = String(self[fullRange])

                // 从诗歌中提取所有诗句（支持 <span> 和 <p> 标签）
                let poemText = poemHtml.extractPoemText()

                guard !poemText.isEmpty else { continue }

                processedRanges.append(match.range)
                paragraphsWithPos.append((
                    position: match.range.location,
                    paragraph: ParsedParagraph(
                        id: findIdForRange(match.range),
                        text: poemText,
                        html: poemHtml,
                        index: 0,
                        type: .blockquote,
                        images: nil
                    )
                ))
            }
        }

        // Step 4: 处理标题 h1-h6
        let headingPattern = #"<(h[1-6])\s*[^>]*>(.*?)</\1>"#
        if let headingRegex = try? NSRegularExpression(pattern: headingPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = headingRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in matches {
                guard !isRangeProcessed(match.range),
                      let fullRange = Range(match.range, in: self),
                      match.range(at: 1).location != NSNotFound,
                      let tagRange = Range(match.range(at: 1), in: self),
                      match.range(at: 2).location != NSNotFound,
                      let innerRange = Range(match.range(at: 2), in: self) else { continue }

                let rawHtml = String(self[fullRange])
                let tagName = String(self[tagRange]).lowercased()
                let innerHtml = String(self[innerRange])
                let text = innerHtml.extractTextWithLineBreaks()

                guard !text.isEmpty else { continue }

                // 解析标题级别
                let level = Int(String(tagName.dropFirst())) ?? 1

                processedRanges.append(match.range)
                paragraphsWithPos.append((
                    position: match.range.location,
                    paragraph: ParsedParagraph(
                        id: findIdForRange(match.range),
                        text: text,
                        html: rawHtml,
                        index: 0,
                        type: .heading(level),
                        images: nil
                    )
                ))
            }
        }

        // Step 5: 处理普通段落 <p>（排除诗歌中的和表格中的）
        let paragraphPattern = #"<p\s*[^>]*>(.*?)</p>"#
        if let pRegex = try? NSRegularExpression(pattern: paragraphPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = pRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in matches {
                guard !isRangeProcessed(match.range),
                      let fullRange = Range(match.range, in: self),
                      match.range(at: 1).location != NSNotFound,
                      let innerRange = Range(match.range(at: 1), in: self) else { continue }

                let rawHtml = String(self[fullRange])
                let innerHtml = String(self[innerRange])

                // 跳过页码标记（包含 x-ebookmaker-pageno）
                if rawHtml.contains("x-ebookmaker-pageno") { continue }

                // 提取图片
                let images = rawHtml.extractImages()

                // 提取文本
                let text = innerHtml.extractTextWithLineBreaks()

                // 跳过空内容（除非有图片）
                guard !text.isEmpty || !images.isEmpty else { continue }

                processedRanges.append(match.range)
                paragraphsWithPos.append((
                    position: match.range.location,
                    paragraph: ParsedParagraph(
                        id: findIdForRange(match.range),
                        text: text,
                        html: rawHtml,
                        index: 0,
                        type: images.isEmpty ? .paragraph : .image,
                        images: images.isEmpty ? nil : images
                    )
                ))
            }
        }

        // Step 6: 处理独立图片（不在 figure 或 p 中的 img）
        let standaloneImgPattern = #"<img\s+[^>]*>"#
        if let imgRegex = try? NSRegularExpression(pattern: standaloneImgPattern, options: [.caseInsensitive]) {
            let matches = imgRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in matches {
                guard !isRangeProcessed(match.range),
                      let fullRange = Range(match.range, in: self) else { continue }

                let imgHtml = String(self[fullRange])
                let images = imgHtml.extractImages()

                guard !images.isEmpty else { continue }

                // 提取 alt 作为描述文字
                let altText = images.first?.alt ?? ""

                processedRanges.append(match.range)
                paragraphsWithPos.append((
                    position: match.range.location,
                    paragraph: ParsedParagraph(
                        id: findIdForRange(match.range),
                        text: altText,
                        html: imgHtml,
                        index: 0,
                        type: .image,
                        images: images
                    )
                ))
            }
        }

        // Step 7: 按位置排序（保持阅读顺序）
        paragraphsWithPos.sort { $0.position < $1.position }

        // Step 8: 重新分配索引并提取段落
        let paragraphs: [ParsedParagraph] = paragraphsWithPos.enumerated().map { idx, item in
            ParsedParagraph(
                id: item.paragraph.id,
                text: item.paragraph.text,
                html: item.paragraph.html,
                index: idx,
                type: item.paragraph.type,
                images: item.paragraph.images
            )
        }

        // Fallback
        if paragraphs.isEmpty {
            return extractParagraphsFallback()
        }

        return paragraphs
    }

    /// Extract text from poem structure (preserving line breaks)
    /// 支持两种格式：
    /// 1. <span class="i0/i4">诗句<br/></span> （新格式）
    /// 2. <p class="i2">诗句</p> （旧格式）
    private func extractPoemText() -> String {
        var lines: [String] = []

        // 首先尝试匹配 <span class="i..."> 格式（新格式）
        let spanPattern = #"<span\s+class\s*=\s*"i\d+"[^>]*>(.*?)</span>"#
        if let spanRegex = try? NSRegularExpression(pattern: spanPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = spanRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
            for match in matches {
                guard match.range(at: 1).location != NSNotFound,
                      let innerRange = Range(match.range(at: 1), in: self) else { continue }

                var lineText = String(self[innerRange])
                // 移除 <br/> 标签和 dropcap 图片
                lineText = lineText.replacingOccurrences(of: "<br\\s*/?>", with: "", options: .regularExpression)
                lineText = lineText.replacingOccurrences(of: "<img[^>]*class\\s*=\\s*\"dropcap\"[^>]*>", with: "", options: .regularExpression)
                lineText = lineText.stripHtmlTags().trimmingCharacters(in: .whitespacesAndNewlines)
                if !lineText.isEmpty {
                    lines.append(lineText)
                }
            }
        }

        // 如果没找到 span，尝试匹配 <p> 格式（旧格式）
        if lines.isEmpty {
            let pPattern = #"<p\s+[^>]*>(.*?)</p>"#
            if let pRegex = try? NSRegularExpression(pattern: pPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let matches = pRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))
                for match in matches {
                    guard match.range(at: 1).location != NSNotFound,
                          let innerRange = Range(match.range(at: 1), in: self) else { continue }

                    let lineText = String(self[innerRange]).extractTextWithLineBreaks()
                    if !lineText.isEmpty {
                        lines.append(lineText)
                    }
                }
            }
        }

        // 如果还是没找到，直接提取文本
        if lines.isEmpty {
            return extractTextWithLineBreaks()
        }

        return lines.joined(separator: "\n")
    }

    /// Fallback method when no block tags found
    private func extractParagraphsFallback() -> [ParsedParagraph] {
        let text = self.extractTextWithLineBreaks()
        let lines = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.enumerated().map { idx, lineText in
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

    /// Extract images from HTML content (basic extraction)
    /// Returns array of ImageBlock with src and alt attributes
    func extractImages() -> [ImageBlock] {
        return extractImagesAdvanced(containerHtml: nil)
    }

    /// Extract images with alignment, width, and dropcap detection
    /// containerHtml: 容器的完整 HTML（用于提取 style 和 class）
    func extractImagesAdvanced(containerHtml: String?) -> [ImageBlock] {
        var images: [ImageBlock] = []

        // 从容器提取对齐方式和宽度
        var containerAlignment: ImageAlignment = .center
        var containerWidth: CGFloat? = nil
        var containerCaption: String? = nil

        if let container = containerHtml {
            // 提取对齐方式
            if container.contains("figright") {
                containerAlignment = .right
            } else if container.contains("figleft") {
                containerAlignment = .left
            } else if container.contains("figcenter") {
                containerAlignment = .center
            }

            // 提取宽度: style="width: 300px;"
            let widthPattern = #"style\s*=\s*"[^"]*width:\s*(\d+)px"#
            if let regex = try? NSRegularExpression(pattern: widthPattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: container, options: [], range: NSRange(location: 0, length: (container as NSString).length)),
               match.range(at: 1).location != NSNotFound,
               let widthRange = Range(match.range(at: 1), in: container) {
                containerWidth = CGFloat(Double(String(container[widthRange])) ?? 0)
            }

            // 提取 caption: <span class="caption">...</span>
            let captionPattern = #"<span\s+class\s*=\s*"caption"[^>]*>(.*?)</span>"#
            if let regex = try? NSRegularExpression(pattern: captionPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: container, options: [], range: NSRange(location: 0, length: (container as NSString).length)),
               match.range(at: 1).location != NSNotFound,
               let captionRange = Range(match.range(at: 1), in: container) {
                containerCaption = String(container[captionRange]).stripHtmlTags().trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 匹配 <img> 标签
        let imgTagPattern = #"<img\s+[^>]*>"#
        guard let imgTagRegex = try? NSRegularExpression(pattern: imgTagPattern, options: [.caseInsensitive]) else {
            return images
        }

        let matches = imgTagRegex.matches(in: self, options: [], range: NSRange(location: 0, length: (self as NSString).length))

        for match in matches {
            guard let fullRange = Range(match.range, in: self) else { continue }
            let imgTag = String(self[fullRange])

            // 检测 dropcap 装饰图
            let isDropcap = imgTag.contains("dropcap")
            if isDropcap { continue }  // 跳过装饰性首字母图

            // 提取 src
            var src: String? = nil
            let srcPatterns = [
                #"src\s*=\s*"([^"]*)""#,  // 双引号
                #"src\s*=\s*'([^']*)'"#,  // 单引号
                #"src\s*=\s*([^\s>]+)"#   // 无引号
            ]
            for pattern in srcPatterns {
                if src != nil { break }
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let srcMatch = regex.firstMatch(in: imgTag, options: [], range: NSRange(location: 0, length: (imgTag as NSString).length)),
                   srcMatch.range(at: 1).location != NSNotFound,
                   let srcRange = Range(srcMatch.range(at: 1), in: imgTag) {
                    src = String(imgTag[srcRange])
                }
            }

            guard var finalSrc = src, !finalSrc.isEmpty else { continue }

            // URL 编码
            if let encoded = finalSrc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                finalSrc = encoded
            }

            // 提取 alt
            var alt: String? = nil
            let altPatterns = [
                #"alt\s*=\s*"([^"]*)""#,
                #"alt\s*=\s*'([^']*)'"#
            ]
            for pattern in altPatterns {
                if alt != nil { break }
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let altMatch = regex.firstMatch(in: imgTag, options: [], range: NSRange(location: 0, length: (imgTag as NSString).length)),
                   altMatch.range(at: 1).location != NSNotFound,
                   let altRange = Range(altMatch.range(at: 1), in: imgTag) {
                    alt = String(imgTag[altRange])
                    if alt?.isEmpty == true { alt = nil }
                }
            }

            images.append(ImageBlock(
                src: finalSrc,
                alt: alt,
                width: containerWidth,
                alignment: containerAlignment,
                caption: containerCaption,
                isDropcap: false
            ))
        }

        return images
    }
}

/// Helper function to detect paragraph type from HTML tag name
private func detectParagraphType(tagName: String, hasImages: Bool) -> ParagraphType {
    switch tagName.lowercased() {
    case "h1":
        return .heading(1)
    case "h2":
        return .heading(2)
    case "h3":
        return .heading(3)
    case "h4":
        return .heading(4)
    case "h5":
        return .heading(5)
    case "h6":
        return .heading(6)
    case "blockquote":
        return .blockquote
    case "pre":
        return .code
    case "li":
        return .list
    case "img":
        return .image
    case "figure":
        return hasImages ? .image : .paragraph
    default:
        return .paragraph
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
