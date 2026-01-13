//
//  APIService.swift
//  CastReader
//

import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)
    case networkError(Error)
    case bookNotFound
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .bookNotFound:
            return "Book not available"
        case .serverError(let message):
            return message
        }
    }
}

actor APIService {
    static let shared = APIService()

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
    }

    // MARK: - Generic Request

    private func request<T: Decodable>(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            // Print error response body for debugging
            if let errorBody = String(data: data, encoding: .utf8) {
                print("🔴 [API] HTTP \(httpResponse.statusCode) error response: \(errorBody)")
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Debug: print raw response and detailed error
            if let jsonString = String(data: data, encoding: .utf8) {
                print("🔴 Decoding failed. Raw response: \(String(jsonString.prefix(1500)))")
            }
            print("🔴 Decoding error details: \(error)")
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Explore API

    func fetchGenres(number: Int = 100) async throws -> [String] {
        guard let url = URL(string: "\(Constants.API.genres)?number=\(number)") else {
            throw APIError.invalidURL
        }

        let response: GenreResponse = try await request(url)
        return response.list
    }

    // MARK: - Search API

    func searchBooks(query: String, page: Int = 0, pageSize: Int = 10) async throws -> [Book] {
        guard let url = URL(string: Constants.API.searchBooks) else {
            throw APIError.invalidURL
        }

        let searchRequest = SearchRequest(text: query, pageNumber: page, pageSize: pageSize)
        let bodyData = try JSONEncoder().encode(searchRequest)

        let response: SearchResponse = try await request(url, method: "POST", body: bodyData)
        return response.data?.list ?? []
    }

    func fetchBooks(genre: String, page: Int = 0, pageSize: Int = 20) async throws -> BookListData {
        // URL encode the genre parameter (handles spaces and special characters)
        let encodedGenre = genre.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? genre
        let urlString = "\(Constants.API.books)?page_number=\(page)&page_size=\(pageSize)&genre=\(encodedGenre)"

        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }

        let response: BookListResponse = try await request(url)
        return response.data
    }

    // MARK: - Library API

    func fetchDocuments(userId: String, limit: Int = 100, offset: Int = 0) async throws -> [Document] {
        var components = URLComponents(string: Constants.API.documents)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: userId),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]

        guard let url = components?.url else {
            throw APIError.invalidURL
        }

        // API returns {"success":true,"documents":[...],"count":N}
        let response: DocumentListResponse = try await request(url)
        return response.documents ?? []
    }

    // MARK: - Upload API

    func fetchSTSCredentials() async throws -> STSCredentials {
        guard let url = URL(string: Constants.API.sts) else {
            throw APIError.invalidURL
        }

        let response: STSResponse = try await request(url)
        guard let sts = response.sts else {
            throw APIError.invalidResponse
        }
        return sts
    }

    func notifyUpload(filename: String, filepath: String, userId: String, voiceId: String = Constants.TTS.defaultVoice) async throws -> UploadResponse {
        guard let url = URL(string: Constants.API.asyncUpload) else {
            throw APIError.invalidURL
        }

        print("📤 [API] notifyUpload URL: \(url)")
        print("📤 [API] notifyUpload params: filename=\(filename), filepath=\(filepath), user_id=\(userId), voice_id=\(voiceId)")

        // Use multipart/form-data format (same as web)
        let boundary = "Boundary-\(UUID().uuidString)"
        var bodyData = Data()

        // Helper to append form field
        func appendFormField(name: String, value: String) {
            bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
            bodyData.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            bodyData.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendFormField(name: "filename", value: filename)
        appendFormField(name: "filepath", value: filepath)
        appendFormField(name: "user_id", value: userId)
        appendFormField(name: "voice_id", value: voiceId)

        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            if let errorBody = String(data: data, encoding: .utf8) {
                print("🔴 [API] HTTP \(httpResponse.statusCode) error response: \(errorBody)")
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(UploadResponse.self, from: data)
        } catch {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("🔴 [API] Decoding failed. Raw response: \(String(jsonString.prefix(1500)))")
            }
            print("🔴 [API] Decoding error details: \(error)")
            throw APIError.decodingError(error)
        }
    }

    /// Upload EPUB file synchronously (returns immediately with book data)
    func uploadEPUB(fileData: Data, filename: String, userId: String, voiceId: String = Constants.TTS.defaultVoice) async throws -> EPUBUploadResponse {
        guard let url = URL(string: Constants.API.syncUpload) else {
            throw APIError.invalidURL
        }

        print("📗 [API] uploadEPUB URL: \(url)")
        print("📗 [API] uploadEPUB params: filename=\(filename), size=\(fileData.count) bytes, user_id=\(userId)")

        // Use multipart/form-data with file binary
        let boundary = "Boundary-\(UUID().uuidString)"
        var bodyData = Data()

        // Add file field
        bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
        bodyData.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        bodyData.append("Content-Type: application/epub+zip\r\n\r\n".data(using: .utf8)!)
        bodyData.append(fileData)
        bodyData.append("\r\n".data(using: .utf8)!)

        // Add user_id field
        bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
        bodyData.append("Content-Disposition: form-data; name=\"user_id\"\r\n\r\n".data(using: .utf8)!)
        bodyData.append("\(userId)\r\n".data(using: .utf8)!)

        // Add voice_id field
        bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
        bodyData.append("Content-Disposition: form-data; name=\"voice_id\"\r\n\r\n".data(using: .utf8)!)
        bodyData.append("\(voiceId)\r\n".data(using: .utf8)!)

        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        // EPUB processing can take longer
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        print("📗 [API] uploadEPUB response status: \(httpResponse.statusCode)")

        guard 200..<300 ~= httpResponse.statusCode else {
            if let errorBody = String(data: data, encoding: .utf8) {
                print("🔴 [API] HTTP \(httpResponse.statusCode) error response: \(errorBody)")
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        // Debug: print raw response
        if let jsonString = String(data: data, encoding: .utf8) {
            print("📗 [API] uploadEPUB raw response: \(String(jsonString.prefix(500)))")
        }

        do {
            return try decoder.decode(EPUBUploadResponse.self, from: data)
        } catch {
            if let jsonString = String(data: data, encoding: .utf8) {
                print("🔴 [API] Decoding failed. Raw response: \(String(jsonString.prefix(1500)))")
            }
            print("🔴 [API] Decoding error details: \(error)")
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Book Content API

    func fetchBookDetail(uid: String) async throws -> BookDetail {
        guard let url = URL(string: "\(Constants.API.baseURL)/html-ebook?uid=\(uid)") else {
            throw APIError.invalidURL
        }

        let response: HtmlBookResponse = try await request(url)

        // Check if API returned success
        guard response.success else {
            if let message = response.message {
                throw APIError.serverError(message)
            }
            throw APIError.bookNotFound
        }

        // Check if data exists
        guard let data = response.data else {
            throw APIError.bookNotFound
        }

        return data.book
    }

    func fetchHtmlContent(url urlString: String) async throws -> String {
        // URL 编码处理空格等特殊字符
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let contentURL = URL(string: encoded) else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: contentURL)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw APIError.invalidResponse
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Fetch Markdown content from URL
    func fetchMarkdownContent(url urlString: String) async throws -> String {
        // URL encode to handle spaces and special characters
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let contentURL = URL(string: encoded) else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: contentURL)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw APIError.invalidResponse
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - TTS API

    func generateTTS(text: String, voice: String = Constants.TTS.defaultVoice, speed: Double = Constants.TTS.defaultSpeed, language: String = Constants.TTS.defaultLanguage) async throws -> TTSResponse {
        guard let url = URL(string: Constants.API.tts) else {
            throw APIError.invalidURL
        }

        // Truncate text if too long (API might have limit)
        let maxLength = 5000
        let inputText = text.count > maxLength ? String(text.prefix(maxLength)) : text

        let ttsRequest = TTSRequest(input: inputText, voice: voice, speed: speed, language: language)
        let bodyData = try JSONEncoder().encode(ttsRequest)

        return try await request(url, method: "POST", body: bodyData)
    }
}
