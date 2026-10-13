import WebKit
import XCTest
@testable import CastReader

@MainActor
final class GoogleBooksBindingRecoveryTests: XCTestCase {
#if DEBUG
    func testLoginPollingCannotRewindAHundredBookScanStartedByDidFinish() async throws {
        let hiddenShelf = GoogleBooksWebScripts.debugHundredBookShelfFixture
            .replacingOccurrences(of: "<gpb-library-home>", with: "<gpb-library-home style=\"display:none\">")
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { view, _ in
                view.loadHTMLString(hiddenShelf, baseURL: GoogleBooksWebScripts.shelfURL)
            },
            signInURLResolver: { _ in nil }
        )
        prepare(model.webView)
        let delayed = DelayedCommitDelegate(model: model, forwardsCommit: true)
        model.webView.navigationDelegate = delayed
        defer { model.stop() }
        model.loadIfNeeded()
        let pollingStarted = await waitUntil {
            delayed.finishedNavigation != nil
                && model.bindingPhase == .awaitingShelf
                && model.statusText == AppLocalized("正在检测书架中的书籍，请稍候。")
                && !model.isScanning
        }
        XCTAssertTrue(pollingStarted, "The committed account shell must start login polling before didFinish")
        let finish = try XCTUnwrap(delayed.finishedNavigation)
        _ = try await model.webView.evaluateJavaScript("""
        (function () {
          var shelf = document.getElementById('shelf');
          var scroll = Object.getOwnPropertyDescriptor(Element.prototype, 'scrollTop');
          window.__testShelfRewinds = 0;
          Object.defineProperty(shelf, 'scrollTop', {
            get: function () { return scroll.get.call(this); },
            set: function (position) {
              if (scroll.get.call(this) > 4 && position < scroll.get.call(this) - 4) {
                window.__testShelfRewinds += 1;
              }
              scroll.set.call(this, position);
            }
          });
          document.querySelector('gpb-library-home').style.display = 'block';
          return true;
        })()
        """)
        model.webView.navigationDelegate = model
        model.webView(model.webView, didFinish: finish)

        // The independent document observer starts scanning while the earlier
        // one-second login poll is still scheduled. Its session probe must
        // not rewind this virtual shelf after the first viewport was read.
        let passedFirstWindow = await waitUntil(timeout: 4) {
            model.isScanning && model.availableCount > 4
        }
        XCTAssertTrue(passedFirstWindow)
        let complete = await waitUntil(timeout: 22) {
            model.bindingPhase == .ready && !model.isScanning
        }
        XCTAssertTrue(complete)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.availableCount, 100)
        let rewinds = try await model.webView.evaluateJavaScript("window.__testShelfRewinds")
        XCTAssertEqual((rewinds as? NSNumber)?.intValue, 0, "A stale login probe must not reset an active scan to the first window")
        let renderedCount = try await model.webView.evaluateJavaScript("window.__castreaderGoogleBooksHundredFixture.seenVolumeIDs.length")
        XCTAssertEqual((renderedCount as? NSNumber)?.intValue, 100)
    }
#endif

    func testDelayedRealShelfCardsCannotFinishAsAnEmptyLibraryBeforeHydration() async throws {
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { view, _ in
                view.loadHTMLString(Self.delayedShelfShell, baseURL: GoogleBooksWebScripts.shelfURL)
            },
            signInURLResolver: { _ in nil }
        )
        prepare(model.webView)
        defer { model.stop() }
        model.loadIfNeeded()
        let documentFinished = await waitUntil {
            model.isScanning && !model.webView.isLoading
        }
        XCTAssertTrue(documentFinished)
        let cardsJSON = String(decoding: try JSONEncoder().encode(Self.delayedShelfCards), as: UTF8.self)
        _ = try await model.webView.evaluateJavaScript("""
        setTimeout(function () {
            document.getElementById('delayed-cards').innerHTML = \(cardsJSON);
        }, 8000); true
        """)

        // Real Google Books can finish navigation before its shelf data is
        // rendered. Seven seconds of quiet empty DOM is not an empty shelf.
        let quietDeadline = ProcessInfo.processInfo.systemUptime + 7
        while ProcessInfo.processInfo.systemUptime < quietDeadline {
            XCTAssertNotEqual(model.bindingPhase, .ready)
            XCTAssertFalse(model.canSyncLibrary)
            XCTAssertFalse(model.showsSyncAction)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let hydrated = await waitUntil(timeout: 6) {
            model.bindingPhase == .ready && model.availableCount == 2
        }
        XCTAssertTrue(hydrated, "The same native scan must collect both late cards instead of completing with zero")
        XCTAssertNil(model.errorText)
        let cardCount = try await model.webView.evaluateJavaScript("document.querySelectorAll('gpb-volume-card').length")
        XCTAssertEqual((cardCount as? NSNumber)?.intValue, 2)
    }

    func testReturningFromCredentialsReloadsAHydratingShelfOnlyOnce() async throws {
        var shelfRequests = 0
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { view, request in
                let credential = GoogleBooksBindingFlowContract.isGoogleCredentialURL(request.url)
                if request.url == GoogleBooksWebScripts.shelfURL { shelfRequests += 1 }
                return view.loadHTMLString(
                    credential ? Self.credentials : Self.hydratingShelf,
                    baseURL: request.url
                )
            },
            signInURLResolver: { _ in GoogleBooksWebScripts.signInURL }
        )
        prepare(model.webView)
        defer { model.stop() }
        model.openSignIn()
        let credentialsLoaded = await waitUntil { model.bindingPhase == .signingIn && !model.webView.isLoading }
        XCTAssertTrue(credentialsLoaded)
        let hasForm = try await model.webView.evaluateJavaScript("!!document.querySelector('input[type=password]')")
        XCTAssertTrue((hasForm as? Bool) == true)

        // Model the official return using a local document. The requested
        // shelf remains visibly hydrating for multiple observer/poll passes.
        _ = model.webView.loadHTMLString(Self.hydratingShelf, baseURL: GoogleBooksWebScripts.shelfURL)
        let returnedToShelf = await waitUntil { shelfRequests == 1 }
        XCTAssertTrue(returnedToShelf)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertEqual(shelfRequests, 1, "A slow shelf must not repeatedly consume the credential return")
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.errorText)
    }

    func testCancellingCredentialPopupDoesNotReloadTheSignedOutOpener() async throws {
        var requests = 0
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { view, request in
                requests += 1
                return view.loadHTMLString(Self.signedOutShelf, baseURL: request.url)
            },
            signInURLResolver: { _ in GoogleBooksWebScripts.signInURL }
        )
        prepare(model.webView)
        model.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        defer { model.stop() }
        model.loadIfNeeded()
        let openerLoaded = await waitUntil {
            requests == 1 && !model.webView.isLoading && model.bindingPhase == .needsSignIn
        }
        XCTAssertTrue(openerLoaded)
        let credentialsJSON = String(decoding: try JSONEncoder().encode(Self.credentials), as: UTF8.self)
        _ = try await model.webView.evaluateJavaScript("""
        var loginPopup = window.open('about:blank', 'cancel-google-credential-popup');
        loginPopup.document.open();
        loginPopup.document.write(\(credentialsJSON));
        loginPopup.document.close();
        true
        """)
        let popupOpened = await waitUntil { model.popupWebView != nil }
        XCTAssertTrue(popupOpened)
        let popup = try XCTUnwrap(model.popupWebView)
        prepare(popup)
        let credentialsVisible = await waitUntil { model.bindingPhase == .signingIn }
        XCTAssertTrue(credentialsVisible)
        let hasPassword = try await popup.evaluateJavaScript("!!document.querySelector('input[type=password]')")
        XCTAssertEqual(hasPassword as? Bool, true)

        model.closePopup()
        let openerNeedsSignIn = await waitUntil {
            model.popupWebView == nil && model.bindingPhase == .needsSignIn
        }
        XCTAssertTrue(openerNeedsSignIn)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(model.activeWebView === model.webView)
        XCTAssertEqual(model.bindingPhase, .needsSignIn)
        XCTAssertEqual(requests, 1, "Cancelling a credential popup is not successful authorization and must not navigate its opener")
        XCTAssertFalse(model.isScanning)
        XCTAssertFalse(model.canSyncLibrary)
        XCTAssertNil(model.errorText)
    }

    func testCoveredOpenerCommitIsProbedAfterThePopupCloses() async throws {
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { view, _ in
                view.loadHTMLString(Self.readyShelf, baseURL: GoogleBooksWebScripts.shelfURL)
            },
            signInURLResolver: { _ in nil }
        )
        prepare(model.webView)
        model.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let delayed = DelayedCommitDelegate(model: model)
        model.webView.navigationDelegate = delayed
        defer { model.stop() }
        model.loadIfNeeded()
        let openerLoaded = await waitUntil { delayed.finishedNavigation != nil }
        XCTAssertTrue(openerLoaded)

        // WebKit created a real local document, but its commit callback is
        // delivered only after a new popup has covered this opener.
        _ = try await model.webView.evaluateJavaScript("window.open('about:blank', 'binding-recovery-popup'); true")
        let popupOpened = await waitUntil { model.popupWebView != nil }
        XCTAssertTrue(popupOpened)
        let popup = try XCTUnwrap(model.popupWebView)
        model.webView.navigationDelegate = model
        delayed.deliverCommitAndFinish(in: model.webView)
        XCTAssertTrue(model.activeWebView === popup)
        XCTAssertEqual(model.availableCount, 0, "A covered opener must not replace the active popup's state")

        model.closePopup()
        XCTAssertTrue(model.activeWebView === model.webView)
        let openerScanned = await waitUntil(timeout: 10) {
            model.bindingPhase == .ready && model.availableCount == 1
        }
        XCTAssertTrue(openerScanned, "Closing the popup must probe the opener that committed while covered")
        XCTAssertNil(model.errorText)
    }

    func testRetiredNavigationCallbacksCannotReplaceANewerReadyShelf() async throws {
        var firstNavigation: WKNavigation?
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { view, request in
                let navigation = view.loadHTMLString(Self.credentials, baseURL: request.url)
                firstNavigation = navigation
                return navigation
            },
            signInURLResolver: { _ in GoogleBooksWebScripts.signInURL }
        )
        prepare(model.webView)
        defer { model.stop() }
        model.openSignIn()
        let credentialsLoaded = await waitUntil { firstNavigation != nil && model.bindingPhase == .signingIn && !model.webView.isLoading }
        XCTAssertTrue(credentialsLoaded)
        let retired = try XCTUnwrap(firstNavigation)
        _ = model.webView.loadHTMLString(Self.readyShelf, baseURL: GoogleBooksWebScripts.shelfURL)
        let shelfScanned = await waitUntil(timeout: 10) {
            model.bindingPhase == .ready && model.availableCount == 1
        }
        XCTAssertTrue(shelfScanned)

        // Reordered callbacks from the earlier credential navigation may
        // arrive after this shelf has already finished its complete scan.
        model.webView(model.webView, didStartProvisionalNavigation: retired)
        model.webView(model.webView, didCommit: retired)
        model.webView(model.webView, didFinish: retired)
        model.webView(
            model.webView, didFailProvisionalNavigation: retired,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        await Task.yield()
        XCTAssertEqual(model.bindingPhase, .ready)
        XCTAssertEqual(model.availableCount, 1)
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.errorText)
    }

    private func prepare(_ view: WKWebView) {
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
    }

    private func waitUntil(
        timeout: TimeInterval = 6,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// Hold only the completion callbacks so the test can reproduce an
    /// opener finishing underneath a popup without depending on networking.
    private final class DelayedCommitDelegate: NSObject, WKNavigationDelegate {
        weak var model: GoogleBooksLibrarySyncViewModel?
        private let forwardsCommit: Bool
        private var committedNavigation: WKNavigation?
        private(set) var finishedNavigation: WKNavigation?

        init(model: GoogleBooksLibrarySyncViewModel, forwardsCommit: Bool = false) {
            self.model = model
            self.forwardsCommit = forwardsCommit
        }

        func webView(
            _ view: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let model else { decisionHandler(.cancel); return }
            model.webView(view, decidePolicyFor: action, decisionHandler: decisionHandler)
        }

        func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model?.webView(view, didStartProvisionalNavigation: navigation)
        }

        func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
            committedNavigation = navigation
            if forwardsCommit { model?.webView(view, didCommit: navigation) }
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            finishedNavigation = navigation
        }

        func deliverCommitAndFinish(in view: WKWebView) {
            if let committedNavigation { model?.webView(view, didCommit: committedNavigation) }
            if let finishedNavigation { model?.webView(view, didFinish: finishedNavigation) }
        }
    }

    private static let credentials = """
    <!doctype html><html><body>
      <form><label>Email<input type="email" autocomplete="username"></label>
      <label>Password<input type="password" autocomplete="current-password"></label></form>
    </body></html>
    """

    private static let hydratingShelf = """
    <!doctype html><html><body><main aria-busy="true"><p>Loading your library…</p></main></body></html>
    """

    private static let signedOutShelf = """
    <!doctype html><html><body>
      <header><a href="https://accounts.google.com/ServiceLogin">Sign in</a></header>
      <p>Sign in to view your Google Play Books library.</p>
    </body></html>
    """

    private static let readyShelf = """
    <!doctype html><html><body>
      <header><button data-email="binding-recovery@example.invalid">Account</button></header>
      <main><div role="listitem"><a title="Synthetic recovery book" href="/books/reader?id=GBLOCAL001">Synthetic recovery book</a></div></main>
    </body></html>
    """

    private static let delayedShelfShell = """
    <!doctype html><html><body>
      <header><button data-email="delayed-shelf@example.invalid">Account</button></header>
      <gpb-library-home style="display:block">
        <gpb-shelf-page style="display:block;min-height:100px">
          <div id="delayed-cards" class="-gb-book-card-grid"></div>
        </gpb-shelf-page>
      </gpb-library-home>
    </body></html>
    """

    private static let delayedShelfCards = (1...2).map { number in
        """
        <gpb-volume-card style="display:block"><div class="card ebook">
          <div class="cover"><img aria-hidden="true" alt="" width="40" height="60"></div>
          <div class="below-cover"><div class="bottompanel"><div class="metadata">
            <a class="title" title="Synthetic delayed book \(number)" href="/books/reader?id=GBDELAY00\(number)">Synthetic delayed book \(number)</a>
            <a class="author" title="Synthetic Author">Synthetic Author</a>
          </div></div></div>
        </div></gpb-volume-card>
        """
    }.joined()
}
