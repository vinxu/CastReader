import XCTest
import UIKit
import WebKit
@testable import CastReader

private actor NavigationSpeechFixture: ParagraphSpeechGenerating {
    private(set) var inputs: [String] = []
    func generateTTSForParagraph(
        paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        inputs.append(text)
        await onSegmentReady(AudioSegment(paragraphIndex: paragraphIndex, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 10),
            timestamps: [TTSTimestamp(word: text, startTime: 0, endTime: 9)],
            duration: 10, text: text, isWavFormat: true))
    }
}

@MainActor
final class KindleNavigationPositionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var wasPro = false

    override func setUp() async throws {
        suite = "kindle-navigation-test-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        wasPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
    }

    override func tearDown() async throws {
        ProManager.shared.debugForcePro = wasPro
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func testUnplayedNavigationSurvivesProcessStoreRecreation() throws {
        let store = KindleLibraryStore(defaults: defaults)
        let pending = try XCTUnwrap(store.beginNavigation(bookID: "book", boundary: store.positionStorageGeneration))
        XCTAssertEqual(KindleLibraryStore(defaults: defaults).navigationPositions["book"]?.id, pending.id)
        XCTAssertTrue(store.confirmNavigation(bookID: "book", id: pending.id,
            pageKey: "ephemeral-page", pixelFingerprint: "stable-pixels", progressLabel: "Location 1892", readerURL: nil))
        let reopened = KindleLibraryStore(defaults: defaults)
        XCTAssertEqual(reopened.navigationPositions["book"]?.pixelFingerprint, "stable-pixels")
        XCTAssertEqual(reopened.navigationPositions["book"]?.progressLabel, "Location 1892")
        XCTAssertNil(reopened.listeningAnchor(for: "book"), "Looking at a page is not listening to it")
    }

    func testLatestNavigationRejectsOldPageAndOldAudioCallbacks() throws {
        let store = KindleLibraryStore(defaults: defaults)
        let old = try XCTUnwrap(store.beginNavigation(bookID: "book", boundary: store.positionStorageGeneration))
        let latest = try XCTUnwrap(store.beginNavigation(bookID: "book", boundary: store.positionStorageGeneration))
        XCTAssertFalse(store.confirmNavigation(bookID: "book", id: old.id,
            pageKey: "old", pixelFingerprint: "old-pixels", progressLabel: nil, readerURL: nil))
        let anchor = KindleListeningAnchor(bookId: "book", pageKey: "new", pageTextHash: "hash",
            paragraphIndex: 0, wordIndex: 0, charOffset: 0, anchorPhrase: "Fixture", anchorWordOffset: 0,
            voice: "fixture", speed: 1, updatedAt: Date(timeIntervalSince1970: 1_700_000_000), schemaVersion: 1, readerImplementationVersion: 1)
        XCTAssertFalse(store.saveListeningAnchor(anchor, navigationID: old.id))
        XCTAssertFalse(store.saveListeningAnchor(anchor))
        XCTAssertEqual(store.navigationPositions["book"]?.id, latest.id)
        XCTAssertTrue(store.saveListeningAnchor(anchor, navigationID: latest.id))
        let reopened = KindleLibraryStore(defaults: defaults)
        XCTAssertNil(reopened.navigationPositions["book"])
        XCTAssertEqual(reopened.listeningAnchor(for: "book"), anchor)
    }

    func testAccountBoundaryRejectsOldNavigationIntent() throws {
        let store = KindleLibraryStore(defaults: defaults)
        let boundary = store.positionStorageGeneration
        store.deactivateAccountScope()
        XCTAssertNil(store.beginNavigation(bookID: "book", boundary: boundary))
        XCTAssertTrue(store.navigationPositions.isEmpty)
    }

    func testYesAndNoEachReadTheChosenPageDespiteAnOldCheckpoint() async throws {
        for choice in ["yes", "no"] {
            let fixture = try await makeFixture()
            defer { fixture.close() }
            try await send(fixture.model, "sendSync(true)")
            try await wait { fixture.model.isKindleSyncDialogVisible }
            try await send(fixture.model, "choose('\(choice)'); sendSync(false)")
            try await wait {
                fixture.store.navigationPositions[fixture.book.id]?.pixelFingerprint == "chosen-\(choice)"
            }
            let outcome = try await fixture.model.startCurrentMode()
            guard case .started = outcome else { return XCTFail("Play must start after \(choice)") }
            try await assertCurrentPagePlaying(fixture)
        }
    }

    func testPlayBeforeDialogChoiceAutomaticallyContinuesAfterChoice() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await send(fixture.model, "sendSync(true)")
        try await wait { fixture.model.isKindleSyncDialogVisible }
        guard case .deferred = try await fixture.model.startCurrentMode() else { return XCTFail("Wait for the choice") }
        try await send(fixture.model, "choose('yes'); sendSync(false)")
        try await assertCurrentPagePlaying(fixture)
    }

    func testPlayFallsBackToCurrentPageWhenOldExactCursorCannotBeLocated() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        guard case .started = try await fixture.model.startCurrentMode() else { return XCTFail("Current page must remain playable") }
        try await assertCurrentPagePlaying(fixture)
    }

    func testPausedGestureSavesNewestPageWithoutStartingSpeech() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await send(fixture.model, "gesture('1'); gesture('2'); settled('1','old'); settled('2','new')")
        try await wait { fixture.store.navigationPositions[fixture.book.id]?.pixelFingerprint == "new" }
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
        let inputs = await fixture.speech.inputs
        XCTAssertTrue(inputs.isEmpty)
        let reopened = KindleLibraryStore(defaults: defaults)
        XCTAssertEqual(reopened.navigationPositions[fixture.book.id]?.pageKey, "new")
        XCTAssertEqual(reopened.navigationPositions[fixture.book.id]?.pixelFingerprint, "new")
    }

    private struct Fixture {
        let model: KindleBookViewModel
        let book: KindleBook
        let store: KindleLibraryStore
        let speech: NavigationSpeechFixture
        let window: UIWindow
        let previousWindow: UIWindow?
        @MainActor func close() {
            model.destroy()
            model.webView.removeFromSuperview()
            window.isHidden = true
            previousWindow?.makeKey()
        }
    }

    private func makeFixture() async throws -> Fixture {
        let book = KindleBook(id: "book-" + UUID().uuidString, asin: "B000000001",
            title: "Navigation fixture", author: "", coverURL: nil,
            readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "",
            storefrontID: "us", lastOpenedAt: nil, lastSyncedAt: Date(), lastReadPageKey: nil, lastReadURL: nil)
        let store = KindleLibraryStore(defaults: defaults)
        let history = HistoryStore(directory: directory)
        history.recordKindleBook(book, language: "en")
        let old = [ReadingParagraph(id: 0, text: "An entirely different old page.")]
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: old).checkpoint(
            sourceKind: .kindle, paragraphIndex: 0, audio: nil))
        XCTAssertTrue(history.saveReadingCheckpoint(checkpoint, for: book.id, boundary: history.progressBoundaryToken))
        let model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent(), libraryStore: store, historyStore: history)
        let speech = NavigationSpeechFixture()
        model.readSpeechGeneratorForTesting = speech
        model.startDocumentPreparationForTesting = {
            ReadingDocument(title: "Current", sourceKind: .kindle, language: "en",
                paragraphs: [ReadingParagraph(id: 0, text: "Read the currently chosen page.")])
        }
        model.syncDialogReadinessForTesting = {}
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.rootViewController!.view.addSubview(model.webView)
        model.webView.frame = window.bounds
        // Only page preparation and speech are fixtures. Messages travel through
        // WK's installed handler into the production sync/navigation/start paths.
        model.webView.navigationDelegate = nil
        model.webView.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none';script-src 'unsafe-inline'">
        <script>
        let page='current';
        window.__crKindleState=()=>JSON.stringify({key:page,pixelFingerprint:page,progress:'Location 1892'});
        window.__crKindleLiveClear=()=>JSON.stringify({ok:true});
        window.sendSync=visible=>webkit.messageHandlers.castReaderKindle.postMessage({type:'kindle-sync-dialog',visible,localLocation:1892,cloudLocation:1866});
        window.choose=choice=>{page='chosen-'+choice;webkit.messageHandlers.castReaderKindle.postMessage({type:'kindle-sync-dialog-choice',visible:true,choice,localLocation:1892,cloudLocation:1866});};
        window.gesture=id=>webkit.messageHandlers.castReaderKindle.postMessage({type:'kindle-user-page-gesture',direction:'left',gestureID:id});
        window.settled=(id,key)=>webkit.messageHandlers.castReaderKindle.postMessage({type:'kindle-user-page-settled',gestureID:id,key,pixelFingerprint:key,progress:'Location 1892'});
        window.fixtureReady=true;
        </script>
        """, baseURL: URL(string: book.readerURL))
        for _ in 0..<100 {
            if (try? await model.webView.evaluateJavaScript("window.fixtureReady")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let ready = (try? await model.webView.evaluateJavaScript("window.fixtureReady")) as? Bool
        XCTAssertEqual(ready, true)
        return Fixture(model: model, book: book, store: store, speech: speech, window: window, previousWindow: previous)
    }

    private func assertCurrentPagePlaying(_ fixture: Fixture) async throws {
        try await wait { fixture.model.readVM?.isPlaying == true && AudioPlayerService.shared.hasAudibleProgress }
        XCTAssertNil(fixture.model.readVM?.resumeNotice)
        XCTAssertEqual(AudioPlayerService.shared.currentBookId, fixture.book.id)
        let inputs = await fixture.speech.inputs
        XCTAssertEqual(inputs.first, "Read the currently chosen page.")
        fixture.model.pauseReadPlayback()
    }

    private func send(_ model: KindleBookViewModel, _ script: String) async throws {
        _ = try await model.webView.evaluateJavaScript(script + "; true")
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(7)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(condition())
    }
}
