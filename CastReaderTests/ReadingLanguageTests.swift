//
//  ReadingLanguageTests.swift
//  CastReaderTests
//
//  Regression cover for the 1.0.x Italian report: "the only working voices are the
//  English ones, and I cannot pick Nicola." The backend was verified healthy first
//  (the catalog lists all 15 Italian voices as selectable), so the fault was
//  entirely on the client, in two layers:
//
//  1. reading language is a per-page detection result, and a page carrying little
//     prose has too little evidence to decide — it fell back to English mid-book,
//     which silently repointed the voice; and
//  2. the voice panel filtered everything, including its own search box, by that
//     page language while disabling the control that could change it, so no
//     Italian voice was reachable to correct it with.
//

import XCTest
@testable import CastReader

final class ReadingLanguageTests: XCTestCase {

    // MARK: - Fixtures

    /// Pinocchio, 1883 (public domain) — a full page of ordinary Italian prose.
    private let italianFullPage = """
    C'era una volta un pezzo di legno. Non era un legno di lusso, ma un semplice \
    pezzo da catasta, di quelli che d'inverno si mettono nelle stufe e nei caminetti \
    per accendere il fuoco e per riscaldare le stanze. Non so come andasse, ma il \
    fatto gli è che un bel giorno questo pezzo di legno capitò nella bottega di un \
    vecchio falegname, il quale aveva nome mastr'Antonio, se non che tutti lo \
    chiamavano maestro Ciliegia, per via della punta del suo naso, che era sempre \
    lustra e paonazza, come una ciliegia matura.
    """

    private let englishControl = """
    That dream was but a moment in a man's life, whose proper business it seemed was \
    to get food and kill his fellows and beget after the manner of all that belongs \
    to the fellowship of the beasts. About him, hidden from him by the thinnest of \
    veils, were the untouched sources of Power, whose magnitude we scarcely do more \
    than suspect even to-day.
    """

    /// Pages that carry little prose. Reading language is decided per page, so one
    /// of these inside an Italian book used to be enough to flip it to an English
    /// voice — that is what "the app forgot my voice" looked like from the outside.
    private let sparseItalianPages: KeyValuePairs<String, String> = [
        "chapter title only": "Capitolo quarto",
        "epigraph": "«Il tempo non aspetta nessuno.»",
        "front matter": """
        Titolo originale: Le avventure di Pinocchio
        Traduzione di M. Rossi
        Prima edizione
        """,
        "short dialogue": "- Sì.\n- No.\n- Forse domani.",
        "picture caption": "Figura 3. La bottega del falegname.",
        "names and numbers": "Antonio Rossi, 1883\nPagina 42",
    ]

    private func italianCatalog() throws -> TTSVoiceCatalogDocument {
        let languages = [
            TTSVoiceCatalogLanguage(
                code: "en", locale: "en-US", name: "English", status: "ga",
                defaultVoice: "af_heart", timestampMode: "word"
            ),
            TTSVoiceCatalogLanguage(
                code: "it", locale: "it-IT", name: "Italian", status: "ga",
                defaultVoice: "if_sara", timestampMode: "word"
            ),
        ]
        let voices = [
            ("af_heart", "Heart", "en", "en-US", "female"),
            ("am_michael", "Michael", "en", "en-US", "male"),
            ("if_sara", "Sara", "it", "it-IT", "female"),
            ("im_nicola", "Nicola", "it", "it-IT", "male"),
        ].map { id, name, language, locale, gender in
            TTSVoiceCatalogVoice(
                id: id, name: name, engine: "kokoro", modelVersion: "v1.0",
                language: language, locale: locale, genderPresentation: gender,
                tier: "free", status: "ga", enabled: true, selectable: true,
                timestampMode: "word", tags: [], avatar: nil, sampleUrl: nil,
                accent: nil, sourceModelVersion: nil, collection: nil,
                recommended: nil, qualityGrade: nil, trainingDuration: nil,
                description: nil, descriptionZh: nil, bestFor: nil
            )
        }
        return TTSVoiceCatalogDocument(
            contract: TTSVoiceCatalogDocument.expectedContract,
            version: "italian-repro", languages: languages, voices: voices
        )
    }

    // MARK: - Detection

    func testOrdinaryProseIsDetectedInItsOwnLanguage() {
        XCTAssertEqual(LanguageDetector.detect(italianFullPage), "it")
        XCTAssertEqual(LanguageDetector.detect(englishControl), "en")
    }

    /// A page of ordinary prose is decidable in every one of the close Latin
    /// languages the recognizer has to separate.
    func testOrdinaryPagesAreConfidentEnoughToDecide() {
        let pages: KeyValuePairs<String, String> = [
            "it": italianFullPage,
            "en": englishControl,
            "it/no accents": """
            Il falegname prese il pezzo di legno e lo poso sul banco. Voleva cominciare \
            il lavoro prima di sera, ma la pialla non si trovava da nessuna parte nella \
            bottega piena di trucioli.
            """,
            "es": """
            El carpintero tomo el trozo de madera y lo dejo sobre el banco de trabajo. \
            Queria empezar antes de que cayera la noche, pero no encontraba el cepillo \
            por ninguna parte del taller.
            """,
            "pt": """
            O carpinteiro pegou o pedaço de madeira e colocou-o sobre a bancada. Queria \
            começar antes do anoitecer, mas não encontrava a plaina em lugar nenhum da \
            oficina cheia de aparas.
            """,
        ]
        let expected = ["it": "it", "en": "en", "it/no accents": "it", "es": "es", "pt": "pt"]
        for (label, text) in pages {
            XCTAssertEqual(
                ReadingLanguagePolicy.confidentLanguage(for: text),
                expected[label],
                "\(label) is an ordinary page and must be able to decide the language"
            )
        }
    }

    /// The measurements the thresholds were chosen from. `NLLanguageRecognizer`
    /// does not fall silent on a page with almost no text — it guesses, and it
    /// guesses confidently. These are the two independent ways a page can be too
    /// thin to trust; both gates are needed because each catches cases the other
    /// misses.
    func testThresholdsSitBetweenGuessworkAndRealPages() {
        // Confident but nearly textless: 13 readable characters read as English at
        // 0.94. Only the character floor rejects this one.
        let url = LanguageDetector.evidence(for: "www.example.com")
        XCTAssertGreaterThan(url.confidence, ReadingLanguagePolicy.minimumConfidence)
        XCTAssertLessThan(
            url.readableCharacterCount,
            ReadingLanguagePolicy.minimumReadableCharacters
        )
        XCTAssertNil(ReadingLanguagePolicy.confidentLanguage(in: url))

        // Outright guesswork on a handful of characters.
        for sample in ["III", "Fig. 1", "l1 |0 rn"] {
            let evidence = LanguageDetector.evidence(for: sample)
            XCTAssertLessThan(
                evidence.confidence,
                ReadingLanguagePolicy.minimumConfidence,
                "\(sample) must not clear the confidence floor"
            )
            XCTAssertNil(ReadingLanguagePolicy.confidentLanguage(for: sample))
        }

        // Nothing readable at all still returns "en" from the detector — the exact
        // silent English fallback this policy exists to stop believing.
        for sample in ["", "   \n  \t ", "42"] {
            let evidence = LanguageDetector.evidence(for: sample)
            XCTAssertEqual(evidence.language, "en")
            XCTAssertEqual(evidence.confidence, 0)
            XCTAssertNil(ReadingLanguagePolicy.confidentLanguage(for: sample))
        }

        // A long page can still be undecidable: garbled OCR of 73 characters reads
        // as Portuguese at 0.66. Only the confidence floor rejects this one.
        let garble = LanguageDetector.evidence(
            for: "lll 0O rn vv iii |||  ll1 O0O rnrn vvvv ii ||| lll OO0 rn vv iii ||| "
                + "ll1 0OO rnrn vvv ii ||| lll OO rn vvv iiii ||| ll1 O0 rn vv ii |||"
        )
        XCTAssertLessThan(garble.confidence, ReadingLanguagePolicy.minimumConfidence)
        XCTAssertNil(ReadingLanguagePolicy.confidentLanguage(in: garble))
    }

    func testSparsePagesCarryNoConfidentEvidence() {
        for (label, text) in sparseItalianPages {
            XCTAssertNil(
                ReadingLanguagePolicy.confidentLanguage(for: text),
                "\(label) is too thin to decide a language on its own"
            )
        }
    }

    /// The reported behaviour, page by page: page one is prose and settles the
    /// book; every sparse page after it keeps that language instead of falling
    /// back to English and silently repointing the voice.
    func testASparsePageInsideAnItalianBookKeepsReadingItalian() {
        let opening = ReadingLanguagePolicy.resolve(
            userOverride: nil,
            confidentDetection: ReadingLanguagePolicy.confidentLanguage(for: italianFullPage),
            remembered: nil
        )
        XCTAssertEqual(opening.language, "it")
        XCTAssertEqual(opening.source, .detected)
        XCTAssertTrue(opening.shouldRemember)

        for (label, text) in sparseItalianPages {
            let next = ReadingLanguagePolicy.resolve(
                userOverride: nil,
                confidentDetection: ReadingLanguagePolicy.confidentLanguage(for: text),
                remembered: opening.language
            )
            XCTAssertEqual(next.language, "it", label)
            XCTAssertEqual(next.source, .remembered, label)
            // Carrying a language forward must not harden into evidence for itself.
            XCTAssertFalse(next.shouldRemember, label)
        }
    }

    func testAUserCorrectionOutranksEvenAConfidentDetection() {
        let decision = ReadingLanguagePolicy.resolve(
            userOverride: "it",
            confidentDetection: ReadingLanguagePolicy.confidentLanguage(for: englishControl),
            remembered: "en"
        )
        XCTAssertEqual(decision.language, "it")
        XCTAssertEqual(decision.source, .user)
        // A correction is the user's, not the detector's: re-detecting must never
        // overwrite it, or the next page puts back what they just changed.
        XCTAssertFalse(decision.shouldRemember)
    }

    func testNothingKnownYetStillFallsBackToEnglish() {
        let decision = ReadingLanguagePolicy.resolve(
            userOverride: nil,
            confidentDetection: nil,
            remembered: nil
        )
        XCTAssertEqual(decision.language, "en")
        XCTAssertEqual(decision.source, .fallback)
        XCTAssertFalse(decision.shouldRemember)
    }

    func testResolveNormalizesEveryEvidenceToAProductLanguage() {
        XCTAssertEqual(
            ReadingLanguagePolicy.resolve(
                userOverride: "it-IT", confidentDetection: nil, remembered: nil
            ).language,
            "it"
        )
        XCTAssertEqual(
            ReadingLanguagePolicy.resolve(
                userOverride: "  ", confidentDetection: "pt-BR", remembered: nil
            ).language,
            "pt"
        )
        XCTAssertEqual(
            ReadingLanguagePolicy.resolve(
                userOverride: nil, confidentDetection: nil, remembered: "zh_Hans"
            ).language,
            "zh"
        )
    }

    // MARK: - Per-book persistence

    private func isolatedStore() -> (ReadingLanguageStore, UserDefaults, String) {
        let suite = "ReadingLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ReadingLanguageStore(defaults: defaults), defaults, suite)
    }

    func testAnOverrideSurvivesAcrossStoreInstances() {
        let (store, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = ReadingLanguageStore.contentKey(namespace: "google_books", bookID: "abc123")
        XCTAssertEqual(key, "google_books:abc123")
        XCTAssertNil(store.override(for: key))

        store.setOverride("it-IT", for: key)
        XCTAssertEqual(ReadingLanguageStore(defaults: defaults).override(for: key), "it")

        // Namespaced so two shelves cannot collide on the same book id.
        let sameIDElsewhere = ReadingLanguageStore.contentKey(namespace: "kindle", bookID: "abc123")
        XCTAssertNil(store.override(for: sameIDElsewhere))

        store.clearOverride(for: key)
        XCTAssertNil(ReadingLanguageStore(defaults: defaults).override(for: key))
    }

    func testAnEmptyBookIdentityIsNeverStored() {
        let (store, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ReadingLanguageStore.contentKey(namespace: "web", bookID: "  "), "")
        XCTAssertEqual(ReadingLanguageStore.contentKey(namespace: " ", bookID: "abc"), "")
        store.setOverride("it", for: "")
        XCTAssertNil(store.override(for: ""))
    }

    /// A shelf can grow without limit; the least recently used corrections go first.
    func testStoreKeepsTheMostRecentCorrectionsWithinItsCap() {
        let suite = "ReadingLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var clock = Date(timeIntervalSince1970: 0)
        let store = ReadingLanguageStore(defaults: defaults, now: { clock })
        let total = ReadingLanguageStore.maximumEntries + 10
        for index in 0..<total {
            clock = Date(timeIntervalSince1970: TimeInterval(index))
            store.setOverride(
                "it",
                for: ReadingLanguageStore.contentKey(namespace: "kindle", bookID: "book\(index)")
            )
        }

        let oldest = ReadingLanguageStore.contentKey(namespace: "kindle", bookID: "book0")
        let newest = ReadingLanguageStore.contentKey(namespace: "kindle", bookID: "book\(total - 1)")
        XCTAssertNil(store.override(for: oldest))
        XCTAssertEqual(store.override(for: newest), "it")
    }

    // MARK: - The panel is a correctable default, never a lock

    @MainActor
    func testExplainPinsItsLanguageAndReadAloudNeverCanAgain() {
        let center = PlaybackVoicePanelCenter.shared
        defer { center.dismiss() }

        // Explain: the language is a user setting, cross-language picks are rejected
        // downstream, so opening it up would only offer voices that do nothing.
        center.present(language: "it-IT")
        XCTAssertEqual(center.request?.language, "it")
        XCTAssertEqual(center.request?.isReadingLanguageCorrectable, false)

        // Read-aloud always arrives with a correction, so it can never be pinned.
        var corrected: [String] = []
        center.present(language: "en") { corrected.append($0) }
        XCTAssertEqual(center.request?.isReadingLanguageCorrectable, true)
        center.correctReadingLanguage("it")
        XCTAssertEqual(corrected, ["it"])

        // Dismissing releases the handler; a later pin must not inherit it.
        center.dismiss()
        center.present(language: "en")
        XCTAssertEqual(center.request?.isReadingLanguageCorrectable, false)
        center.correctReadingLanguage("ja")
        XCTAssertEqual(corrected, ["it"])
    }

    /// The two call sites that produced the dead end. Read surfaces must always
    /// hand the panel a correction; only Explain may leave it out.
    func testEveryReadAloudVoiceControlOffersACorrection() throws {
        let sources = try repositorySources([
            "CastReader/Views/Settings/VoiceBrowserView.swift",
            "CastReader/Views/Reader/ReaderHostView.swift",
            "CastReader/Views/Kindle/KindleBookView.swift",
            "CastReader/Views/Player/MiniPlayerView.swift",
        ])

        let panel = sources["CastReader/Views/Settings/VoiceBrowserView.swift"]!
        XCTAssertFalse(
            panel.contains("lockedLanguage"),
            "The panel language is an initial selection, not a lock"
        )
        XCTAssertTrue(panel.contains("""
        initialLanguage != nil && onCorrectReadingLanguage == nil
        """))
        XCTAssertTrue(panel.contains("onCorrectReadingLanguage?(normalized)"))

        // Every read-aloud surface wires its view model's correction through.
        for path in [
            "CastReader/Views/Reader/ReaderHostView.swift",
            "CastReader/Views/Kindle/KindleBookView.swift",
            "CastReader/Views/Player/MiniPlayerView.swift",
        ] {
            XCTAssertTrue(
                sources[path]!.contains("correctReadingLanguage($0)"),
                "\(path) must let read-aloud correct its reading language"
            )
        }
    }

    // MARK: - Searching the panel

    /// The user's exact action: open the reader's voice panel and type "Nicola".
    func testSearchingNicolaDependsOnlyOnTheChosenLanguage() throws {
        defer { VoiceCatalog.resetForTesting() }
        try VoiceCatalog.install(italianCatalog())

        func search(_ query: String, language: String) -> [String] {
            VoiceBrowserFilter.apply(
                voices: VoiceCatalog.voices(for: language),
                search: query,
                language: language,
                gender: "",
                tier: .all
            ).map(\.code)
        }

        XCTAssertEqual(search("Nicola", language: "it"), ["im_nicola"])
        // Still empty while the panel shows English — that is the filter working.
        // What made it a dead end was that the language could not be changed.
        XCTAssertEqual(search("Nicola", language: "en"), [])
    }

    // MARK: - Correcting playback

    @MainActor
    func testCorrectingTheReadingLanguageRepointsTheVoice() throws {
        defer { VoiceCatalog.resetForTesting() }
        try VoiceCatalog.install(italianCatalog())

        let document = ReadingDocument(
            title: "Misdetected page",
            sourceKind: .text,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: englishControl, type: .paragraph)]
        )
        let vm = ReadAloudViewModel(document: document)
        XCTAssertEqual(vm.playbackLanguage, "en")
        XCTAssertEqual(AppSettings.shared.voice(for: vm.playbackLanguage), "af_heart")

        vm.correctReadingLanguage("it-IT")

        XCTAssertEqual(vm.playbackLanguage, "it")
        XCTAssertEqual(AppSettings.shared.voice(for: vm.playbackLanguage), "if_sara")
    }

    /// A correction is about this book, not this page: re-extracting the next page
    /// must not put the misdetected language back. That flip-back is precisely the
    /// behaviour that was reported.
    @MainActor
    func testALaterPageDetectionCannotUndoTheCorrection() throws {
        defer { VoiceCatalog.resetForTesting() }
        try VoiceCatalog.install(italianCatalog())

        let document = ReadingDocument(
            title: "Live page",
            sourceKind: .web,
            language: "en",
            paragraphs: []
        )
        let vm = ReadAloudViewModel(document: document)
        vm.correctReadingLanguage("it")
        XCTAssertEqual(vm.playbackLanguage, "it")

        vm.loadWebParagraphs(
            [ReadingParagraph(id: 0, text: "Capitolo quarto", type: .paragraph)],
            language: "en"
        )
        XCTAssertEqual(vm.playbackLanguage, "it")
    }

    /// Every per-page language decision in the live web readers goes through the
    /// policy. A bare `detect` there is the original defect: it throws away the
    /// confidence the recognizer reports and believes a guess.
    func testLiveWebReadersNeverDecideALanguageFromDetectAlone() throws {
        let bridge = try repositorySources(["CastReader/Services/WebReaderBridge.swift"])
            .values
            .first!
        XCTAssertFalse(
            bridge.contains("LanguageDetector.detect("),
            "WebReaderBridge must resolve page languages through ReadingLanguagePolicy"
        )
        XCTAssertEqual(
            bridge.components(separatedBy: "resolveReadingLanguage(").count - 1,
            // One definition plus the five per-page decision points: WeRead's
            // committed page and its prediction, the generic article, and Google
            // Books' parsed page and its speech preload.
            6
        )
    }

    /// The correction has to outlive the page it was made on, and the session.
    @MainActor
    func testACorrectionIsRememberedForThatBookOnReopen() throws {
        defer { VoiceCatalog.resetForTesting() }
        try VoiceCatalog.install(italianCatalog())

        let document = ReadingDocument(
            id: "reading-language-test-\(UUID().uuidString)",
            title: "Reopened book",
            sourceKind: .googleBooks,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: englishControl, type: .paragraph)]
        )
        let key = ReadingLanguageStore.contentKey(
            namespace: document.sourceKind.rawValue,
            bookID: document.id
        )
        defer { ReadingLanguageStore.shared.clearOverride(for: key) }

        ReadAloudViewModel(document: document).correctReadingLanguage("it")
        XCTAssertEqual(ReadingLanguageStore.shared.override(for: key), "it")

        // Reopening the same book starts in the corrected language, not in whatever
        // the document or the first page says.
        XCTAssertEqual(ReadAloudViewModel(document: document).playbackLanguage, "it")
    }

    /// Kindle builds a fresh document per page, so its book identity arrives with
    /// the playback metadata. Without keying on that, a correction would last
    /// exactly one page on the shelf the report came from.
    @MainActor
    func testAKindlePageTurnKeepsTheCorrection() throws {
        defer { VoiceCatalog.resetForTesting() }
        try VoiceCatalog.install(italianCatalog())

        let asin = "B0-reading-language-\(UUID().uuidString)"
        let key = ReadingLanguageStore.contentKey(namespace: "kindle", bookID: asin)
        defer { ReadingLanguageStore.shared.clearOverride(for: key) }

        func pageViewModel() -> ReadAloudViewModel {
            // A new UUID per page, exactly as the Kindle capture path builds them.
            let page = ReadingDocument(
                title: "Kindle page",
                sourceKind: .kindle,
                language: "en",
                paragraphs: [ReadingParagraph(id: 0, text: englishControl, type: .paragraph)]
            )
            let vm = ReadAloudViewModel(document: page)
            vm.configurePlaybackMetadata(id: asin, title: "Kindle book", coverURL: nil)
            return vm
        }

        let firstPage = pageViewModel()
        XCTAssertEqual(firstPage.playbackLanguage, "en")
        firstPage.correctReadingLanguage("it")
        XCTAssertEqual(ReadingLanguageStore.shared.override(for: key), "it")

        XCTAssertEqual(pageViewModel().playbackLanguage, "it")
    }

    // MARK: - Helpers

    private func repositorySources(_ paths: [String]) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CastReaderTests
            .deletingLastPathComponent()   // repository root
        var sources: [String: String] = [:]
        for path in paths {
            sources[path] = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
        }
        return sources
    }
}
