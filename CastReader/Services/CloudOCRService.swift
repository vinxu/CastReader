import Foundation
import UIKit

/// Uses the existing image-language setting shared by imports and Settings.
/// An explicit script choice avoids relying on unsupported native OCR models.
enum PhotoOCRLanguagePreference {
    static let key = "image_text_language_v1"

    static func selected(defaults: UserDefaults = .standard, route: ServiceRoute = ServiceRouting.current) -> String? {
        guard route == .globalGateway,
              let value = defaults.string(forKey: key),
              let language = SupportedTTSLanguage(identifier: value), language.requiresCloudOCR else { return nil }
        return language.rawValue
    }
}

enum CloudOCRError: LocalizedError {
    case signInRequired, unavailable, invalidResponse, imageTooLarge, rateLimited, noText

    var errorDescription: String? {
        switch self {
        case .signInRequired: return AppLocalized("Sign in to recognize this language.")
        case .unavailable: return AppLocalized("Cloud text recognition is unavailable. Please try again later.")
        case .invalidResponse: return AppLocalized("The recognized text could not be positioned on this image. Please try another photo.")
        case .imageTooLarge: return AppLocalized("This image is too large. Please crop the page and try again.")
        case .rateLimited: return AppLocalized("Too many recognition requests. Please try again later.")
        case .noText: return AppLocalized("No text was found. Please try a clearer photo.")
        }
    }
}

struct CloudOCRResponse: Decodable {
    struct Word: Decodable {
        let id: Int
        let text: String
        let polygon: [[Double]]
        let confidence: Double?
    }
    let contract: String
    let provider: String
    let layoutVersion: String
    let language: String
    let width: Int
    let height: Int
    let columnCount: Int
    let words: [Word]

    /// Geometry uses the uploaded JPEG's pixels, with the origin at top left.
    /// Conversion happens once here; the reader continues using Vision space.
    func document(imageData: Data, expectedSize: CGSize, language expectedLanguage: String, title: String?) throws -> ReadingDocument {
        guard contract == "mobile-ocr-v1", provider == "google-vision", layoutVersion == "layout-footer-v3",
              language == expectedLanguage, SupportedTTSLanguage(identifier: language)?.requiresCloudOCR == true,
              width > 0, height > 0, CGFloat(width) == expectedSize.width, CGFloat(height) == expectedSize.height,
              (1...2).contains(columnCount), !words.isEmpty, words.count <= 4_000,
              Set(words.map(\.id)).count == words.count,
              words.allSatisfy({ $0.id >= 0 && $0.id < words.count }) else { throw CloudOCRError.invalidResponse }
        var paragraphs: [ReadingParagraph] = []
        var pending: [OCRWord] = []
        var characterCount = 0
        func flush() {
            guard !pending.isEmpty else { return }
            paragraphs.append(ReadingParagraph(id: paragraphs.count, text: pending.map(\.text).joined(separator: " "),
                words: pending, bboxNorm: pending.dropFirst().reduce(pending[0].bboxNorm) { $0.union($1.bboxNorm) }))
            pending = []; characterCount = 0
        }
        for (index, word) in words.enumerated() {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, word.text.count <= 2_048,
                  word.polygon.count == 4, word.polygon.allSatisfy({ point in
                      point.count == 2 && point[0].isFinite && point[1].isFinite &&
                      point[0] >= 0 && point[0] <= Double(width) && point[1] >= 0 && point[1] <= Double(height)
                  }), word.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw CloudOCRError.invalidResponse }
            let xs = word.polygon.map { $0[0] }, ys = word.polygon.map { $0[1] }
            let left = xs.min()!, right = xs.max()!, top = ys.min()!, bottom = ys.max()!
            guard right > left, bottom > top else { throw CloudOCRError.invalidResponse }
            let rect = CGRect(x: left / Double(width), y: 1 - bottom / Double(height),
                              width: (right - left) / Double(width), height: (bottom - top) / Double(height))
            // Preserve server order, including orphan joins and deferred footers.
            // IDs are contiguous in reading order, matching the existing reader.
            if characterCount + word.text.count > 800 || pending.count >= 80 { flush() }
            pending.append(OCRWord(id: index, text: word.text, bboxNorm: rect, bboxSource: .googleVisionWord,
                                   recognitionConfidence: word.confidence.map { Float($0) }))
            characterCount += word.text.count + 1
            if characterCount >= 160, word.text.last.map({ ".!?।॥".contains($0) }) == true { flush() }
        }
        flush()
        return ReadingDocument(title: title ?? String(paragraphs[0].text.prefix(48)), sourceKind: .photo,
            language: language, paragraphs: paragraphs, imageData: imageData, imagePixelSize: expectedSize,
            layoutColumnCount: columnCount)
    }
}

actor CloudOCRService {
    static let shared = CloudOCRService()
    private let session: URLSession
    private let mobileSession: MobileSessionProviding
    private let route: ServiceRoute

    init(session: URLSession? = nil, mobileSession: MobileSessionProviding = MobileSessionStore.shared,
         route: ServiceRoute = ServiceRouting.current) {
        self.route = route
        self.mobileSession = mobileSession
        self.session = session ?? OwnedAPIURLSession.makeExplicitCredentialSession(route: route, requestTimeout: 55, resourceTimeout: 65)
    }

    func recognize(image: UIImage, language: String, title: String? = nil, singleFlow: Bool = false) async throws -> ReadingDocument {
        guard route == .globalGateway, SupportedTTSLanguage(identifier: language)?.requiresCloudOCR == true else {
            throw CloudOCRError.unavailable
        }
        try Task.checkCancellation()
        guard var token = await mobileSession.sessionToken(), token.hasPrefix("cms_") else { throw CloudOCRError.signInRequired }
        let (jpeg, size) = try Self.prepare(image)
        let body = try JSONSerialization.data(withJSONObject: ["imageBase64": jpeg.base64EncodedString(),
            "language": language, "layout": singleFlow ? "single-flow" : "document"])
        for attempt in 0...1 {
            try Task.checkCancellation()
            guard await mobileSession.sessionToken() == token else { throw CancellationError() }
            var request = URLRequest(url: URL(string: route.apiGatewayBaseURL + "/api/mobile/ocr")!)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard await mobileSession.sessionToken() == token else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw CloudOCRError.invalidResponse }
            if http.statusCode == 401 {
                if attempt == 0, let refreshed = await mobileSession.refreshSession(replacing: token), refreshed.hasPrefix("cms_") {
                    token = refreshed; continue
                }
                await mobileSession.rejectSession(token)
                throw CloudOCRError.signInRequired
            }
            if http.statusCode == 429 { throw CloudOCRError.rateLimited }
            if http.statusCode == 413 { throw CloudOCRError.imageTooLarge }
            if http.statusCode == 422 { throw CloudOCRError.noText }
            guard http.statusCode == 200 else { throw CloudOCRError.unavailable }
            guard data.count <= 8_000_000, let decoded = try? JSONDecoder().decode(CloudOCRResponse.self, from: data) else {
                throw CloudOCRError.invalidResponse
            }
            return try decoded.document(imageData: jpeg, expectedSize: size, language: language, title: title)
        }
        throw CloudOCRError.signInRequired
    }

    static func prepare(_ image: UIImage) throws -> (Data, CGSize) {
        guard image.size.width > 0, image.size.height > 0, image.size.width.isFinite, image.size.height.isFinite else {
            throw CloudOCRError.invalidResponse
        }
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, 2500 / max(pixelSize.width, pixelSize.height))
        let size = CGSize(width: max(1, (pixelSize.width * scale).rounded()), height: max(1, (pixelSize.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.9, 0.8, 0.7] {
            if let data = normalized.jpegData(compressionQuality: quality), data.count <= 2_500_000 { return (data, size) }
        }
        throw CloudOCRError.imageTooLarge
    }
}
