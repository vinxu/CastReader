//
//  BookCoverImage.swift
//  CastReader
//

import SwiftUI

struct BookCoverImage: View {
    let url: String?
    var width: CGFloat = 80
    var height: CGFloat = 120
    var cornerRadius: CGFloat = 8

    /// 获取有效的 URL（处理已编码和未编码的情况，并添加 COS 图片处理参数）
    private var imageURL: URL? {
        guard let urlString = url, !urlString.isEmpty else { return nil }

        // 添加 COS 图片处理参数（中等尺寸用于封面）
        let processedUrl = urlString.cosImageUrl(size: .medium)

        // 先尝试直接创建 URL（可能已经编码过）
        if let url = URL(string: processedUrl) {
            return url
        }

        // 如果失败，尝试编码后创建（处理含空格等特殊字符的情况）
        if let encoded = processedUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            return url
        }

        return nil
    }

    var body: some View {
        Group {
            if let imageUrl = imageURL {
                CachedAsyncImage(url: imageUrl, contentMode: .fill) {
                    placeholder
                        .overlay(ProgressView())
                }
            } else {
                placeholder
                    .overlay(bookIcon)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppTheme.surfaceVariant)
    }

    private var bookIcon: some View {
        Image(systemName: "book.closed")
            .font(.title2)
            .foregroundColor(AppTheme.mutedForeground)
    }
}

struct BookCoverImage_Previews: PreviewProvider {
    static var previews: some View {
        BookCoverImage(url: nil)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
