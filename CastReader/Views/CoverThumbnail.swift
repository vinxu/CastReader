//
//  CoverThumbnail.swift
//  CastReader
//
//  历史卡片封面缩略图：有封面（web og:image / PDF 首页 / 图片原图 / EPUB 封面）→ 显示图；
//  无封面（纯文本 / DOCX / 抓取失败）→ 标题哈希渐变 + 源图标占位，让每张卡片都「成品感」不空。
//

import SwiftUI
import UIKit
import ImageIO

private enum CoverThumbnailDecodeSource {
    case data(Data)
    case file(URL)
}

private final class CoverThumbnailDecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// ImageIO decoding is deliberately serialized and always downsamples. A
/// restored Home can contain the same YouTube cover in multiple rails; decoding
/// all originals concurrently caused a real-device scene-update watchdog kill.
private enum CoverThumbnailDecoder {
    private static let queue = DispatchQueue(
        label: "com.same.castreader.cover-thumbnail-decode",
        qos: .utility
    )

    static func image(
        from source: CoverThumbnailDecodeSource,
        maxPixelSize: Int = 480
    ) async -> UIImage? {
        let cancellation = CoverThumbnailDecodeCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let imageSource: CGImageSource?
                    switch source {
                    case .data(let data):
                        imageSource = CGImageSourceCreateWithData(
                            data as CFData,
                            [kCGImageSourceShouldCache: false] as CFDictionary
                        )
                    case .file(let url):
                        imageSource = CGImageSourceCreateWithURL(
                            url as CFURL,
                            [kCGImageSourceShouldCache: false] as CFDictionary
                        )
                    }
                    guard let imageSource, !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                        kCGImageSourceShouldCacheImmediately: true,
                    ]
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        imageSource,
                        0,
                        options as CFDictionary
                    ).map(UIImage.init(cgImage:))
                    continuation.resume(
                        returning: cancellation.isCancelled ? nil : image
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

@MainActor
private final class CoverThumbnailImageLoader {
    static let shared = CoverThumbnailImageLoader()

    private struct InFlight {
        let token: UUID
        let task: Task<UIImage?, Never>
    }

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: InFlight] = [:]
    private var missing = Set<String>()

    private init() {
        cache.countLimit = 48
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(
        for record: HistoryRecord,
        identity: String,
        forceReload: Bool
    ) async -> UIImage? {
        let key = identity as NSString
        if forceReload {
            cache.removeObject(forKey: key)
            missing.remove(identity)
            inFlight.removeValue(forKey: identity)?.task.cancel()
        }
        if let cached = cache.object(forKey: key) { return cached }
        if missing.contains(identity) { return nil }
        if let existing = inFlight[identity] {
            return await existing.task.value
        }

        let source: CoverThumbnailDecodeSource?
        if record.sourceKind == .youtube {
            guard let sourceURL = record.sourceURL,
                  let reference = YouTubeURLParser.parse(sourceURL) else {
                missing.insert(identity)
                return nil
            }
            let videoID = reference.videoId
            let task = Task<UIImage?, Never> {
                guard let data = await YouTubeCacheProvider.shared?
                    .peekThumbnail(videoId: videoID),
                      !Task.isCancelled else { return nil }
                return await CoverThumbnailDecoder.image(from: .data(data))
            }
            return await finish(task, identity: identity, key: key)
        } else if let url = HistoryStore.shared.coverURL(for: record) {
            source = .file(url)
        } else {
            source = nil
        }
        guard let source else {
            missing.insert(identity)
            return nil
        }
        let task = Task<UIImage?, Never> {
            guard !Task.isCancelled else { return nil }
            return await CoverThumbnailDecoder.image(from: source)
        }
        return await finish(task, identity: identity, key: key)
    }

    private func finish(
        _ task: Task<UIImage?, Never>,
        identity: String,
        key: NSString
    ) async -> UIImage? {
        let token = UUID()
        inFlight[identity] = InFlight(token: token, task: task)
        let image = await task.value
        guard inFlight[identity]?.token == token else { return image }
        inFlight.removeValue(forKey: identity)
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key, cost: cost)
        } else if !task.isCancelled {
            missing.insert(identity)
        }
        return image
    }
}

struct CoverThumbnail: View {
    let record: HistoryRecord
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?
    @State private var reloadRevision = 0

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
        .task(id: taskIdentity) {
            await load(forceReload: reloadRevision > 0)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .castReaderYouTubeThumbnailCacheChanged
            )
        ) { notification in
            guard record.sourceKind == .youtube,
                  let videoIDHash,
                  notification.object as? String == videoIDHash else { return }
            reloadRevision &+= 1
        }
    }

    private func load(forceReload: Bool = false) async {
        let decoded = await CoverThumbnailImageLoader.shared.image(
            for: record,
            identity: loadIdentity,
            forceReload: forceReload
        )
        guard !Task.isCancelled else { return }
        image = decoded
    }

    private var loadIdentity: String {
        [record.id, record.sourceURL ?? "", record.coverPath ?? ""].joined(separator: "|")
    }

    private var taskIdentity: String {
        "\(loadIdentity)|\(reloadRevision)"
    }

    private var videoIDHash: String? {
        guard let sourceURL = record.sourceURL,
              let reference = YouTubeURLParser.parse(sourceURL) else { return nil }
        return YouTubeCacheDigest.sha256(reference.videoId)
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
