//
//  Document.swift
//  CastReader
//

import Foundation

// MARK: - Document List Response
struct DocumentListResponse: Codable {
    let success: Bool?
    let documents: [Document]?
    let count: Int?

    // Handle both array response and object response
    init(from decoder: Decoder) throws {
        // Try to decode as array first
        if let container = try? decoder.singleValueContainer(),
           let documents = try? container.decode([Document].self) {
            self.success = true
            self.documents = documents
            self.count = documents.count
        } else {
            // Try to decode as object
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.success = try container.decodeIfPresent(Bool.self, forKey: .success)
            self.documents = try container.decodeIfPresent([Document].self, forKey: .documents)
            self.count = try container.decodeIfPresent(Int.self, forKey: .count)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case success
        case documents
        case count
    }
}

// MARK: - Document Model
struct Document: Codable, Identifiable {
    let id: String
    let name: String
    let mdUrl: String?
    let thumbnail: String?
    let wordCount: Int?
    let chapterCount: Int?
    let processingStatus: ProcessingStatus?
    let voiceId: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mdUrl = "md_url"
        case thumbnail
        case wordCount = "word_count"
        case chapterCount = "chapter_count"
        case processingStatus = "processing_status"
        case voiceId = "voice_id"
        case createdAt = "created_at"
    }
}

enum ProcessingStatus: String, Codable {
    case pending = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"

    var displayText: String {
        switch self {
        case .pending: return "Pending"
        case .processing: return "Processing"
        case .completed: return "Ready"
        case .failed: return "Failed"
        }
    }

    var isReady: Bool {
        self == .completed
    }
}

// MARK: - Upload Response (for async PDF upload)
struct UploadResponse: Codable {
    let success: Bool
    let message: String?
    let documentId: String?
    let document: Document?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case documentId = "document_id"
        case document
    }
}

// MARK: - EPUB Upload Response (for sync EPUB upload)
struct EPUBUploadResponse: Codable {
    let success: Bool
    let message: String?
    let bookId: String?
    let book: EPUBBook?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case bookId = "book_id"
        case book
    }
}

// MARK: - EPUB Book
struct EPUBBook: Codable, Identifiable {
    let id: String
    let title: String?
    let authors: [String]?
    let cover: String?
    let mdUrl: String?
    let wordCount: Int?
    let chapterCount: Int?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case authors
        case cover
        case mdUrl = "md_url"
        case wordCount = "word_count"
        case chapterCount = "chapter_count"
        case language
    }
}

// MARK: - STS Response
struct STSResponse: Codable {
    let success: Bool
    let sts: STSCredentials?
}

struct STSCredentials: Codable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let bucket: String
    let region: String
    let prefix: String

    enum CodingKeys: String, CodingKey {
        case accessKeyId
        case secretAccessKey
        case sessionToken
        case bucket
        case region
        case prefix
    }
}

// MARK: - Text Input Data (for direct playback)
struct TextInputData: Identifiable {
    let id: String
    let title: String
    let content: String
    let createdAt: Date

    init(title: String, content: String) {
        self.id = UUID().uuidString
        self.title = title.isEmpty ? "Text Input" : title
        self.content = content
        self.createdAt = Date()
    }

    /// Parse content and return data for PlayerView
    /// Splits text into proper paragraphs to match library format
    var playerData: (paragraphs: [String], parsedParagraphs: [ParsedParagraph], indices: [BookIndex]) {
        // Split content into paragraphs (by double newlines or reasonable length)
        let contentParagraphs = splitIntoParagraphs(content)

        // Build markdown with title as heading and each paragraph separated
        var markdown = "# \(title)\n\n"
        markdown += contentParagraphs.joined(separator: "\n\n")

        print("🟣 [TextInputData.playerData] Generated markdown with \(contentParagraphs.count) paragraphs")
        print("🟣 [TextInputData.playerData] \(String(markdown.prefix(200)))...")

        let parsed = MarkdownParser.parse(markdown)
        print("🟣 [TextInputData.playerData] Parsed result:")
        print("🟣 [TextInputData.playerData] paragraphs count: \(parsed.paragraphs.count)")
        print("🟣 [TextInputData.playerData] toc count: \(parsed.toc.count)")

        let result = parsed.asPlayerData
        print("🟣 [TextInputData.playerData] asPlayerData result:")
        print("🟣 [TextInputData.playerData] paragraphs: \(result.paragraphs.count)")
        print("🟣 [TextInputData.playerData] parsedParagraphs: \(result.parsedParagraphs.count)")
        print("🟣 [TextInputData.playerData] indices: \(result.indices.count)")

        return result
    }

    /// Split text into paragraphs - by double newlines, or by sentence boundaries for long text
    private func splitIntoParagraphs(_ text: String) -> [String] {
        // First, try splitting by double newlines (user-intended paragraph breaks)
        let byDoubleNewline = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // If we have reasonable paragraphs, use them
        if byDoubleNewline.count > 1 {
            return byDoubleNewline
        }

        // If text is one big block, split by sentences into ~500 char chunks
        let sentences = splitIntoSentences(text)
        var paragraphs: [String] = []
        var currentParagraph = ""

        for sentence in sentences {
            if currentParagraph.isEmpty {
                currentParagraph = sentence
            } else if currentParagraph.count + sentence.count < 500 {
                currentParagraph += " " + sentence
            } else {
                paragraphs.append(currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines))
                currentParagraph = sentence
            }
        }

        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return paragraphs.isEmpty ? [text] : paragraphs
    }

    /// Split text into sentences
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var currentSentence = ""

        // Sentence-ending punctuation
        let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]

        for char in text {
            currentSentence.append(char)

            if sentenceEnders.contains(char) {
                let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                currentSentence = ""
            }
        }

        // Add remaining text
        let remaining = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        return sentences
    }
}
