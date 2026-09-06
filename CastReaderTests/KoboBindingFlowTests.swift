//
//  KoboBindingFlowTests.swift
//  CastReaderTests
//
//  Synthetic login/shelf fixtures. No user credentials or live account data.
//

import WebKit
import XCTest
@testable import CastReader

final class KoboBindingFlowContractTests: XCTestCase {
    func testReadyCommittedShelfCanStartWithoutWaitingForOtherPageResources() {
        let probe = KoboBindingPageProbe([
            "isShelfContext": true, "hasAccountEvidence": true,
            "isBlank": false, "isLoading": false, "hasCredentialForm": false,
        ])
        XCTAssertTrue(probe.canStartShelfScan(at: KoboWebScripts.shelfURL, hasCommittedDocument: true))
        XCTAssertFalse(probe.canStartShelfScan(at: KoboWebScripts.shelfURL, hasCommittedDocument: false))
        XCTAssertFalse(probe.canStartShelfScan(at: URL(string: "https://authorize.kobo.com/signin"), hasCommittedDocument: true))
        let loading = KoboBindingPageProbe([
            "isShelfContext": true, "hasAccountEvidence": true,
            "isBlank": false, "isLoading": true, "hasCredentialForm": false,
        ])
        XCTAssertFalse(loading.canStartShelfScan(at: KoboWebScripts.shelfURL, hasCommittedDocument: true))
    }

    func testPageProbeRequiresShelfEvidenceAndNoCredentialFormOrLoading() {
        XCTAssertFalse(KoboBindingPageProbe([:]).canScanShelf)
        let trusted: [String: Any] = [
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "hasShelfBooks": true,
            "isLoading": false,
            "isBlank": false,
        ]
        XCTAssertTrue(KoboBindingPageProbe(trusted).canScanShelf)

        for key in ["hasCredentialForm", "isLoading", "isBlank"] {
            var raw = trusted
            raw[key] = true
            XCTAssertFalse(KoboBindingPageProbe(raw).canScanShelf, key)
        }
        for key in ["hasAccountEvidence", "isShelfContext"] {
            var raw = trusted
            raw[key] = false
            XCTAssertFalse(KoboBindingPageProbe(raw).canScanShelf, key)
        }
        var emptyShelf = trusted
        emptyShelf["hasShelfBooks"] = false
        XCTAssertTrue(KoboBindingPageProbe(emptyShelf).canScanShelf)
    }

    func testCredentialRoutesAreSeparateFromShelfRoutesAndUnsafeHosts() {
        let credentialRoutes = [
            "https://www.kobo.com/signin",
            "https://www.kobo.com/sg/en/login",
            "https://www.kobo.com/oauth/authorize",
            "https://accounts.google.com/v3/signin/identifier",
            "https://appleid.apple.com/auth/authorize",
        ]
        for route in credentialRoutes {
            XCTAssertTrue(KoboBindingFlowContract.isCredentialURL(URL(string: route)), route)
        }
        let otherRoutes = [
            "https://www.kobo.com/sg/en/library/books",
            "https://evil.example/signin",
            "https://www.kobo.com.evil.example/signin",
            "http://www.kobo.com/signin",
            "https://user@www.kobo.com/signin",
        ]
        for route in otherRoutes {
            XCTAssertFalse(KoboBindingFlowContract.isCredentialURL(URL(string: route)), route)
        }
        XCTAssertFalse(KoboBindingFlowContract.isCredentialURL(nil))
    }

    func testBlankPopupRequiresATrustedHTTPSOpener() {
        let trusted = URL(string: "https://www.kobo.com/signin")!
        let blank = URL(string: "about:blank")!
        XCTAssertTrue(KoboBindingFlowContract.allowsPopupBootstrap(blank, openerURL: trusted))
        XCTAssertTrue(KoboBindingFlowContract.allowsPopupBootstrap(nil, openerURL: trusted))
        for opener in [
            "https://evil.example/signin",
            "https://www.kobo.com.evil.example/signin",
            "http://www.kobo.com/signin",
            "https://user@www.kobo.com/signin",
        ] {
            XCTAssertFalse(KoboBindingFlowContract.allowsPopupBootstrap(blank, openerURL: URL(string: opener)), opener)
        }
        XCTAssertFalse(KoboBindingFlowContract.allowsPopupBootstrap(blank, openerURL: nil))
        for route in ["about:blank#unexpected", "about:srcdoc", "javascript:void(0)", "data:text/html,hello"] {
            XCTAssertFalse(KoboBindingFlowContract.allowsPopupBootstrap(URL(string: route), openerURL: trusted), route)
        }
    }

    func testBindingNavigationAllowsOnlyTheNarrowGoogleLandingException() {
        XCTAssertTrue(KoboWebScripts.allowsBindingNavigation(URL(string: "https://gds.google.com/web/landing?rapt=synthetic")))
        for route in [
            "https://gds.google.com/other",
            "https://gds.google.com/web/landing/extra",
            "http://gds.google.com/web/landing",
            "https://gds.google.com.evil.example/web/landing",
            "https://user@gds.google.com/web/landing",
            "https://gds.google.com:444/web/landing",
        ] {
            XCTAssertFalse(KoboWebScripts.allowsBindingNavigation(URL(string: route)), route)
        }
    }

    func testTrustedContinuationUnwrapsOnlyKnownGoogleRoutesToAnExactShelf() {
        let shelf = URL(string: "https://www.kobo.com/sg/en/library/books")!
        let cookie = wrapping(shelf, with: "https://accounts.google.com/CheckCookie")
        let landing = wrapping(cookie, with: "https://gds.google.com/web/landing")
        for route in [shelf, cookie, landing] {
            XCTAssertEqual(KoboBindingFlowContract.trustedShelfContinuation(route), shelf)
        }

        let rejected = [
            wrapping(URL(string: "https://evil.example/library/books")!, with: "https://accounts.google.com/CheckCookie"),
            wrapping(URL(string: "https://www.kobo.com.evil.example/sg/en/library/books")!, with: "https://gds.google.com/web/landing"),
            wrapping(URL(string: "http://www.kobo.com/sg/en/library/books")!, with: "https://accounts.google.com/CheckCookie"),
            wrapping(URL(string: "https://user@www.kobo.com/sg/en/library/books")!, with: "https://accounts.google.com/CheckCookie"),
            wrapping(URL(string: "https://www.kobo.com/sg/en/library/books/extra")!, with: "https://accounts.google.com/CheckCookie"),
            wrapping(shelf, with: "https://evil.example/CheckCookie"),
            wrapping(shelf, with: "https://gds.google.com/other"),
            wrapping(shelf, with: "https://accounts.google.com/unrelated"),
        ]
        for route in rejected {
            XCTAssertNil(KoboBindingFlowContract.trustedShelfContinuation(route), route.host ?? "invalid host")
        }
        var deeplyNested = shelf
        for _ in 0..<8 {
            deeplyNested = wrapping(deeplyNested, with: "https://accounts.google.com/CheckCookie")
        }
        XCTAssertNil(KoboBindingFlowContract.trustedShelfContinuation(deeplyNested))
        XCTAssertNil(KoboBindingFlowContract.trustedShelfContinuation(nil))
    }

    func testDiagnosticRouteLabelNeverIncludesRawPathQueryFragmentOrUserInfo() {
        let url = URL(string: "https://synthetic-user:synthetic-password@www.kobo.com/sg/en/library/books?token=synthetic-token#synthetic-fragment")!
        let label = KoboBindingFlowContract.safeRouteLabel(url)
        XCTAssertEqual(label, "www.kobo.com/other")
        for secret in ["synthetic-user", "synthetic-password", "synthetic-token", "synthetic-fragment"] {
            XCTAssertFalse(label.contains(secret))
        }
        let credentialURL = URL(string: "https://accounts.google.com/signin/synthetic-account-identifier?token=synthetic-token")!
        let credentialLabel = KoboBindingFlowContract.safeRouteLabel(credentialURL)
        XCTAssertEqual(credentialLabel, "accounts.google.com/credentials")
        XCTAssertFalse(credentialLabel.contains("synthetic-account-identifier"))
        XCTAssertFalse(credentialLabel.contains("synthetic-token"))
    }

    private func wrapping(_ destination: URL, with base: String) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "continue", value: destination.absoluteString)]
        return components.url!
    }
}

@MainActor
final class KoboBindingPageWebTests: XCTestCase {
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
    private let shelfMarkup = """
        <header><a href="/logout" data-email="reader@example.com">My account</a></header>
        <main aria-label="My books"><article data-testid="book-card">
          <h3 data-testid="book-title">Synthetic Binding Book</h3>
          <a href="https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001">Read Now</a>
        </article></main>
        """
    private let credentialMarkup = """
        <form id="credentials">
          <label>Email<input type="email" autocomplete="username" value="synthetic-private-email"></label>
          <label>Password<input type="password" autocomplete="current-password" value="synthetic-private-password"></label>
          <button type="submit" data-testid="sign-in">Sign in</button>
        </form>
        """

    override func tearDown() async throws {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        navigationWaiter = nil
        try await super.tearDown()
    }

    func testVisibleCredentialsOverrideStaleShelfAndAccountEvidenceWithoutReadingInputs() async throws {
        let view = try await load(credentialMarkup + shelfMarkup)
        _ = try await view.evaluateJavaScript(
            """
            window.__fixtureInputReads = 0;
            window.__fixtureSubmitClicks = 0;
            document.querySelectorAll('input').forEach(function (input) {
              Object.defineProperty(input, 'value', { get: function () {
                window.__fixtureInputReads += 1;
                return 'synthetic-private-value';
              } });
            });
            document.querySelector('button').addEventListener('click', function (event) {
              event.preventDefault();
              window.__fixtureSubmitClicks += 1;
            });
            """
        )
        let before = try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let raw = try await probe(view)
        let result = KoboBindingPageProbe(raw)
        XCTAssertTrue(result.hasCredentialForm)
        XCTAssertFalse(result.canScanShelf)
        let after = try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String
        XCTAssertEqual(before, after, "The binding probe must only observe the page")
        XCTAssertFalse(String(describing: raw).contains("synthetic-private"))

        let activation = try await view.evaluateJavaScript(KoboWebScripts.activateSignIn)
        XCTAssertEqual(activation as? String, "form")
        let scanValue = try await view.evaluateJavaScript(KoboWebScripts.libraryScan)
        let scan = try XCTUnwrap(scanValue as? [String: Any])
        XCTAssertEqual(scan["authenticated"] as? Bool, false)
        XCTAssertEqual(scan["authRequired"] as? Bool, true)
        XCTAssertEqual(scan["isCompleteSnapshot"] as? Bool, false)
        let reads = try await view.evaluateJavaScript("window.__fixtureInputReads")
        let clicks = try await view.evaluateJavaScript("window.__fixtureSubmitClicks")
        XCTAssertEqual(reads as? Int, 0)
        XCTAssertEqual(clicks as? Int, 0)
    }

    func testActivateSignInClicksTheVisibleControlAndIgnoresHiddenLinks() async throws {
        let view = try await load(
            """
            <main><h1>Welcome to Kobo</h1>
              <a id="hidden" style="display:none" href="/signin">Sign in</a>
              <a id="visible" href="/signin">Sign in</a>
            </main>
            <script>
              window.__fixtureHiddenClicks = 0;
              window.__fixtureVisibleClicks = 0;
              document.querySelectorAll('a').forEach(function (link) {
                link.addEventListener('click', function (event) {
                  event.preventDefault();
                  if (link.id === 'hidden') window.__fixtureHiddenClicks += 1;
                  else window.__fixtureVisibleClicks += 1;
                });
              });
            </script>
            """
        )
        let result = KoboBindingPageProbe(try await probe(view))
        XCTAssertTrue(result.hasSignInControl)
        XCTAssertFalse(result.hasCredentialForm)
        XCTAssertFalse(result.canScanShelf)
        let activation = try await view.evaluateJavaScript(KoboWebScripts.activateSignIn)
        XCTAssertEqual(activation as? String, "clicked")
        let hidden = try await view.evaluateJavaScript("window.__fixtureHiddenClicks")
        let visible = try await view.evaluateJavaScript("window.__fixtureVisibleClicks")
        XCTAssertEqual(hidden as? Int, 0)
        XCTAssertEqual(visible as? Int, 1)

        _ = try await view.evaluateJavaScript("document.getElementById('visible').remove()")
        let hiddenOnly = KoboBindingPageProbe(try await probe(view))
        XCTAssertFalse(hiddenOnly.hasSignInControl)
        let unavailable = try await view.evaluateJavaScript(KoboWebScripts.activateSignIn)
        XCTAssertEqual(unavailable as? String, "unavailable")
    }

    func testBlankDOMIsDistinctFromAVisibleSignedOutPage() async throws {
        let view = try await load("")
        let blank = KoboBindingPageProbe(try await probe(view))
        XCTAssertTrue(blank.isBlank)
        XCTAssertFalse(blank.hasSignInControl)
        XCTAssertFalse(blank.hasCredentialForm)
        XCTAssertFalse(blank.canScanShelf)

        _ = try await view.evaluateJavaScript("document.body.innerHTML = '<main><h1>Welcome</h1><a href=\"/signin\">Sign in</a></main>'")
        let signedOut = KoboBindingPageProbe(try await probe(view))
        XCTAssertFalse(signedOut.isBlank)
        XCTAssertTrue(signedOut.hasSignInControl)
        XCTAssertFalse(signedOut.canScanShelf)
    }

    func testSameURLSPATransitionFromCredentialsToShelfCanStartScanning() async throws {
        let view = try await load(credentialMarkup)
        let initialURL = view.url
        let before = KoboBindingPageProbe(try await probe(view))
        XCTAssertFalse(before.canScanShelf)
        let encoded = try JSONSerialization.data(withJSONObject: [shelfMarkup])
        let argument = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        _ = try await view.evaluateJavaScript("document.body.innerHTML = \(argument)[0]")
        let shelf = KoboBindingPageProbe(try await probe(view))
        XCTAssertEqual(view.url, initialURL)
        XCTAssertFalse(shelf.hasCredentialForm)
        XCTAssertTrue(shelf.hasAccountEvidence)
        XCTAssertTrue(shelf.isShelfContext)
        XCTAssertTrue(shelf.hasShelfBooks)
        XCTAssertTrue(shelf.canScanShelf)
    }

    func testLoadingShelfAndHiddenCredentialTemplateDoNotConfuseReadiness() async throws {
        let view = try await load("<div hidden>" + credentialMarkup + "</div>" + shelfMarkup)
        _ = try await view.evaluateJavaScript("document.querySelector('main').setAttribute('aria-busy', 'true')")
        let loading = KoboBindingPageProbe(try await probe(view))
        XCTAssertFalse(loading.hasCredentialForm)
        XCTAssertTrue(loading.isLoading)
        XCTAssertFalse(loading.canScanShelf)

        _ = try await view.evaluateJavaScript("document.querySelector('main').removeAttribute('aria-busy')")
        let ready = KoboBindingPageProbe(try await probe(view))
        XCTAssertFalse(ready.isLoading)
        XCTAssertTrue(ready.canScanShelf)
    }

    func testServerAuthenticatedMobileLibraryWorksWithACollapsedAccountMenu() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: true))
        let hiddenMenuRects = try await view.evaluateJavaScript("document.querySelector('.nav-user-account a').getClientRects().length")
        XCTAssertEqual(hiddenMenuRects as? Int, 0)
        let result = KoboBindingPageProbe(try await probe(view))
        XCTAssertFalse(result.hasCredentialForm)
        XCTAssertTrue(result.hasAccountEvidence)
        XCTAssertTrue(result.isShelfContext)
        XCTAssertTrue(result.hasShelfBooks)
        XCTAssertFalse(result.isBlank)
        XCTAssertFalse(result.isLoading)
        XCTAssertTrue(result.canScanShelf)
    }

    func testServerSignedOutOverridesResidualLibraryCardsAndAccountMenus() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: false))
        for showStaleMenu in [false, true] {
            if showStaleMenu {
                _ = try await view.evaluateJavaScript(
                    """
                    document.querySelector('.nav-user-account').style.display = 'block';
                    document.querySelector('a[href*="signin"]').remove();
                    """
                )
            }
            let result = KoboBindingPageProbe(try await probe(view))
            XCTAssertFalse(result.hasAccountEvidence)
            XCTAssertFalse(result.canScanShelf)
        }
    }

    func testServerAuthenticationWithOnlyRecommendationsDoesNotProveALibrary() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: true, includesLibraryRoot: false))
        let result = KoboBindingPageProbe(try await probe(view))
        XCTAssertFalse(result.hasShelfBooks)
        XCTAssertFalse(result.canScanShelf)
    }

    func testAuthenticatedEmptyMobileLibraryCanScanWithoutVisibleAccountMenu() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: true, includesBook: false))
        let result = KoboBindingPageProbe(try await probe(view))
        XCTAssertTrue(result.hasAccountEvidence)
        XCTAssertFalse(result.hasShelfBooks)
        XCTAssertFalse(result.isBlank)
        XCTAssertTrue(result.canScanShelf)
    }

    func testVisibleCredentialsStillOverrideServerAuthenticatedLibrary() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: true) + credentialMarkup)
        let result = KoboBindingPageProbe(try await probe(view))
        XCTAssertTrue(result.hasCredentialForm)
        XCTAssertFalse(result.canScanShelf)
    }

    func testAccountSettingsIdentityReturnsOnlyHashAndDomainUsingGET() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: true))
        let email = "  Synthetic.Reader@Example.com  "
        try await mockAccountSettingsFetch(in: view, html: accountSettingsHTML(email: email))
        let resolved = try await settingsIdentity(in: view)
        let result = try XCTUnwrap(resolved)
        XCTAssertEqual(result["identity"] as? String, KoboAccountIdentity.hash(email))
        XCTAssertEqual(result["label"] as? String, "Kobo · example.com")
        XCTAssertEqual(Set(result.keys), Set(["identity", "label"]))
        XCTAssertFalse(String(describing: result).lowercased().contains("synthetic.reader"))
        XCTAssertFalse(String(describing: result).contains("synthetic-private-password"))

        let requestsValue = try await view.evaluateJavaScript("window.__fixtureSettingsRequests")
        let requests = try XCTUnwrap(requestsValue as? [[String: Any]])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["url"] as? String, "https://www.kobo.com/sg/en/account/settings")
        XCTAssertEqual(requests.first?["method"] as? String, "GET")
        XCTAssertEqual(requests.first?["credentials"] as? String, "same-origin")
        XCTAssertEqual(requests.first?["hasBody"] as? Bool, false)
        let passwordReads = try await view.evaluateJavaScript("window.__fixturePasswordReads")
        XCTAssertEqual(passwordReads as? Int, 0)
    }

    func testAccountSettingsIdentityRejectsLoginAndCrossOriginRedirectsBeforeReadingHTML() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: true))
        for redirectedURL in [
            "https://www.kobo.com/sg/en/signin",
            "https://accounts.google.com/ServiceLogin",
            "https://evil.example/sg/en/account/settings",
            "https://www.kobo.com.evil.example/sg/en/account/settings",
            "http://www.kobo.com/sg/en/account/settings",
        ] {
            try await mockAccountSettingsFetch(
                in: view,
                html: accountSettingsHTML(email: "synthetic.reader@example.com"),
                responseURL: redirectedURL
            )
            let result = try await settingsIdentity(in: view)
            XCTAssertNil(result, redirectedURL)
            let bodyReads = try await view.evaluateJavaScript("window.__fixtureSettingsBodyReads")
            XCTAssertEqual(bodyReads as? Int, 0, redirectedURL)
        }
    }

    func testAccountSettingsIdentityRequiresTheExactProfileEmailForm() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: true))
        let validHTML = accountSettingsHTML(email: "synthetic.reader@example.com")
        let invalidProfiles = [
            validHTML.replacingOccurrences(of: "Account-AccountSettings", with: "Account-SignIn"),
            validHTML.replacingOccurrences(of: "save-email-form", with: "login-form"),
            validHTML.replacingOccurrences(of: "name=\"Email\"", with: "name=\"Username\""),
            validHTML.replacingOccurrences(of: "type=\"email\"", with: "type=\"password\""),
            accountSettingsHTML(email: "invalid-address"),
        ]
        for html in invalidProfiles {
            try await mockAccountSettingsFetch(in: view, html: html)
            let result = try await settingsIdentity(in: view)
            XCTAssertNil(result)
            let passwordReads = try await view.evaluateJavaScript("window.__fixturePasswordReads")
            XCTAssertEqual(passwordReads as? Int, 0)
        }
    }

    func testSignedOutLibraryDoesNotFetchAccountSettings() async throws {
        let view = try await load(KoboMobileLibraryFixture.body(isLoggedIn: false))
        try await mockAccountSettingsFetch(in: view, html: accountSettingsHTML(email: "synthetic.reader@example.com"))
        let result = try await settingsIdentity(in: view)
        XCTAssertNil(result)
        let requestCount = try await view.evaluateJavaScript("window.__fixtureSettingsRequests.length")
        XCTAssertEqual(requestCount as? Int, 0)
    }

    private func settingsIdentity(in view: WKWebView) async throws -> [String: Any]? {
        let value = try await view.callAsyncJavaScript(
            KoboWebScripts.accountSettingsIdentity, arguments: [:], in: nil, contentWorld: .page
        )
        return value as? [String: Any]
    }

    private func accountSettingsHTML(email: String) -> String {
        """
        <!doctype html><html><body class="Account-AccountSettings">
          <form id="save-email-form"><input id="email" type="email" name="Email" value="\(email)"></form>
          <form id="change-password-form"><input type="password" value="synthetic-private-password"></form>
        </body></html>
        """
    }

    /// Keep identity resolution on the real WKWebView/DOMParser/WebCrypto path,
    /// replacing only fetch with a local response. The mock records requests
    /// and rejects any accidental use of password values on parsed documents.
    private func mockAccountSettingsFetch(
        in view: WKWebView,
        html: String,
        responseURL: String = "https://www.kobo.com/sg/en/account/settings"
    ) async throws {
        _ = try await view.callAsyncJavaScript(
            """
            window.__fixtureSettingsRequests = [];
            window.__fixtureSettingsBodyReads = 0;
            window.__fixturePasswordReads = 0;
            if (!window.__fixturePasswordGuardInstalled) {
              window.__fixturePasswordGuardInstalled = true;
              var originalAttribute = Element.prototype.getAttribute;
              Element.prototype.getAttribute = function (name) {
                if (this.tagName === 'INPUT' && originalAttribute.call(this, 'type') === 'password') {
                  window.__fixturePasswordReads += 1;
                }
                return originalAttribute.call(this, name);
              };
              var originalValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
              Object.defineProperty(HTMLInputElement.prototype, 'value', {
                configurable: true,
                get: function () {
                  if (originalAttribute.call(this, 'type') === 'password') window.__fixturePasswordReads += 1;
                  return originalValue.get.call(this);
                },
                set: originalValue.set
              });
            }
            window.fetch = async function (url, options) {
              options = options || {};
              window.__fixtureSettingsRequests.push({
                url: String(url), method: String(options.method || 'GET').toUpperCase(),
                credentials: options.credentials || '', hasBody: options.body != null
              });
              return { ok: true, url: responseURL, text: async function () {
                window.__fixtureSettingsBodyReads += 1;
                return responseHTML;
              } };
            };
            """,
            arguments: ["responseHTML": html, "responseURL": responseURL],
            in: nil,
            contentWorld: .page
        )
    }

    private func probe(_ view: WKWebView) async throws -> [String: Any] {
        let value = try await view.evaluateJavaScript(KoboWebScripts.bindingPageProbe)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func load(_ body: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        let waiter = NavigationWaiter()
        view.navigationDelegate = waiter
        webView = view
        navigationWaiter = waiter
        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            view.loadHTMLString(
                "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body>\(body)</body></html>",
                baseURL: KoboWebScripts.shelfURL
            )
        }
        return view
    }
}

/// Synthetic data reproducing the structural evidence observed on Kobo's
/// mobile library. Book/account values are invented; no captured user data.
enum KoboMobileLibraryFixture {
    static let bookUUID = "f0000001-1111-4111-8111-000000000001"
    static let title = "Synthetic Mobile Shelf Book"
    static let author = "Avery Author"

    static func body(
        isLoggedIn: Bool,
        includesLibraryRoot: Bool = true,
        includesBook: Bool = true
    ) -> String {
        let book = """
            <li class="item-wrapper book">
              <h3 class="title">\(title)</h3>
              <a class="library-action" data-web-reader-entrypoint="true"
                 data-book-title="\(title)" data-contributors="\(author)"
                 href="https://readnow.kobo.com/\(bookUUID)">Read now</a>
            </li>
            """
        let content: String
        if includesLibraryRoot {
            content = """
                <section id="library-grid"><h1>My Books</h1>
                  <section class="library-content book-list grid">
                    <ul class="library-items">\(includesBook ? book : "")</ul>
                    \(includesBook ? "" : "<div class=\"library-empty\">There are no books in your library.</div>")
                  </section>
                </section>
                """
        } else {
            content = "<aside aria-label=\"Recommended books\"><h1>Recommended books</h1><ul>\(book)</ul></aside>"
        }
        return """
            <header><div class="nav-user-account collapsed" style="display:none">
              <a href="/sg/en/SignOut">Sign out</a>
              <a href="/sg/en/account">My Account</a>
              <a href="/sg/en/account/settings">Account settings</a>
            </div></header>
            \(isLoggedIn ? "" : "<a href=\"/sg/en/signin\">Sign in</a>")
            \(content)
            <script>
              document.body.classList.add('Store-Library');
              window.DynamicConfiguration = { user: {
                isLoggedIn: \(isLoggedIn ? "true" : "false"),
                hasPreviouslyAuthenticated: true,
                inHomeStoreFront: true,
                homeStorefront: 'sg',
                currentStorefront: 'sg'
              } };
            </script>
            """
    }
}
