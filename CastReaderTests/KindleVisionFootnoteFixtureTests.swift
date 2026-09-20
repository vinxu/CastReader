import UIKit
import XCTest
@testable import CastReader

/// Actual lossless controlled pixels through iOS Vision and production layout.
/// These are locally generated prose samples, not a live Kindle book or the
/// customer's screenshot. Android's OCR outputs are not expected Vision outputs.
final class KindleVisionFootnoteFixtureTests: XCTestCase {
    @MainActor
    func testVisionRecognizesRaisedReferenceBeforeProjectionRemovesIt() async throws {
        let fixture = try await recognize("raised-reference")
        for document in [fixture.raw, fixture.rebuilt] {
            assertRecognized("12", in: document)
            assertRecognized("1924", in: document)
            assertRecognized("1894", in: document)
            let marker = try XCTUnwrap(document.paragraphs.flatMap(\.words).first { $0.text == "12" })
            XCTAssertTrue(marker.inkBoundsChecked, fixture.diagnostics)
            XCTAssertNotNil(marker.inkBoundsNorm, fixture.diagnostics)
        }
        let speech = KindleFootnoteSpeech.prepare(document: fixture.rebuilt)
        let removed = speech.paragraphs.flatMap { paragraph in
            paragraph.skippedSourceWordIndices.sorted().map { paragraph.sourceParagraph.words[$0].text }
        }
        XCTAssertEqual(removed, ["12"], fixture.diagnostics)
        let changed = try XCTUnwrap(speech.paragraphs.first { !$0.skippedSourceWordIndices.isEmpty })
        let timestamps = changed.spokenParagraph.words.enumerated().map {
            TTSTimestamp(word: $0.element.text, startTime: Double($0.offset), endTime: Double($0.offset) + 0.5)
        }
        XCTAssertEqual(changed.mapTimestampWords(timestamps), changed.spokenWordSourceIndices.map(Optional.some), fixture.diagnostics)
        XCTAssertEqual(changed.spokenParagraph.words.map(\.id), changed.spokenWordSourceIndices.map { changed.sourceParagraph.words[$0].id })
        let spoken = speech.paragraphs.map(\.spokenText).joined(separator: " ")
        XCTAssertTrue(spoken.contains("1924") && spoken.contains("1894"), fixture.diagnostics)
        XCTAssertTrue(spoken.contains("people returned"), fixture.diagnostics)
        let disabled = KindleFootnoteSpeech.prepare(document: fixture.rebuilt, skipReferences: false)
        XCTAssertEqual(disabled.paragraphs.map(\.spokenText), fixture.rebuilt.paragraphs.map(\.text))
    }

    @MainActor
    func testVisionNormalBaselineNumberAndYearsRemainAudible() async throws {
        let fixture = try await recognize("baseline-number")
        for document in [fixture.raw, fixture.rebuilt] {
            for token in ["12", "1924", "1894"] { assertRecognized(token, in: document) }
        }
        assertIdentity(fixture)
    }

    @MainActor
    func testVisionRecognizedMathExponentRemainsAudible() async throws {
        let fixture = try await recognize("math-exponent")
        for document in [fixture.raw, fixture.rebuilt] {
            XCTAssertTrue(document.fullText.contains("2"), "Vision must actually recognize the exponent digit.\n" + fixture.diagnostics)
        }
        assertIdentity(fixture)
    }

    @MainActor
    func testVisionBracketedReferenceIsConservativelyPreserved() async throws {
        let fixture = try await recognize("bracketed-reference")
        // Record what Vision actually returns, including any fused token or
        // missing brackets. A missing digit is a recognition failure, not a pass.
        for document in [fixture.raw, fixture.rebuilt] {
            XCTAssertTrue(document.fullText.contains("12"), fixture.diagnostics)
        }
        assertIdentity(fixture)
    }

    @MainActor
    func testReportedAndroidPageThroughProductionVisionSkipsEntirePairedNotes() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "kindle-paired-footnotes-reported-page", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(data: Data(contentsOf: url)))
        let document = try await OCRService.shared.recognizeKindle(image: image,
            profile: XCTUnwrap(KindleLanguageContract.profile(language: "en")), title: "Reported footnotes",
            paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy)
        XCTAssertEqual(document.paragraphs.count, 7)
        let page = KindleFootnoteSpeech.prepare(document: document)
        XCTAssertTrue(document.paragraphs[3].text.contains("declination"))
        XCTAssertTrue(document.paragraphs[4].text.contains("Inclination"))
        XCTAssertEqual(page.paragraphs[3].spokenText, "")
        XCTAssertEqual(page.paragraphs[4].spokenText, "")
        XCTAssertFalse(page.paragraphs[2].spokenText.contains("|2|"))
        XCTAssertFalse(page.paragraphs[2].spokenText.contains("|3|"))
        for index in [0, 1, 5, 6] {
            XCTAssertEqual(page.paragraphs[index].spokenParagraph, document.paragraphs[index])
        }
        for paragraph in page.paragraphs {
            let chars = Array(paragraph.sourceParagraph.text)
            XCTAssertEqual(String(paragraph.spokenCharacterSourceOffsets.map { chars[$0] }), paragraph.spokenText)
        }
        XCTAssertEqual(KindleFootnoteSpeech.prepare(document: document, skipReferences: false).paragraphs.map(\.spokenParagraph), document.paragraphs)
        print("PARITY_FIXED actualVisionPairedNotesRemoved=2 sourceParagraphs=7 unaffectedNarrative=4")
    }

    private struct Fixture {
        let raw: ReadingDocument
        let rebuilt: ReadingDocument
        let diagnostics: String
    }

    @MainActor
    private func recognize(_ name: String) async throws -> Fixture {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "kindle-footnote-" + name, withExtension: "png") ??
                bundle.url(forResource: "kindle-footnote-" + name, withExtension: "png", subdirectory: "Fixtures"),
            "The controlled image must be bundled; missing fixtures do not skip verification."
        )
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Explicit Vision entry point prevents a Tesseract fallback from being
        // reported as successful Vision coverage.
        let raw = try await OCRService.shared.recognize(
            image: image, languages: ["en-US"], title: name,
            paragraphStrategy: .visionLines, languageHint: "en"
        )
        let rebuilt = try await OCRService.shared.recognize(
            image: image, languages: ["en-US"], title: name,
            paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy, languageHint: "en"
        )
        let diagnostics = try String(decoding: JSONSerialization.data(withJSONObject: [
            "fixture": name,
            "scope": "Actual iOS Vision on locally generated pixels; no live-book claim",
            "raw": dump(raw), "rebuilt": dump(rebuilt)
        ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        let report = XCTAttachment(string: diagnostics)
        report.name = name + "-vision"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertFalse(raw.isEmpty, diagnostics)
        XCTAssertFalse(rebuilt.isEmpty, diagnostics)
        return Fixture(raw: raw, rebuilt: rebuilt, diagnostics: diagnostics)
    }

    private func assertRecognized(_ text: String, in document: ReadingDocument,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(document.paragraphs.flatMap(\.words).contains {
            $0.text == text && $0.bboxSource == .visionTextRange
        }, "Expected independently recognized Vision token '\(text)': \(document.fullText)", file: file, line: line)
    }

    private func assertIdentity(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        let speech = KindleFootnoteSpeech.prepare(document: fixture.rebuilt)
        XCTAssertTrue(speech.paragraphs.allSatisfy { $0.skippedSourceWordIndices.isEmpty }, fixture.diagnostics, file: file, line: line)
        XCTAssertEqual(speech.paragraphs.map(\.spokenText), fixture.rebuilt.paragraphs.map(\.text), fixture.diagnostics, file: file, line: line)
    }

    private func dump(_ document: ReadingDocument) -> [[String: Any]] {
        document.paragraphs.map { paragraph in
            ["id": paragraph.id, "text": paragraph.text, "words": paragraph.words.map { word -> [String: Any] in
                ["id": word.id, "text": word.text, "source": word.bboxSource.rawValue,
                 "line": word.sourceLineID.map { $0 as Any } ?? NSNull(),
                 "confidence": word.recognitionConfidence.map { $0 as Any } ?? NSNull(),
                 "inkChecked": word.inkBoundsChecked,
                 "ink": word.inkBoundsNorm.map { ["x": $0.minX, "y": $0.minY,
                                                  "width": $0.width, "height": $0.height] as Any } ?? NSNull(),
                 "x": word.bboxNorm.minX, "y": word.bboxNorm.minY,
                 "width": word.bboxNorm.width, "height": word.bboxNorm.height]
            }]
        }
    }
}
