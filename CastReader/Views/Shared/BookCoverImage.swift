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

    /// 获取有效的 URL（处理已编码和未编码的情况）
    private var imageURL: URL? {
        guard let urlString = url, !urlString.isEmpty else { return nil }

        // 先尝试直接创建 URL（可能已经编码过）
        if let url = URL(string: urlString) {
            return url
        }

        // 如果失败，尝试编码后创建（处理含空格等特殊字符的情况）
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            return url
        }

        return nil
    }

    var body: some View {
        Group {
            if let imageUrl = imageURL {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                            .overlay(ProgressView())
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                            .overlay(bookIcon)
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                // URL 无效时直接显示 placeholder（不触发网络请求）
                placeholder
                    .overlay(bookIcon)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.2))
    }

    private var bookIcon: some View {
        Image(systemName: "book.closed")
            .font(.title2)
            .foregroundColor(.gray)
    }
}

struct BookCoverImage_Previews: PreviewProvider {
    static var previews: some View {
        BookCoverImage(url: nil)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}
