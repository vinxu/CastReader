import WebKit
import XCTest
@testable import CastReader

/// Local WKWebView fixtures cover both the legacy listitem/data-volume contract
/// and the Google custom-element/card structure observed on 2026-09-06. Account
/// identity is always synthetic; the 100-book fixture has no real book content.
@MainActor
final class GoogleBooksShelfWebTests: XCTestCase {
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Error>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private var webView: WKWebView?
    private var navigationWaiter: NavigationWaiter?
    private let accountHTML = "<header><button data-email=\"synthetic-googlebooks@example.invalid\">Synthetic account</button></header>"
    private let bookHTML = "<div role=\"listitem\"><a title=\"Synthetic Google Book\" href=\"/books/reader?id=GBFIX0001\">Synthetic Google Book</a></div>"

    override func tearDown() async throws {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        navigationWaiter = nil
        try await super.tearDown()
    }

    func testNarrowVirtualShelfUsesOverlappingViewportSteps() async throws {
        let view = try await load(GoogleBooksWebScripts.debugHundredBookShelfFixture)
        let raw = try await scan(view)
        XCTAssertEqual(raw["scrollPosition"] as? Double, 0)
        XCTAssertEqual(raw["viewportHeight"] as? Double, 180)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
        let actualTop = try await view.evaluateJavaScript("document.getElementById('shelf').scrollTop")
        let top = try XCTUnwrap((actualTop as? NSNumber)?.doubleValue)
        XCTAssertGreaterThan(top, 0)
        XCTAssertLessThan(top, 180, "The former minimum 520px jump skipped virtual rows on phones")
    }

    func testHundredAsynchronouslyVirtualizedBooksAreAllObservedBeforeCompletion() async throws {
        let view = try await load(GoogleBooksWebScripts.debugHundredBookShelfFixture)
        let legacySurfaceCount = try await view.evaluateJavaScript("document.querySelectorAll('main,[role=main],[role=list],[role=grid]').length")
        XCTAssertEqual(legacySurfaceCount as? Int, 0, "All 100 rows use the observed Google custom-element card structure")
        var books: [String: GoogleBooksBook] = [:]
        var completed = false
        var samples = 0
        var previousPosition = 0.0
        for _ in 0..<180 {
            let raw = try await scan(view)
            samples += 1
            if raw["hasPendingWork"] as? Bool != true {
                let position = (raw["scrollPosition"] as? NSNumber)?.doubleValue ?? -1
                let viewport = (raw["viewportHeight"] as? NSNumber)?.doubleValue ?? 0
                XCTAssertGreaterThanOrEqual(position + 1, previousPosition)
                XCTAssertLessThanOrEqual(position - previousPosition, viewport + 1)
                previousPosition = position
                let result = GoogleBooksScanResult(raw)
                XCTAssertTrue(result.authenticated)
                for book in result.books { books[book.id] = book }
            }
            if raw["isCompleteSnapshot"] as? Bool == true {
                completed = true
                break
            }
            try await waitForRendering(in: view)
        }
        XCTAssertTrue(completed)
        XCTAssertGreaterThan(samples, 24, "This fixture intentionally exceeds the old 24-pass ceiling")
        XCTAssertEqual(books.count, 100)
        XCTAssertEqual(Set(books.keys), Set((1...100).map { "googlebooks:" + String(format: "GBFIX%04d", $0) }))
        XCTAssertEqual(books["googlebooks:GBFIX0001"]?.title, "Google 合成测试书 001")
        XCTAssertEqual(books["googlebooks:GBFIX0100"]?.title, "Google 合成测试书 100")
        XCTAssertTrue(books.values.allSatisfy { $0.author == "Synthetic Google Author" })
    }

    func testScrollWaitsForNewVirtualCardsEvenWhenTheLoadingMarkerDisappearsEarly() async throws {
        let view = try await load(GoogleBooksWebScripts.debugHundredBookShelfFixture)
        _ = try await view.evaluateJavaScript("window.__castreaderGoogleBooksHundredFixture.stallRendering = true")
        let first = try await scan(view)
        try await waitForRendering(in: view)
        let movedTop = try await view.evaluateJavaScript("document.getElementById('shelf').scrollTop") as? NSNumber
        // Simulate a list that removes its spinner before the rows hydrate.
        _ = try await view.evaluateJavaScript("document.getElementById('shelf').removeAttribute('aria-busy')")
        for _ in 0..<3 {
            let waiting = try await scan(view)
            XCTAssertEqual(waiting["pageFingerprint"] as? String, first["pageFingerprint"] as? String)
            XCTAssertEqual(waiting["hasPendingWork"] as? Bool, true)
            XCTAssertEqual(waiting["isCompleteSnapshot"] as? Bool, false)
            let top = try await view.evaluateJavaScript("document.getElementById('shelf').scrollTop") as? NSNumber
            XCTAssertEqual(top, movedTop, "Do not scroll past an unobserved virtual window")
        }
        _ = try await view.evaluateJavaScript("window.__castreaderGoogleBooksHundredFixture.finishPendingRender()")
        let resumed = try await scan(view)
        XCTAssertNotEqual(resumed["pageFingerprint"] as? String, first["pageFingerprint"] as? String)
        XCTAssertEqual(resumed["hasPendingWork"] as? Bool, false)
    }

    func testSessionProbeRewindsTheHundredBookShelfWithoutConsumingItsFirstWindow() async throws {
        let view = try await load(GoogleBooksWebScripts.debugHundredBookShelfFixture)
        _ = try await view.evaluateJavaScript("document.getElementById('shelf').scrollTop = 5820")
        try await waitForRendering(in: view)
        let value = try await view.evaluateJavaScript(GoogleBooksWebScripts.sessionProbe)
        let probe = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(probe["authenticated"] as? Bool, true)
        XCTAssertEqual(probe["scrollPosition"] as? Double, 0)
        XCTAssertEqual(probe["isCompleteSnapshot"] as? Bool, false)
        try await waitForRendering(in: view)
        let first = GoogleBooksScanResult(try await scan(view))
        XCTAssertEqual(first.books.first?.volumeID, "GBFIX0001")
    }

    func testNearestListScrollerWinsOverALargerOuterScroller() async throws {
        let view = try await loadDocument(
            accountHTML + """
            <div id="outer" style="height:220px;overflow-y:auto"><div style="height:3200px">
              <main id="inner" style="height:140px;overflow-y:auto">
                <div style="height:900px">\(bookHTML)</div>
              </main>
            </div></div>
            """
        )
        _ = try await scan(view)
        let inner = try await view.evaluateJavaScript("document.getElementById('inner').scrollTop") as? NSNumber
        let outer = try await view.evaluateJavaScript("document.getElementById('outer').scrollTop") as? NSNumber
        XCTAssertGreaterThan(inner?.doubleValue ?? 0, 0)
        XCTAssertEqual(outer?.doubleValue, 0)
    }

    func testNestedBusyAndVisibleIndeterminateSpinnerPreventCompletion() async throws {
        let view = try await loadDocument(accountHTML + "<main><div id=\"list\" role=\"list\" aria-busy=\"true\">\(bookHTML)</div></main>")
        let busy = try await scan(view)
        XCTAssertEqual(busy["hasPendingWork"] as? Bool, true)
        XCTAssertEqual(busy["isCompleteSnapshot"] as? Bool, false)
        _ = try await view.evaluateJavaScript(
            """
            document.getElementById('list').removeAttribute('aria-busy');
            document.querySelector('main').insertAdjacentHTML('beforeend', '<div id="spinner" role="progressbar">Loading</div>');
            """
        )
        let spinner = try await scan(view)
        XCTAssertEqual(spinner["hasPendingWork"] as? Bool, true)
        _ = try await view.evaluateJavaScript(
            """
            document.getElementById('spinner').hidden = true;
            document.querySelector('[role="listitem"]').insertAdjacentHTML('beforeend', '<span role="progressbar" aria-valuenow="42">42%</span>');
            """
        )
        let settled = try await scan(view)
        XCTAssertEqual(settled["hasPendingWork"] as? Bool, false)
        XCTAssertEqual(settled["isCompleteSnapshot"] as? Bool, true)
    }

    func testInteractiveTrustedShelfDoesNotWaitForUnrelatedResourcesButLoadingDocumentCannotComplete() async throws {
        let view = try await loadDocument(accountHTML + "<main>\(bookHTML)</main>")
        _ = try await view.evaluateJavaScript("Object.defineProperty(document, 'readyState', { configurable: true, get: function () { return 'interactive'; } }); true;")
        let interactive = try await scan(view)
        XCTAssertEqual(interactive["isDocumentReady"] as? Bool, true)
        XCTAssertEqual(interactive["hasShelfSurface"] as? Bool, true)
        XCTAssertEqual(interactive["isCompleteSnapshot"] as? Bool, true)
        _ = try await view.evaluateJavaScript("Object.defineProperty(document, 'readyState', { configurable: true, get: function () { return 'loading'; } }); true;")
        let loading = try await scan(view)
        XCTAssertEqual(loading["isDocumentReady"] as? Bool, false)
        XCTAssertEqual(loading["hasPendingWork"] as? Bool, true)
        XCTAssertEqual(loading["isCompleteSnapshot"] as? Bool, false)
    }

    func testVisibleCredentialFormOverridesResidualAccountAndBookCardsWithoutReadingPassword() async throws {
        let view = try await loadDocument(accountHTML + "<main>\(bookHTML)<form><input type=\"password\" value=\"synthetic-private-password\"></form></main>")
        _ = try await view.evaluateJavaScript(
            """
            window.__fixturePasswordReads = 0;
            Object.defineProperty(document.querySelector('input'), 'value', { get: function () {
              window.__fixturePasswordReads += 1; return 'synthetic-private-password';
            } });
            true;
            """
        )
        let raw = try await scan(view)
        XCTAssertEqual(raw["hasCredentialForm"] as? Bool, true)
        XCTAssertEqual(raw["authenticated"] as? Bool, false)
        XCTAssertEqual(raw["authRequired"] as? Bool, true)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
        let reads = try await view.evaluateJavaScript("window.__fixturePasswordReads")
        XCTAssertEqual(reads as? Int, 0)
        XCTAssertFalse(String(describing: raw).contains("synthetic-private-password"))
    }

    func testReaderLinksMustUseTheExactGoogleOriginAndOneVolumeID() async throws {
        let urls = [
            "https://evil.example/books/reader?id=EVIL0001",
            "https://play.google.com.evil.example/books/reader?id=EVIL0002",
            "http://play.google.com/books/reader?id=EVIL0003",
            "https://user@play.google.com/books/reader?id=EVIL0004",
            "https://play.google.com/books/reader?id=EVIL0005&id=OTHER001",
            "https://play.google.com/books/reader/extra?id=EVIL0006",
        ]
        let invalidCards = urls.map { "<div role=\"listitem\"><a title=\"Forged\" href=\"\($0)\">Forged</a></div>" }.joined()
        let view = try await loadDocument(accountHTML + "<main>\(bookHTML)\(invalidCards)</main>")
        let result = GoogleBooksScanResult(try await scan(view))
        XCTAssertEqual(result.books.map(\.volumeID), ["GBFIX0001"])
    }

    func testUnsupportedPaginationCannotBeReportedAsACompleteSinglePage() async throws {
        let view = try await loadDocument(accountHTML + """
            <main>\(bookHTML)<nav aria-label="Pagination">
              <a href="?page=1" aria-current="page">1</a><a href="?page=2">2</a><a rel="next" href="?page=2">Next</a>
            </nav></main>
            """)
        let raw = try await scan(view)
        XCTAssertEqual(raw["hasUnsupportedPagination"] as? Bool, true)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
    }

    func testGenericAccountArtworkDoesNotBecomeASharedAccountIdentity() async throws {
        let view = try await loadDocument("<header><img class=\"gb_P\" alt=\"Google Account\"></header><main>\(bookHTML)</main>")
        let raw = try await scan(view)
        XCTAssertEqual(raw["accountIdentitySource"] as? String, "")
        XCTAssertNil(GoogleBooksScanResult(raw).account?.identity)
    }

    func testAccountIdentityIgnoresGenericArtworkAndLocalizedLabelParentheses() async throws {
        let view = try await loadDocument("""
          <header><img class="gb_P" alt="Google Account">
            <a id="account" href="https://accounts.google.com/SignOutOptions" aria-label="Google Account: Synthetic (Reader+Tag@Example.Invalid)">Account</a>
          </header><main>\(bookHTML)</main>
        """)
        let first = try await scan(view)
        XCTAssertEqual(first["accountIdentitySource"] as? String, "reader+tag@example.invalid")
        XCTAssertEqual(GoogleBooksScanResult(first).account?.identity, GoogleBooksAccountIdentity.hash("reader+tag@example.invalid"))
        _ = try await view.evaluateJavaScript("document.getElementById('account').setAttribute('aria-label', 'Google 帐号：合成用户（Reader+Tag@Example.Invalid）'); true;")
        let localized = try await scan(view)
        XCTAssertEqual(localized["accountIdentitySource"] as? String, first["accountIdentitySource"] as? String)
    }

    func testObservedGoogleCustomElementsRecognizeBothBooksAndDecorativeCoverImages() async throws {
        let firstCover = "https://play.google.com/books/publisher/content/images/frontcover/b_40EQAAQBAJ?w=300&usc=0"
        let secondCover = "https://play.google.com/books/publisher/content/images/frontcover/QrpAEQAAQBAJ?w=300&usc=0"
        let cards = observedGoogleCard(id: "b_40EQAAQBAJ", title: "The Enchanted Isles", cover: firstCover)
            + observedGoogleCard(id: "QrpAEQAAQBAJ", title: "Sasha's Secret Life", cover: secondCover)
        let view = try await loadObservedGoogleShelf(cards)
        let semanticSurfaceCount = try await view.evaluateJavaScript("document.querySelectorAll('main,[role=main],[role=list],[role=grid]').length")
        XCTAssertEqual(semanticSurfaceCount as? Int, 0, "The real page has none of the previous shelf-surface selectors")
        let raw = try await scan(view)
        let result = GoogleBooksScanResult(raw)
        XCTAssertTrue(result.hasShelfSurface)
        XCTAssertTrue(result.isCompleteSnapshot)
        XCTAssertEqual(raw["unrecognizedBookCandidateCount"] as? Int, 0)
        XCTAssertEqual(raw["hasExplicitEmptyShelf"] as? Bool, false)
        XCTAssertEqual(result.books.count, 2)
        let books = Dictionary(uniqueKeysWithValues: result.books.map { ($0.volumeID ?? "", $0) })
        XCTAssertEqual(books["b_40EQAAQBAJ"]?.title, "The Enchanted Isles")
        XCTAssertEqual(books["QrpAEQAAQBAJ"]?.title, "Sasha's Secret Life")
        XCTAssertEqual(books["b_40EQAAQBAJ"]?.author, "Esa Myllylä")
        XCTAssertEqual(books["b_40EQAAQBAJ"]?.coverURL, firstCover)
        XCTAssertEqual(books["QrpAEQAAQBAJ"]?.coverURL, secondCover)
    }

    func testAuthenticatedGenericSurfaceAndUnhydratedGoogleShelfCannotProveEmpty() async throws {
        let view = try await loadDocument(accountHTML + "<main><p>My library</p></main>")
        for _ in 0..<12 {
            let raw = try await scan(view)
            XCTAssertEqual(raw["authenticated"] as? Bool, true)
            XCTAssertEqual(raw["hasExplicitEmptyShelf"] as? Bool, false)
            XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
        }
        _ = try await view.evaluateJavaScript("document.querySelector('main').outerHTML = '<gpb-library-home><gpb-shelf-page style=\"display:block;height:120px\"><div class=\"-gb-book-card-grid\"></div></gpb-shelf-page></gpb-library-home>'; true;")
        let emptyShell = try await scan(view)
        XCTAssertEqual(emptyShell["hasShelfSurface"] as? Bool, true)
        XCTAssertEqual(emptyShell["hasExplicitEmptyShelf"] as? Bool, false)
        XCTAssertEqual(emptyShell["isCompleteSnapshot"] as? Bool, false)
    }

    func testExplicitEmptyShelfRequiresVisibleUncontestedStateAndNoPendingWork() async throws {
        let view = try await loadObservedGoogleShelf("<p id=\"empty\" role=\"status\" data-testid=\"empty-library\">No books yet</p>")
        let empty = try await scan(view)
        XCTAssertEqual(empty["hasExplicitEmptyShelf"] as? Bool, true)
        XCTAssertEqual(empty["isCompleteSnapshot"] as? Bool, true)
        _ = try await view.evaluateJavaScript("document.querySelector('gpb-shelf-page').setAttribute('aria-busy', 'true'); true;")
        let loading = try await scan(view)
        XCTAssertEqual(loading["hasExplicitEmptyShelf"] as? Bool, false)
        XCTAssertEqual(loading["isCompleteSnapshot"] as? Bool, false)
        _ = try await view.evaluateJavaScript("document.querySelector('gpb-shelf-page').removeAttribute('aria-busy'); document.getElementById('empty').hidden = true; true;")
        let hidden = try await scan(view)
        XCTAssertEqual(hidden["hasExplicitEmptyShelf"] as? Bool, false)
        XCTAssertEqual(hidden["isCompleteSnapshot"] as? Bool, false)
    }

    func testUnrecognizedVisibleGoogleCardCannotBeDiscardedAsAnEmptyOrCompleteShelf() async throws {
        let malformed = observedGoogleCard(id: "bad", title: "Undecodable Google card", cover: "data:image/svg+xml,")
        let view = try await loadObservedGoogleShelf("<p role=\"status\" data-testid=\"empty-library\">No books yet</p>" + malformed)
        let unknown = try await scan(view)
        XCTAssertEqual((unknown["books"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(unknown["unrecognizedBookCandidateCount"] as? Int, 1)
        XCTAssertEqual(unknown["hasExplicitEmptyShelf"] as? Bool, false)
        XCTAssertEqual(unknown["isCompleteSnapshot"] as? Bool, false)
        _ = try await view.evaluateJavaScript("document.querySelector('gpb-shelf-page').insertAdjacentHTML('beforeend', '<div role=\"listitem\"><a title=\"Valid synthetic book\" href=\"/books/reader?id=GBFIX0001\">Valid synthetic book</a></div>'); true;")
        let partial = try await scan(view)
        XCTAssertEqual((partial["books"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(partial["unrecognizedBookCandidateCount"] as? Int, 1)
        XCTAssertEqual(partial["isCompleteSnapshot"] as? Bool, false)
    }

    func testMissingTitleAndUnknownCardControlsAreReportedInsteadOfSilentlyDropped() async throws {
        let view = try await loadObservedGoogleShelf("""
          <gpb-volume-card><div class="card ebook"><a href="/books/reader?id=NOTITLE1"><img alt="" width="20" height="30"></a></div></gpb-volume-card>
          <gpb-volume-card><div class="card ebook"><img alt="Unknown book" width="20" height="30"><button data-id="not-a-supported-reader-id">Synthetic future card</button></div></gpb-volume-card>
        """)
        let raw = try await scan(view)
        XCTAssertEqual((raw["books"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(raw["unrecognizedBookCandidateCount"] as? Int, 2)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
    }

    func testUnknownVirtualCardHoldsItsViewportUntilMetadataHydrates() async throws {
        let view = try await load(GoogleBooksWebScripts.debugHundredBookShelfFixture)
        _ = try await view.evaluateJavaScript("""
          var fixtureCard = document.querySelector('gpb-volume-card');
          fixtureCard.querySelectorAll('a[href*="/books/reader"]').forEach(function (anchor) {
            anchor.dataset.fixtureHref = anchor.getAttribute('href');
            anchor.removeAttribute('href');
          });
          true;
        """)
        for _ in 0..<3 {
            let waiting = try await scan(view)
            XCTAssertEqual(waiting["unrecognizedBookCandidateCount"] as? Int, 1)
            XCTAssertEqual(waiting["isCompleteSnapshot"] as? Bool, false)
            let actualTop = try await view.evaluateJavaScript("document.getElementById('shelf').scrollTop")
            XCTAssertEqual(actualTop as? Double, 0, "Never scroll an undecoded card out of a virtual list")
        }
        _ = try await view.evaluateJavaScript("""
          document.querySelectorAll('[data-fixture-href]').forEach(function (anchor) {
            anchor.setAttribute('href', anchor.dataset.fixtureHref);
          });
          true;
        """)
        let hydrated = try await scan(view)
        XCTAssertEqual(hydrated["unrecognizedBookCandidateCount"] as? Int, 0)
        XCTAssertEqual(GoogleBooksScanResult(hydrated).books.count, 4)
        let resumedTop = try await view.evaluateJavaScript("document.getElementById('shelf').scrollTop") as? NSNumber
        XCTAssertGreaterThan(resumedTop?.doubleValue ?? 0, 0)
    }

    func testHiddenAndRecommendedCardsDoNotContaminateAnExplicitEmptyShelf() async throws {
        let card = observedGoogleCard(id: "HIDDEN01", title: "Synthetic hidden card", cover: "data:image/svg+xml,")
        let view = try await loadObservedGoogleShelf("<p role=\"status\" data-testid=\"empty-library\">No books yet</p><div hidden>\(card)</div><aside aria-label=\"Recommendations\">\(card)</aside>")
        let raw = try await scan(view)
        XCTAssertEqual(raw["unrecognizedBookCandidateCount"] as? Int, 0)
        XCTAssertEqual(raw["hasExplicitEmptyShelf"] as? Bool, true)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, true)
    }

    func testObservedProgressDropdownAndExplicitShelfSearchCannotCommitAFilteredSubset() async throws {
        let view = try await loadObservedGoogleShelf("""
          <fireball-dropdown class="progress-filter"><mat-select id="progress" role="combobox" class="mat-mdc-select mat-mdc-select-empty">
            <span class="mat-mdc-select-placeholder">进度</span>
          </mat-select></fireball-dropdown><input id="search" type="search" value="">
          \(observedGoogleCard(id: "GBFILTER01", title: "Synthetic filtered book", cover: "data:image/svg+xml,"))
        """)
        let unfiltered = try await scan(view)
        XCTAssertEqual(unfiltered["hasActiveShelfFilter"] as? Bool, false)
        XCTAssertEqual(unfiltered["isCompleteSnapshot"] as? Bool, true)
        _ = try await view.evaluateJavaScript("document.getElementById('progress').classList.remove('mat-mdc-select-empty'); document.getElementById('progress').innerHTML = '<span class=\"mat-mdc-select-value-text\">Finished</span>'; true;")
        let selected = try await scan(view)
        XCTAssertEqual(selected["hasActiveShelfFilter"] as? Bool, true)
        XCTAssertEqual(selected["isCompleteSnapshot"] as? Bool, false)
        _ = try await view.evaluateJavaScript("document.getElementById('progress').classList.add('mat-mdc-select-empty'); document.getElementById('progress').innerHTML = '<span class=\"mat-mdc-select-placeholder\">进度</span>'; document.getElementById('search').value = 'synthetic query'; true;")
        let searched = try await scan(view)
        XCTAssertEqual(searched["hasActiveShelfFilter"] as? Bool, true)
        XCTAssertEqual(searched["isCompleteSnapshot"] as? Bool, false)
        XCTAssertFalse(String(describing: searched).contains("synthetic query"))
        _ = try await view.evaluateJavaScript("document.getElementById('search').value = '  '; true;")
        let cleared = try await scan(view)
        XCTAssertEqual(cleared["hasActiveShelfFilter"] as? Bool, false)
        XCTAssertEqual(cleared["isCompleteSnapshot"] as? Bool, true)
    }

    private func observedGoogleCard(id: String, title: String, cover: String) -> String {
        // Structural excerpt of the observed card. Framework-generated CSS
        // tokens, selection/menu controls and account markup are unnecessary.
        // Real cover URLs are metadata only; the fixture CSP prevents requests.
        """
        <gpb-volume-card draggable="true"><div class="card ebook">
          <div style="display:none" id="title-\(id)">对应“\(title)”</div>
          <a aria-hidden="true" tabindex="-1" class="card-link" title="\(title)" href="/books/reader?id=\(id)"></a>
          <div class="cover"><div class="cover-image-container">
            <img alt="" aria-hidden="true" class="refresh-cover-image" src="\(cover.replacingOccurrences(of: "&", with: "&amp;"))" width="60" height="84">
            <a class="cover-link" title="\(title)" aria-label="\(title)" href="/books/reader?id=\(id)"></a>
          </div></div>
          <div class="below-cover"><div class="bottompanel"><div class="metadata">
            <a class="title" title="\(title)" href="/books/reader?id=\(id)">\(title)</a>
            <a class="author" title="Esa Myllylä" href="https://play.google.com/store/books/author?id=SyntheticAuthor">Esa Myllylä</a>
          </div></div></div>
        </div></gpb-volume-card>
        """
    }

    private func loadObservedGoogleShelf(_ cards: String) async throws -> WKWebView {
        try await loadDocument("""
          <style>gpb-library-home,gpb-shelf-page,gpb-volume-card{display:block}gpb-shelf-page{min-height:100px}.card{display:flex}.metadata{display:flex;flex-direction:column}.card-link{display:none}</style>
          <header><a href="https://accounts.google.com/SignOutOptions" aria-label="synthetic-googlebooks@example.invalid">Synthetic Google account</a></header>
          <gpb-library-home><div class="main-content"><div class="content"><gpb-shelf-page><div class="-gb-book-card-grid">\(cards)</div></gpb-shelf-page></div></div></gpb-library-home>
        """)
    }

    private func scan(_ view: WKWebView) async throws -> [String: Any] {
        let value = try await view.evaluateJavaScript(GoogleBooksWebScripts.libraryScan)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func waitForRendering(in view: WKWebView) async throws {
        _ = try await view.callAsyncJavaScript(
            "await new Promise(resolve => setTimeout(resolve, 100)); return true;",
            arguments: [:], in: nil, contentWorld: .page
        )
    }

    private func loadDocument(_ body: String) async throws -> WKWebView {
        try await load("<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"img-src data:; connect-src 'none'\"></head><body>\(body)</body></html>")
    }

    private func load(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        let waiter = NavigationWaiter()
        view.navigationDelegate = waiter
        webView = view
        navigationWaiter = waiter
        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            view.loadHTMLString(html, baseURL: GoogleBooksWebScripts.shelfURL)
        }
        return view
    }
}
