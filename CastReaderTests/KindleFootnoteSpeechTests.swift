import CoreGraphics
import XCTest
@testable import CastReader

final class KindleFootnoteSpeechTests: XCTestCase {
    func testOnlyRaisedSentenceReferenceIsRemovedAndSourceIDsStayIntact() throws {
        let source = paragraph()
        let page = prepare(source)
        let speech = try XCTUnwrap(page.paragraphs.first)
        XCTAssertEqual(speech.skippedSourceWordIndices, [6])
        XCTAssertEqual(speech.spokenText, "In 1924 the long war ended. The people returned.")
        XCTAssertEqual(speech.sourceParagraph, source)
        XCTAssertEqual(speech.spokenParagraph.words.map(\.id), [100, 101, 102, 103, 104, 105, 107, 108, 109])
        let timestamps = speech.spokenParagraph.words.enumerated().map {
            TTSTimestamp(word: $0.element.text, startTime: Double($0.offset), endTime: Double($0.offset) + 0.5)
        }
        XCTAssertEqual(speech.mapTimestampWords(timestamps), speech.spokenWordSourceIndices.map(Optional.some))
        XCTAssertEqual(speech.sourceWordIndex(forSpokenWordIndex: 6), 7)
        XCTAssertNil(speech.sourceWordIndex(forSpokenWordIndex: 99))
        let sourceChars = Array(source.text)
        XCTAssertEqual(String(speech.spokenCharacterSourceOffsets.map { sourceChars[$0] }), speech.spokenText)
    }

    func testSameNumberAtNormalBaselineAndFourDigitYearsArePreserved() {
        for source in [paragraph(raised: false), paragraph(marker: "1924")] {
            let speech = prepare(source).paragraphs[0]
            XCTAssertTrue(speech.skippedSourceWordIndices.isEmpty)
            XCTAssertEqual(speech.spokenText, source.text)
        }
    }

    func testMathDateChapterAndBracketNotationStayAudible() {
        let sources = [
            paragraph(prefix: ["The", "formula", "is", "x."], marker: "2"),
            paragraph(prefix: ["We", "read", "chapter", "twelve."], marker: "2"),
            paragraph(prefix: ["We", "met", "in", "January."], marker: "2"),
            paragraph(marker: "[12]"), paragraph(marker: "²"),
            paragraph(prefix: ["The", "value", "x=2", "increased."], marker: "2")
        ]
        for source in sources {
            let speech = prepare(source).paragraphs[0]
            XCTAssertEqual(speech.spokenText, source.text)
            XCTAssertTrue(speech.skippedSourceWordIndices.isEmpty, source.text)
        }
    }

    func testMissingProvenanceMixedEstimatedLineAndLowConfidenceNeverDelete() {
        for boxSource in [OCRWordBoxSource.unknown, .proportional, .tesseractWord] {
            let source = paragraph(markerSource: boxSource)
            XCTAssertTrue(prepare(source).paragraphs[0].skippedSourceWordIndices.isEmpty)
        }
        let source = paragraph(confidence: 0.50)
        XCTAssertTrue(prepare(source).paragraphs[0].skippedSourceWordIndices.isEmpty)
        let noLine = paragraph(lineID: nil)
        XCTAssertTrue(prepare(noLine).paragraphs[0].skippedSourceWordIndices.isEmpty)
    }

    func testPartialOrNormalizedSourceBindingFallsBackToWholeParagraphIdentity() {
        let source = paragraph()
        let mismatched = ReadingParagraph(id: source.id, text: "Missing " + source.text, words: source.words)
        let speech = prepare(mismatched).paragraphs[0]
        XCTAssertEqual(speech.spokenText, mismatched.text)
        XCTAssertEqual(speech.spokenWordSourceIndices, Array(source.words.indices))
        XCTAssertTrue(speech.skippedSourceWordIndices.isEmpty)
    }

    func testRepeatedDigitsBindToTheRaisedOccurrenceOnly() {
        let source = paragraph(prefix: ["12", "people", "thought", "the", "long", "war", "ended."])
        let speech = prepare(source).paragraphs[0]
        XCTAssertEqual(speech.skippedSourceWordIndices, [7])
        XCTAssertTrue(speech.spokenText.hasPrefix("12 people"))
        XCTAssertEqual(speech.spokenParagraph.words.first?.id, source.words.first?.id)
        XCTAssertEqual(speech.mapTimestampWords([
            TTSTimestamp(word: "12", startTime: 0, endTime: 0.5)
        ]), [0])
    }

    func testDisableRestoresExactOriginalAndPolicyChangesCacheSignature() {
        let source = paragraph()
        let on = prepare(source)
        let off = prepare(source, enabled: false)
        XCTAssertEqual(off.paragraphs[0].spokenParagraph, source)
        XCTAssertNotEqual(on.cacheSignature, off.cacheSignature)
        XCTAssertNotEqual(on.cacheSignature, prepare(paragraph(raised: false)).cacheSignature)
        XCTAssertEqual(on.cacheSignature, prepare(source).cacheSignature)
    }

    func testMissingPixelSizeAndUnsupportedScriptRemainIdentity() {
        let source = paragraph()
        let missingSize = ReadingDocument(title: "Fixture", sourceKind: .kindle, language: "en", paragraphs: [source])
        XCTAssertTrue(KindleFootnoteSpeech.prepare(document: missingSize).paragraphs[0].skippedSourceWordIndices.isEmpty)
        var differentScript = missingSize
        differentScript.language = "ja"
        differentScript.imagePixelSize = CGSize(width: 1000, height: 1000)
        XCTAssertTrue(KindleFootnoteSpeech.prepare(document: differentScript).paragraphs[0].skippedSourceWordIndices.isEmpty)
    }

    func testLegacyWordInitializerIsUnknownAndReidentificationPreservesEvidence() {
        let legacy = OCRWord(id: 1, text: "12", bboxNorm: .zero)
        XCTAssertEqual(legacy.bboxSource, .unknown)
        XCTAssertNil(legacy.sourceLineID)
        let original = paragraph().words[6]
        let mapped = original.reidentified(id: 300)
        XCTAssertEqual(mapped.id, 300)
        XCTAssertEqual(mapped.text, original.text)
        XCTAssertEqual(mapped.bboxNorm, original.bboxNorm)
        XCTAssertEqual(mapped.bboxSource, original.bboxSource)
        XCTAssertEqual(mapped.sourceLineID, original.sourceLineID)
        XCTAssertEqual(mapped.recognitionConfidence, original.recognitionConfidence)
    }

    func testLegacyPhotoSnapshotStillDecodesWithoutInventingVisionProvenance() throws {
        let json = """
        {"version":1,"language":"en","payloadByteCount":3,"paragraphs":[
          {"id":0,"text":"12","words":[
            {"id":42,"text":"12","x":0.1,"y":0.8,"width":0.04,"height":0.02}
          ]}
        ]}
        """
        let snapshot = try JSONDecoder().decode(PhotoOCRSnapshot.self, from: Data(json.utf8))
        let word = try XCTUnwrap(snapshot.readingParagraphs.first?.words.first)
        XCTAssertEqual(word.id, 42)
        XCTAssertEqual(word.text, "12")
        XCTAssertEqual(word.bboxSource, .unknown)
        XCTAssertNil(word.sourceLineID)
        XCTAssertNil(word.recognitionConfidence)
    }

    func testMeasuredInkCanProveReferenceWhenVisionFlattensEveryTokenToLineHeight() {
        let source = measuredParagraph()
        let speech = prepare(source).paragraphs[0]
        XCTAssertEqual(speech.skippedSourceWordIndices, [6])
        XCTAssertEqual(speech.sourceParagraph, source)
        XCTAssertEqual(source.words[6].bboxNorm.height, source.words[5].bboxNorm.height)
        XCTAssertEqual(source.words[6].reidentified(id: 400).inkBoundsNorm, source.words[6].inkBoundsNorm)
        XCTAssertTrue(source.words[6].reidentified(id: 400).inkBoundsChecked)
    }

    func testFailedInkMeasurementCannotFallBackToAnApparentlyRaisedRawBox() {
        let source = measuredParagraph(failedIndices: [6], flattenRawBoxes: false)
        XCTAssertTrue(prepare(source).paragraphs[0].skippedSourceWordIndices.isEmpty)
    }

    func testSameLineFollowingProseSupportsBaselineWithoutUsingRejectedWordPixels() {
        // Only two preceding alphabetic words still have usable pixels, but
        // three following words independently confirm this same line's baseline.
        let source = measuredParagraph(failedIndices: [0, 2, 3])
        XCTAssertEqual(prepare(source).paragraphs[0].skippedSourceWordIndices, [6])
        let tooFew = measuredParagraph(failedIndices: [0, 2, 3, 4, 7, 8, 9])
        XCTAssertTrue(prepare(tooFew).paragraphs[0].skippedSourceWordIndices.isEmpty)
        let normal = measuredParagraph(raised: false)
        XCTAssertTrue(prepare(normal).paragraphs[0].skippedSourceWordIndices.isEmpty)
    }

    func testPairedDefinitionsAndInlineMarkersAreRemovedWithStableSourceGeometry() throws {
        let doc = noteDocument([
            "We measured declination|2| and inclination|3| in 1924.",
            "[2] The declination is the variation of the magnetic compass.",
            "[3] Inclination is the dip of the magnetic needle.",
            "The journey continued in 1894."
        ])
        let projected = KindleFootnoteSpeech.prepare(document: doc)
        XCTAssertEqual(projected.paragraphs.map(\.spokenText), ["We measured declination and inclination in 1924.", "", "", "The journey continued in 1894."])
        XCTAssertEqual(projected.paragraphs.map(\.sourceParagraphID), [0, 1, 2, 3])
        let first = projected.paragraphs[0]
        XCTAssertEqual(first.spokenParagraph.words[2].text, "declination")
        for (i, word) in first.spokenParagraph.words.enumerated() {
            let source = doc.paragraphs[0].words[first.spokenWordSourceIndices[i]]
            XCTAssertEqual(word.id, source.id)
            XCTAssertEqual(word.bboxNorm, source.bboxNorm)
            XCTAssertEqual(word.sourceLineID, source.sourceLineID)
            XCTAssertEqual(word.inkBoundsChecked, source.inkBoundsChecked)
        }
        for paragraph in projected.paragraphs {
            let source = Array(paragraph.sourceParagraph.text)
            XCTAssertEqual(String(paragraph.spokenCharacterSourceOffsets.map { source[$0] }), paragraph.spokenText)
        }
    }

    func testVisionAndAndroidDamagedDefinitionBracketsRequireUniqueTermPair() {
        for marker in ["12", "[21", "[2l", "[2I", "2]", "［2］", "{2}"] {
            let doc = noteDocument(["We measured declination|2| today.", "\(marker) The declination is the variation of the compass."])
            let page = KindleFootnoteSpeech.prepare(document: doc)
            XCTAssertEqual(page.paragraphs[0].spokenText, "We measured declination today.", marker)
            XCTAssertEqual(page.paragraphs[1].spokenText, "", marker)
        }
    }

    func testAmbiguousDamagedNumberAndUnpairedOrMixedNarrativeArePreserved() {
        let cases = [
            ["We measured declination|2| and declination|12|.", "12 The declination is the variation of the compass."],
            ["We measured declination|2| and declination|21|.", "[21 The declination is the variation of the compass."],
            ["We measured declination|2| today.", "[2] The inclination is the dip of the needle."],
            ["We measured declination|2| today.", "[2] The declination is the variation of the compass. We left at noon."],
            ["We measured declination|2| today.", "[2] The declination is the variation of the compass.", "[2] Declination is another variation of the compass."],
            ["There were 12 people.", "[2] The declination is the variation of the compass."]
        ]
        for texts in cases {
            XCTAssertEqual(KindleFootnoteSpeech.prepare(document: noteDocument(texts)).paragraphs.map(\.spokenText), texts)
        }
    }

    func testMergedTailNoteRequiresRealLineBoundaryAndPreservesPrecedingProse() {
        let texts = ["We measured declination|2| today.", "The journey continued. [2] The declination is the variation of the compass."]
        var doc = noteDocument(texts)
        XCTAssertEqual(KindleFootnoteSpeech.prepare(document: doc).paragraphs.map(\.spokenText), texts)
        doc.paragraphs[1] = noteParagraph(texts[1], id: 1, lineStarts: [3])
        XCTAssertEqual(KindleFootnoteSpeech.prepare(document: doc).paragraphs.map(\.spokenText), ["We measured declination today.", "The journey continued."])
    }

    func testIndentedNoteIsOneDefinitionAndKeepsStableSourceOffsets() {
        let doc = noteDocument(["We measured declination|2| today.", "  [2] The declination is the variation of the compass."])
        let page = KindleFootnoteSpeech.prepare(document: doc)
        XCTAssertEqual(page.paragraphs[0].spokenText, "We measured declination today.")
        XCTAssertEqual(page.paragraphs[1].spokenText, "")
    }

    func testIncompleteBindingPreservesBothReferenceAndDefinition() {
        var doc = noteDocument(["We measured declination|2| today.", "[2] The declination is the variation of the compass."])
        doc.paragraphs[0] = ReadingParagraph(id: 0, text: "Missing " + doc.paragraphs[0].text, words: doc.paragraphs[0].words)
        XCTAssertEqual(KindleFootnoteSpeech.prepare(document: doc).paragraphs.map(\.spokenText), doc.paragraphs.map(\.text))
    }

    @MainActor
    func testReadExplainAndPrefetchShareProjectionAndMarksMapBackToOriginal() throws {
        let key = "kindle.skipFootnoteReferences.v1"
        let old = UserDefaults.standard.object(forKey: key)
        defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)
        let doc = noteDocument(["We measured declination|2| and inclination during the journey.", "[2] The declination is the variation of the compass."])
        let read = KindleFootnoteSpeech.prepare(document: doc)
        let explain = ExplainViewModel.explanationInput(doc)
        XCTAssertEqual(explain.paragraphs, read.paragraphs.map(\.spokenParagraph))
        let vm = ExplainViewModel(document: doc)
        defer { vm.stop(); vm.deactivate() }
        let hit = try XCTUnwrap(MarkAnchoring.locate(markText: "inclination during the journey", in: explain, near: nil))
        let range = try XCTUnwrap(vm.sourceMarkRange(paragraphID: hit.paragraphIndex, range: hit.range))
        XCTAssertEqual(String(Array(doc.paragraphs[0].text)[range]), "inclination during the journey.")
        XCTAssertEqual(vm.document, doc, "The visual document stays original")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertEqual(ExplainViewModel.explanationInput(doc).paragraphs, doc.paragraphs)
        XCTAssertNotEqual(read.cacheSignature, KindleFootnoteSpeech.prepare(document: doc, skipReferences: false).cacheSignature)
    }

    func testUnicodeCharacterOffsetsSurvivePartialTokenRemoval() throws {
        let doc = noteDocument(["We measured déclination|2| and inclination today.", "[2] The déclination is the variation of the compass."])
        let page = KindleFootnoteSpeech.prepare(document: doc)
        XCTAssertFalse(page.paragraphs[0].spokenText.contains("|2|"))
        let source = Array(doc.paragraphs[0].text)
        XCTAssertEqual(String(page.paragraphs[0].spokenCharacterSourceOffsets.map { source[$0] }), page.paragraphs[0].spokenText)
    }

    private func noteDocument(_ texts: [String]) -> ReadingDocument {
        ReadingDocument(title: "Notes", sourceKind: .kindle, language: "en",
                        paragraphs: texts.enumerated().map { noteParagraph($0.element, id: $0.offset) },
                        imagePixelSize: CGSize(width: 1000, height: 1000))
    }

    private func noteParagraph(_ text: String, id: Int, lineStarts: Set<Int> = []) -> ReadingParagraph {
        var line = id * 10
        let words = text.split(separator: " ").enumerated().map { index, token in
            if lineStarts.contains(index) { line += 1 }
            return OCRWord(id: id * 100 + index, text: String(token),
                bboxNorm: CGRect(x: 0.02 + Double(index) * 0.06, y: 0.8 - Double(line) * 0.01, width: 0.05, height: 0.02),
                bboxSource: .visionTextRange, sourceLineID: line, recognitionConfidence: 1)
        }
        return ReadingParagraph(id: id, text: text, words: words)
    }

    private func measuredParagraph(raised: Bool = true, failedIndices: Set<Int> = [],
                                   flattenRawBoxes: Bool = true) -> ReadingParagraph {
        let source = paragraph(raised: raised)
        let words = source.words.enumerated().map { index, word in
            OCRWord(id: word.id, text: word.text,
                    bboxNorm: flattenRawBoxes ? CGRect(x: word.bboxNorm.minX, y: 0.84,
                                                       width: word.bboxNorm.width, height: 0.07) : word.bboxNorm,
                    bboxSource: word.bboxSource, sourceLineID: word.sourceLineID,
                    recognitionConfidence: word.recognitionConfidence,
                    inkBoundsNorm: failedIndices.contains(index) ? nil : word.bboxNorm,
                    inkBoundsChecked: true)
        }
        return ReadingParagraph(id: source.id, text: source.text, words: words)
    }

    private func prepare(_ source: ReadingParagraph, enabled: Bool = true) -> KindleSpeechPage {
        KindleFootnoteSpeech.prepare(document: ReadingDocument(
            title: "Fixture", sourceKind: .kindle, language: "en", paragraphs: [source],
            imagePixelSize: CGSize(width: 1000, height: 1000)
        ), skipReferences: enabled)
    }

    private func paragraph(prefix: [String] = ["In", "1924", "the", "long", "war", "ended."],
                           marker: String = "12", raised: Bool = true,
                           markerSource: OCRWordBoxSource = .visionTextRange,
                           confidence: Float = 0.99, lineID: Int? = 0) -> ReadingParagraph {
        let strings = prefix + [marker, "The", "people", "returned."]
        var left: CGFloat = 40
        let words = strings.enumerated().map { index, text -> OCRWord in
            let isMarker = index == prefix.count
            let width = CGFloat(text.count) * 9
            let top: CGFloat = isMarker && raised ? 94 : 100
            let height: CGFloat = isMarker && raised ? 24 : 40
            defer { left += width + 10 }
            return OCRWord(
                id: 100 + index, text: text,
                bboxNorm: CGRect(x: left / 1000, y: 1 - (top + height) / 1000,
                                 width: width / 1000, height: height / 1000),
                bboxSource: isMarker ? markerSource : .visionTextRange,
                sourceLineID: lineID, recognitionConfidence: confidence
            )
        }
        return ReadingParagraph(id: 7, text: strings.joined(separator: " "), words: words)
    }
}
