//
//  Book.swift
//  CastReader
//

import Foundation

// MARK: - Genre Response
struct GenreResponse: Codable {
    let success: Bool
    let list: [String]
}

// MARK: - Search Request/Response
struct SearchRequest: Codable {
    let text: String
    let pageNumber: Int
    let pageSize: Int

    enum CodingKeys: String, CodingKey {
        case text
        case pageNumber = "page_number"
        case pageSize = "page_size"
    }
}

struct SearchResponse: Codable {
    let success: Bool
    let data: BookListData?
}

// MARK: - Book List Response
struct BookListResponse: Codable {
    let success: Bool
    let data: BookListData
}

struct BookListData: Codable {
    let count: Int
    let list: [Book]
}

// MARK: - Book Model
struct Book: Codable, Identifiable {
    let uid: String
    let cover: String?
    let name: String
    let genre: [String]?
    let metadata: BookMetadata?

    var id: String { uid }

    var title: String {
        metadata?.title ?? name
    }

    var author: String {
        metadata?.author ?? "Unknown Author"
    }

    var description: String {
        metadata?.description ?? ""
    }

    var rating: Double? {
        metadata?.rating
    }

    var date: String? {
        metadata?.date
    }

    /// 封面 URL - 使用顶层 cover 字段，需要 URL 编码处理空格
    var coverUrl: String? {
        guard let url = cover, !url.isEmpty else { return nil }
        // URL 编码处理空格等特殊字符
        return url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

struct BookMetadata: Codable {
    let cover: String?
    let title: String?
    let author: String?
    let rating: Double?
    let description: String?
    let date: String?

    enum CodingKeys: String, CodingKey {
        case cover, title, author, rating, description, date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        date = try container.decodeIfPresent(String.self, forKey: .date)

        // Handle rating as either Double or String
        if let doubleRating = try? container.decodeIfPresent(Double.self, forKey: .rating) {
            rating = doubleRating
        } else if let stringRating = try? container.decodeIfPresent(String.self, forKey: .rating) {
            rating = Double(stringRating)
        } else {
            rating = nil
        }
    }

    init(cover: String? = nil, title: String?, author: String?, rating: Double?, description: String?, date: String? = nil) {
        self.cover = cover
        self.title = title
        self.author = author
        self.rating = rating
        self.description = description
        self.date = date
    }
}

// MARK: - Book Content (for reader)
struct BookContent: Codable {
    let uid: String
    let title: String
    let chapters: [Chapter]
}

// MARK: - HTML Book Detail Response
struct HtmlBookResponse: Codable {
    let success: Bool
    let message: String?
    let data: HtmlBookData?
}

struct HtmlBookData: Codable {
    let book: BookDetail
    let relatedBooks: [RelatedBook]?

    enum CodingKeys: String, CodingKey {
        case book
        case relatedBooks = "related_books"
    }
}

struct BookDetail: Codable {
    let uid: String
    let cover: String?
    let name: String
    let author: String?
    let genre: [String]?
    let metadata: BookDetailMetadata?
    let indices: [BookIndex]?
    let content: String?  // HTML URL - might be nil for some books

    /// 封面 URL - 使用顶层 cover 字段，需要 URL 编码处理空格
    var coverUrl: String? {
        guard let url = cover, !url.isEmpty else { return nil }
        return url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

struct BookDetailMetadata: Codable {
    let cover: String?
    let genre: [String]?  // 统一转为数组
    let title: String?
    let author: String?
    let rating: Double?   // 统一转为 Double
    let creator: String?
    let language: String?
    let subjects: [String]?
    let description: String?
    let date: String?
    let coverUrl: String?
    let publisher: String?
    let identifier: String?
    let searchTerm: String?
    let reviewCount: Int?
    let goodreadsUrl: String?

    enum CodingKeys: String, CodingKey {
        case cover, genre, title, author, rating, creator, language
        case subjects, description, date, publisher, identifier
        case coverUrl = "cover_url"
        case searchTerm = "search_term"
        case reviewCount = "review_count"
        case goodreadsUrl = "goodreads_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 普通字段
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        subjects = try container.decodeIfPresent([String].self, forKey: .subjects)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        searchTerm = try container.decodeIfPresent(String.self, forKey: .searchTerm)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount)
        goodreadsUrl = try container.decodeIfPresent(String.self, forKey: .goodreadsUrl)

        // genre: 可能是 String 或 [String]
        if let genreArray = try? container.decodeIfPresent([String].self, forKey: .genre) {
            genre = genreArray
        } else if let genreString = try? container.decodeIfPresent(String.self, forKey: .genre) {
            genre = genreString.components(separatedBy: ", ")
        } else {
            genre = nil
        }

        // rating: 可能是 Double 或 String
        if let ratingDouble = try? container.decodeIfPresent(Double.self, forKey: .rating) {
            rating = ratingDouble
        } else if let ratingString = try? container.decodeIfPresent(String.self, forKey: .rating) {
            rating = Double(ratingString)
        } else {
            rating = nil
        }
    }
}

struct BookIndex: Codable {
    let href: String?  // API 可能返回 null
    let text: String?  // API 可能返回 null
}

struct RelatedBook: Codable, Identifiable {
    let uid: String
    let cover: String?
    let name: String
    let author: String?

    var id: String { uid }

    /// 封面 URL - URL 编码处理空格
    var coverUrl: String? {
        guard let url = cover, !url.isEmpty else { return nil }
        return url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

// MARK: - Image Alignment
enum ImageAlignment {
    case center    // figcenter - 居中大图
    case left      // figleft - 左对齐
    case right     // figright - 右对齐小图
    case inline    // 行内图片
}

// MARK: - Image Block (for inline images in HTML)
struct ImageBlock: Identifiable {
    let id: String              // 唯一标识
    let src: String             // 图片 URL
    let alt: String?            // 图片描述文字
    let width: CGFloat?         // 图片宽度（从 style 提取）
    let alignment: ImageAlignment  // 对齐方式
    let caption: String?        // 图片说明文字
    let isDropcap: Bool         // 是否是装饰性首字母

    init(src: String, alt: String? = nil, width: CGFloat? = nil, alignment: ImageAlignment = .center, caption: String? = nil, isDropcap: Bool = false) {
        self.id = UUID().uuidString
        self.src = src
        self.alt = alt
        self.width = width
        self.alignment = alignment
        self.caption = caption
        self.isDropcap = isDropcap
    }

    /// 判断是否是小图（宽度小于 200px 或 figright/figleft）
    var isSmallImage: Bool {
        if let w = width, w < 200 { return true }
        return alignment == .right || alignment == .left
    }
}

// MARK: - Paragraph Type (for styling)
enum ParagraphType: Equatable {
    case paragraph           // 普通段落
    case heading(Int)        // 标题 (1-6)
    case blockquote          // 引用块
    case code                // 代码块
    case list                // 列表项
    case image               // 纯图片段落

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    var headingLevel: Int? {
        if case .heading(let level) = self { return level }
        return nil
    }
}

// MARK: - Parsed Paragraph (for HTML parsing with IDs)
struct ParsedParagraph {
    let id: String?      // HTML 中的 id 属性，如 "ch1"
    let text: String     // 段落纯文本内容，包含 \n（用于 TTS）
    let html: String     // 原始 HTML 内容（用于渲染样式）
    let index: Int       // 段落索引
    let type: ParagraphType    // 段落类型（用于样式）
    let images: [ImageBlock]?  // 段落中的图片

    init(id: String?, text: String, html: String, index: Int, type: ParagraphType = .paragraph, images: [ImageBlock]? = nil) {
        self.id = id
        self.text = text
        self.html = html
        self.index = index
        self.type = type
        self.images = images
    }
}
