import XCTest
import Vision
import SwiftUI
import UIKit
import AVFoundation
import CryptoKit
import PDFKit
@testable import CastReader

/// Opt-in original publisher files stay outside the app and repository. This
/// checks extraction/anchors and document-level detection, not OCR or listening.
final class MultilingualOriginalDocumentTests: XCTestCase {
    func testOriginalPublicationsKeepStructureAndSourceRanges() throws {
        guard let manifest = ProcessInfo.processInfo.environment["CASTREADER_ORIGINAL_DOCUMENT_MANIFEST"] else {
            throw XCTSkip("Provide the SHA-verified original publication manifest")
        }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as! [String: Any]
        let rows = root["rows"] as! [[String: Any]]
        var results: [[String: Any]] = []
        for row in rows {
            let path = row["file"] as! String, language = row["language"] as! String
            let format = row["format"] as! String
            let title = row["title"] as! String
            let start = Date()
            do {
                let url = URL(fileURLWithPath: path)
                let data = try Data(contentsOf: url)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(hash, row["sha256"] as? String, title)
                let parsed: ReadingDocument?
                switch format {
                case "epub": parsed = try DocumentBuilder.fromEPUBCancellable(data: data, title: title)
                case "pdf": parsed = DocumentBuilder.fromPDFNative(url: url, title: title)
                case "txt": parsed = DocumentBuilder.fromTextFile(url: url)
                default: throw NSError(domain: "OriginalDocumentTest", code: 1)
                }
                let document = try XCTUnwrap(parsed, title)
                XCTAssertGreaterThan(document.readableParagraphs.count, 5, title)
                XCTAssertEqual(document.paragraphs.map(\.id), Array(document.paragraphs.indices), title)
                XCTAssertEqual(document.language, language, title)
                var invalidRanges = 0
                if format == "pdf" {
                    let pdf = try XCTUnwrap(PDFDocument(data: data))
                    for paragraph in document.readableParagraphs {
                        guard let pageIndex = paragraph.pdfPageIndex, let range = paragraph.pdfRange,
                              let text = pdf.page(at: pageIndex)?.string,
                              range.location != NSNotFound, range.location >= 0, range.length > 0,
                              NSMaxRange(range) <= (text as NSString).length else {
                            invalidRanges += 1; continue
                        }
                    }
                    XCTAssertEqual(invalidRanges, 0, title)
                }
                results.append(["language": language, "format": format, "sha256": hash,
                    "detectedLanguage": document.language, "paragraphs": document.paragraphs.count,
                    "readableParagraphs": document.readableParagraphs.count, "invalidPDFRanges": invalidRanges,
                    "contextSource": document.languageContext?.source.rawValue ?? "none",
                    "seconds": Date().timeIntervalSince(start), "source": row["url"] ?? ""])
            } catch {
                results.append(["language": language, "format": format, "error": String(describing: error)])
                XCTFail("\(title): \(error)")
            }
        }
        let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Original publication extraction and document context; no OCR/audio quality claim", "results": results]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "original-publication-imports.json"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(results.count, rows.count)
    }
}

final class MultilingualContractTests: XCTestCase {
    func testNewWebImportsWaitForBodyBeforeChoosingLanguage() throws {
        let urls = ["https://he.wikipedia.org/wiki/%D7%A1%D7%A4%D7%A8%D7%99%D7%99%D7%94",
                    "tl.wikipedia.org/wiki/Aklatan", "example.com/articles/123?lang=id"]
        for raw in urls {
            let document = try XCTUnwrap(DocumentBuilder.fromWebURL(raw))
            XCTAssertTrue(document.language.isEmpty, raw)
            XCTAssertNil(document.languageContext, raw)
            XCTAssertTrue(document.paragraphs.isEmpty, raw)
            XCTAssertEqual(document.sourceURL, raw.hasPrefix("https://") ? raw : "https://" + raw)
        }
    }

    func testPublisherLicenceDelimitersOnlyNarrowLanguageEvidence() {
        let texts = ["Distribution licence", "*** START OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***",
                     "First original paragraph", "Second original paragraph",
                     "*** END OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***", "English licence"]
        let paragraphs = texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) }
        XCTAssertEqual(DocumentLanguageContext.languageEvidenceBody(paragraphs).map(\.id), [2, 3])
        XCTAssertEqual(paragraphs.count, 6)
        XCTAssertEqual(DocumentLanguageContext.languageEvidenceBody(Array(paragraphs.prefix(4))).count, 4,
                       "A lone marker cannot discard the rest of a document")
    }

    func testEmbeddedEnglishTermRetainsChineseProseWithoutErasingForeignSentences() {
        let text = "投资金额 200 万美元，Post-Money Valuation Cap 为 2000 万美元。"
        let evidence = LanguageDetector.evidence(for: text)
        XCTAssertEqual(evidence.status, .supported(.chinese))
        XCTAssertGreaterThan(evidence.embeddedTermCandidates["zh"] ?? 0, 0.98)
        XCTAssertFalse(evidence.nativeCandidates.isEmpty)
        XCTAssertFalse(evidence.supplementalCandidates.isEmpty)
        for foreign in [
            "这是中文说明。This is an English sentence. 这是另一句中文说明。",
            "研究人员引用了“Reading helps people understand the world”作为文章的标题。",
            "欢迎王小明 Reading 中文课程",
            "中国の研究者はPost-Money Valuation Capを説明しました。",
            "研究人员引用 Reading helps people understand the world 作为标题并进行讨论。"
        ] {
            XCTAssertNil(LanguageDetector.proseAroundEmbeddedLatinTerm(foreign), foreign)
        }
    }

    func testClassifierLabelsKeepUnsupportedNeighboursAndSeparateCloseLanguages() {
        let mapping = ["__label__fil_Latn": "fil", "__label__tgl_Latn": "fil",
                       "__label__ind_Latn": "id", "__label__zsm_Latn": "ms",
                       "__label__nno_Latn": "nn", "__label__nob_Latn": "nb",
                       "__label__cmn_Hani": "zh", "__label__yue_Hani": "yue",
                       "__label__arb_Arab": "ar", "__label__ars_Arab": "ar",
                       "__label__fas_Arab": "fa", "__label__urd_Arab": "ur",
                       "__label__npi_Deva": "ne", "__label__und_Latn": "und"]
        for (raw, expected) in mapping {
            XCTAssertEqual(SupplementalLanguageIdentifier.languageCode(for: raw), expected, raw)
        }
        let missing = LanguageDetector.reconcile(native: ["id": 1], supplemental: [:], readableCharacterCount: 200)
        XCTAssertEqual(missing.status, .uncertain)
        let neighbouring = LanguageDetector.reconcile(native: ["hi": 1], supplemental: ["ne": 0.99], readableCharacterCount: 200)
        XCTAssertEqual(neighbouring.status, .unsupported("ne"))
        let ambiguous = LanguageDetector.reconcile(native: ["id": 1], supplemental: ["id": 0.8, "ms": 0.2], readableCharacterCount: 200)
        XCTAssertEqual(ambiguous.status, .uncertain)
    }

    func testDocumentLanguageNeedsBodyCorroborationAndPreservesUnsupportedEvidence() {
        func sample(_ code: String, _ confidence: Double = 0.99, candidates: [String: Double]? = nil) -> LanguageDetector.Evidence {
            .init(language: code, confidence: confidence, readableCharacterCount: 180,
                  candidates: candidates ?? [code: confidence])
        }
        let body = DocumentLanguageContext.resolve(samples: [sample("fr"), sample("fr"), sample("en")], declaredLanguage: "en")
        XCTAssertEqual(body.language, "fr")
        XCTAssertEqual(body.source, .body)
        let metadata = DocumentLanguageContext.resolve(samples: [sample("id", 0.7, candidates: ["id": 0.55, "ms": 0.45]),
            sample("ms", 0.7, candidates: ["id": 0.3, "ms": 0.7])], declaredLanguage: "ms-MY")
        XCTAssertEqual(metadata.language, "ms")
        XCTAssertEqual(metadata.source, .corroboratedMetadata)
        XCTAssertEqual(DocumentLanguageContext.resolve(samples: [], declaredLanguage: "en").language, "")
        XCTAssertEqual(DocumentLanguageContext.resolve(samples: [sample("uk"), sample("uk")], declaredLanguage: "ru").language, "uk")
        let weak = [sample("id", 0.7), sample("id", 0.7)]
        XCTAssertEqual(DocumentLanguageContext.resolve(samples: weak, declaredLanguage: "ms").language, "")
    }

    func testActualNarrationRejectsWrongLanguageButAllowsNamesAndForeignQuotations() throws {
        let english = "The author explains how readers can compare the evidence, understand the argument, and connect each new idea to what they already know. This paragraph describes the central finding and its practical implications."
        XCTAssertThrowsError(try QuickReadOutputLanguage.validateNarration(english, requested: "he")) {
            guard case QuickReadError.outputLanguageMismatch = $0 else { return XCTFail("Wrong language error") }
        }
        XCTAssertNoThrow(try QuickReadOutputLanguage.validateNarration(english, requested: "en"))
        XCTAssertNoThrow(try QuickReadOutputLanguage.validateNarration("Albert Einstein — E = mc²", requested: "he"))
        let arabic = "يشرح الكاتب كيف تساعد القراءة المتأنية على فهم الأفكار وربطها بالأدلة. وتوضح هذه الفقرة أهمية التفكير في المعنى بدلاً من حفظ الكلمات وحدها."
        XCTAssertNoThrow(try QuickReadOutputLanguage.validateNarration(arabic + " “" + english + "”", requested: "ar"))
        XCTAssertThrowsError(try QuickReadOutputLanguage.validateNarration(arabic, requested: "en"))
    }

    func testCloneLanguageCopyUsesSelectableCapabilitiesInsteadOfAllStandardLanguages() {
        let voice = ClonedVoice(voiceId: "vc_fixture", supportedLanguages: VoiceCloneLanguageSupport.all)
        let expected = Set(["en", "zh", "ja", "es", "fr", "de", "pt", "it"])
        XCTAssertEqual(Set(VoiceCloneLanguageSupport.selectableLanguages(for: voice, route: .globalGateway)), expected.union(["ko", "ru"]))
        XCTAssertEqual(Set(VoiceCloneLanguageSupport.selectableLanguages(for: voice, route: .chinaGateway)), expected)
        XCTAssertEqual(VoiceCloneLanguageSupport.languages(for: voice).count, 10,
                       "Retain server clone metadata separately from current client availability")
        let limited = ClonedVoice(voiceId: "vc_limited", supportedLanguages: ["en", "ko", "fil"])
        XCTAssertEqual(VoiceCloneLanguageSupport.selectableLanguages(for: limited, route: .globalGateway), ["en", "ko"])
        XCTAssertEqual(VoiceCloneLanguageSupport.selectableLanguages(for: limited, route: .chinaGateway), ["en"])
    }

    func testGreekOCRNormalizesLettersWithoutChangingScientificUnits() {
        XCTAssertEqual(OCRTextNormalization.canonical("άτοµο µπορεί µια δοµικές", language: "el"), "άτομο μπορεί μια δομικές")
        XCTAssertEqual(OCRTextNormalization.canonical("10 µm, µ, μάζα", language: "el"), "10 µm, µ, μάζα")
        XCTAssertEqual(OCRTextNormalization.canonical("µm", language: "en"), "µm")
    }
    func testAutomaticOCRSupplementIsBoundedAndMustAgreeWithItsResult() {
        XCTAssertEqual(Set(ImportedOCRLanguageSelection.supplementalProbeLanguages(vision: nil)), Set(["hi", "el", "he"]))
        let clear = LanguageDetector.Evidence(language: "en", confidence: 0.99, readableCharacterCount: 200)
        XCTAssertTrue(ImportedOCRLanguageSelection.supplementalProbeLanguages(vision: clear).isEmpty)
        let weak = LanguageDetector.Evidence(language: "", confidence: 0.2, readableCharacterCount: 10, candidates: ["he": 0.2])
        XCTAssertEqual(ImportedOCRLanguageSelection.supplementalProbeLanguages(vision: weak).first, "he")
        let hebrew = LanguageDetector.Evidence(language: "he", confidence: 0.99, readableCharacterCount: 180)
        XCTAssertTrue(ImportedOCRLanguageSelection.shouldPreferSupplemental(vision: weak, candidate: hebrew,
                                                                          language: "he", meanConfidence: 90))
        XCTAssertFalse(ImportedOCRLanguageSelection.shouldPreferSupplemental(vision: weak, candidate: hebrew,
                                                                           language: "hi", meanConfidence: 90))
        XCTAssertFalse(ImportedOCRLanguageSelection.shouldPreferSupplemental(vision: weak, candidate: hebrew,
                                                                           language: "he", meanConfidence: 20))
    }

    func testOCRProfilesCoverProductLanguagesWithoutInventingFallbackModels() throws {
        for language in SupportedTTSLanguage.allCases {
            let profile = try XCTUnwrap(KindleLanguageContract.profile(language: language.rawValue))
            XCTAssertEqual(profile.language, language.rawValue)
            XCTAssertEqual(profile.tesseractModel, language.bundledOCRModel ?? "")
            if language.bundledOCRModel == nil {
                XCTAssertEqual(KindleOCRRoutingContract.route(for: profile).engines, [.vision])
            }
        }
        XCTAssertNil(KindleLanguageContract.profile(language: "nn"))
        XCTAssertNil(KindleLanguageContract.profile(language: "uk"))
        XCTAssertEqual(KindleLanguageContract.profile(language: "he")?.readingDirection, .rtl)
    }

    func testGlobalExpansionDoesNotExpandChinaServiceScope() {
        XCTAssertEqual(SupportedTTSLanguage.supported(in: .globalGateway).count, 28)
        XCTAssertEqual(Set(SupportedTTSLanguage.supported(in: .chinaGateway).map(\.rawValue)),
                       Set(["en", "zh", "ja", "es", "fr", "de", "pt", "it", "hi"]))
        XCTAssertFalse(SupportedTTSLanguage.hebrew.isSupported(in: .chinaGateway))
        XCTAssertTrue(SupportedTTSLanguage.hebrew.isSupported(in: .globalGateway))
    }

    func testNarrationLanguageIsExplicitAndIndependentOfSourceOrUI() throws {
        XCTAssertEqual(QuickReadOutputLanguage.resolve(preference: nil, source: "iw-IL"), "he")
        XCTAssertEqual(QuickReadOutputLanguage.resolve(preference: "en", source: "ar"), "en")
        XCTAssertEqual(QuickReadOutputLanguage.resolve(preference: "ar", source: "en"), "ar")
        XCTAssertEqual(QuickReadOutputLanguage.resolve(preference: "en", source: "ar", locked: "fil"), "fil")
        XCTAssertNoThrow(try QuickReadOutputLanguage.validate(requested: "fil", returned: "tl-PH"))
        XCTAssertNoThrow(try QuickReadOutputLanguage.validate(requested: "he", returned: nil))
        for pair in [("he", "en"), ("ms", "id"), ("nb", "nn"), ("cs", "sk")] {
            XCTAssertThrowsError(try QuickReadOutputLanguage.validate(requested: pair.0, returned: pair.1)) {
                guard case QuickReadError.outputLanguageMismatch = $0 else { return XCTFail("Must keep a non-retryable language error") }
            }
        }
    }

    func testGoogleErrorUsesMachineCodesWithoutLeakingTheResponseBody() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.castreader.ai/api/captioned_speech_partly")!, statusCode: 429, httpVersion: nil, headerFields: nil)!
        let failure = GoogleStandardTTSError(response: response, data: Data(#"{"code":"API_TTS_REQUEST_PENDING","detail":"PRIVATE_DOCUMENT_TEXT"}"#.utf8), requestID: "fixture-id")
        XCTAssertEqual(failure.code, "API_TTS_REQUEST_PENDING")
        XCTAssertEqual(failure.status, 429)
        XCTAssertEqual(failure.requestID, "fixture-id")
        XCTAssertFalse(failure.localizedDescription.contains("PRIVATE_DOCUMENT_TEXT"))
        let invalid = GoogleStandardTTSError(response: response, data: Data(#"{"code":"not a safe code PRIVATE_DOCUMENT_TEXT"}"#.utf8), requestID: "fixture-id")
        XCTAssertEqual(invalid.code, "API_TTS_REQUEST_FAILED")
    }

    func testGooglePartlyProjectionPreservesUnicodeHyphensAndEveryTail() throws {
        let sentence = "שָׁלוֹם — xin chào 👩🏽‍🔬 -- 안녕하세요 2026. "
        var remaining = String(repeating: sentence, count: 300)
        let original = remaining
        var reconstructed = ""
        var parts = 0
        while !remaining.isEmpty {
            let projection = PresetTTSSourceProjection(remaining, normalizeHyphens: false)
            XCTAssertLessThanOrEqual(projection.wire.utf16.count, 5_000)
            XCTAssertTrue(projection.wire.contains("--"))
            let boundary = try XCTUnwrap(projection.wire.firstIndex(of: "👩🏽‍🔬"))
            let split = projection.wire.index(after: boundary)
            let part = try projection.resolve(processed: String(projection.wire[..<split]), remaining: String(projection.wire[split...]))
            XCTAssertFalse(part.processed.isEmpty)
            XCTAssertLessThan(part.remaining.utf16.count, remaining.utf16.count)
            reconstructed += part.processed
            remaining = part.remaining
            parts += 1
            if parts > 400 { return XCTFail("No bounded progress") }
            if !remaining.contains("👩🏽‍🔬") {
                let final = PresetTTSSourceProjection(remaining, normalizeHyphens: false)
                let part = try final.resolve(processed: final.wire, remaining: "")
                reconstructed += part.processed; remaining = part.remaining
            }
        }
        XCTAssertEqual(reconstructed, original)
    }

    func testRTLInkStartsAtTheRightOfEachLineAndLeavesNumeralsReadable() throws {
        let rects = [CGRect(x: 20, y: 20, width: 120, height: 22), CGRect(x: 20, y: 55, width: 70, height: 22)]
        for action in ["highlight", "underline", "wave", "strike"] {
            let ink = HandwrittenMark.stroke(action: action, rects: rects, seed: 42, rightToLeft: true)
            var starts: [CGPoint] = []
            ink.path.forEach { if case .move(let point) = $0 { starts.append(point) } }
            XCTAssertEqual(starts.count, 2, action)
            XCTAssertGreaterThan(starts[0].x, rects[0].midX, action)
            XCTAssertGreaterThan(starts[1].x, rects[1].midX, action)
        }
        let left = HandwrittenMark.numberPath(near: rects, n: 2, seed: 3)
        let right = HandwrittenMark.numberPath(near: rects, n: 2, seed: 3, rightToLeft: true)
        XCTAssertGreaterThan(right.boundingRect.maxX, left.boundingRect.maxX)
    }

    @MainActor
    func testRenderedMarkCoordinatesDoNotMirrorWithInterfaceLanguage() async throws {
        // UIKit and Vision rectangles are physical coordinates. Changing the
        // interface language must not reflect the ink away from those words.
        let size = CGSize(width: 320, height: 120)
        let rects = [CGRect(x: 25, y: 35, width: 80, height: 24)]
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.isHidden = false
        defer { window.isHidden = true }
        func render(_ direction: LayoutDirection, language: String, action: String, kindle: Bool) async -> UIImage {
            let root = ZStack {
                Color.white
                if kindle {
                    KindleTimedMarkInkView(
                        ink: HandwrittenMark.stroke(action: action, rects: rects, seed: 42, n: 2,
                            rightToLeft: SupportedTTSLanguage(identifier: language)?.isRightToLeft == true),
                        animation: .init(startedAt: ProcessInfo.processInfo.systemUptime - 3, duration: 1))
                } else {
                    MarkInkView(rects: rects, action: action, seed: 42, n: 2,
                                animateOnAppear: false, sourceLanguage: language)
                }
            }
            .frame(width: size.width, height: size.height)
            .environment(\.layoutDirection, direction)
            .ignoresSafeArea()
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 50_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        }
        func inkCenter(_ image: UIImage) throws -> Double {
            let cg = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            var mass = 0.0, weightedX = 0.0
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(origin: .zero, size: size))
                let p = bytes.bindMemory(to: UInt8.self)
                for y in 0..<cg.height { for x in 0..<cg.width {
                    let index = (y * cg.width + x) * 4
                    let weight = Double(max(0, Int(p[index]) - Int(p[index + 1]))) / 255
                    mass += weight; weightedX += weight * Double(x)
                } }
            }
            XCTAssertGreaterThan(mass, 20, "The actual SwiftUI mark must render")
            return weightedX / max(mass, 1)
        }
        for language in ["en", "fil", "ar", "he"] {
            for action in ["circle", "highlight", "number"] {
                for kindle in [false, true] {
                    let ltr = await render(.leftToRight, language: language, action: action, kindle: kindle)
                    let rtl = await render(.rightToLeft, language: language, action: action, kindle: kindle)
                    XCTAssertEqual(try inkCenter(ltr), try inkCenter(rtl), accuracy: 1,
                                   "\(language) \(action) kindle=\(kindle): interface direction must preserve word coordinates")
                    XCTAssertLessThan(try inkCenter(rtl), 150, "Ink must remain near the supplied word")
                    let attachment = XCTAttachment(image: rtl)
                    attachment.name = "rtl-interface-\(language)-\(action)-kindle-\(kindle)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testPhotoCacheRejectsSameLengthDifferentImageAndLanguageChanges() throws {
        let data = Data([1, 2, 3, 4])
        let document = ReadingDocument(id: "fixture", title: "fixture", sourceKind: .photo, language: "ar",
            paragraphs: [.init(id: 0, text: "عالم", words: [.init(id: 0, text: "عالم", bboxNorm: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1))])], imageData: data)
        let snapshot = try XCTUnwrap(PhotoOCRSnapshot(document: document, payload: data))
        XCTAssertTrue(snapshot.matches(payload: data, language: "ar"))
        XCTAssertFalse(snapshot.matches(payload: Data([4, 3, 2, 1]), language: "ar"))
        XCTAssertFalse(snapshot.matches(payload: data, language: "he"))
        let restored = try JSONDecoder().decode(PhotoOCRSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(restored.matches(payload: data, language: "ar"))
    }

    func testCorrectionsStayInTheirAccountAndDoNotAdoptUnownedLegacyEntries() {
        let name = "language-scope-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var scope = "account-A"
        let store = ReadingLanguageStore(defaults: defaults, scopedKey: { "correction." + scope })
        let book = ReadingLanguageStore.contentKey(namespace: "kindle", bookID: "same-book")
        store.setOverride("ms", for: book)
        scope = "account-B"
        XCTAssertNil(store.override(for: book))
        store.setOverride("id", for: book)
        scope = "account-A"
        XCTAssertEqual(store.override(for: book), "ms")
        store.setOverride("uk", for: book)
        XCTAssertEqual(store.override(for: book), "ms")
    }

    func testGoogleAuthorizationUsesRegionalGatewayAndDoesNotReplayARejection() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleRejectionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for route in ServiceRoute.allCases {
            let request = TTSRequest(input: "Een openbare tekst.", voice: "api_nl_fixture", language: "nl")
            do {
                _ = try await PresetTTSTransport.generate(input: request.input, voice: request.voice,
                    body: JSONEncoder().encode(request), route: route, requestID: UUID().uuidString,
                    session: session, sessionToken: "cms_test_fixture_only", google: true)
                XCTFail("A rejected Google request must not return playable audio")
            } catch let rejection as GoogleStandardTTSError { XCTAssertEqual(rejection.status, 401) }
        }
    }

    func testVisionLocaleMappingUsesOnlyTheRequestedLanguage() {
        let available: Set<String> = ["en-US", "vi-VT", "ar-SA", "no-NO", "nn-NO", "nb-NO"]
        XCTAssertEqual(SupportedTTSLanguage.vietnamese.availableVisionLocale(in: available), "vi-VT")
        XCTAssertEqual(SupportedTTSLanguage.arabic.availableVisionLocale(in: available), "ar-SA")
        XCTAssertEqual(SupportedTTSLanguage.norwegianBokmal.availableVisionLocale(in: available), "nb-NO")
        XCTAssertNil(SupportedTTSLanguage.norwegianBokmal.availableVisionLocale(in: ["nn-NO", "no-NO"]))
        XCTAssertNil(SupportedTTSLanguage.hebrew.availableVisionLocale(in: available))
    }

    func testV2RequiresUsableFreeDefaultAndKeepsPartialCatalogs() throws {
        func fixture(enabled: Bool = true, tier: String = "free", language: String = "nl") throws -> TTSVoiceCatalogDocument {
            let object: [String: Any] = ["contract": "tts-voice-catalog-v2", "version": "unit-fixture",
                "languages": [["code": "nl", "name": "Dutch", "locale": "nl-NL", "status": "beta", "defaultVoice": "api_nl_fixture", "timestampMode": "word"]],
                "voices": [["id": "api_nl_fixture", "name": "Fixture", "engine": "google", "modelVersion": "wavenet", "language": language,
                    "locale": "nl-NL", "genderPresentation": "female", "tier": tier, "status": "beta", "enabled": enabled, "selectable": true, "timestampMode": "word"]]]
            return try TTSVoiceCatalogDocument.decodeServerResponse(from: JSONSerialization.data(withJSONObject: object))
        }
        let valid = try fixture()
        try VoiceCatalog.install(valid)
        defer { VoiceCatalog.resetForTesting() }
        XCTAssertEqual(VoiceCatalog.resolvedVoice(preferred: "", for: "nl"), "api_nl_fixture")
        XCTAssertEqual(VoiceCatalog.resolvedVoice(preferred: "", for: "he"), "")
        XCTAssertEqual(VoiceCatalog.defaultFreeVoice(for: "en"), "af_heart")
        XCTAssertThrowsError(try fixture(enabled: false))
        XCTAssertThrowsError(try fixture(tier: "pro"))
        XCTAssertThrowsError(try fixture(language: "en"))
    }

    func testScopeAliasesAndExcludedNeighbours() {
        XCTAssertEqual(SupportedTTSLanguage.allCases.count, 28)
        XCTAssertEqual(SupportedTTSLanguage.allCases.filter(\.isGoogle).count, 19)
        for (alias, expected) in ["tl-PH": "fil", "iw-IL": "he", "in-ID": "id", "zh-Hant": "zh", "nob": "nb"] {
            XCTAssertEqual(SupportedTTSLanguage(identifier: alias)?.rawValue, expected)
        }
        for code in Array(SupportedTTSLanguage.excludedCodes) + ["nn", "no", "fa", "ne", "as", "ti", "et", "bg", "az", "sw", ""] {
            XCTAssertNil(SupportedTTSLanguage(identifier: code), code)
            XCTAssertNotEqual(SupportedTTSLanguage.canonicalCode(code), "en", code)
        }
        XCTAssertEqual(LanguageDetector.detect("123 — 🎵"), "")
        XCTAssertEqual(ReadingLanguagePolicy.resolve(userOverride: nil, confidentDetection: nil, remembered: nil).status, .uncertain)
        XCTAssertEqual(ReadingLanguagePolicy.resolve(userOverride: nil, confidentDetection: "uk", remembered: "ru").status, .unsupported("uk"))
        XCTAssertEqual(ReadingLanguagePolicy.resolve(userOverride: "ms", confidentDetection: "id", remembered: "en").language, "ms")
    }

    func testUnavailableGoogleLanguageHasNoInventedVoice() {
        VoiceCatalog.resetForTesting()
        for language in SupportedTTSLanguage.allCases where language.isGoogle {
            XCTAssertTrue(VoiceCatalog.voices(for: language.rawValue).isEmpty)
            XCTAssertEqual(VoiceCatalog.defaultFreeVoice(for: language.rawValue), "")
            XCTAssertEqual(VoiceCatalog.resolvedVoice(preferred: "af_heart", for: language.rawValue), "")
        }
        XCTAssertEqual(VoiceCatalog.defaultFreeVoice(for: "uk"), "")
        XCTAssertEqual(VoiceCatalog.defaultFreeVoice(for: "en"), "af_heart")
    }

    func testGoogleRequestsUseNativeMarksAndClientSpeed() throws {
        for language in SupportedTTSLanguage.allCases where language.isGoogle {
            let request = TTSRequest(input: "public test", voice: "api_fixture", speed: 2, language: language.rawValue)
            XCTAssertEqual(request.speed, 1)
            XCTAssertTrue(request.returnTimestamps)
            XCTAssertEqual(request.model, "google-wavenet")
        }
        for code in ["vc_fixture", "vl_fixture"] {
            let clone = TTSRequest(input: "fixture", voice: code, speed: 1.25, language: "ko")
            XCTAssertEqual(clone.model, "kokoro", "Preserve clone compatibility wire contract")
            XCTAssertEqual(clone.speed, 1.25, "Only Google standard requests force speed 1")
            XCTAssertFalse(clone.returnTimestamps)
            XCTAssertTrue(TTSRequest(input: "fixture", voice: code, language: "ko", requiresSourceTiming: true).returnTimestamps)
            let marks = [TTSTimestamp(word: "한국어", startTime: 0, endTime: 1)]
            XCTAssertTrue(TTSHighlightPolicy.displayTimestamps(marks, language: "ko", voice: code).isEmpty)
            XCTAssertEqual(TTSHighlightPolicy.displayTimestamps(marks, language: "ko", voice: "g-ko-KR-Standard-A").count, 1)
        }
        XCTAssertFalse(TTSRequest(input: "测试", language: "zh").returnTimestamps)
        XCTAssertFalse(TTSRequest(input: "テスト", language: "ja").returnTimestamps)
    }

    func testNativeMarksRequireCompleteOrderedCoverageIncludingCombiningMarks() {
        let text = "שָׁלוֹם عالم 2026"
        let words = text.split(separator: " ").map(String.init)
        let marks = words.enumerated().map { TTSTimestamp(word: $0.element, startTime: Double($0.offset), endTime: Double($0.offset + 1)) }
        XCTAssertTrue(GoogleNativeMarks.isValid(text: text, timestamps: marks, duration: 3.1))
        XCTAssertFalse(GoogleNativeMarks.isValid(text: text, timestamps: Array(marks.dropLast()), duration: 3.1))
        XCTAssertFalse(GoogleNativeMarks.isValid(text: text, timestamps: marks.reversed(), duration: 3.1))
        XCTAssertFalse(GoogleNativeMarks.isValid(text: text, timestamps: marks, duration: 1))
        XCTAssertFalse(GoogleNativeMarks.isValid(text: text, timestamps: marks.map { .init(word: $0.word, startTime: 0, endTime: 1) }, duration: 3.1))
        XCTAssertTrue(GoogleNativeMarks.isValid(text: "שלום", timestamps: [.init(word: "שלום", startTime: 0.1, endTime: 1)], duration: 1.1))
    }
}

/// Printed public-corpus smoke: exercises actual native/WASM recognition, not
/// a mocked OCR response. Real photos/scans and minimum-OS acceptance stay separate.
final class MultilingualOCRIntegrationTests: XCTestCase {
    @MainActor
    func testOriginalPublicationRasterOCR() async throws {
        guard let manifest = ProcessInfo.processInfo.environment["CASTREADER_ORIGINAL_DOCUMENT_MANIFEST"] else {
            throw XCTSkip("Provide the SHA-verified original publication manifest")
        }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as! [String: Any]
        let rows = (root["rows"] as! [[String: Any]]).filter { $0["format"] as? String == "pdf" }
        var results: [[String: Any]] = []
        for row in rows {
            let language = row["language"] as! String
            let data = try Data(contentsOf: URL(fileURLWithPath: row["file"] as! String))
            let sourceHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sourceHash, row["sha256"] as? String)
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            // Fixed, evenly spaced pages selected before OCR; no cherry-picking
            // on recognizer confidence, text quality, or the resulting score.
            for n in 1...10 {
                let index = n * (pdf.pageCount - 1) / 11
                let page = try XCTUnwrap(pdf.page(at: index))
                let rendered = try XCTUnwrap(PDFOCRGeometry.render(page))
                let png = try XCTUnwrap(rendered.image.pngData())
                let expected = page.string ?? ""
                let sampleID = "\(language)-page-\(index + 1)"
                let source = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                source.name = sampleID; source.lifetime = .keepAlways; add(source)
                let started = Date()
                do {
                    let document = try await OCRService.shared.recognizeImportedImage(image: rendered.image,
                        title: sampleID, languageHint: language, orientationSettled: true)
                    let words = document.paragraphs.flatMap(\.words)
                    let ns = expected as NSString
                    var cursor = 0, matched = 0, overlapping = 0, invalid = 0
                    for word in words {
                        let box = word.bboxNorm
                        if box.width <= 0 || box.height <= 0 || box.minX < 0 || box.minY < 0
                            || box.maxX > 1.001 || box.maxY > 1.001 { invalid += 1 }
                        let range = ns.range(of: word.text, range: NSRange(location: cursor, length: ns.length - cursor))
                        guard range.location != NSNotFound else { continue }
                        cursor = NSMaxRange(range)
                        guard let selection = page.selection(for: range) else { continue }
                        matched += 1
                        let target = selection.bounds(for: page).insetBy(dx: -2, dy: -2)
                        let actual = PDFOCRGeometry.pageRect(rendered.normalizedPageRect(box), page: page)
                        if target.contains(CGPoint(x: actual.midX, y: actual.midY)) { overlapping += 1 }
                    }
                    results.append(["id": sampleID, "language": language, "sourceSHA256": sourceHash,
                        "imageSHA256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                        "page": index + 1, "expected": expected, "recognized": document.fullText,
                        "words": words.count, "invalidBounds": invalid, "matchedSourceWords": matched,
                        "boxesOnMatchedSourceWords": overlapping, "seconds": Date().timeIntervalSince(started)])
                    XCTAssertFalse(expected.isEmpty, sampleID)
                    XCTAssertFalse(document.fullText.isEmpty, sampleID)
                    XCTAssertFalse(words.isEmpty, sampleID)
                    XCTAssertEqual(invalid, 0, sampleID)
                } catch {
                    results.append(["id": sampleID, "language": language, "sourceSHA256": sourceHash,
                        "page": index + 1, "expected": expected, "error": String(describing: error)])
                    XCTFail("\(sampleID): \(error)")
                }
            }
        }
        let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Original publisher page rasters, not camera photos. One publication per language; source/font/minimum-device coverage incomplete. Score separately with NFC grapheme CER, whitespace CER and WER.",
            "results": results]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "original-publication-ocr.json"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testAutomaticDiscoveryOfVisionGapsKeepsRecognizedLanguageAndGeometry() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "language-audit-regression", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        var results: [[String: Any]] = []
        for code in ["en", "hi", "el", "he", "fi", "hu", "fil"] {
            let language = try XCTUnwrap(SupportedTTSLanguage(identifier: code))
            let row = try XCTUnwrap(rows.first { $0["language"] as? String == code })
            let text = row["text"] as! String
            let image = Self.printedImage(text, language: language)
            let started = Date()
            do {
                let document = try await OCRService.shared.recognizeImportedImage(image: image,
                    title: "Automatic discovery fixture", orientationSettled: true)
                let expected = Self.normalized(text), actual = Self.normalized(document.fullText)
                let errorRate = Double(Self.editDistance(expected, actual)) / Double(max(1, expected.count))
                let words = document.paragraphs.flatMap(\.words)
                results.append(["language": code, "detected": document.language, "recognized": document.fullText,
                    "characterErrorRate": errorRate, "words": words.count, "elapsedSeconds": Date().timeIntervalSince(started)])
                XCTAssertEqual(document.language, code, "Automatic discovery: \(code)")
                XCTAssertLessThanOrEqual(errorRate, 0.08, code)
                XCTAssertFalse(words.isEmpty, code)
                XCTAssertTrue(words.allSatisfy {
                    $0.bboxNorm.width > 0 && $0.bboxNorm.height > 0 &&
                    $0.bboxNorm.minX >= 0 && $0.bboxNorm.minY >= 0 &&
                    $0.bboxNorm.maxX <= 1.001 && $0.bboxNorm.maxY <= 1.001
                }, code)
            } catch {
                results.append(["language": code, "error": error.localizedDescription])
                XCTFail("Automatic discovery \(code): \(error)")
            }
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "scope": "Seven known printed samples; automatic-path integration only, not photo/quality acceptance", "results": results
        ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "automatic-ocr-discovery.json"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private static func printedImage(_ text: String, language: SupportedTTSLanguage) -> UIImage {
        let style = NSMutableParagraphStyle()
        style.alignment = language.isRightToLeft ? .right : .left
        style.baseWritingDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
        style.lineSpacing = 14
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.black, .paragraphStyle: style]
        let height = max(260, (text as NSString).boundingRect(with: CGSize(width: 1100, height: 5000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height + 120)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 1220, height: height), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1220, height: height))
            (text as NSString).draw(in: CGRect(x: 60, y: 45, width: 1100, height: height - 90), withAttributes: attributes)
        }
    }

    @MainActor
    func testEveryLanguageRecognizesPrintedPublicTextWithLogicalOrderAndGeometry() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "language-audit-regression", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        var results: [[String: Any]] = []
        for language in SupportedTTSLanguage.allCases {
            let row = try XCTUnwrap(rows.first { $0["language"] as? String == language.rawValue })
            let text = row["text"] as! String
            let style = NSMutableParagraphStyle()
            style.alignment = language.isRightToLeft ? .right : .left
            style.baseWritingDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
            style.lineSpacing = 14
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.black, .paragraphStyle: style]
            let height = max(260, (text as NSString).boundingRect(with: CGSize(width: 1100, height: 5000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height + 120)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1220, height: height), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1220, height: height))
                (text as NSString).draw(in: CGRect(x: 60, y: 45, width: 1100, height: height - 90), withAttributes: attributes)
            }
            let started = Date()
            do {
                let document = try await OCRService.shared.recognizeImportedImage(image: image,
                    title: "Public OCR fixture", languageHint: language.rawValue, orientationSettled: true)
                let expected = Self.normalized(text), actual = Self.normalized(document.fullText)
                let errorRate = Double(Self.editDistance(expected, actual)) / Double(max(1, expected.count))
                let words = document.paragraphs.flatMap(\.words)
                let geometryValid = words.allSatisfy { word in
                    let box = word.bboxNorm
                    return box.width > 0 && box.height > 0 && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1.001 && box.maxY <= 1.001
                }
                results.append(["language": language.rawValue, "sourceID": row["id"]!, "expected": text,
                    "recognized": document.fullText, "characterErrorRate": errorRate,
                    "words": words.count, "geometryValid": geometryValid, "elapsedSeconds": Date().timeIntervalSince(started)])
                XCTAssertEqual(document.language, language.rawValue)
                XCTAssertLessThanOrEqual(errorRate, 0.08, language.rawValue)
                XCTAssertFalse(words.isEmpty, language.rawValue)
                XCTAssertTrue(geometryValid, language.rawValue)
            } catch {
                results.append(["language": language.rawValue, "sourceID": row["id"]!, "error": error.localizedDescription])
                XCTFail("\(language.rawValue): \(error)")
            }
        }
        let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Single printed public sample per language; not real-photo or release qualification", "results": results]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "native-28-printed-ocr.json"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private static func normalized(_ text: String) -> [Unicode.Scalar] {
        Array(text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        })
    }

    private static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

private final class GoogleRejectionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertTrue(["api.castreader.ai", "api.castreader.cn"].contains(request.url?.host ?? ""))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cms_test_fixture_only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
        XCTAssertEqual(request.url?.path, "/api/captioned_speech_partly")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// These gates intentionally fail when native evidence misses the acceptance
/// criteria. The corpus is known regression material, never an unseen final set.
final class NativeLanguageAuditTests: XCTestCase {
    func testNativeRegressionCorpus() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "language-audit-regression", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        var results: [[String: Any]] = []
        var counts: [String: [String: Int]] = [:]
        for row in rows {
            let truth = row["language"] as! String, text = row["text"] as! String
            let evidence = LanguageDetector.evidence(for: text)
            let output = LanguageDetector.detect(text)
            let supported = SupportedTTSLanguage(identifier: truth) != nil
            let correct = supported ? output == truth : SupportedTTSLanguage(identifier: output) == nil && !output.isEmpty
            let misroute = !output.isEmpty && output != truth && SupportedTTSLanguage(identifier: output) != nil
            counts[truth, default: [:]]["total", default: 0] += 1
            counts[truth, default: [:]]["correct", default: 0] += correct ? 1 : 0
            counts[truth, default: [:]]["misroute", default: 0] += misroute ? 1 : 0
            counts[truth, default: [:]]["uncertain", default: 0] += output.isEmpty ? 1 : 0
            results.append(["truth": truth, "id": row["id"]!, "sha256": row["sha256"]!, "split": row["split"]!,
                "output": output, "candidates": evidence.candidates, "correct": correct, "misroute": misroute])
        }
        let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "policy": SupportedTTSLanguage.policyVersion, "counts": counts, "results": results,
            "dataset": "known FLORES regression; not release qualification"]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "native-language-regression.json"; attachment.lifetime = .keepAlways; add(attachment)
        for (language, values) in counts.sorted(by: { $0.key < $1.key }) {
            if SupportedTTSLanguage(identifier: language) != nil {
                XCTAssertGreaterThanOrEqual(Double(values["correct"]!) / Double(values["total"]!), 0.90, language)
            }
            XCTAssertEqual(values["misroute"], 0, language)
        }
    }

    func testVisionCapabilityInventory() throws {
        var revisions: [[String: Any]] = []
        for revision in VNRecognizeTextRequest.supportedRevisions {
            let request = VNRecognizeTextRequest()
            request.revision = revision; request.recognitionLevel = .accurate
            let supported = try request.supportedRecognitionLanguages()
            revisions.append(["revision": revision, "locales": supported,
                "missingExactProductLocales": SupportedTTSLanguage.allCases.filter { !supported.contains($0.visionRecognitionLanguage) }.map(\.rawValue)])
        }
        let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": "Vision accurate", "revisions": revisions, "qualityPassed": false, "releaseQualified": false]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "vision-capability.json"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(revisions.isEmpty)
    }
}

/// Explicitly enabled, bounded live acceptance. Uses only public corpus text and
/// free default voices; never borrows an account session or modifies entitlement.
final class MultilingualLivePlaybackTests: XCTestCase {
    @MainActor
    func testGlobalFreeVoicesPlayPauseResumeAndAdvanceNativeMarks() async throws {
        guard ProcessInfo.processInfo.environment["CASTREADER_LIVE_TTS"] == "1" else {
            throw XCTSkip("Opt-in production synthesis/player acceptance")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var components = URLComponents(string: "https://api.castreader.ai/api/tts/catalog")!
        components.queryItems = [URLQueryItem(name: "contract", value: "tts-voice-catalog-v2"),
            URLQueryItem(name: "languages", value: SupportedTTSLanguage.allCases.map(\.rawValue).joined(separator: ","))]
        let (catalogData, catalogResponse) = try await session.data(from: components.url!)
        XCTAssertEqual((catalogResponse as? HTTPURLResponse)?.statusCode, 200)
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(from: catalogData)
        let corpusURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "language-audit-regression", withExtension: "json"))
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [[String: Any]]
        var results: [[String: Any]] = []
        let selected = ProcessInfo.processInfo.environment["CASTREADER_LIVE_LANGUAGES"]?.split(separator: ",").map(String.init)
        for language in SupportedTTSLanguage.allCases where selected == nil || selected!.contains(language.rawValue) {
            let started = Date()
            let requestID = UUID().uuidString
            do {
                let definition = try XCTUnwrap(catalog.languages.first { $0.code == language.rawValue })
                let voice = try XCTUnwrap(catalog.voices.first { $0.id == definition.defaultVoice && $0.enabled && $0.selectable && $0.tier == "free" })
                let row = try XCTUnwrap(corpus.first { row in
                    let text = row["text"] as! String
                    return row["language"] as? String == language.rawValue && text.count >= 65 && text.count <= 150
                })
                let text = row["text"] as! String
                var remaining = text
                var segments: [AudioSegment] = []
                var requestIDs: [String] = []
                while !remaining.isEmpty {
                    guard segments.count < 32 else { throw APIError.serverError("LIVE_TEST_PART_BOUND") }
                    let partID = UUID().uuidString
                    requestIDs.append(partID)
                    let request = TTSRequest(input: remaining, voice: voice.id, language: language.rawValue)
                    let response = try await PresetTTSTransport.generate(input: remaining, voice: voice.id,
                        body: JSONEncoder().encode(request), route: .globalGateway, requestID: partID,
                        session: session, google: language.isGoogle)
                    let audio = try XCTUnwrap(Data(base64Encoded: response.audio))
                    let decoded = try AVAudioPlayer(data: audio)
                    XCTAssertGreaterThan(decoded.duration, 0, language.rawValue)
                    if language.isGoogle {
                        XCTAssertTrue(GoogleNativeMarks.isValid(text: response.processedText ?? "",
                            timestamps: response.safeTimestamps, duration: decoded.duration), language.rawValue)
                    }
                    let next = response.unprocessedText ?? ""
                    guard next.utf16.count < remaining.utf16.count else { throw APIError.serverError("LIVE_TEST_NO_PROGRESS") }
                    segments.append(AudioSegment(paragraphIndex: 0, segmentIndex: segments.count, audioData: audio,
                        timestamps: response.safeTimestamps, duration: decoded.duration, text: response.processedText ?? remaining,
                        unprocessedText: next))
                    remaining = next
                }
                let totalDuration = segments.reduce(0) { $0 + $1.duration }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("live-language-" + UUID().uuidString)
                let player = AudioPlayerService(testTemporaryRoot: temporary)
                let token = player.claimPlaybackSession(owner: .readAloud)
                defer { _ = player.clearQueue(session: token); try? FileManager.default.removeItem(at: temporary) }
                XCTAssertTrue(player.clearQueue(session: token))
                XCTAssertTrue(player.setMoreSegmentsExpected(false, session: token))
                var finished = false
                var failure: String?
                player.onPlaybackComplete = { finished = true }
                player.onPlaybackError = { failure = $0 }
                player.setPlaybackRate(2)
                XCTAssertTrue(player.loadSegments(segments, session: token))
                var didPause = false, didResume = false, maximumTime = 0.0
                var visitedMarks = Set<String>()
                var visitedSegments = Set<Int>()
                let deadline = Date().addingTimeInterval(max(25, totalDuration + 10))
                while !finished && failure == nil && Date() < deadline {
                    try await Task.sleep(nanoseconds: 40_000_000)
                    maximumTime = max(maximumTime, player.currentTime)
                    if let segment = player.currentSegment {
                        visitedSegments.insert(segment.segmentIndex)
                        if let mark = segment.timestamps.lastIndex(where: { $0.startTime <= player.currentTime }) {
                            visitedMarks.insert("\(segment.segmentIndex):\(mark)")
                        }
                    }
                    if !didPause && player.currentTime > 0.3 {
                        XCTAssertTrue(player.pause(session: token))
                        didPause = true
                        try await Task.sleep(nanoseconds: 100_000_000)
                        let pausedAt = player.currentTime
                        try await Task.sleep(nanoseconds: 250_000_000)
                        XCTAssertEqual(player.currentTime, pausedAt, accuracy: 0.08, language.rawValue)
                        XCTAssertFalse(player.isPlaying)
                        didResume = player.play(session: token)
                    }
                }
                XCTAssertNil(failure, language.rawValue)
                XCTAssertTrue(finished, language.rawValue)
                XCTAssertTrue(didPause && didResume, language.rawValue)
                XCTAssertGreaterThan(maximumTime, min(1, totalDuration * 0.6), language.rawValue)
                XCTAssertEqual(visitedSegments.count, segments.count, language.rawValue)
                if language.isGoogle { XCTAssertGreaterThan(visitedMarks.count, 1, language.rawValue) }
                results.append(["language": language.rawValue, "voice": voice.id, "requestID": requestID,
                    "sourceID": row["id"]!, "sourceSHA256": row["sha256"]!, "decodedDuration": totalDuration, "parts": segments.count, "requestIDs": requestIDs,
                    "nativeMarks": segments.reduce(0) { $0 + $1.timestamps.count }, "visitedMarks": visitedMarks.count,
                    "maximumPlayerTime": maximumTime, "completed": finished, "pauseResume": didPause && didResume,
                    "playerFailure": failure ?? "", "elapsedSeconds": Date().timeIntervalSince(started)])
            } catch {
                results.append(["language": language.rawValue, "requestID": requestID, "error": String(describing: error)])
                XCTFail("\(language.rawValue): \(error)")
            }
        }
        let report: [String: Any] = ["scope": "Live Global free voices via iOS transport and isolated AVPlayer; not UI, Pro, or native-speaker quality acceptance",
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "catalogVersion": catalog.version, "results": results]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "native-global-28-playback.json"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

/// Records the supplemental model separately from the product detector. A
/// successful model load is not a language-routing acceptance pass.
final class SupplementalLanguageModelAuditTests: XCTestCase {
    func testNativeModelMatchesReferenceEndOfSentenceFeatures() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "language-audit-regression", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        // Pinned model + fastText v0.9.2 CLI, with its mandatory final newline.
        // These regressions previously changed to an unrelated Devanagari label.
        let references: [(String, String, Double)] = [
            ("a97443ea3f28cca1b32cf180f858751b95c784044fa0b4ffc567acb21081462e", "__label__arb_Arab", 0.876676),
            ("d9ff555d168f4cecd477acbd74951056c727115c1411a8ec7bfbb97d21e48bc5", "__label__cmn_Hani", 0.921424)
        ]
        for (sha, label, probability) in references {
            let row = try XCTUnwrap(rows.first { $0["sha256"] as? String == sha })
            let hypotheses = SupplementalLanguageIdentifier.rawHypotheses(for: row["text"] as! String)
            XCTAssertEqual(hypotheses.max(by: { $0.value < $1.value })?.key, label)
            XCTAssertEqual(try XCTUnwrap(hypotheses[label]), probability, accuracy: 0.00002)
        }
    }

    func testNativeModelLoadsAndKeepsUnconstrainedLabels() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "language-audit-regression", withExtension: "json"))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        var results: [[String: Any]] = []
        var elapsed: [Double] = []
        for row in rows {
            let start = ProcessInfo.processInfo.systemUptime
            let hypotheses = SupplementalLanguageIdentifier.rawHypotheses(for: row["text"] as! String)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            elapsed.append(milliseconds)
            XCTAssertFalse(hypotheses.isEmpty)
            results.append(["truth": row["language"]!, "id": row["id"]!, "split": row["split"]!,
                "sha256": row["sha256"]!, "candidates": hypotheses, "milliseconds": milliseconds])
        }
        elapsed.sort()
        let report: [String: Any] = ["scope": "Unconstrained supplemental model audit, not product acceptance or unseen qualification",
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "p95Milliseconds": elapsed[Int(Double(elapsed.count - 1) * 0.95)], "results": results]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "native-supplemental-language-model.json"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor
final class PhotoLanguageCorrectionTests: XCTestCase {
    private func fixture(id: String = UUID().uuidString, language: String = "en", text: String = "Original text") -> ReadingDocument {
        ReadingDocument(id: id, title: "Photo fixture", sourceKind: .photo, language: language,
            paragraphs: [ReadingParagraph(id: 0, text: text, words: [
                OCRWord(id: 0, text: text, bboxNorm: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1))
            ])], imageData: Data([1, 2, 3]), imagePixelSize: CGSize(width: 100, height: 100))
    }

    private func waitForCompletion(_ player: PlayerCoordinator) async throws {
        for _ in 0..<200 {
            if !player.isCorrectingPhotoLanguage { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Photo correction did not finish")
    }

    func testCorrectionAtomicallyReplacesTextGeometryAndCachedLanguage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = HistoryStore(directory: directory)
        let original = fixture()
        let key = ReadingLanguageStore.contentKey(namespace: "photo", bookID: original.id)
        let corrected = fixture(language: "he", text: "שלום עולם")
        let player = PlayerCoordinator(historyStore: store, photoRecognizer: { data, language in
            XCTAssertEqual(data, original.imageData)
            XCTAssertEqual(language, "he")
            return corrected
        })
        defer {
            player.close()
            ReadingLanguageStore.shared.clearOverride(for: key)
            try? FileManager.default.removeItem(at: directory)
        }
        player.open(original)
        let oldInstance = try XCTUnwrap(player.session?.instanceID)
        let oldVM = try XCTUnwrap(player.session?.readVM)
        oldVM.correctReadingLanguage("iw-IL")
        XCTAssertTrue(player.isCorrectingPhotoLanguage)
        oldVM.ensurePlaying()
        XCTAssertFalse(oldVM.isPlaying)
        try await waitForCompletion(player)
        let updated = try XCTUnwrap(player.session)
        XCTAssertNotEqual(updated.instanceID, oldInstance)
        XCTAssertEqual(updated.document.id, original.id)
        XCTAssertEqual(updated.document.title, original.title)
        XCTAssertEqual(updated.document.paragraphs, corrected.paragraphs)
        XCTAssertEqual(updated.readVM.playbackLanguage, "he")
        XCTAssertFalse(updated.readVM.isPlaying, "Changing language while paused must remain paused")
        XCTAssertEqual(ReadingLanguageStore.shared.override(for: key), "he")
        let record = try XCTUnwrap(store.records.first { $0.id == original.id })
        let reopened = try XCTUnwrap(store.instantPhotoDocument(record))
        XCTAssertEqual(reopened.language, "he")
        XCTAssertEqual(reopened.paragraphs.map(\.text), corrected.paragraphs.map(\.text))
    }

    func testFailureRetainsPriorLanguageAndGeometryWithoutPersistingCorrection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let original = fixture()
        let player = PlayerCoordinator(historyStore: HistoryStore(directory: directory), photoRecognizer: { _, _ in
            throw OCRError.noText
        })
        let key = ReadingLanguageStore.contentKey(namespace: "photo", bookID: original.id)
        defer { player.close(); ReadingLanguageStore.shared.clearOverride(for: key); try? FileManager.default.removeItem(at: directory) }
        player.open(original)
        let instance = player.session?.instanceID
        player.session?.readVM.correctReadingLanguage("he")
        try await waitForCompletion(player)
        XCTAssertEqual(player.session?.instanceID, instance)
        XCTAssertEqual(player.session?.document.paragraphs, original.paragraphs)
        XCTAssertEqual(player.session?.readVM.playbackLanguage, "en")
        XCTAssertNil(ReadingLanguageStore.shared.override(for: key))
        guard case .error = player.session?.readVM.status else { return XCTFail("Recognition failure must be visible") }
    }

    func testLateResultCannotReplaceAnotherDocumentOrWriteAnOverride() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let original = fixture()
        let started = expectation(description: "recognition started")
        var continuation: CheckedContinuation<ReadingDocument, Error>?
        let player = PlayerCoordinator(historyStore: HistoryStore(directory: directory), photoRecognizer: { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        })
        let key = ReadingLanguageStore.contentKey(namespace: "photo", bookID: original.id)
        defer { player.close(); ReadingLanguageStore.shared.clearOverride(for: key); try? FileManager.default.removeItem(at: directory) }
        player.open(original)
        player.session?.readVM.correctReadingLanguage("he")
        await fulfillment(of: [started], timeout: 2)
        var next = fixture(text: "Different document")
        next.imageData = Data([9, 8, 7])
        player.open(next)
        let instance = player.session?.instanceID
        continuation?.resume(returning: fixture(language: "he", text: "שלום"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(player.session?.instanceID, instance)
        XCTAssertEqual(player.session?.document.id, next.id)
        XCTAssertNil(ReadingLanguageStore.shared.override(for: key))
        XCTAssertFalse(player.isCorrectingPhotoLanguage)
    }

    func testAccountBoundaryDiscardsRecognitionBeforePersistingItsResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = HistoryStore(accountDataRoot: directory)
        XCTAssertTrue(store.activate(storageID: "photo-correction-account-a"))
        let original = fixture()
        let started = expectation(description: "recognition started")
        var continuation: CheckedContinuation<ReadingDocument, Error>?
        let player = PlayerCoordinator(historyStore: store, photoRecognizer: { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        })
        let key = ReadingLanguageStore.contentKey(namespace: "photo", bookID: original.id)
        defer { player.close(); ReadingLanguageStore.shared.clearOverride(for: key); try? FileManager.default.removeItem(at: directory) }
        player.open(original)
        let instance = player.session?.instanceID
        player.session?.readVM.correctReadingLanguage("he")
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.activate(storageID: "photo-correction-account-b"))
        continuation?.resume(returning: fixture(language: "he", text: "שלום"))
        try await waitForCompletion(player)
        XCTAssertEqual(player.session?.instanceID, instance)
        XCTAssertEqual(player.session?.readVM.playbackLanguage, "en")
        XCTAssertNil(ReadingLanguageStore.shared.override(for: key))
        XCTAssertTrue(store.records.isEmpty)
    }
}
