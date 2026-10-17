import XCTest
import UIKit
@testable import CastReader

private actor OCRTestSession: MobileSessionProviding {
    var token: String? = "cms_original"
    var refreshes = 0
    func sessionToken() -> String? { token }
    func refreshSession() -> String? { refreshes += 1; token = "cms_refreshed"; return token }
    func invalidateSession() { token = nil }
}

private final class OCRTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var loadingTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        loadingTask = Task {
            do {
                let (status, data) = try await Self.handler!(request)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { loadingTask?.cancel() }
}

@MainActor
final class CloudOCRTests: XCTestCase {
    private let examples = ["bn": ["বাংলা", "বই", "পড়ি"], "mr": ["मराठी", "पुस्तक", "वाचतो"],
                            "pa": ["ਸਾਡੇ", "ਮਿਲ", "ਗਏ"], "ta": ["தமிழ்", "புத்தகம்", "படிக்கிறேன்"]]
    private func payload(_ language: String = "pa", count: Int = 3) throws -> Data {
        let words: [[String: Any]] = (0..<count).map { index in
            ["id": count - index - 1, "text": examples[language]![index % 3],
             "polygon": [[10, 20 + index % 3 * 20], [80, 20 + index % 3 * 20], [80, 30 + index % 3 * 20], [10, 30 + index % 3 * 20]], "confidence": 0.95]
        }
        return try JSONSerialization.data(withJSONObject: ["contract": "mobile-ocr-v1", "provider": "google-vision",
            "layoutVersion": "layout-footer-v3", "language": language, "width": 100, "height": 100, "columnCount": 2, "words": words])
    }
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { $0.fill(CGRect(x: 0, y: 0, width: 100, height: 100)) }
    }
    private func service(_ session: OCRTestSession, route: ServiceRoute = .globalGateway) -> CloudOCRService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OCRTestURLProtocol.self]
        return CloudOCRService(session: URLSession(configuration: config), mobileSession: session, route: route)
    }
    override func tearDown() { OCRTestURLProtocol.handler = nil; super.tearDown() }

    func testRecordedGooglePagesAndEightNativeVoicesAlignInTheActualReader() throws {
        struct Voice: Decodable { let voice: String; let timestamps: [TTSTimestamp]; let duration: Double }
        struct Fixture: Decodable { let language: String; let response: CloudOCRResponse; let voices: [Voice] }
        let url = TestRepository.root.appendingPathComponent("CastReaderTests/Fixtures/google-four-ocr-native-marks.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(fixtures.map(\.language)), Set(["bn", "mr", "pa", "ta"]))
        for fixture in fixtures {
            let response = fixture.response
            let doc = try response.document(imageData: Data(), expectedSize: CGSize(width: response.width, height: response.height), language: fixture.language, title: nil)
            let words = doc.paragraphs.flatMap(\.words)
            XCTAssertEqual(words.map(\.text), response.words.map(\.text))
            XCTAssertEqual(LanguageDetector.detect(doc.fullText), fixture.language)
            let combined = ReadingParagraph(id: 0, text: doc.paragraphs.map(\.text).joined(separator: " "), words: words)
            XCTAssertEqual(fixture.voices.count, 2)
            for voice in fixture.voices {
                let mapping = OCRWordAligner.mapTimestampWords(voice.timestamps, in: combined, allowFallback: false)
                XCTAssertEqual(mapping.compactMap { $0 }.count, voice.timestamps.count, voice.voice)
                let indices = mapping.compactMap { $0 }
                XCTAssertEqual(indices, indices.sorted(), voice.voice)
                var offset = 0
                for paragraph in doc.paragraphs {
                    let selected = zip(voice.timestamps, mapping).filter { _, index in index.map { $0 >= offset && $0 < offset + paragraph.words.count } ?? false }
                    let local = OCRWordAligner.mapTimestampWords(selected.map { $0.0 }, in: paragraph, allowFallback: false)
                    XCTAssertEqual(local, selected.map { $0.1.map { $0 - offset } }, voice.voice)
                    offset += paragraph.words.count
                }
                XCTAssertTrue(voice.timestamps.allSatisfy { $0.startTime >= 0 && $0.endTime <= voice.duration && $0.startTime < $0.endTime })
            }
        }
    }

    func testCloudLanguagesDoNotEnterOfflineRecognition() async throws {
        OCRTestURLProtocol.handler = { _ in XCTFail("Offline must not upload"); return (500, Data()) }
        let data = try XCTUnwrap(image().jpegData(compressionQuality: 0.8))
        let page = ReadingDocument(title: "Public fixture", sourceKind: .photo, language: "pa",
            paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, imageData: data)])
        do { _ = try await KindleOfflineOCRService().recognize(page, sourceWordCount: 3); XCTFail("Requires online recognition") }
        catch OCRError.unsupportedLanguages(let languages) { XCTAssertEqual(languages, ["pa"]) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFourLanguagesPreserveOrderGeometryAndHighlighting() throws {
        for language in examples.keys {
            let response = try JSONDecoder().decode(CloudOCRResponse.self, from: payload(language))
            let document = try response.document(imageData: Data(), expectedSize: CGSize(width: 100, height: 100), language: language, title: nil)
            let words = document.paragraphs.flatMap(\.words)
            XCTAssertEqual(words.map(\.text), examples[language]); XCTAssertEqual(words.map(\.id), [0, 1, 2])
            XCTAssertEqual(words[0].bboxNorm.minY, 0.7, accuracy: 0.00001)
            XCTAssertEqual(words[0].bboxNorm.minX, 0.1, accuracy: 0.00001)
            XCTAssertTrue(words.allSatisfy { $0.bboxSource == .googleVisionWord })
            let stamps = words.enumerated().map { TTSTimestamp(word: $0.element.text, startTime: Double($0.offset), endTime: Double($0.offset + 1)) }
            XCTAssertEqual(OCRWordAligner.mapTimestampWords(stamps, in: document.paragraphs[0], allowFallback: false), [0, 1, 2])
            XCTAssertEqual(document.layoutColumnCount, 2)
        }
    }
    func testLongPageChunksRemainBoundedAndLossless() throws {
        let response = try JSONDecoder().decode(CloudOCRResponse.self, from: payload("pa", count: 240))
        let document = try response.document(imageData: Data(), expectedSize: CGSize(width: 100, height: 100), language: "pa", title: nil)
        XCTAssertGreaterThan(document.paragraphs.count, 1)
        XCTAssertTrue(document.paragraphs.allSatisfy { $0.words.count <= 80 && $0.text.count <= 800 })
        XCTAssertEqual(document.paragraphs.flatMap(\.words).map(\.text), response.words.map(\.text))
        XCTAssertEqual(document.paragraphs.flatMap(\.words).map(\.id), Array(0..<240))
    }
    func testRejectsWrongImageLanguageDuplicateIDsAndInvalidPolygons() throws {
        let raw = try payload(), size = CGSize(width: 100, height: 100)
        let decoded = try JSONDecoder().decode(CloudOCRResponse.self, from: raw)
        XCTAssertThrowsError(try decoded.document(imageData: Data(), expectedSize: CGSize(width: 200, height: 100), language: "pa", title: nil))
        XCTAssertThrowsError(try decoded.document(imageData: Data(), expectedSize: size, language: "bn", title: nil))
        for duplicate in [true, false] {
            var json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            var words = json["words"] as! [[String: Any]]
            if duplicate { words[0]["id"] = words[1]["id"] } else { words[0]["polygon"] = [[-1, 0], [50, 0], [50, 20], [-1, 20]] }
            json["words"] = words
            let invalid = try JSONDecoder().decode(CloudOCRResponse.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try invalid.document(imageData: Data(), expectedSize: size, language: "pa", title: nil))
        }
    }
    func testSessionAuthenticationRefreshesOnce() async throws {
        let session = OCRTestSession(), data = try payload()
        OCRTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.castreader.ai/api/mobile/ocr")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer cms_original" { return (401, Data()) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cms_refreshed")
            return (200, data)
        }
        let doc = try await service(session).recognize(image: image(), language: "pa")
        XCTAssertEqual(doc.language, "pa")
        let count = await session.refreshes; XCTAssertEqual(count, 1)
    }
    func testSignOutDiscardsInFlightDocument() async throws {
        let session = OCRTestSession(), data = try payload()
        OCRTestURLProtocol.handler = { _ in await session.invalidateSession(); return (200, data) }
        do { _ = try await service(session).recognize(image: image(), language: "pa"); XCTFail("Account boundary must reject the response") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testChinaAndMissingSessionNeverUpload() async {
        OCRTestURLProtocol.handler = { _ in XCTFail("Must not send image"); return (500, Data()) }
        let session = OCRTestSession()
        do { _ = try await service(session, route: .chinaGateway).recognize(image: image(), language: "pa"); XCTFail() } catch {}
        await session.invalidateSession()
        do { _ = try await service(session).recognize(image: image(), language: "pa"); XCTFail() } catch {}
    }
    func testSelectionAliasesAndEngineRoutingRemainScoped() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertNil(PhotoOCRLanguagePreference.selected(defaults: defaults, route: .globalGateway))
        for (alias, code) in [("ben", "bn"), ("mar", "mr"), ("pan", "pa"), ("tam", "ta")] {
            let language = try XCTUnwrap(SupportedTTSLanguage(identifier: alias))
            XCTAssertEqual(language.rawValue, code); XCTAssertTrue(language.requiresCloudOCR)
            XCTAssertFalse(language.isSupported(in: .chinaGateway))
            defaults.set(code, forKey: PhotoOCRLanguagePreference.key)
            XCTAssertEqual(PhotoOCRLanguagePreference.selected(defaults: defaults, route: .globalGateway), code)
            XCTAssertNil(PhotoOCRLanguagePreference.selected(defaults: defaults, route: .chinaGateway))
            let profile = try XCTUnwrap(KindleLanguageContract.profile(language: code))
            XCTAssertEqual(KindleOCRRoutingContract.route(for: profile).engines, [.googleVision])
        }
        XCTAssertFalse(SupportedTTSLanguage.hindi.requiresCloudOCR)
    }
}
