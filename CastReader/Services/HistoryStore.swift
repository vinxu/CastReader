//
//  HistoryStore.swift
//  CastReader
//
//  文库 = 本地历史记录：处理/朗读/解读/粘贴过的所有文档都在此留存。
//  **纯本地、不上云**。元数据存 index.json；原始数据（图片/PDF/DOCX/EPUB/文本）存 <id>.payload，
//  重新打开时按 sourceKind 重建 ReadingDocument（web 用 URL、photo 重新 OCR、pdf 重新解析）。
//

import SwiftUI
import UIKit
import PDFKit

/// 一条历史记录（元数据）。原始数据另存 payload 文件。
struct HistoryRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var sourceKindRaw: String
    var sourceURL: String?
    var language: String
    var createdAt: Date
    var lastOpenedAt: Date
    /// 封面文件名（History 目录内 <id>.cover.jpg）。三态：nil=未生成；""=已尝试但无封面（用渐变占位、不重复抓取）；非空=有封面。
    var coverPath: String?

    var sourceKind: ReadingSourceKind { ReadingSourceKind(rawValue: sourceKindRaw) ?? .text }
}

/// Home has dedicated rails for Kindle and WeRead, so neither source may also
/// appear in Continue.  The full local history remains available in Library.
enum HomeContinueContract {
    static func includes(_ sourceKind: ReadingSourceKind) -> Bool {
        sourceKind != .kindle && sourceKind != .weread
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [HistoryRecord] = []

    private let dir: URL
    private let indexURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("History", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        Task { await backfillCovers() }   // 给升级前的旧记录补封面 + web 真实标题（best-effort）
    }

    private func payloadURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).payload") }
    private func coverFileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).cover.jpg") }

    /// 卡片读取封面文件 URL（有真实封面才返回；nil = 用渐变占位）。
    func coverURL(for rec: HistoryRecord) -> URL? {
        guard let name = rec.coverPath, !name.isEmpty else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let recs = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        records = recs.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: indexURL) }
    }

    /// 记录一次打开：新文档新增、已存在则更新时间并置顶。原始数据存 payload 供重开（web 仅记 URL）。
    func record(_ doc: ReadingDocument) {
        let payload: Data? = {
            switch doc.sourceKind {
            case .web, .weread: return nil
            case .text: return doc.fullText.data(using: .utf8)
            case .photo: return doc.imageData
            case .kindle: return doc.fullText.data(using: .utf8)
            case .pdf, .docx, .epub: return doc.fileData
            }
        }()
        if let payload { try? payload.write(to: payloadURL(doc.id)) }

        let now = Date()
        let existing = records.first(where: { $0.id == doc.id })
        let createdAt = existing?.createdAt ?? now
        var rec = HistoryRecord(id: doc.id, title: doc.title.isEmpty ? AppLocalized("未命名") : doc.title,
                                sourceKindRaw: doc.sourceKind.rawValue, sourceURL: doc.sourceURL,
                                language: doc.language, createdAt: createdAt, lastOpenedAt: now)
        rec.coverPath = existing?.coverPath   // 沿用已生成的封面/标题，避免重复抓取
        if let t = existing?.title, !t.isEmpty, rec.coverPath != nil { rec.title = t }  // 已抓到真实标题则保留
        records.removeAll { $0.id == doc.id }
        records.insert(rec, at: 0)
        save()

        if rec.coverPath == nil {   // 首次记录 → 异步生成封面（+ web 抓取真实标题），best-effort，不阻塞打开
            Task { await generateCover(for: doc) }
        }
    }

    /// Web/DOCX language is only known after DOM extraction. Persist the final
    /// nine-language result so history reopen, voice defaults and analytics do
    /// not fall back to the placeholder English value.
    func updateDetectedLanguage(documentID: String, language: String) {
        guard let language = SupportedTTSLanguage(identifier: language)?.rawValue,
              let index = records.firstIndex(where: { $0.id == documentID }),
              records[index].language != language else { return }
        records[index].language = language
        save()
    }

    /// Kindle 书本级历史：点击朗读/解读后写入顶部 Continue。这里保存的是书架 metadata，
    /// 不是某一页 OCR 临时文档，避免 MiniPlayer/锁屏/首页拿不到书封和真实书名。
    func recordKindleBook(_ book: KindleBook, language: String = Constants.TTS.defaultLanguage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let payload = try? encoder.encode(book) {
            try? payload.write(to: payloadURL(book.id))
        }

        let now = Date()
        let existing = records.first(where: { $0.id == book.id })
        var rec = HistoryRecord(
            id: book.id,
            title: book.title.isEmpty ? AppLocalized("Kindle Book") : book.title,
            sourceKindRaw: ReadingSourceKind.kindle.rawValue,
            sourceURL: book.effectiveReaderURL,
            language: language,
            createdAt: existing?.createdAt ?? now,
            lastOpenedAt: now
        )
        rec.coverPath = existing?.coverPath
        records.removeAll { $0.id == book.id }
        records.insert(rec, at: 0)
        save()

        if rec.coverPath == nil || rec.coverPath == "" {
            Task { await generateCoverFromURL(book.coverURL, id: book.id) }
        }
    }

    func kindleBook(for rec: HistoryRecord) -> KindleBook? {
        guard rec.sourceKind == .kindle,
              let data = try? Data(contentsOf: payloadURL(rec.id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KindleBook.self, from: data)
    }

    func delete(_ id: String) {
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: payloadURL(id))
        try? FileManager.default.removeItem(at: coverFileURL(id))
        save()
    }

    func clearAll() {
        for r in records {
            try? FileManager.default.removeItem(at: payloadURL(r.id))
            try? FileManager.default.removeItem(at: coverFileURL(r.id))
        }
        records.removeAll()
        save()
    }

    // MARK: - 封面 + 标题生成

    /// 启动回填：给所有还没封面的历史项补封面 + web 真实标题（best-effort、串行、不阻塞 UI）。
    /// 让升级前已有的「继续看」卡片（如微信文章链接）也自动从 demo 的 host 文字升级为封面+标题。
    func backfillCovers() async {
        for rec in records where rec.coverPath == nil {
            await generateCoverFromRecord(rec)
        }
    }

    /// 新打开文档时生成封面：用内存中的数据（含 epub 已解析的封面图段），最快。
    private func generateCover(for doc: ReadingDocument) async {
        var imageData: Data?
        var title: String?
        switch doc.sourceKind {
        case .web, .weread:   (title, imageData) = await webCover(doc.sourceURL)
        case .pdf:   if let d = doc.fileData { imageData = await Task.detached { Self.pdfFirstPageJPEG(d) }.value }
        case .photo: imageData = doc.imageData
        case .kindle: imageData = doc.paragraphs.first(where: { $0.type == .image && $0.imageData != nil })?.imageData
        case .epub:  imageData = doc.paragraphs.first(where: { $0.type == .image && $0.imageData != nil })?.imageData
        case .text, .docx: break
        }
        finishCover(id: doc.id, imageData: imageData, title: title)
    }

    /// 回填路径：从历史记录 + payload 文件生成（无内存文档）。epub/docx/text 用渐变占位（不重解析大书）。
    private func generateCoverFromRecord(_ rec: HistoryRecord) async {
        var imageData: Data?
        var title: String?
        switch rec.sourceKind {
        case .web, .weread:   (title, imageData) = await webCover(rec.sourceURL)
        case .pdf:   if let d = try? Data(contentsOf: payloadURL(rec.id)) { imageData = await Task.detached { Self.pdfFirstPageJPEG(d) }.value }
        case .photo: imageData = try? Data(contentsOf: payloadURL(rec.id))
        case .epub, .docx, .kindle, .text: break
        }
        finishCover(id: rec.id, imageData: imageData, title: title)
    }

    /// web：抓 og:title + 下载 og:image 字节。
    private func webCover(_ urlString: String?) async -> (String?, Data?) {
        guard let urlString else { return (nil, nil) }
        let meta = await LinkMetadata.fetch(urlString)
        var img: Data?
        if let s = meta.imageURL, let u = URL(string: s) { img = try? await URLSession.shared.data(from: u).0 }
        return (meta.title, img)
    }

    private func generateCoverFromURL(_ urlString: String?, id: String) async {
        guard let url = Self.makeURL(urlString) else {
            finishCover(id: id, imageData: nil, title: nil)
            return
        }
        let imageData = try? await URLSession.shared.data(from: url).0
        finishCover(id: id, imageData: imageData, title: nil)
    }

    private nonisolated static func makeURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let url = URL(string: raw) { return url }
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }

    /// 落地封面 + 标题：写降采样 jpeg、置 coverPath（无图时置 "" 标记已尝试，用占位、不再重复抓取）。
    private func finishCover(id: String, imageData: Data?, title: String?) {
        if let t = title { applyTitle(t, id: id) }
        var savedName = ""
        if let data = imageData, let down = EpubImageDecoder.downsampled(data, maxPixel: 640),
           let jpeg = down.jpegData(compressionQuality: 0.72) {
            try? jpeg.write(to: coverFileURL(id))
            savedName = coverFileURL(id).lastPathComponent
        }
        applyCover(savedName, id: id)
    }

    private func applyTitle(_ title: String, id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        records[idx].title = clean
        save()
    }

    private func applyCover(_ name: String, id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].coverPath = name
        save()
    }

    /// PDF 首页渲染为 JPEG（白底、长边 640）。
    nonisolated private static func pdfFirstPageJPEG(_ data: Data) -> Data? {
        guard let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) else { return nil }
        let rect = page.bounds(for: .mediaBox)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let scale = 640 / max(rect.width, rect.height)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.white.set(); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        return img.jpegData(compressionQuality: 0.8)
    }

    /// 从历史项重建可播放文档（id 沿用 rec.id，保证重开后 record 是更新而非新增）。photo 需重新 OCR，故 async。
    func reopen(_ rec: HistoryRecord) async -> ReadingDocument? {
        switch rec.sourceKind {
        case .web:
            guard let url = rec.sourceURL else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .web, language: rec.language,
                                   paragraphs: [], sourceURL: url)
        case .weread:
            guard let url = rec.sourceURL else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .weread, language: rec.language,
                                   paragraphs: [], sourceURL: url)
        case .text:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let built = DocumentBuilder.fromPlainText(text, title: rec.title)
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .text,
                                   language: built.language, paragraphs: built.paragraphs)
        case .pdf:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)) else { return nil }
            guard let built = await DocumentBuilder.fromPDFWithOCR(
                data: data,
                title: rec.title,
                fallbackTitle: rec.title
            ) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .pdf, language: built.language,
                                   paragraphs: built.paragraphs, fileData: data)
        case .docx:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .docx,
                                   language: rec.language, paragraphs: [], fileData: data)
        case .kindle:
            if kindleBook(for: rec) != nil { return nil }
            guard let data = try? Data(contentsOf: payloadURL(rec.id)),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let built = DocumentBuilder.fromPlainText(text, title: rec.title)
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .text,
                                   language: built.language, paragraphs: built.paragraphs)
        case .epub:
            // EPUB 原生重开：从字节重新解析为段落（像 PDF），而非旧 WebView 的空 paragraphs（否则白屏）
            guard let data = try? Data(contentsOf: payloadURL(rec.id)),
                  let built = DocumentBuilder.fromEPUB(data: data, title: rec.title) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .epub, language: built.language,
                                   paragraphs: built.paragraphs, fileData: data)
        case .photo:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)), let img = UIImage(data: data) else { return nil }
            let cap = CaptureFlowViewModel()
            await cap.process(image: img)
            guard let built = cap.document else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .photo, language: built.language,
                                   paragraphs: built.paragraphs, imageData: built.imageData, imagePixelSize: built.imagePixelSize)
        }
    }
}

// MARK: - 网页元数据抓取（og:title / og:image，给「继续看」/文库卡片做封面+真实标题）

enum LinkMetadata {
    /// 抓取网页 <head> 的标题与封面图 URL（best-effort，失败返回 nil）。
    static func fetch(_ urlString: String) async -> (title: String?, imageURL: String?) {
        guard let url = URL(string: urlString) else { return (nil, nil) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, nil) }
        let finalURL = resp.url ?? url
        // 仅取前 ~400KB（<head> 足够），兼容非 UTF-8 用 lossy 解码。
        let head = data.prefix(400_000)
        let html = String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self)
        return parse(html: html, baseURL: finalURL)
    }

    /// 从 HTML 解析标题 + 封面（与网络分离，便于单测）。
    static func parse(html: String, baseURL: URL) -> (title: String?, imageURL: String?) {
        let title = metaContent(html, keys: ["og:title", "twitter:title"]) ?? htmlTitle(html)
        var image = metaContent(html, keys: ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"])
        if let img = image, let resolved = URL(string: img, relativeTo: baseURL)?.absoluteString { image = resolved }
        return (title, image)
    }

    /// 扫描所有 <meta> 标签，命中 property/name ∈ keys 时取 content（属性顺序任意）。
    private static func metaContent(_ html: String, keys: Set<String>) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let key = (attr(tag, "property") ?? attr(tag, "name"))?.lowercased(), keys.contains(key) else { continue }
            if let content = attr(tag, "content")?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                return decodeEntities(content)
            }
        }
        return nil
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : decodeEntities(raw)
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        return r
    }
}
