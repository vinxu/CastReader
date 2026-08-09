//
//  GoogleBooksContractTests.swift
//  CastReaderTests
//
//  Google Play 图书绑定书库的纯函数契约自检：地址归一化、书架过滤、
//  翻页提交/续播判定、跨页断句裁剪。这些是「读错书 / 跳页 / 重复读一句」
//  三类线上问题的唯一防线。
//

import XCTest
import WebKit
@testable import CastReader

final class GoogleBooksContractTests: XCTestCase {

    // MARK: - 地址

    func testCanonicalReaderURLIsExtractedFromAnyEntryShape() {
        let cases = [
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PP1.w.1.1.9_250",
            "/books/reader?id=b_40EQAAQBAJ",
            "//play.google.com/books/reader?id=b_40EQAAQBAJ&hl=en",
        ]
        for raw in cases {
            XCTAssertEqual(
                GoogleBooksBookValidator.usableReaderURL(raw),
                "https://play.google.com/books/reader?id=b_40EQAAQBAJ",
                "failed for \(raw)"
            )
        }
    }

    func testSignInContinueURLIsBuiltAsAQueryItem() throws {
        let components = try XCTUnwrap(
            URLComponents(
                url: GoogleBooksWebScripts.signInURL,
                resolvingAgainstBaseURL: false
            )
        )
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(values["service"], "print")
        XCTAssertEqual(values["continue"], GoogleBooksWebScripts.shelfURL.absoluteString)
    }

    func testReaderMainFrameNavigationAllowlistIsStrict() {
        let allowed = [
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ",
            "https://play.google.com/books/reader/?id=b_40EQAAQBAJ&pg=GBS.PT12",
            "https://play.google.com:443/books/reader?id=b_40EQAAQBAJ#page",
        ]
        for raw in allowed {
            let url = URL(string: raw)
            XCTAssertTrue(
                GoogleBooksWebAccessPolicy.allowsMainFrameNavigation(url),
                "should allow \(raw)"
            )
            XCTAssertTrue(GoogleBooksWebScripts.isReaderURL(url))
        }

        let rejected = [
            "http://play.google.com/books/reader?id=b_40EQAAQBAJ",
            "https://user@play.google.com/books/reader?id=b_40EQAAQBAJ",
            "https://play.google.com:444/books/reader?id=b_40EQAAQBAJ",
            "https://books.google.com/books/reader?id=b_40EQAAQBAJ",
            "https://play.google.com/books/readerevil?id=b_40EQAAQBAJ",
            "https://play.google.com/store/books/details?id=b_40EQAAQBAJ",
            "https://evil.example.com/books/reader?id=b_40EQAAQBAJ",
            "https://play.google.com/books/reader",
            "https://play.google.com/books/reader?id=",
            "https://play.google.com/books/reader?id=bad",
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ&id=OTHERBOOK",
            "https://play.google.com/books/reader#id=b_40EQAAQBAJ",
        ]
        for raw in rejected {
            let url = URL(string: raw)
            XCTAssertFalse(
                GoogleBooksWebAccessPolicy.allowsMainFrameNavigation(url),
                "should reject \(raw)"
            )
            XCTAssertFalse(GoogleBooksWebScripts.isReaderURL(url))
        }
    }

    func testBridgeMessageAllowlistAcceptsOnlyTheExpectedMainAndReaderFrames() {
        let legalMain = GoogleBooksScriptMessageFrame(
            isMainFrame: true,
            securityScheme: "https",
            securityHost: "play.google.com",
            securityPort: 443,
            requestURL:
                "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12"
        )
        XCTAssertTrue(
            GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: "googleBooksLocation",
                from: legalMain
            )
        )
        XCTAssertFalse(
            GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: "rendered",
                from: legalMain
            ),
            "the Play Books shell may report only its canonical location"
        )

        let legalReader = GoogleBooksScriptMessageFrame(
            isMainFrame: false,
            securityScheme: "https",
            securityHost: "books.googleusercontent.com",
            securityPort: 0,
            requestURL:
                "https://books.googleusercontent.com/books/reader/frame?id=b_40EQAAQBAJ"
        )
        XCTAssertTrue(
            GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: "rendered",
                from: legalReader
            )
        )
        XCTAssertTrue(
            GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: "googleBooksSpeechPreview",
                from: legalReader
            )
        )
        XCTAssertTrue(
            GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: "googleBooksPreviewDiagnostic",
                from: legalReader
            )
        )

        let nestedReader = GoogleBooksScriptMessageFrame(
            isMainFrame: legalReader.isMainFrame,
            securityScheme: legalReader.securityScheme,
            securityHost: legalReader.securityHost,
            securityPort: legalReader.securityPort,
            requestURL:
                "https://books.googleusercontent.com/books/reader/frame/relay?id=b_40EQAAQBAJ"
        )
        XCTAssertTrue(
            GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: "googleBooksPageChanging",
                from: nestedReader
            )
        )
        XCTAssertFalse(
            GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: "googleBooksLocation",
                from: nestedReader
            ),
            "only the top-level shell owns the resumable Play Books URL"
        )
    }

    func testBridgeMessageAllowlistRejectsForgedOriginsAndNonReaderFrames() {
        let rejected = [
            GoogleBooksScriptMessageFrame(
                isMainFrame: true,
                securityScheme: "https",
                securityHost: "evil.example.com",
                securityPort: 443,
                requestURL:
                    "https://play.google.com/books/reader?id=b_40EQAAQBAJ"
            ),
            GoogleBooksScriptMessageFrame(
                isMainFrame: false,
                securityScheme: "https",
                securityHost: "books.googleusercontent.com",
                securityPort: 443,
                requestURL:
                    "https://evil.example.com/books/reader/frame?id=b_40EQAAQBAJ"
            ),
            GoogleBooksScriptMessageFrame(
                isMainFrame: false,
                securityScheme: "https",
                securityHost: "books.google.com",
                securityPort: 443,
                requestURL:
                    "https://books.google.com/books/reader/frame?id=b_40EQAAQBAJ"
            ),
            GoogleBooksScriptMessageFrame(
                isMainFrame: false,
                securityScheme: "https",
                securityHost: "play.google.com",
                securityPort: 443,
                requestURL:
                    "https://play.google.com/books/reader?id=b_40EQAAQBAJ"
            ),
            GoogleBooksScriptMessageFrame(
                isMainFrame: false,
                securityScheme: "https",
                securityHost: "books.googleusercontent.com",
                securityPort: 443,
                requestURL:
                    "https://books.googleusercontent.com/books/readerevil?id=b_40EQAAQBAJ"
            ),
            GoogleBooksScriptMessageFrame(
                isMainFrame: false,
                securityScheme: "http",
                securityHost: "books.googleusercontent.com",
                securityPort: 80,
                requestURL:
                    "http://books.googleusercontent.com/books/reader/frame?id=b_40EQAAQBAJ"
            ),
            GoogleBooksScriptMessageFrame(
                isMainFrame: false,
                securityScheme: "https",
                securityHost: "books.googleusercontent.com",
                securityPort: 444,
                requestURL:
                    "https://books.googleusercontent.com:444/books/reader/frame?id=b_40EQAAQBAJ"
            ),
            GoogleBooksScriptMessageFrame(
                isMainFrame: false,
                securityScheme: "https",
                securityHost: "books.googleusercontent.com",
                securityPort: 443,
                requestURL: "about:srcdoc"
            ),
        ]
        for frame in rejected {
            let validTypeForRole = frame.isMainFrame
                ? "googleBooksLocation"
                : "rendered"
            XCTAssertFalse(
                GoogleBooksWebAccessPolicy.allowsScriptMessage(
                    type: validTypeForRole,
                    from: frame
                ),
                "should reject \(frame)"
            )
        }
    }

    func testNonReaderURLsAreRejected() {
        let rejected = [
            "https://play.google.com/store/books/details?id=b_40EQAAQBAJ",
            "https://books.google.com/books/reader?id=b_40EQAAQBAJ",
            "https://play.google.com/books/readerevil?id=b_40EQAAQBAJ",
            "http://play.google.com/books/reader?id=b_40EQAAQBAJ",
            "https://weread.qq.com/web/reader/abc",
            "https://evil.example.com/books/reader?id=b_40EQAAQBAJ",
            "https://play.google.com/books/reader",
            nil,
        ]
        for raw in rejected {
            XCTAssertNil(GoogleBooksBookValidator.usableReaderURL(raw), "should reject \(raw ?? "nil")")
        }
    }

    func testResumeURLKeepsPositionButRefusesAnotherBook() {
        let resume = "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12"
        XCTAssertEqual(
            GoogleBooksBookValidator.usableResumeURL(resume, expecting: "b_40EQAAQBAJ"),
            resume
        )
        XCTAssertNil(GoogleBooksBookValidator.usableResumeURL(resume, expecting: "OTHERVOLUME"))
    }

    func testResumeURLRejectsUnsafeOrAmbiguousAuthorities() {
        let rejected = [
            "http://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12",
            "https://user@play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12",
            "https://play.google.com:444/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12",
            "https://books.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12",
            "https://play.google.com/books/readerevil?id=b_40EQAAQBAJ&pg=GBS.PT12",
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ&id=ANOTHER1",
            "https://play.google.com/books/reader?id=bad&pg=GBS.PT12#id=b_40EQAAQBAJ",
            "https://play.google.com/BOOKS/READER?id=b_40EQAAQBAJ&pg=GBS.PT12",
        ]
        for raw in rejected {
            XCTAssertNil(
                GoogleBooksBookValidator.usableResumeURL(raw, expecting: "b_40EQAAQBAJ"),
                "should reject \(raw)"
            )
        }

        XCTAssertEqual(
            GoogleBooksBookValidator.usableResumeURL(
                "https://play.google.com:443/books/reader/?id=b_40EQAAQBAJ&pg=GBS.PT12",
                expecting: "b_40EQAAQBAJ"
            ),
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12"
        )
    }

    func testStableIDPrefersVolumeID() {
        let withVolume = GoogleBooksBookValidator.stableID(
            volumeID: "b_40EQAAQBAJ",
            readerURL: "https://play.google.com/books/reader?id=b_40EQAAQBAJ",
            title: "The Enchanted Isles"
        )
        XCTAssertEqual(withVolume, "googlebooks:b_40EQAAQBAJ")

        let hashed = GoogleBooksBookValidator.stableID(
            volumeID: nil,
            readerURL: "https://play.google.com/books/reader?id=x",
            title: "T"
        )
        XCTAssertTrue(hashed.hasPrefix("googlebooks:"))
        XCTAssertEqual(hashed.count, "googlebooks:".count + 24)
    }

    // MARK: - 书架扫描

    func testScanResultKeepsOnlyRealBooks() {
        let result = GoogleBooksScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "account": "Google · example.com",
            "accountIdentitySource": "Reader@example.com",
            "books": [
                [
                    "readerURL": "https://play.google.com/books/reader?id=b_40EQAAQBAJ",
                    "title": "The Enchanted Isles",
                    "author": "Sofia Moreau",
                    "coverURL": "//books.google.com/cover.jpg",
                    "progressLabel": "42%",
                ],
                // 商店链接：不是阅读器入口
                ["readerURL": "https://play.google.com/store/books/details?id=zz", "title": "Store"],
                // 无标题
                ["readerURL": "https://play.google.com/books/reader?id=aaaaaaaa", "title": "  "],
            ],
        ])
        XCTAssertTrue(result.authenticated)
        XCTAssertTrue(result.hasAccountEvidence)
        XCTAssertTrue(result.isShelfContext)
        XCTAssertTrue(result.isCompleteSnapshot)
        XCTAssertEqual(result.account?.displayLabel, "Google · example.com")
        XCTAssertEqual(
            result.account?.identity,
            GoogleBooksAccountIdentity.hash("reader@example.com")
        )
        XCTAssertFalse(result.account?.identity?.contains("reader@example.com") == true)
        XCTAssertEqual(result.books.count, 1)
        let book = try! XCTUnwrap(result.books.first)
        XCTAssertEqual(book.id, "googlebooks:b_40EQAAQBAJ")
        XCTAssertEqual(book.coverURL, "https://books.google.com/cover.jpg")
        XCTAssertEqual(book.displayProgress, "42%")
        XCTAssertTrue(GoogleBooksBookValidator.isLikelyLibraryBook(book))
    }

    func testReaderLinksAloneNeverAuthenticateAPublicPage() {
        let result = GoogleBooksScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": false,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "books": [[
                "readerURL": "https://play.google.com/books/reader?id=b_40EQAAQBAJ",
                "title": "Public Preview",
            ]],
        ])

        XCTAssertFalse(result.authenticated)
        XCTAssertNil(result.account)
        XCTAssertEqual(result.books.count, 1)
    }

    func testAccountEvidenceOutsideShelfDoesNotBecomeAuthenticatedShelf() {
        let result = GoogleBooksScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": false,
            "isCompleteSnapshot": false,
            "accountIdentitySource": "reader@example.com",
            "books": [],
        ])

        XCTAssertFalse(result.authenticated)
        XCTAssertTrue(result.hasAccountEvidence)
        XCTAssertFalse(result.isShelfContext)
        XCTAssertEqual(
            result.account?.identity,
            GoogleBooksAccountIdentity.hash("reader@example.com")
        )
    }

    func testBindingLoginPhaseNeverShowsTheNativeLoginGuide() {
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.showsLoginGuide(for: .signingIn)
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.showsSyncBar(for: .signingIn)
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.showsSyncAction(for: .scanning)
        )
        XCTAssertTrue(
            GoogleBooksBindingFlowContract.showsSyncAction(for: .ready)
        )
        XCTAssertTrue(
            GoogleBooksBindingFlowContract.showsLoginGuide(for: .needsSignIn)
        )
    }

    func testSuccessfulLoginCanRecoverAWhiteOrNonShelfDestination() {
        XCTAssertTrue(
            GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
                phase: .signingIn,
                didEnterCredentialFlow: true,
                isBlankDocument: true,
                hasAccountEvidence: false,
                isShelfContext: false
            )
        )
        XCTAssertTrue(
            GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
                phase: .signingIn,
                didEnterCredentialFlow: true,
                isBlankDocument: false,
                isPlayBooksDestination: true,
                hasAccountEvidence: false,
                isShelfContext: false
            )
        )
        XCTAssertTrue(
            GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
                phase: .signingIn,
                didEnterCredentialFlow: true,
                isBlankDocument: false,
                hasAccountEvidence: true,
                isShelfContext: false
            )
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
                phase: .awaitingShelf,
                didEnterCredentialFlow: true,
                isBlankDocument: true,
                hasAccountEvidence: true,
                isShelfContext: false
            )
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
                phase: .signingIn,
                didEnterCredentialFlow: true,
                isBlankDocument: false,
                hasAccountEvidence: true,
                isShelfContext: true
            )
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
                phase: .signingIn,
                didEnterCredentialFlow: false,
                isBlankDocument: false,
                isPlayBooksDestination: true,
                hasAccountEvidence: false,
                isShelfContext: false
            ),
            "a late didFinish from the pre-login Play Books page is not login success"
        )
    }

    func testCredentialURLDetectionIsStrict() {
        XCTAssertTrue(
            GoogleBooksBindingFlowContract.isGoogleCredentialURL(
                URL(string: "https://accounts.google.com/ServiceLogin")
            )
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.isGoogleCredentialURL(
                URL(string: "http://accounts.google.com/ServiceLogin")
            )
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.isGoogleCredentialURL(
                URL(string: "https://accounts.google.com.evil.example/ServiceLogin")
            )
        )
        XCTAssertFalse(
            GoogleBooksBindingFlowContract.isGoogleCredentialURL(
                GoogleBooksWebScripts.homeURL
            )
        )
    }

    /// gds.google.com/web/landing 是登录续跳链中的落地中转页（Android 6a2f17d
    /// 案例）：直接命中或作为 CheckCookie 的 continue 目标都要触发书架恢复。
    @MainActor
    func testShelfRecoveryDestinationAcceptsTheGdsLandingHop() {
        XCTAssertTrue(
            GoogleBooksLibrarySyncViewModel.isShelfRecoveryDestination(
                URL(string: "https://gds.google.com/web/landing?rapt=abc")!
            )
        )
        XCTAssertTrue(
            GoogleBooksLibrarySyncViewModel.isShelfRecoveryDestination(
                URL(
                    string: "https://accounts.google.com/CheckCookie?continue=https%3A%2F%2Fgds.google.com%2Fweb%2Flanding"
                )!
            )
        )
        XCTAssertFalse(
            GoogleBooksLibrarySyncViewModel.isShelfRecoveryDestination(
                URL(string: "https://gds.google.com/other")!
            )
        )
        XCTAssertFalse(
            GoogleBooksLibrarySyncViewModel.isShelfRecoveryDestination(
                URL(string: "http://gds.google.com/web/landing")!
            )
        )
    }

    /// 被拦导航诊断只允许携带 URL 的形状：host、path 与排序后的参数名。
    /// 参数值可能携带账号数据，任何情况下都不得出现在形状里。
    @MainActor
    func testBlockedNavigationShapeCarriesParameterNamesButNeverValues() {
        let shape = GoogleBooksLibrarySyncViewModel.blockedNavigationShape(
            URL(
                string: "https://idp.example.com/signin/challenge?TL=secret1&continue=https%3A%2F%2Fx&b=2"
            )!
        )
        XCTAssertEqual(shape, "idp.example.com/signin/challenge?[TL,b,continue]")
        XCTAssertFalse(shape.contains("secret1"))
        XCTAssertEqual(
            GoogleBooksLibrarySyncViewModel.blockedNavigationShape(
                URL(string: "https://idp.example.com/hop")!
            ),
            "idp.example.com/hop?[]"
        )
        XCTAssertEqual(
            GoogleBooksLibrarySyncViewModel.blockedNavigationShape(nil),
            "unparseable"
        )
    }

    /// 被拦回落的限频契约：8 秒窗口内只放行一次，窗口过后可再次回落。
    @MainActor
    func testBindingBlockRescueIsRateLimitedToOnePerWindow() {
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { _, _ in nil },
            signInURLResolver: { _ in nil }
        )
        XCTAssertTrue(model.consumeBindingBlockRescue(now: 100))
        XCTAssertFalse(model.consumeBindingBlockRescue(now: 107.9))
        XCTAssertTrue(model.consumeBindingBlockRescue(now: 108))
        XCTAssertFalse(model.consumeBindingBlockRescue(now: 108.5))
        model.stop()
    }

    @MainActor
    func testNativeSignInActionDispatchesCredentialNavigationBeforeHidingGuide() async {
        let requestAccepted = expectation(description: "credential request accepted")
        var capturedRequest: URLRequest?
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { webView, request in
                capturedRequest = request
                requestAccepted.fulfill()
                return webView.load(
                    URLRequest(url: URL(string: "about:blank")!)
                )
            },
            signInURLResolver: { _ in GoogleBooksWebScripts.signInURL }
        )

        XCTAssertTrue(model.showsLoginGuide)
        model.openSignIn()
        await fulfillment(of: [requestAccepted], timeout: 2)
        await Task.yield()

        XCTAssertEqual(capturedRequest?.url, GoogleBooksWebScripts.signInURL)
        XCTAssertEqual(model.bindingPhase, .signingIn)
        XCTAssertFalse(model.showsLoginGuide)
        model.stop()
    }

    @MainActor
    func testRejectedNativeSignInNavigationKeepsTheGuideActionable() async {
        let requestRejected = expectation(description: "credential request rejected")
        let model = GoogleBooksLibrarySyncViewModel(
            requestLoader: { _, _ in
                requestRejected.fulfill()
                return nil
            },
            signInURLResolver: { _ in GoogleBooksWebScripts.signInURL }
        )

        model.openSignIn()
        await fulfillment(of: [requestRejected], timeout: 2)
        await Task.yield()

        XCTAssertEqual(model.bindingPhase, .needsSignIn)
        XCTAssertTrue(model.showsLoginGuide)
        XCTAssertNotNil(model.errorText)
        XCTAssertFalse(model.isStartingSignIn)
        model.stop()
    }

    func testEmptyShelfNeedsLongerStableConfirmationBeforeItCanSync() {
        let account = GoogleBooksAccountInfo(
            label: "Google · example.com",
            identity: GoogleBooksAccountIdentity.hash("reader@example.com"),
            hasAccountEvidence: true,
            isShelfContext: true,
            isCompleteSnapshot: true
        )
        XCTAssertEqual(GoogleBooksShelfSyncContract.requiredStablePasses(bookCount: 0), 10)
        XCTAssertFalse(
            GoogleBooksShelfSyncContract.canCommit(
                bookCount: 0,
                account: account,
                reachedEnd: true,
                stableEndPasses: 9
            )
        )
        XCTAssertTrue(
            GoogleBooksShelfSyncContract.canCommit(
                bookCount: 0,
                account: account,
                reachedEnd: true,
                stableEndPasses: 10
            )
        )
        XCTAssertTrue(
            GoogleBooksShelfSyncContract.canCommit(
                bookCount: 1,
                account: nil,
                reachedEnd: true,
                stableEndPasses: 4
            )
        )
    }

    func testShelfChromeIsNotABook() {
        let chrome = GoogleBooksBook(
            id: "googlebooks:aaaaaaaa",
            title: "My books",
            author: "",
            coverURL: nil,
            readerURL: "https://play.google.com/books/reader?id=aaaaaaaa",
            progressLabel: "",
            volumeID: "aaaaaaaa",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )
        XCTAssertFalse(GoogleBooksBookValidator.isLikelyLibraryBook(chrome))
    }

    // MARK: - 翻页

    func testRepeatedSignatureIsNeverCommittedTwice() {
        XCTAssertFalse(GoogleBooksPageTurnContract.shouldCommit(
            reason: .auto,
            previousSignature: "sig-a",
            incomingSignature: "sig-a",
            paragraphCount: 5
        ))
        XCTAssertTrue(GoogleBooksPageTurnContract.shouldCommit(
            reason: .auto,
            previousSignature: "sig-a",
            incomingSignature: "sig-b",
            paragraphCount: 5
        ))
    }

    func testEmptyPageIsNeverCommitted() {
        for reason in [GoogleBooksPageEventReason.initial, .auto, .manual, .refresh] {
            XCTAssertFalse(GoogleBooksPageTurnContract.shouldCommit(
                reason: reason,
                previousSignature: "",
                incomingSignature: "sig",
                paragraphCount: 0
            ))
        }
    }

    func testOnlyDedicatedReaderFramePayloadCanDriveGooglePaging() {
        XCTAssertTrue(GoogleBooksPageTurnContract.isReaderPagePayload([
            "source": "google-books",
            "frameSessionID": "reader-a",
            "paragraphs": [["text": "page"]],
        ]))
        XCTAssertFalse(GoogleBooksPageTurnContract.isReaderPagePayload([
            "paragraphs": [],
        ]))
        XCTAssertFalse(GoogleBooksPageTurnContract.isReaderPagePayload([
            "source": "generic",
            "paragraphs": [["text": "Google account chrome"]],
        ]))
        XCTAssertEqual(
            GoogleBooksPageTurnContract.frameSessionID(from: [
                "frameSessionID": " reader-a ",
            ]),
            "reader-a"
        )
        XCTAssertNil(GoogleBooksPageTurnContract.frameSessionID(from: [
            "frameSessionID": " ",
        ]))
    }

    func testGoogleBooksTurnSignatureIsAnOpaqueWireValue() {
        let signature = "0,66,430,593,66,24,775,sample \t"
        XCTAssertEqual(
            GoogleBooksPageTurnContract.opaqueSignature(from: signature),
            signature
        )
        XCTAssertNil(
            GoogleBooksPageTurnContract.opaqueSignature(from: " \n\t ")
        )
        XCTAssertNil(
            GoogleBooksPageTurnContract.opaqueSignature(from: 42)
        )
    }

    func testMainFrameWatchdogOutlivesReaderFrameBootBudget() {
        XCTAssertGreaterThanOrEqual(
            GoogleBooksPageTurnContract.readerBootstrapTimeoutNanoseconds,
            18_000_000_000
        )
        XCTAssertGreaterThanOrEqual(
            GoogleBooksPageTurnContract.turnConfirmationTimeoutNanoseconds,
            12_000_000_000,
            "slow chapter fetches must not lose automatic-turn ownership"
        )
    }

    func testFirstPageCommitsEvenWithoutSignatureChange() {
        XCTAssertTrue(GoogleBooksPageTurnContract.shouldCommit(
            reason: .initial,
            previousSignature: "",
            incomingSignature: "",
            paragraphCount: 3
        ))
    }

    func testResumePolicyMatchesTheProductRule() {
        // 打开书本身不自动播（由 autoPlay 设置与 startAutoPlaybackIfNeeded 决定）
        XCTAssertFalse(GoogleBooksPageTurnContract.shouldResumePlayback(
            reason: .initial, wasAutomaticTurn: false, wasPlaying: true
        ))
        // 朗读读完自动翻页 → 必须继续读
        XCTAssertTrue(GoogleBooksPageTurnContract.shouldResumePlayback(
            reason: .auto, wasAutomaticTurn: true, wasPlaying: false
        ))
        // 手动滑动切页：原本在播才续播，原本没播就保持安静
        XCTAssertTrue(GoogleBooksPageTurnContract.shouldResumePlayback(
            reason: .manual, wasAutomaticTurn: false, wasPlaying: true
        ))
        XCTAssertFalse(GoogleBooksPageTurnContract.shouldResumePlayback(
            reason: .manual, wasAutomaticTurn: false, wasPlaying: false
        ))
    }

    func testSinglePagePreloadConsumesOnlyAnExactCommittedPrediction() {
        XCTAssertTrue(
            GoogleBooksSinglePagePreloadContract.canConsume(
                sourceSignature: "page-a",
                previousSignature: "page-a",
                predictedParagraphs: ["continuation", "next paragraph"],
                visibleParagraphs: ["continuation", "next paragraph"],
                preparedVoiceID: "voice-a",
                selectedVoiceID: "voice-a"
            )
        )
    }

    func testSinglePagePreloadRejectsReflowReverseTurnAndVoiceChange() {
        let predicted = ["continuation", "next paragraph"]
        XCTAssertFalse(
            GoogleBooksSinglePagePreloadContract.canConsume(
                sourceSignature: "page-a",
                previousSignature: "page-a-reflowed",
                predictedParagraphs: predicted,
                visibleParagraphs: predicted,
                preparedVoiceID: "voice-a",
                selectedVoiceID: "voice-a"
            )
        )
        XCTAssertFalse(
            GoogleBooksSinglePagePreloadContract.canConsume(
                sourceSignature: "page-a",
                previousSignature: "page-a",
                predictedParagraphs: predicted,
                visibleParagraphs: ["previous page"],
                preparedVoiceID: "voice-a",
                selectedVoiceID: "voice-a"
            )
        )
        XCTAssertFalse(
            GoogleBooksSinglePagePreloadContract.canConsume(
                sourceSignature: "page-a",
                previousSignature: "page-a",
                predictedParagraphs: predicted,
                visibleParagraphs: predicted,
                preparedVoiceID: "voice-a",
                selectedVoiceID: "voice-b"
            )
        )
    }

    func testSpeechPreloadSplitsExactFirstSourceSentenceAndPreservesRemainderDOMOffset() {
        let candidate = GoogleBooksSpeechPreviewCandidate(
            sourceSignature: "page-a",
            originFrameSessionID: "frame-a",
            contentFingerprint: "sentence-a",
            sourceParagraphIndex: 7,
            sourceUTF16Start: 120,
            sourceUTF16End: 134,
            text: "Next sentence."
        )
        let split = GoogleBooksSpeechPreloadContract.splitCommittedPage(
            candidate: candidate,
            previousSignature: "page-a",
            activeFrameSessionID: "frame-a",
            sourceSlices: [
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 120,
                    sourceUTF16End: 160,
                    text: "Next sentence.  Remaining words."
                ),
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 1,
                    sourceParagraphIndex: 8,
                    sourceUTF16Start: 0,
                    sourceUTF16End: 12,
                    text: "Later block."
                ),
            ],
            paragraphs: [
                "Next sentence.  Remaining words.",
                "Later block.",
            ],
            domCharacterOffsets: [120, 0]
        )

        XCTAssertEqual(
            split?.paragraphs,
            ["Next sentence.", "Remaining words.", "Later block."]
        )
        XCTAssertEqual(split?.domParagraphIndices, [0, 0, 1])
        XCTAssertEqual(split?.domCharacterOffsets, [120, 136, 0])
        XCTAssertEqual(split?.preparedParagraphIndex, 0)
        XCTAssertTrue(split?.insertedRemainder == true)
    }

    func testSpeechPreviewPreparationRequiresExactCurrentFrameAndUTF16Source() {
        let candidate = GoogleBooksSpeechPreviewCandidate(
            sourceSignature: "page-a",
            originFrameSessionID: "frame-a",
            contentFingerprint: "12ab34ef",
            sourceParagraphIndex: 7,
            sourceUTF16Start: 120,
            sourceUTF16End: 137,
            text: "Next 😀 sentence."
        )
        func accepts(
            _ value: GoogleBooksSpeechPreviewCandidate = candidate,
            exact: Bool = true,
            source: String = "page-a",
            frame: String = "frame-a"
        ) -> Bool {
            GoogleBooksSpeechPreloadContract.canPrepare(
                candidate: value,
                exactText: exact,
                currentSourceSignature: source,
                activeFrameSessionID: frame
            )
        }

        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(exact: false))
        XCTAssertFalse(accepts(source: "page-b"))
        XCTAssertFalse(accepts(frame: "frame-b"))
        XCTAssertFalse(accepts(
            GoogleBooksSpeechPreviewCandidate(
                sourceSignature: candidate.sourceSignature,
                originFrameSessionID:
                    candidate.originFrameSessionID,
                contentFingerprint: "not-a-hash",
                sourceParagraphIndex:
                    candidate.sourceParagraphIndex,
                sourceUTF16Start: candidate.sourceUTF16Start,
                sourceUTF16End:
                    candidate.sourceUTF16End - 1,
                text: candidate.text
            )
        ))
        let oversized = String(
            repeating: "a",
            count:
                GoogleBooksSpeechPreloadContract
                    .maximumPreviewUTF16Length + 1
        )
        XCTAssertFalse(accepts(
            GoogleBooksSpeechPreviewCandidate(
                sourceSignature: candidate.sourceSignature,
                originFrameSessionID:
                    candidate.originFrameSessionID,
                contentFingerprint: "abcdef12",
                sourceParagraphIndex:
                    candidate.sourceParagraphIndex,
                sourceUTF16Start: 0,
                sourceUTF16End:
                    (oversized as NSString).length,
                text: oversized
            )
        ))
    }

    func testSpeechContinuousHandoffFailsClosedUntilExactAutomaticCommit() {
        func canRelease(
            automatic: Bool = true,
            identity: Bool = true,
            queue: Bool = true,
            quota: Bool = true,
            exactSplit: Bool = true,
            selectedVoice: String = "voice-a",
            preparedParagraph: Int = 0,
            queuedParagraph: Int = 0
        ) -> Bool {
            GoogleBooksSpeechContinuousHandoffContract.canRelease(
                isAuthorizedAutomaticTurn: automatic,
                issuedTurnIdentityMatches: identity,
                queueIsIntact: queue,
                canContinueListening: quota,
                candidateMatchesCommittedSplit: exactSplit,
                preparedVoiceID: "voice-a",
                selectedVoiceID: selectedVoice,
                preparedParagraphIndex: preparedParagraph,
                queuedParagraphIndex: queuedParagraph
            )
        }

        XCTAssertTrue(canRelease())
        XCTAssertFalse(canRelease(automatic: false))
        XCTAssertFalse(canRelease(identity: false))
        XCTAssertFalse(canRelease(queue: false))
        XCTAssertFalse(canRelease(quota: false))
        XCTAssertFalse(canRelease(exactSplit: false))
        XCTAssertFalse(canRelease(selectedVoice: "voice-b"))
        XCTAssertFalse(canRelease(preparedParagraph: 1))
    }

    func testSpeechPreloadFailsClosedForWrongFrameCoordinateTextOrEarlierSpeech() {
        let base = GoogleBooksSpeechPreviewCandidate(
            sourceSignature: "page-a",
            originFrameSessionID: "frame-a",
            contentFingerprint: "sentence-a",
            sourceParagraphIndex: 7,
            sourceUTF16Start: 120,
            sourceUTF16End: 134,
            text: "Next sentence."
        )
        let slices = [
            LiveWebPageSourceSlice(
                visibleParagraphIndex: 0,
                sourceParagraphIndex: 7,
                sourceUTF16Start: 120,
                sourceUTF16End: 160,
                text: "Next sentence. Remaining words."
            ),
        ]
        func split(
            _ candidate: GoogleBooksSpeechPreviewCandidate = base,
            frame: String = "frame-a",
            paragraphs: [String] = ["Next sentence. Remaining words."],
            slices overrideSlices: [LiveWebPageSourceSlice]? = nil,
            offsets: [Int] = [120]
        ) -> GoogleBooksSpeechPageSplit? {
            GoogleBooksSpeechPreloadContract.splitCommittedPage(
                candidate: candidate,
                previousSignature: "page-a",
                activeFrameSessionID: frame,
                sourceSlices: overrideSlices ?? slices,
                paragraphs: paragraphs,
                domCharacterOffsets: offsets
            )
        }

        XCTAssertNil(split(frame: "frame-b"))
        XCTAssertNil(split(offsets: [121]))
        XCTAssertNil(split(paragraphs: ["Different sentence."]))
        XCTAssertNil(split(
            paragraphs: ["Earlier speech.", "Next sentence. Remaining words."],
            slices: [
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 6,
                    sourceUTF16Start: 0,
                    sourceUTF16End: 15,
                    text: "Earlier speech."
                ),
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 1,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 120,
                    sourceUTF16End: 160,
                    text: "Next sentence. Remaining words."
                ),
            ],
            offsets: [0, 120]
        ))
    }

    func testContinuousPreloadReleasesOnlyAfterAuthorizedExactCommit() {
        XCTAssertTrue(
            GoogleBooksContinuousPageHandoffContract.canRelease(
                isAuthorizedAutomaticTurn: true,
                issuedTurnIdentityMatches: true,
                queueIsIntact: true,
                canContinueListening: true,
                sourceSignature: "page-a",
                issuedBaselineSignature: "page-a",
                predictedParagraphs: ["next page", "second paragraph"],
                visibleParagraphs: ["next page", "second paragraph"],
                preparedVoiceID: "voice-a",
                selectedVoiceID: "voice-a"
            )
        )
    }

    func testContinuousPreloadStaysGatedForWrongTurnPageVoiceOrQueue() {
        let source = "page-a"
        let predicted = ["predicted next page"]
        func canRelease(
            authorized: Bool = true,
            identity: Bool = true,
            queue: Bool = true,
            quota: Bool = true,
            visible: [String] = ["predicted next page"],
            voice: String = "voice-a"
        ) -> Bool {
            GoogleBooksContinuousPageHandoffContract.canRelease(
                isAuthorizedAutomaticTurn: authorized,
                issuedTurnIdentityMatches: identity,
                queueIsIntact: queue,
                canContinueListening: quota,
                sourceSignature: source,
                issuedBaselineSignature: source,
                predictedParagraphs: predicted,
                visibleParagraphs: visible,
                preparedVoiceID: "voice-a",
                selectedVoiceID: voice
            )
        }

        XCTAssertFalse(canRelease(authorized: false))
        XCTAssertFalse(canRelease(identity: false))
        XCTAssertFalse(canRelease(queue: false))
        XCTAssertFalse(canRelease(quota: false))
        XCTAssertFalse(canRelease(visible: ["different page"]))
        XCTAssertFalse(canRelease(voice: "voice-b"))
    }

    func testPageVisualsStaySuppressedForEveryUnconfirmedTurnState() {
        XCTAssertTrue(
            GoogleBooksPageVisualStateContract.shouldSuppress(
                pendingAutomaticTurn: true,
                pendingManualTurn: false,
                awaitingReaderRecovery: false
            )
        )
        XCTAssertTrue(
            GoogleBooksPageVisualStateContract.shouldSuppress(
                pendingAutomaticTurn: false,
                pendingManualTurn: true,
                awaitingReaderRecovery: false
            )
        )
        XCTAssertTrue(
            GoogleBooksPageVisualStateContract.shouldSuppress(
                pendingAutomaticTurn: false,
                pendingManualTurn: false,
                awaitingReaderRecovery: true
            )
        )
        XCTAssertTrue(
            GoogleBooksPageVisualStateContract.shouldSuppress(
                pendingAutomaticTurn: false,
                pendingManualTurn: false,
                awaitingReaderRecovery: false,
                awaitingLateAutomaticTurn: true
            )
        )
        XCTAssertFalse(
            GoogleBooksPageVisualStateContract.shouldSuppress(
                pendingAutomaticTurn: false,
                pendingManualTurn: false,
                awaitingReaderRecovery: false
            )
        )
        XCTAssertTrue(
            GoogleBooksPageVisualStateContract.shouldRestoreAfterFailedTurn(
                preserveLateResult: false
            )
        )
        XCTAssertFalse(
            GoogleBooksPageVisualStateContract.shouldRestoreAfterFailedTurn(
                preserveLateResult: true
            )
        )
    }

    func testActiveCarryRequiresARealConsumedPrefixAndDOMOrigin() {
        XCTAssertFalse(
            GoogleBooksAudioPageBoundaryContract.canRequestPhysicalTurn(
                after: .estimatedBoundary
            ),
            "UTF-16/fixed-lead prediction must never move the visible page"
        )
        XCTAssertTrue(
            GoogleBooksAudioPageBoundaryContract.canRequestPhysicalTurn(
                after: .queuedSuccessorGate
            )
        )
        XCTAssertTrue(
            GoogleBooksAudioPageBoundaryContract.canRequestPhysicalTurn(
                after: .documentFinished
            )
        )
        XCTAssertTrue(
            GoogleBooksAudioPageBoundaryContract.canCommitActiveCarry(
                carryParagraphIndex: 0,
                carryUTF16Length: 18,
                carryDOMUTF16Start: 42
            )
        )
        XCTAssertFalse(
            GoogleBooksAudioPageBoundaryContract.canCommitActiveCarry(
                carryParagraphIndex: 0,
                carryUTF16Length: 0,
                carryDOMUTF16Start: 42
            ),
            "trim=0 must not transfer highlight ownership to an active carry"
        )
        XCTAssertFalse(
            GoogleBooksAudioPageBoundaryContract.canCommitActiveCarry(
                carryParagraphIndex: nil,
                carryUTF16Length: 18,
                carryDOMUTF16Start: 42
            )
        )
        XCTAssertFalse(
            GoogleBooksAudioPageBoundaryContract.canCommitActiveCarry(
                carryParagraphIndex: 0,
                carryUTF16Length: 18,
                carryDOMUTF16Start: nil
            )
        )
    }

    func testSuccessfulStreamingProducerResolvesAnAlreadyDrainedQueue() {
        XCTAssertTrue(
            StreamingQueueDrainContract.shouldCompletePlayback(
                producerFinishedSuccessfully: true,
                isWaitingForNextSegment: true,
                moreSegmentsExpected: false,
                currentSegmentIndex: 2,
                queueCount: 3
            )
        )
        XCTAssertFalse(
            StreamingQueueDrainContract.shouldCompletePlayback(
                producerFinishedSuccessfully: false,
                isWaitingForNextSegment: true,
                moreSegmentsExpected: false,
                currentSegmentIndex: 2,
                queueCount: 3
            ),
            "失败的生产请求必须显示错误，不能假装正常完成"
        )
        XCTAssertFalse(
            StreamingQueueDrainContract.shouldCompletePlayback(
                producerFinishedSuccessfully: true,
                isWaitingForNextSegment: false,
                moreSegmentsExpected: false,
                currentSegmentIndex: 2,
                queueCount: 3
            ),
            "已有新音频接管时不得重复完成"
        )
        XCTAssertFalse(
            StreamingQueueDrainContract.shouldCompletePlayback(
                producerFinishedSuccessfully: true,
                isWaitingForNextSegment: true,
                moreSegmentsExpected: false,
                currentSegmentIndex: 1,
                queueCount: 3
            ),
            "队列里仍有下一段时不得提前完成"
        )
    }

    func testExplainPrefetchRequiresExactPageAndSettings() {
        func canConsume(
            visible: [String] = ["next visible page"],
            voice: String = "voice-a",
            depth: String = "standard",
            language: String = "auto"
        ) -> Bool {
            GoogleBooksExplainPagePrefetchContract.canConsume(
                sourceSignature: "page-a",
                previousSignature: "page-a",
                predictedContentFingerprint: "fingerprint-b",
                payloadTextFingerprint: "fingerprint-b",
                predictedParagraphs: ["next visible page"],
                visibleParagraphs: visible,
                preparedVoiceID: "voice-a",
                selectedVoiceID: voice,
                preparedDepth: "standard",
                selectedDepth: depth,
                requestedLanguage: "auto",
                selectedLanguage: language
            )
        }

        XCTAssertTrue(canConsume())
        XCTAssertFalse(canConsume(visible: ["another page"]))
        XCTAssertFalse(canConsume(voice: "voice-b"))
        XCTAssertFalse(canConsume(depth: "deep"))
        XCTAssertFalse(canConsume(language: "zh"))
    }

    // MARK: - 跨页断句

    func testCrossPageCursorCoversTheExtendedSentence() {
        // 可见到第 74 字，补句到第 201 字（多读 127 字）
        let boundary = LiveWebPageSpeechBoundary(
            paragraphIndex: 3,
            visibleUTF16Offset: 74,
            speechUTF16Length: 201
        )
        let cursor = GoogleBooksCrossPageContract.consumedCursor(
            boundary: boundary,
            sourceParagraphIndex: 4,
            sourceVisibleEnd: 74
        )
        XCTAssertEqual(cursor?.sourceParagraphIndex, 4)
        XCTAssertEqual(cursor?.sourceUTF16End, 201)
    }

    func testNoCursorWhenTheSentenceEndedOnThisPage() {
        XCTAssertNil(GoogleBooksCrossPageContract.consumedCursor(
            boundary: nil, sourceParagraphIndex: 4, sourceVisibleEnd: 74
        ))
        let flush = LiveWebPageSpeechBoundary(
            paragraphIndex: 3, visibleUTF16Offset: 74, speechUTF16Length: 74
        )
        XCTAssertNil(GoogleBooksCrossPageContract.consumedCursor(
            boundary: flush, sourceParagraphIndex: 4, sourceVisibleEnd: 74
        ))
    }

    /// 真实 fixture 取到的形状：上一页读到源段 #4 的第 201 字，
    /// 新页里同一段可见区是 [36,200) —— 整段都已读过，必须被裁空而不是重复朗读。
    func testAlreadySpokenPrefixIsTrimmedOnTheNextPage() {
        let carried = String(repeating: "x", count: 164)
        let fresh = "She set the cup down beside the window."
        let consumption = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 4,
                    sourceUTF16Start: 36,
                    sourceUTF16End: 200,
                    text: carried
                ),
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 1,
                    sourceParagraphIndex: 5,
                    sourceUTF16Start: 0,
                    sourceUTF16End: fresh.count,
                    text: fresh
                ),
            ],
            through: LiveWebPageConsumedCursor(sourceParagraphIndex: 4, sourceUTF16End: 201)
        )
        XCTAssertEqual(consumption.texts.first, "")
        XCTAssertEqual(consumption.texts.last, fresh)
        XCTAssertEqual(consumption.carryParagraphIndex, 0)
        XCTAssertEqual(consumption.carryUTF16Length, 164)
    }

    func testPartiallySpokenParagraphKeepsItsRemainder() {
        let visible = "0123456789ABCDEFGHIJ"
        let consumption = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 100,
                    sourceUTF16End: 120,
                    text: visible
                ),
            ],
            through: LiveWebPageConsumedCursor(sourceParagraphIndex: 7, sourceUTF16End: 110)
        )
        XCTAssertEqual(consumption.texts.first, "ABCDEFGHIJ")
        XCTAssertEqual(consumption.carryUTF16Length, 10)
    }

    func testDOMOffsetTracksConsumedPrefixAndWhitespaceTrim() {
        let slices = [
            LiveWebPageSourceSlice(
                visibleParagraphIndex: 0,
                sourceParagraphIndex: 7,
                sourceUTF16Start: 100,
                sourceUTF16End: 122,
                text: "0123456789  ABCDEFGHIJ"
            ),
        ]
        let offsets = GoogleBooksCrossPageContract.domCharacterOffsets(
            in: slices,
            through: LiveWebPageConsumedCursor(
                sourceParagraphIndex: 7,
                sourceUTF16End: 110
            )
        )
        // 10 source characters were consumed, then the same two spaces that
        // `consumeAlreadySpokenPrefix` trims must be skipped in the DOM Range.
        XCTAssertEqual(offsets, [112])
    }

    func testDOMOffsetAdvancesToEndWhenWholeVisibleSliceWasSpoken() {
        let offsets = GoogleBooksCrossPageContract.domCharacterOffsets(
            in: [
                LiveWebPageSourceSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 4,
                    sourceUTF16Start: 36,
                    sourceUTF16End: 200,
                    text: String(repeating: "x", count: 164)
                ),
            ],
            through: LiveWebPageConsumedCursor(
                sourceParagraphIndex: 4,
                sourceUTF16End: 201
            )
        )
        XCTAssertEqual(offsets, [200])
    }

    func testOneParagraphCanCarryAcrossThreeVisualPagesWithoutRepeating() {
        let prior = LiveWebPageConsumedCursor(
            sourceParagraphIndex: 9,
            sourceUTF16End: 200
        )
        let fullyCovered = LiveWebPageSourceSlice(
            visibleParagraphIndex: 0,
            sourceParagraphIndex: 9,
            sourceUTF16Start: 100,
            sourceUTF16End: 180,
            text: String(repeating: "b", count: 80)
        )
        let secondPage = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [fullyCovered],
            through: prior
        )
        XCTAssertEqual(secondPage.texts, [""])
        XCTAssertEqual(
            GoogleBooksCrossPageContract.retainedCursor(
                previous: prior,
                carryParagraphIndex: secondPage.carryParagraphIndex
            ),
            prior,
            "a fully covered middle page must not drop the absolute source cursor"
        )

        let thirdVisible = String(repeating: "c", count: 40)
            + String(repeating: "d", count: 20)
        let thirdSlice = LiveWebPageSourceSlice(
            visibleParagraphIndex: 0,
            sourceParagraphIndex: 9,
            sourceUTF16Start: 160,
            sourceUTF16End: 220,
            text: thirdVisible
        )
        let thirdPage = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [thirdSlice],
            through: prior
        )
        XCTAssertEqual(thirdPage.texts, [String(repeating: "d", count: 20)])
        let thirdOffset = GoogleBooksCrossPageContract.domCharacterOffsets(
            in: [thirdSlice],
            through: prior
        ).first ?? -1
        XCTAssertEqual(thirdOffset, 200)

        let rawSpeech = thirdVisible + String(repeating: "e", count: 30)
        let remainingSpeech = GoogleBooksCrossPageContract.remainingSpeechText(
            rawSpeech,
            sourceUTF16Start: 160,
            domCharacterOffset: thirdOffset
        )
        XCTAssertEqual(
            remainingSpeech,
            String(repeating: "d", count: 20) + String(repeating: "e", count: 30)
        )
        let next = GoogleBooksCrossPageContract.consumedCursor(
            boundary: LiveWebPageSpeechBoundary(
                paragraphIndex: 0,
                visibleUTF16Offset: 20,
                speechUTF16Length: 50
            ),
            sourceParagraphIndex: 9,
            sourceVisibleEnd: 220
        )
        XCTAssertEqual(next?.sourceUTF16End, 250)
    }

    func testMiddleVisualPageTurnsOnlyWhenCarryAudioReachesItsSourceEdge() {
        XCTAssertEqual(
            GoogleBooksCrossPageContract.visualTurnTime(
                boundaryTime: 2,
                segmentDuration: 10,
                sourceBoundaryUTF16End: 100,
                visibleCarryUTF16End: 200,
                consumedUTF16End: 300
            ),
            6,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GoogleBooksCrossPageContract.visualTurnTime(
                boundaryTime: 2,
                segmentDuration: 10,
                sourceBoundaryUTF16End: 100,
                visibleCarryUTF16End: 300,
                consumedUTF16End: 300
            ),
            10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GoogleBooksCrossPageContract.visualTurnTime(
                boundaryTime: 2,
                segmentDuration: 10,
                sourceBoundaryUTF16End: 100,
                visibleCarryUTF16End: 100,
                consumedUTF16End: 300
            ),
            2,
            accuracy: 0.0001
        )
    }

    func testSamePageRefreshKeepsTheCarryCursorAndCannotRestoreSpokenText() {
        let cursor = LiveWebPageConsumedCursor(
            sourceParagraphIndex: 21,
            sourceUTF16End: 160
        )
        let slice = LiveWebPageSourceSlice(
            visibleParagraphIndex: 0,
            sourceParagraphIndex: 21,
            sourceUTF16Start: 100,
            sourceUTF16End: 220,
            text: String(repeating: "a", count: 120)
        )

        let first = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [slice],
            through: cursor
        )
        let refresh = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [slice],
            through: cursor
        )

        XCTAssertEqual(first.texts, [String(repeating: "a", count: 60)])
        XCTAssertEqual(refresh, first)
        XCTAssertEqual(
            GoogleBooksCrossPageContract.domCharacterOffsets(
                in: [slice],
                through: cursor
            ),
            [160]
        )
    }

    func testFullyConsumedMiddlePageCannotReintroduceItsRawSpeechTail() {
        let cursor = LiveWebPageConsumedCursor(
            sourceParagraphIndex: 12,
            sourceUTF16End: 300
        )
        let middle = LiveWebPageSourceSlice(
            visibleParagraphIndex: 0,
            sourceParagraphIndex: 12,
            sourceUTF16Start: 100,
            sourceUTF16End: 200,
            text: String(repeating: "m", count: 100)
        )
        let middleConsumption = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [middle],
            through: cursor
        )
        XCTAssertEqual(middleConsumption.texts, [""])
        let middleDOMOffset = try! XCTUnwrap(
            GoogleBooksCrossPageContract.domCharacterOffsets(
                in: [middle],
                through: cursor
            ).first
        )
        XCTAssertEqual(middleDOMOffset, 200)
        XCTAssertEqual(
            GoogleBooksCrossPageContract.remainingSpeechText(
                String(repeating: "s", count: 200), // absolute [100, 300)
                sourceUTF16Start: 100,
                domCharacterOffset: middleDOMOffset,
                sourceParagraphIndex: 12,
                consumedCursor: cursor
            ),
            "",
            "the absolute consumed cursor, not the clamped DOM origin, owns speech clipping"
        )

        let third = LiveWebPageSourceSlice(
            visibleParagraphIndex: 0,
            sourceParagraphIndex: 12,
            sourceUTF16Start: 200,
            sourceUTF16End: 400,
            text: String(repeating: "t", count: 200)
        )
        let thirdConsumption = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [third],
            through: cursor
        )
        XCTAssertEqual(thirdConsumption.texts, [String(repeating: "t", count: 100)])
        XCTAssertEqual(
            GoogleBooksCrossPageContract.domCharacterOffsets(
                in: [third],
                through: cursor
            ),
            [300]
        )
    }

    func testExplainMarkCharacterRangeConvertsToDOMUTF16AfterEmoji() {
        let text = "A😀BC𠮷DE"
        let range = MarkAnchoring.utf16Range(
            fromCharacterRange: 2..<5,
            in: text
        )
        // Character offsets select "BC𠮷"; both preceding 😀 and selected 𠮷
        // occupy surrogate pairs in WebKit's UTF-16 coordinate space.
        XCTAssertEqual(range, 3..<7)
        XCTAssertNil(MarkAnchoring.utf16Range(
            fromCharacterRange: 0..<99,
            in: text
        ))
    }

    @MainActor
    func testCommittedPageStagesTheInactiveReadAndExplainModes() {
        let document = ReadingDocument(
            id: "googlebooks:b_40EQAAQBAJ",
            title: "Fixture",
            sourceKind: .googleBooks,
            language: "en",
            paragraphs: [],
            sourceURL: GoogleBooksBookValidator.canonicalReaderURL(
                volumeID: "b_40EQAAQBAJ"
            )
        )
        let readVM = ReadAloudViewModel(document: document)
        let explainVM = ExplainViewModel(document: document)
        let pageA = [
            ReadingParagraph(id: 0, text: "old visible page", type: .paragraph),
        ]
        let pageB = [
            ReadingParagraph(id: 0, text: "new visible page", type: .paragraph),
        ]
        readVM.loadWebParagraphs(pageA, language: "en")
        explainVM.loadWebParagraphs(pageA, language: "en")

        readVM.activate()
        explainVM.stageInactiveLiveWebPage(pageB, language: "en")
        XCTAssertEqual(explainVM.stagedLiveWebParagraphTexts, ["new visible page"])
        readVM.deactivate()

        explainVM.activate()
        readVM.stageInactiveLiveWebPage(pageB, language: "en")
        XCTAssertEqual(readVM.stagedLiveWebParagraphTexts, ["new visible page"])
        explainVM.deactivate()
    }

    // MARK: - 账号隔离 / 快照 / 迁移

    @MainActor
    func testAccountChangeReplacesShelfAndDropsPriorAccountAnchors() {
        withIsolatedStore { store in
            let bookA = makeBook(volumeID: "ACCOUNT_A1", title: "Account A")
            let bookB = makeBook(volumeID: "ACCOUNT_B1", title: "Account B")
            let accountA = makeAccount("reader-a@example.com", complete: true)
            let accountB = makeAccount("reader-b@example.com", complete: false)

            store.mergeScrapedBooks([bookA], account: accountA)
            let resumeA =
                "https://play.google.com/books/reader?id=ACCOUNT_A1&pg=GBS.PT12"
            store.updateProgress(
                bookID: bookA.id,
                readerURL: resumeA,
                fingerprint: "page-a",
                progressLabel: "12%"
            )
            XCTAssertNotNil(store.anchor(for: bookA.id))

            // Even an incomplete first scan of a different known account must
            // start from a clean shelf; it must never union two users' books.
            store.mergeScrapedBooks([bookB], account: accountB)

            XCTAssertEqual(store.books.map(\.id), [bookB.id])
            XCTAssertNil(store.book(for: bookA.id))
            XCTAssertNil(store.anchor(for: bookA.id))
            XCTAssertEqual(
                store.accountIdentity,
                GoogleBooksAccountIdentity.hash("reader-b@example.com")
            )
        }
    }

    @MainActor
    func testTrustedAccountChangePurgesOnlyGoogleBooksHistory() {
        withIsolatedStoreAndHistory { store, history in
            let accountA = makeAccount("history-a@example.com", complete: true)
            let accountB = makeAccount("history-b@example.com", complete: true)
            store.mergeScrapedBooks(
                [makeBook(volumeID: "HISTORY_A1", title: "Account A")],
                account: accountA
            )
            let seeded = seedMixedHistory(history)
            XCTAssertEqual(
                Set(history.records.map(\.id)),
                seeded.google.union(seeded.retained)
            )

            store.mergeScrapedBooks(
                [makeBook(volumeID: "HISTORY_B1", title: "Account B")],
                account: accountB
            )

            XCTAssertEqual(Set(history.records.map(\.id)), seeded.retained)
            XCTAssertFalse(history.records.contains { $0.sourceKind == .googleBooks })
            XCTAssertFalse(history.records.contains {
                $0.title.hasPrefix("Old Google")
                    || $0.sourceURL?.contains("OLD_HISTORY") == true
            })
            XCTAssertEqual(
                Set(history.records.map(\.sourceKindRaw)),
                Set([
                    ReadingSourceKind.kindle.rawValue,
                    ReadingSourceKind.weread.rawValue,
                    ReadingSourceKind.text.rawValue,
                ])
            )
        }
    }

    @MainActor
    func testDisconnectPurgesOnlyGoogleBooksHistory() async {
        await withIsolatedStoreAndHistoryAsync { store, history in
            let book = makeBook(volumeID: "DISCONNECT1", title: "Connected")
            store.mergeScrapedBooks(
                [book],
                account: makeAccount("disconnect@example.com", complete: true)
            )
            store.updateProgress(
                bookID: book.id,
                readerURL:
                    "https://play.google.com/books/reader?id=DISCONNECT1&pg=GBS.PT8",
                fingerprint: "disconnect-page",
                progressLabel: "8"
            )
            store.reportError("transient")
            let seeded = seedMixedHistory(history)

            await store.disconnectAccount()

            XCTAssertFalse(store.hasConnected)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertTrue(store.anchors.isEmpty)
            XCTAssertNil(store.accountLabel)
            XCTAssertNil(store.accountIdentity)
            XCTAssertNil(store.lastError)
            XCTAssertEqual(Set(history.records.map(\.id)), seeded.retained)
            XCTAssertFalse(history.records.contains { $0.sourceKind == .googleBooks })
            XCTAssertEqual(
                Set(history.records.map(\.sourceKindRaw)),
                Set([
                    ReadingSourceKind.kindle.rawValue,
                    ReadingSourceKind.weread.rawValue,
                    ReadingSourceKind.text.rawValue,
                ])
            )
        }
    }

    @MainActor
    func testDisconnectPreservesSharedGoogleWebSessionCookie() async throws {
        let webSessionStore = WKWebsiteDataStore.nonPersistent()
        let cookieName = "CastReaderGoogleSessionSentinel-\(UUID().uuidString)"
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".google.com",
            .path: "/",
            .name: cookieName,
            .value: "retained",
            .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 300),
        ]))
        await setCookie(cookie, in: webSessionStore.httpCookieStore)

        try await withIsolatedStoreAndHistoryAsync(
            websiteDataStore: webSessionStore
        ) { store, _ in
            store.mergeScrapedBooks(
                [makeBook(volumeID: "SESSIONKEEP1", title: "Keep Session")],
                account: makeAccount("session@example.com", complete: true)
            )

            await store.disconnectAccount()

            let cookies = await allCookies(in: webSessionStore.httpCookieStore)
            XCTAssertTrue(cookies.contains {
                $0.name == cookieName
                    && $0.domain.hasSuffix("google.com")
                    && $0.value == "retained"
            })
        }
    }

    @MainActor
    func testSharedGoogleWebSessionKeepsItsPersistentProfileIdentifier() {
        let first = GoogleWebSession.websiteDataStore
        let second = GoogleWebSession.websiteDataStore

        XCTAssertTrue(first.isPersistent)
        XCTAssertEqual(first.identifier, GoogleWebSession.websiteDataStoreIdentifier)
        XCTAssertEqual(second.identifier, first.identifier)
        XCTAssertEqual(
            first.identifier?.uuidString,
            "739ED7D6-8C70-4D85-971C-5DDAE87C6C6F"
        )
    }

    @MainActor
    func testOnlyCompleteSnapshotRemovesMissingBooks() {
        withIsolatedStore { store in
            let bookA = makeBook(volumeID: "SNAPSHOT_A", title: "Snapshot A")
            let bookB = makeBook(volumeID: "SNAPSHOT_B", title: "Snapshot B")
            let complete = makeAccount("snapshot@example.com", complete: true)
            let partial = makeAccount("snapshot@example.com", complete: false)

            store.mergeScrapedBooks([bookA, bookB], account: complete)
            store.updateProgress(
                bookID: bookB.id,
                readerURL:
                    "https://play.google.com/books/reader?id=SNAPSHOT_B&pg=GBS.PT8",
                fingerprint: "page-b",
                progressLabel: nil
            )

            store.mergeScrapedBooks([bookA], account: partial)
            XCTAssertNotNil(store.book(for: bookB.id))
            XCTAssertNotNil(store.anchor(for: bookB.id))

            store.mergeScrapedBooks([bookA], account: complete)
            XCTAssertNil(store.book(for: bookB.id))
            XCTAssertNil(store.anchor(for: bookB.id))
        }
    }

    @MainActor
    func testLocalRecoveryURLDoesNotDestroyResumeState() {
        withIsolatedStore { store in
            let book = makeBook(volumeID: "RECOVERY1", title: "Recovery")
            store.mergeScrapedBooks(
                [book],
                account: makeAccount("recovery@example.com", complete: true)
            )
            let resume =
                "https://play.google.com/books/reader?id=RECOVERY1&pg=GBS.PT42"
            store.updateProgress(
                bookID: book.id,
                readerURL: resume,
                fingerprint: "page-42",
                progressLabel: "42%"
            )
            let anchorBefore = store.anchor(for: book.id)

            XCTAssertEqual(
                store.localRecoveryURL(bookID: book.id, failedURL: resume),
                book.readerURL
            )
            XCTAssertEqual(store.book(for: book.id)?.lastReaderURL, resume)
            XCTAssertEqual(store.anchor(for: book.id), anchorBefore)
        }
    }

    @MainActor
    func testLoadSanitizesLegacyResumeURLsAndAnchors() throws {
        let suite = "GoogleBooksContractTests.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var unsafe = makeBook(volumeID: "MIGRATE1", title: "Unsafe Resume")
        unsafe.lastReaderURL =
            "http://play.google.com/books/reader?id=MIGRATE1&pg=GBS.PT1"
        var recovered = makeBook(volumeID: "MIGRATE2", title: "Anchor Resume")
        recovered.lastReaderURL = nil
        let discarded = GoogleBooksBook(
            id: "googlebooks:DISCARD1",
            title: "Wrong Host",
            author: "",
            coverURL: nil,
            readerURL: "https://evil.example.com/books/reader?id=DISCARD1",
            progressLabel: "",
            volumeID: "DISCARD1",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )
        defaults.set(
            try JSONEncoder().encode([unsafe, recovered, discarded]),
            forKey: "googlebooks.library.books.v1"
        )
        defaults.set(
            try JSONEncoder().encode([
                unsafe.id: GoogleBooksReadingAnchor(
                    bookID: unsafe.id,
                    readerURL:
                        "https://play.google.com/books/reader?id=OTHERBOOK&pg=GBS.PT9",
                    pageFingerprint: "wrong-book",
                    progressLabel: nil,
                    updatedAt: Date()
                ),
                recovered.id: GoogleBooksReadingAnchor(
                    bookID: recovered.id,
                    readerURL:
                        "https://play.google.com/books/reader?id=MIGRATE2&pg=GBS.PT7",
                    pageFingerprint: "valid",
                    progressLabel: "7%",
                    updatedAt: Date()
                ),
            ]),
            forKey: "googlebooks.library.anchors.v1"
        )
        defaults.set(
            "reader@example.com",
            forKey: "googlebooks.library.accountIdentity.v1"
        )

        let store = GoogleBooksLibraryStore(defaults: defaults)

        XCTAssertNil(store.book(for: unsafe.id)?.lastReaderURL)
        XCTAssertNil(store.anchor(for: unsafe.id))
        XCTAssertEqual(
            store.book(for: recovered.id)?.lastReaderURL,
            "https://play.google.com/books/reader?id=MIGRATE2&pg=GBS.PT7"
        )
        XCTAssertEqual(
            store.anchor(for: recovered.id)?.readerURL,
            "https://play.google.com/books/reader?id=MIGRATE2&pg=GBS.PT7"
        )
        XCTAssertNil(store.book(for: discarded.id))
        XCTAssertNil(store.accountIdentity)
    }

    // MARK: - 源类型

    func testGoogleBooksIsALiveWebLibrarySource() {
        XCTAssertTrue(ReadingSourceKind.googleBooks.isWebRendered)
        XCTAssertTrue(ReadingSourceKind.googleBooks.isLiveWebLibrary)
        XCTAssertFalse(ReadingSourceKind.googleBooks.isOCRImageRendered)
        XCTAssertFalse(ReadingSourceKind.googleBooks.isNativeTextRendered)
        // 绑定书库有独立书架条，不进「继续阅读」。
        XCTAssertFalse(HomeContinueContract.includes(.googleBooks))
    }

    func testLibraryFilterIncludesEveryBoundReaderSource() {
        XCTAssertTrue(LibraryView.kindOrder.contains(.kindle))
        XCTAssertTrue(LibraryView.kindOrder.contains(.weread))
        XCTAssertTrue(LibraryView.kindOrder.contains(.googleBooks))
    }

    @MainActor
    func testHistorySourceURLCanAdvanceWithoutCreatingAnotherRecord() {
        let id = "googlebooks-history-\(UUID().uuidString)"
        let history = HistoryStore.shared
        let document = ReadingDocument(
            id: id,
            title: "History URL Contract",
            sourceKind: .text,
            paragraphs: [],
            sourceURL: "https://play.google.com/books/reader?id=b_40EQAAQBAJ"
        )
        history.record(document)
        defer { history.delete(id) }

        let resume = "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PT12"
        history.updateSourceURL(documentID: id, sourceURL: resume)

        XCTAssertEqual(history.records.first(where: { $0.id == id })?.sourceURL, resume)
        XCTAssertEqual(history.records.filter { $0.id == id }.count, 1)
    }

    @MainActor
    func testExplicitBookOpenClearsAStaleReaderError() {
        let store = GoogleBooksLibraryStore.shared
        store.reportError("expired")
        let book = GoogleBooksBook(
            id: "googlebooks:\(UUID().uuidString)",
            title: "Error Recovery Contract",
            author: "",
            coverURL: nil,
            readerURL: "https://play.google.com/books/reader?id=b_40EQAAQBAJ",
            progressLabel: "",
            volumeID: "b_40EQAAQBAJ",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )

        store.markOpened(book)

        XCTAssertNil(store.lastError)
    }

    func testOnboardingSourceMapsToTheReaderAndAnalyticsIdentity() {
        XCTAssertEqual(BoundLibraryOnboardingSource.googleBooks.readingSourceKind, .googleBooks)
        XCTAssertEqual(BoundLibraryOnboardingSource.googleBooks.analyticsSource, .googleBooks)
        XCTAssertEqual(BoundLibraryOnboardingSource.googleBooks.analyticsFormat, .googleBooks)
        XCTAssertEqual(AnalyticsContentSource.googleBooks.rawValue, "google_books")
        XCTAssertTrue(BoundLibraryOnboardingSource.allCases.contains(.googleBooks))
    }

    private func makeBook(volumeID: String, title: String) -> GoogleBooksBook {
        GoogleBooksBook(
            id: "googlebooks:\(volumeID)",
            title: title,
            author: "",
            coverURL: nil,
            readerURL: GoogleBooksBookValidator.canonicalReaderURL(volumeID: volumeID),
            progressLabel: "",
            volumeID: volumeID,
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )
    }

    private func makeAccount(
        _ rawIdentity: String,
        complete: Bool
    ) -> GoogleBooksAccountInfo {
        GoogleBooksAccountInfo(
            label: "Google · example.com",
            identity: GoogleBooksAccountIdentity.hash(rawIdentity),
            hasAccountEvidence: true,
            isShelfContext: true,
            isCompleteSnapshot: complete
        )
    }

    @MainActor
    private func seedMixedHistory(
        _ history: HistoryStore
    ) -> (google: Set<String>, retained: Set<String>) {
        let entries: [(id: String, title: String, kind: ReadingSourceKind, url: String?)] = [
            (
                "googlebooks:OLD_HISTORY_A",
                "Old Google Title A",
                .googleBooks,
                "https://play.google.com/books/reader?id=OLD_HISTORY_A&pg=GBS.PT1"
            ),
            (
                "googlebooks:OLD_HISTORY_B",
                "Old Google Title B",
                .googleBooks,
                "https://play.google.com/books/reader?id=OLD_HISTORY_B&pg=GBS.PT9"
            ),
            ("kindle-history", "Kindle", .kindle, "https://read.amazon.com/"),
            ("weread-history", "WeRead", .weread, "https://weread.qq.com/"),
            ("text-history", "Text", .text, nil),
        ]
        for entry in entries {
            history.record(
                ReadingDocument(
                    id: entry.id,
                    title: entry.title,
                    sourceKind: entry.kind,
                    language: "en",
                    paragraphs: [
                        ReadingParagraph(id: 0, text: "\(entry.title) body"),
                    ],
                    sourceURL: entry.url
                )
            )
        }
        return (
            google: Set(entries.filter { $0.kind == .googleBooks }.map(\.id)),
            retained: Set(entries.filter { $0.kind != .googleBooks }.map(\.id))
        )
    }

    @MainActor
    private func withIsolatedStore(
        _ body: (GoogleBooksLibraryStore) throws -> Void
    ) rethrows {
        try withIsolatedStoreAndHistory { store, _ in
            try body(store)
        }
    }

    @MainActor
    private func withIsolatedStoreAndHistory(
        _ body: (GoogleBooksLibraryStore, HistoryStore) throws -> Void
    ) rethrows {
        let suite = "GoogleBooksContractTests.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GoogleBooksContractTests.history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)
        try body(
            GoogleBooksLibraryStore(defaults: defaults, historyStore: history),
            history
        )
    }

    @MainActor
    private func withIsolatedStoreAndHistoryAsync(
        websiteDataStore: WKWebsiteDataStore = .nonPersistent(),
        _ body: (GoogleBooksLibraryStore, HistoryStore) async throws -> Void
    ) async rethrows {
        let suite = "GoogleBooksContractTests.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GoogleBooksContractTests.history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)
        try await body(
            GoogleBooksLibraryStore(
                defaults: defaults,
                historyStore: history,
                websiteDataStore: websiteDataStore
            ),
            history
        )
    }

    @MainActor
    private func setCookie(
        _ cookie: HTTPCookie,
        in store: WKHTTPCookieStore
    ) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    @MainActor
    private func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

@MainActor
final class GoogleBooksLibraryScanWebTests: XCTestCase {
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Error>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private var webView: WKWebView?
    private var navigationWaiter: NavigationWaiter?

    override func tearDown() async throws {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        navigationWaiter = nil
        try await super.tearDown()
    }

    func testLibraryScanWalksVirtualizedShelfAndReturnsAccountEvidence() async throws {
        let html = """
        <!doctype html>
        <html><body>
          <header><button data-email="Reader@Example.com">Account</button></header>
          <main id="shelf" style="height:140px;overflow-y:auto">
            <div style="height:620px">
              <div role="listitem" style="height:180px">
                <a title="The Enchanted Isles"
                   href="/books/reader?id=b_40EQAAQBAJ&amp;pg=GBS.PP1">
                  <img src="https://books.googleusercontent.com/cover.jpg">
                </a>
                <span class="author">Sofia Moreau</span>
                <span role="progressbar" aria-valuenow="42"></span>
              </div>
              <div role="listitem" style="height:180px">
                <a title="Second Volume"
                   href="/books/reader?id=SECOND01"></a>
              </div>
            </div>
          </main>
        </body></html>
        """
        let view = try await loadShelf(html)

        let first = try await scan(view)
        XCTAssertTrue(first.authenticated)
        XCTAssertTrue(first.hasAccountEvidence)
        XCTAssertTrue(first.isShelfContext)
        XCTAssertFalse(first.isCompleteSnapshot)
        XCTAssertEqual(first.books.map(\.id).sorted(), [
            "googlebooks:SECOND01",
            "googlebooks:b_40EQAAQBAJ",
        ])
        XCTAssertEqual(
            first.account?.identity,
            GoogleBooksAccountIdentity.hash("reader@example.com")
        )

        let scrollTop = try await view.evaluateJavaScript(
            "document.getElementById('shelf').scrollTop"
        )
        XCTAssertGreaterThan((scrollTop as? NSNumber)?.doubleValue ?? 0, 0)

        var completed = first
        for _ in 0..<4 where !completed.isCompleteSnapshot {
            completed = try await scan(view)
        }
        XCTAssertTrue(completed.isCompleteSnapshot)
    }

    func testSessionProbeRewindsShelfWithoutConsumingFirstViewport() async throws {
        let view = try await loadShelf(
            """
            <!doctype html><html><body>
              <header><button data-email="Reader@Example.com">Account</button></header>
              <main id="shelf" style="height:140px;overflow-y:auto">
                <div style="height:620px">
                  <a title="First Volume"
                     href="/books/reader?id=FIRST001">First</a>
                </div>
              </main>
            </body></html>
            """
        )
        _ = try await view.evaluateJavaScript(
            "document.getElementById('shelf').scrollTop = 240"
        )

        let value = try await view.evaluateJavaScript(
            GoogleBooksWebScripts.sessionProbe
        )
        let raw = try XCTUnwrap(value as? [String: Any])
        let result = GoogleBooksScanResult(raw)
        let scrollTop = try await view.evaluateJavaScript(
            "document.getElementById('shelf').scrollTop"
        )

        XCTAssertTrue(result.authenticated)
        XCTAssertEqual((scrollTop as? NSNumber)?.doubleValue, 0)
    }

    func testPublicReaderLinksCannotMasqueradeAsAnAuthenticatedShelf() async throws {
        let view = try await loadShelf(
            """
            <!doctype html><html><body>
              <a href="https://accounts.google.com/ServiceLogin">Sign in</a>
              <a title="Public Preview"
                 href="/books/reader?id=b_40EQAAQBAJ">Preview</a>
            </body></html>
            """
        )

        let result = try await scan(view)
        XCTAssertTrue(result.authRequired)
        XCTAssertFalse(result.authenticated)
        XCTAssertFalse(result.hasAccountEvidence)
        XCTAssertNil(result.account)
        XCTAssertEqual(result.books.count, 1)
    }

    func testAuthenticatedEmptyShelfCanProduceATrustedCompleteSnapshot() async throws {
        let view = try await loadShelf(
            """
            <!doctype html><html><body>
              <header><button data-email="empty@example.com">Account</button></header>
              <main><p>No books yet</p></main>
            </body></html>
            """
        )

        let result = try await scan(view)
        XCTAssertTrue(result.authenticated)
        XCTAssertTrue(result.hasAccountEvidence)
        XCTAssertTrue(result.isShelfContext)
        XCTAssertTrue(result.isCompleteSnapshot)
        XCTAssertTrue(result.books.isEmpty)
    }

    private func loadShelf(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            configuration: configuration
        )
        let waiter = NavigationWaiter()
        view.navigationDelegate = waiter
        webView = view
        navigationWaiter = waiter

        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            view.loadHTMLString(
                html,
                baseURL: URL(string: "https://play.google.com/books")
            )
        }
        return view
    }

    private func scan(_ view: WKWebView) async throws -> GoogleBooksScanResult {
        let value = try await view.evaluateJavaScript(GoogleBooksWebScripts.libraryScan)
        let raw = try XCTUnwrap(value as? [String: Any])
        return GoogleBooksScanResult(raw)
    }
}
