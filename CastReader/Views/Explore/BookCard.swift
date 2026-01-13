//
//  BookCard.swift
//  CastReader
//

import SwiftUI

struct BookCard: View {
    let book: Book

    // 检查封面是否有效（与 Web 逻辑一致）
    private var hasCover: Bool {
        guard let cover = book.coverUrl, !cover.isEmpty else { return false }
        return URL(string: cover) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Cover image - 竖版比例 2:3，带缓存
            Group {
                if hasCover, let coverUrl = URL(string: book.coverUrl!) {
                    CachedAsyncImage(url: coverUrl) {
                        fallbackCover
                    }
                } else {
                    // 无封面时直接显示 fallback（不触发网络请求）
                    fallbackCover
                }
            }
            .frame(width: Constants.UI.bookCardWidth, height: Constants.UI.bookCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Title only - 无作者
            Text(book.title)
                .font(.footnote)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .frame(width: Constants.UI.bookCardWidth)
    }

    // 渐变色 fallback 封面（与 Web 一致）
    private var fallbackCover: some View {
        ZStack(alignment: .bottomLeading) {
            // 基于书名生成渐变色
            LinearGradient(
                colors: gradientColors(for: book.name),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(book.title)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
    }

    // 根据书名生成渐变色（与 Web getGradientByString 一致）
    private func gradientColors(for name: String) -> [Color] {
        let gradients: [[Color]] = [
            [Color(red: 251/255, green: 113/255, blue: 133/255), Color(red: 253/255, green: 186/255, blue: 116/255)], // rose-orange
            [Color(red: 96/255, green: 165/255, blue: 250/255), Color(red: 129/255, green: 140/255, blue: 248/255)],  // blue-indigo
            [Color(red: 52/255, green: 211/255, blue: 153/255), Color(red: 34/255, green: 211/255, blue: 238/255)],   // emerald-cyan
            [Color(red: 252/255, green: 211/255, blue: 77/255), Color(red: 234/255, green: 179/255, blue: 8/255)],    // amber-yellow
            [Color(red: 217/255, green: 70/255, blue: 239/255), Color(red: 236/255, green: 72/255, blue: 153/255)],   // fuchsia-pink
            [Color(red: 100/255, green: 116/255, blue: 139/255), Color(red: 30/255, green: 41/255, blue: 59/255)],    // slate
        ]

        var hash = 0
        for char in name.unicodeScalars {
            hash = Int(char.value) &+ ((hash << 5) &- hash)
        }
        let index = abs(hash) % gradients.count
        return gradients[index]
    }
}

struct BookCard_Previews: PreviewProvider {
    static var previews: some View {
        BookCard(
            book: Book(
                uid: "1",
                cover: nil,
                name: "The Great Adventure",
                genre: ["Fantasy"],
                metadata: BookMetadata(
                    title: "The Great Adventure",
                    author: "John Doe",
                    rating: 4.5,
                    description: nil
                )
            )
        )
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
