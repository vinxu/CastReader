//
//  CoverThumbnail.swift
//  CastReader
//
//  历史卡片封面缩略图：有封面（web og:image / PDF 首页 / 图片原图 / EPUB 封面）→ 显示图；
//  无封面（纯文本 / DOCX / 抓取失败）→ 标题哈希渐变 + 源图标占位，让每张卡片都「成品感」不空。
//

import SwiftUI
import UIKit

struct CoverThumbnail: View {
    let record: HistoryRecord
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    placeholder
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .task(id: loadIdentity) { await load() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .castReaderYouTubeThumbnailCacheChanged
            )
        ) { _ in
            guard record.sourceKind == .youtube else { return }
            Task { await load() }
        }
    }

    private func load() async {
        if record.sourceKind == .youtube {
            guard let sourceURL = record.sourceURL,
                  let reference = YouTubeURLParser.parse(sourceURL),
                  let cache = YouTubeCacheProvider.shared,
                  let data = await cache.peekThumbnail(videoId: reference.videoId) else {
                image = nil
                return
            }
            let decoded = await Task.detached { UIImage(data: data) }.value
            guard !Task.isCancelled else { return }
            image = decoded
            return
        }
        guard let url = HistoryStore.shared.coverURL(for: record) else { image = nil; return }
        image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
    }

    private var loadIdentity: String {
        [record.id, record.sourceURL ?? "", record.coverPath ?? ""].joined(separator: "|")
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: Self.gradient(for: record.title), startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
        }
    }

    private var icon: String {
        switch record.sourceKind {
        case .web: return "link"
        case .pdf: return "doc.richtext"
        case .docx: return "doc.text"
        case .epub: return "book"
        case .kindle: return "book.pages"
        case .weread: return "book.closed"
        case .googleBooks: return "book.pages.fill"
        case .kobo: return "book.closed.fill"
        case .oreilly: return "text.book.closed.fill"
        case .youtube: return "play.rectangle.fill"
        case .photo: return "photo"
        case .text: return "text.alignleft"
        }
    }

    /// 标题哈希 → 一组渐变（确定性，同标题同色），与 DocumentRow 占位一致的审美。
    static func gradient(for name: String) -> [Color] {
        let gradients: [[Color]] = [
            [Color(red: 251/255, green: 113/255, blue: 133/255), Color(red: 253/255, green: 186/255, blue: 116/255)],
            [Color(red: 96/255, green: 165/255, blue: 250/255), Color(red: 129/255, green: 140/255, blue: 248/255)],
            [Color(red: 52/255, green: 211/255, blue: 153/255), Color(red: 34/255, green: 211/255, blue: 238/255)],
            [Color(red: 252/255, green: 211/255, blue: 77/255), Color(red: 234/255, green: 179/255, blue: 8/255)],
            [Color(red: 217/255, green: 70/255, blue: 239/255), Color(red: 236/255, green: 72/255, blue: 153/255)],
        ]
        var hash = 0
        for ch in name.unicodeScalars { hash = Int(ch.value) &+ ((hash << 5) &- hash) }
        return gradients[abs(hash) % gradients.count]
    }
}
