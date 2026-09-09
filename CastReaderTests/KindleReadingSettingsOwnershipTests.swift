import XCTest
import UIKit
import WebKit
@testable import CastReader

/// Run in the dedicated QA test host: the real model shares AudioPlayerService.
/// The model never receives loadIfNeeded(), and its navigation delegate is
/// detached before loading this self-contained fixture. No account preferences,
/// Kindle cookies, or service routing are changed by these tests.
@MainActor
final class KindleReadingSettingsOwnershipTests: XCTestCase {
    private var window: UIWindow!
    private weak var previousKeyWindow: UIWindow?
    private var model: KindleBookViewModel!
    private var fixtureReaderURL: URL!

    override func setUp() {
        super.setUp()
        AudioPlayerService.shared.stop()
        previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let storefront = KindleStorefront.entry(id: "us") else {
            XCTFail("The fixture requires the canonical US storefront")
            return
        }
        fixtureReaderURL = storefront.readerURL(asin: "B000000001")
        let book = KindleBook(
            id: "settings-ownership-\(UUID().uuidString)",
            asin: "B000000001",
            title: "Local settings fixture",
            author: "",
            coverURL: nil,
            readerURL: fixtureReaderURL.absoluteString,
            progressLabel: "",
            storefrontID: "us",
            lastOpenedAt: nil,
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
        model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent())
        model.webView.navigationDelegate = nil
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        model.webView.frame = window.bounds
        controller.view.addSubview(model.webView)
    }

    override func tearDown() {
        PlaybackVoicePanelCenter.shared.dismiss()
        model?.webView.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureLightLock")
        model?.destroy()
        model?.webView.removeFromSuperview()
        AudioPlayerService.shared.stop()
        model = nil
        window?.isHidden = true
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        super.tearDown()
    }

    func testVoicePanelRetainsActualReadViewportThroughDismissal() async throws {
        try await assertVoicePanelKeepsViewport(mode: .read)
    }

    func testVoicePanelRetainsActualExplainViewportThroughDismissal() async throws {
        try await assertVoicePanelKeepsViewport(mode: .explain)
    }

    private func assertVoicePanelKeepsViewport(mode: ReaderMode) async throws {
        let center = PlaybackVoicePanelCenter.shared
        center.dismiss()
        try await loadFixture(initializeControls: false)
        model.mode = mode
        let crop = KindleViewportCrop(scale: 1.25, heightScale: 1.2, offsetX: -48.75, offsetY: -60)
        let fit = KindleViewportPresentationFit(scale: 0.9, translationX: 12, translationY: 8)
        let container = KindleWebViewContainer(webView: model.webView, crop: crop, presentationFit: fit)
        let actualSize = CGSize(width: 390, height: 650)
        container.frame = CGRect(origin: .zero, size: actualSize)
        window.rootViewController!.view.addSubview(container)
        container.layoutIfNeeded()
        model.setReaderSurfaceAttached(true)
        model.setReaderPresented(true)
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = try await model.webView.evaluateJavaScript("window.panelResizes=0;window.addEventListener('resize',()=>panelResizes++);true")
        let before = try await voiceViewportMetrics()
        let webBounds = model.webView.bounds
        let webCenter = model.webView.center
        let webTransform = model.webView.transform

        // Present is synchronous. The snapshot must exist before any panel body
        // can lay out, even if prior model/preferences describe another orientation.
        center.present(language: "en")
        let held = try XCTUnwrap(model.playerOverlayViewport)
        XCTAssertEqual(held.surfaceSize, actualSize)
        XCTAssertEqual(held.crop, crop)
        XCTAssertEqual(held.fit, fit)
        let staleLandscape = CGSize(width: 814, height: 297)
        XCTAssertNotEqual(held.surfaceSize, staleLandscape)

        func applyPanelLayoutProposal() {
            let measured = CGSize(width: 414, height: 380)
            let size = KindleReaderSurfaceContract.renderSize(
                measured: measured, stable: model.playerOverlayViewport?.surfaceSize ?? measured,
                isPlayerOverlayPresented: model.playerOverlayViewport != nil)
            container.frame.size = size
            container.crop = model.effectiveViewportCrop(forSurfaceSize: size)
            container.presentationFit = model.effectiveViewportPresentationFit(forSurfaceSize: size)
            container.layoutIfNeeded()
        }
        applyPanelLayoutProposal()
        center.dismiss()
        XCTAssertNotNil(model.playerOverlayViewport, "Dismissing request must not release geometry during the panel animation")
        applyPanelLayoutProposal()
        try await Task.sleep(nanoseconds: 100_000_000)
        center.present(language: "en")
        applyPanelLayoutProposal()
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertNotNil(model.playerOverlayViewport, "An earlier dismissal must not unfreeze a reopened panel")
        applyPanelLayoutProposal()
        XCTAssertEqual(model.webView.bounds, webBounds)
        XCTAssertEqual(model.webView.center, webCenter)
        XCTAssertEqual(model.webView.transform, webTransform)
        let during = try await voiceViewportMetrics()
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: during),
                       "Opening/closing voice UI must not resize, replace, navigate or reload the web document")
        center.dismiss()
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertNil(model.playerOverlayViewport)
        let resumedSize = KindleReaderSurfaceContract.renderSize(measured: actualSize, stable: staleLandscape,
                                                                 isPlayerOverlayPresented: false)
        container.frame.size = resumedSize
        container.layoutIfNeeded()
        let after = try await voiceViewportMetrics()
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
    }

    private func voiceViewportMetrics() async throws -> [String: Any] {
        let value = try await model.webView.evaluateJavaScript("""
        ({width:innerWidth,height:innerHeight,resizes:panelResizes,
          documentID:fixtureLoadID,url:location.href,history:history.length})
        """)
        return try XCTUnwrap(value as? [String: Any])
    }

    func testEarlyAaDoesNotPresentOrCancelRealBootstrapAndSyncObserverStillRuns() async throws {
        try await loadFixture(initializeControls: false)
        XCTAssertFalse(model.readerControlsReady)
        model.openReadingSettings()
        XCTAssertFalse(model.isReadingSettingsPresented)
        XCTAssertFalse(model.isApplyingReadingSettings)
        let before = try await snapshot()
        XCTAssertEqual(before["openClicks"] as? Int, 0)

        let setup = Task { @MainActor in await self.model.prepareReaderControls(reason: "local-early-aa") }
        model.openReadingSettings()
        XCTAssertFalse(model.isReadingSettingsPresented, "An early Aa cannot cancel the queued bootstrap task")
        let initialized = await setup.value
        XCTAssertTrue(initialized)
        XCTAssertTrue(model.readerControlsReady)
        _ = try await model.webView.evaluateJavaScript("window.fixtureShowSyncDialog(); true")
        try await waitUntil { self.model.isKindleSyncDialogVisible }
        XCTAssertTrue(model.readerControlsReady, "A visible sync choice does not undo the installed observer")
        model.openReadingSettings()
        XCTAssertFalse(model.isReadingSettingsPresented)
        let choices = try await model.webView.evaluateJavaScript("window.fixtureSyncChoices") as? [String]
        XCTAssertEqual(choices, [], "Bootstrap observes the prompt without choosing a reading location")
    }

    func testNewDocumentRevokesReadyAndNeedsItsOwnBootstrapBeforeAa() async throws {
        try await loadFixture()
        XCTAssertTrue(model.readerControlsReady)
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        let navigation = SettingsFixtureNavigationObserver(model: model)
        model.webView.navigationDelegate = navigation
        try await loadFixture(initializeControls: false)
        XCTAssertFalse(model.readerControlsReady)
        XCTAssertFalse(model.isReadingSettingsPresented)
        XCTAssertFalse(model.isApplyingReadingSettings)
        // Match SwiftUI's dismissal callback: the old session cannot lock or
        // click controls in the replacement document.
        model.closeReadingSettings()
        model.openReadingSettings()
        XCTAssertFalse(model.isReadingSettingsPresented)
        let before = try await snapshot()
        XCTAssertEqual(before["openClicks"] as? Int, 0)
        XCTAssertEqual(before["closeClicks"] as? Int, 0)
        let ready = await model.prepareReaderControls(reason: "local-replacement-document")
        XCTAssertTrue(ready)
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        XCTAssertTrue(model.isReadingSettingsPresented)
        XCTAssertNil(model.readingSettingsError)
        withExtendedLifetime(navigation) { }
    }

    func testFullCaptureSettingsRelockPreservesNativeFontWithoutSyntheticResize() async throws {
        try await assertSettingsRelockPreservesNativeFont(useLightLock: false)
    }

    func testLightBootstrapSettingsRelockPreservesNativeFontWithoutSyntheticResize() async throws {
        try await assertSettingsRelockPreservesNativeFont(useLightLock: true)
    }

    func testAaRetainsAppliedPortraitViewportWhenModelStillHasLandscapeCrop() async throws {
        try await assertAaRetainsAppliedPortraitViewport(presentationFit: .identity)
    }

    func testAaAlsoRetainsTheAppliedPresentationFitAcrossStaleSurfaceCallback() async throws {
        try await assertAaRetainsAppliedPortraitViewport(presentationFit: KindleViewportPresentationFit(
            scale: 0.94, translationX: 12, translationY: 18
        ))
    }

    func testConfirmedNativeFontDoneClosesAndRelocksOnceWithoutReloading() async throws {
        try await loadNativeFontCommitFixture()
        let navigation = SettingsReloadNavigationSpy()
        model.webView.navigationDelegate = navigation
        let originalURL = try XCTUnwrap(model.webView.url)
        XCTAssertEqual(originalURL, fixtureReaderURL)
        XCTAssertTrue(KindleStorefrontNavigationPolicy.allowsReaderMainFrame(
            originalURL, expectedStorefrontID: "us", expectedASIN: "B000000001"
        ))
        try await openAndCommitNativeFont()
        let committed = try await nativeFontCommitSnapshot()
        XCTAssertEqual(committed["fontClicks"] as? Int, 1)
        XCTAssertEqual(committed["value"] as? Int, 7)
        XCTAssertEqual(committed["saved"] as? Int, 7)

        model.closeReadingSettings()
        model.closeReadingSettings() // SwiftUI onDismiss while Done is in flight.
        try await waitUntil { !self.model.isApplyingReadingSettings && !self.model.isReadingSettingsPresented }
        let closed = try await nativeFontCommitSnapshot()
        XCTAssertEqual(closed["closeClicks"] as? Int, 1)
        XCTAssertEqual(closed["panelHidden"] as? Bool, true)
        XCTAssertEqual(closed["locked"] as? Bool, true)
        XCTAssertEqual(closed["saved"] as? Int, 7)
        let events = try XCTUnwrap(closed["events"] as? [String])
        let closeIndex = try XCTUnwrap(events.firstIndex(of: "close"))
        let relockIndex = try XCTUnwrap(events.lastIndex(of: "lock:true"))
        XCTAssertLessThan(closeIndex, relockIndex)
        XCTAssertTrue(model.readerControlsReady, "Done keeps the current initialized document")
        XCTAssertFalse(model.isReadingSettingsPresented)
        XCTAssertNil(model.readVM)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)

        model.closeReadingSettings() // A repeated Done after the successful session.
        try await assertNoAdditionalNavigation(navigation, count: 0)
        XCTAssertEqual(model.webView.url, originalURL)
        XCTAssertTrue(navigation.types.isEmpty, "Font changes cannot navigate the user away from the current page")
        XCTAssertNil(model.readingSettingsError)
        withExtendedLifetime(navigation) { }
    }

    func testNoFontChangeFootnoteOnlyAndUnpersistedFontDoNotReload() async throws {
        let preferenceKey = "kindle.skipFootnoteReferences.v1"
        let originalPreference = UserDefaults.standard.object(forKey: preferenceKey)
        defer {
            if let originalPreference { UserDefaults.standard.set(originalPreference, forKey: preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: preferenceKey) }
        }
        for scenario in ["open-close", "footnote-only", "unpersisted-font"] {
            try await loadNativeFontCommitFixture(persistChanges: scenario != "unpersisted-font")
            let navigation = SettingsReloadNavigationSpy()
            model.webView.navigationDelegate = navigation
            model.openReadingSettings()
            try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
            if scenario == "footnote-only" {
                model.setSkipsFootnoteReferences(!model.skipsFootnoteReferences)
            } else if scenario == "unpersisted-font" {
                model.changeReaderFont(by: 1)
                try await waitUntil { self.model.readerFontValue == 7 && !self.model.isApplyingReadingSettings }
            }
            model.closeReadingSettings()
            try await waitUntil { !self.model.isApplyingReadingSettings }
            model.closeReadingSettings()
            try await assertNoAdditionalNavigation(navigation, count: 0)
            let closed = try await nativeFontCommitSnapshot()
            XCTAssertEqual(closed["panelHidden"] as? Bool, true, scenario)
            XCTAssertEqual(closed["locked"] as? Bool, true, scenario)
            XCTAssertEqual(closed["closeClicks"] as? Int, 1, scenario)
            XCTAssertEqual(closed["saved"] as? Int, 6, scenario)
            XCTAssertEqual(closed["fontClicks"] as? Int, scenario == "unpersisted-font" ? 1 : 0, scenario)
            XCTAssertFalse(model.isReadingSettingsPresented, scenario)
            XCTAssertNil(model.readingSettingsError, scenario)
            XCTAssertFalse(AudioPlayerService.shared.isPlaying, scenario)
            withExtendedLifetime(navigation) { }
        }
    }

    func testDoneDoesNotReloadOrRewriteAnUnrelatedPreferenceMismatch() async throws {
        try await loadNativeFontCommitFixture()
        let navigation = SettingsReloadNavigationSpy()
        model.webView.navigationDelegate = navigation
        try await openAndCommitNativeFont()
        _ = try await model.webView.evaluateJavaScript("""
        localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:5})); true
        """)
        model.closeReadingSettings()
        try await waitUntil { !self.model.isReadingSettingsPresented && !self.model.isApplyingReadingSettings }
        try await assertNoAdditionalNavigation(navigation, count: 0)
        let closed = try await nativeFontCommitSnapshot()
        XCTAssertEqual(closed["value"] as? Int, 7)
        XCTAssertEqual(closed["saved"] as? Int, 5, "An arbitrary mismatch outside resize is not repair authorization")
        XCTAssertEqual(closed["closeClicks"] as? Int, 1)
        XCTAssertEqual(closed["panelHidden"] as? Bool, true)
        XCTAssertEqual(closed["locked"] as? Bool, true)
        XCTAssertNil(model.readingSettingsError)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
        model.closeReadingSettings()
        try await assertNoAdditionalNavigation(navigation, count: 0)
        withExtendedLifetime(navigation) { }
    }

    func testNavigationAndStopRevokeFontSettingsCloseWithoutAnyReload() async throws {
        for revocation in ["navigation", "stop"] {
            try await loadNativeFontCommitFixture()
            try await openAndCommitNativeFont()
            if revocation == "navigation" {
                let observer = SettingsFixtureNavigationObserver(model: model)
                model.webView.navigationDelegate = observer
                // A real local replacement navigation invokes the production
                // didStart invalidation, without requesting any remote page.
                try await loadFixture(initializeControls: false)
                XCTAssertFalse(model.readerControlsReady)
                withExtendedLifetime(observer) { }
            } else {
                model.stopAll()
            }
            let navigation = SettingsReloadNavigationSpy()
            model.webView.navigationDelegate = navigation
            model.closeReadingSettings()
            model.closeReadingSettings()
            try await waitUntil { !self.model.isApplyingReadingSettings }
            try await assertNoAdditionalNavigation(navigation, count: 0)
            XCTAssertFalse(AudioPlayerService.shared.isPlaying, revocation)
            XCTAssertNil(model.readVM, revocation)
            withExtendedLifetime(navigation) { }
        }
    }

    func testResizeCompatibilityRestoresOnlyFontPairAndNotifiesNativeHook() async throws {
        try await loadFontResizeCompatibilityFixture()
        _ = try await model.webView.evaluateJavaScript("window.dispatchEvent(new Event('resize')); true")
        try await awaitFontResizeTurn()
        let state = try await fontResizeSnapshot()
        XCTAssertEqual(state["index"] as? Int, 6)
        XCTAssertEqual(state["size"] as? Int, 26)
        XCTAssertEqual(state["nativeIndex"] as? Int, 6, "The native hook must adopt the corrected object")
        XCTAssertEqual(state["margin"] as? String, "wide", "Keep the other native resize updates")
        XCTAssertEqual(state["theme"] as? String, "night")
        XCTAssertEqual(state["hookIndices"] as? [Int], [5, 6])
        XCTAssertEqual(state["invalidHookDetails"] as? Int, 0)
    }

    func testNativeWKResizeAlsoPreservesFontAndPublishesCorrectiveHook() async throws {
        try await loadFontResizeCompatibilityFixture()
        let oldBounds = model.webView.bounds
        model.webView.bounds = CGRect(origin: oldBounds.origin, size: CGSize(width: oldBounds.width, height: oldBounds.height + 48))
        defer { model.webView.bounds = oldBounds }
        var observed = false
        for _ in 0..<100 {
            let state = try await fontResizeSnapshot()
            if (state["trustedResizes"] as? Int ?? 0) > 0 {
                observed = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard observed else { throw FixtureError.timedOut("a real WK bounds change must deliver a trusted resize") }
        try await awaitFontResizeTurn()
        let state = try await fontResizeSnapshot()
        XCTAssertEqual(state["index"] as? Int, 6)
        XCTAssertEqual(state["size"] as? Int, 26)
        XCTAssertEqual(state["nativeIndex"] as? Int, 6)
        XCTAssertEqual((state["hookIndices"] as? [Int])?.last, 6)
    }

    func testExplicitNativeFontChangeCancelsPendingResizeCorrection() async throws {
        try await loadFontResizeCompatibilityFixture()
        // Dispatch and the explicit production change occur in one WebContent
        // task, before the repair's timer. There is no test-only cancel call.
        let change = KindleReadingSettingsScript.change(by: 1)
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          window.dispatchEvent(new Event('resize'));
          window.fixtureChangeResult=\(change);
          return true;
        })()
        """)
        let result = try await settingsJSON("window.fixtureChangeResult")
        XCTAssertEqual(result["ok"] as? Bool, true)
        try await awaitFontResizeTurn()
        let state = try await fontResizeSnapshot()
        // Amazon's stale storage hook changes its preference object, while
        // the visible range stays at 6. Real A+ must therefore choose 7/27.
        XCTAssertEqual(state["index"] as? Int, 7)
        XCTAssertEqual(state["size"] as? Int, 27)
        XCTAssertEqual(state["hookIndices"] as? [Int], [5], "Cancelled repair must not send its own hook")
        let second = try await settingsJSON(KindleReadingSettingsScript.change(by: 1))
        XCTAssertEqual(second["ok"] as? Bool, true)
        try await awaitFontResizeTurn()
        let final = try await fontResizeSnapshot()
        XCTAssertEqual(final["index"] as? Int, 8)
        XCTAssertEqual(final["size"] as? Int, 28)
    }

    func testSameKeyWriteOutsideResizeWinsOverPendingCorrection() async throws {
        try await loadFontResizeCompatibilityFixture()
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          window.dispatchEvent(new Event('resize'));
          localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:9,fontSize:29,sideMarginsSize:'latest',theme:'day'}));
          return true;
        })()
        """)
        try await awaitFontResizeTurn()
        let state = try await fontResizeSnapshot()
        XCTAssertEqual(state["index"] as? Int, 9)
        XCTAssertEqual(state["size"] as? Int, 29)
        XCTAssertEqual(state["margin"] as? String, "latest")
        XCTAssertEqual(state["hookIndices"] as? [Int], [5])
    }

    func testUnrelatedLocalKeysAndSessionStoragePassThroughDuringResize() async throws {
        try await loadFontResizeCompatibilityFixture()
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          const stale=window.fixtureResizeWrite;
          window.fixtureResizeWrite=()=>{
            stale();
            localStorage.setItem('fixture.other','unchanged-other');
            sessionStorage.setItem('KWR_Display_Settings','session-only');
          };
          window.dispatchEvent(new Event('resize'));
          return true;
        })()
        """)
        try await awaitFontResizeTurn()
        let state = try await fontResizeSnapshot()
        XCTAssertEqual(state["index"] as? Int, 6)
        let unrelated = try await settingsJSON("JSON.stringify({other:localStorage.getItem('fixture.other'),session:sessionStorage.getItem('KWR_Display_Settings')})")
        XCTAssertEqual(unrelated["other"] as? String, "unchanged-other")
        XCTAssertEqual(unrelated["session"] as? String, "session-only")
        XCTAssertEqual(state["hookIndices"] as? [Int], [5, 6])
    }

    func testMalformedOrAbsentFontPairsAreNeverRepaired() async throws {
        try await loadFontResizeCompatibilityFixture()
        for before in ["null", "'{'", "JSON.stringify({fontSizeIndex:6})", "JSON.stringify({fontSizeIndex:'6',fontSize:26})", "JSON.stringify({fontSizeIndex:6,fontSize:-1})", "'[]'"] {
            _ = try await model.webView.evaluateJavaScript("""
            (() => {
              const before=\(before);
              if(before===null)localStorage.removeItem('KWR_Display_Settings');
              else localStorage.setItem('KWR_Display_Settings',before);
              window.fixtureHookIndices=[];
              window.fixtureResizeWrite=()=>localStorage.setItem('KWR_Display_Settings','{"fontSizeIndex":5,"fontSize":25}');
              window.dispatchEvent(new Event('resize'));
              return true;
            })()
            """)
            try await awaitFontResizeTurn()
            let state = try await fontResizeSnapshot()
            XCTAssertEqual(state["index"] as? Int, 5, before)
            XCTAssertEqual(state["size"] as? Int, 25, before)
            XCTAssertEqual(state["hookIndices"] as? [Int], [], before)
        }
        // A valid before-state also cannot authorize replacing malformed
        // native output or manufacturing a now-missing member afterward.
        for after in ["'{'", "JSON.stringify({fontSizeIndex:5})"] {
            _ = try await model.webView.evaluateJavaScript("""
            (() => {
              localStorage.setItem('KWR_Display_Settings','{"fontSizeIndex":6,"fontSize":26}');
              window.fixtureAfterRaw=\(after);
              window.fixtureResizeWrite=()=>localStorage.setItem('KWR_Display_Settings',fixtureAfterRaw);
              window.dispatchEvent(new Event('resize'));
              return true;
            })()
            """)
            try await awaitFontResizeTurn()
            let unchanged = try await model.webView.evaluateJavaScript("localStorage.getItem('KWR_Display_Settings')===fixtureAfterRaw") as? Bool
            XCTAssertEqual(unchanged, true, after)
        }
    }

    func testTwoResizeBurstRetainsFirstSnapshotAndBootstrapIsIdempotent() async throws {
        try await loadFontResizeCompatibilityFixture()
        _ = try await model.webView.evaluateJavaScript(KindleReadingSettingsScript.resizePreferenceCompatibilityBootstrap)
        _ = try await model.webView.evaluateJavaScript(KindleReadingSettingsScript.resizePreferenceCompatibilityBootstrap)
        _ = try await model.webView.evaluateJavaScript("""
        window.dispatchEvent(new Event('resize'));
        window.dispatchEvent(new Event('resize'));
        true
        """)
        try await awaitFontResizeTurn()
        let state = try await fontResizeSnapshot()
        XCTAssertEqual(state["index"] as? Int, 6)
        XCTAssertEqual(state["size"] as? Int, 26)
        XCTAssertEqual(state["hookIndices"] as? [Int], [5, 5, 6], "One corrective hook covers the burst; installation must not add duplicate observers")
    }

    private func loadFontResizeCompatibilityFixture() async throws {
        try await loadNativeFontCommitFixture()
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:6,fontSize:26,sideMarginsSize:'narrow',theme:'night'}));
          window.fixtureHookIndices=[];window.fixtureInvalidHookDetails=0;window.fixtureTrustedResizes=0;
          window.fixtureNativePreferenceIndex=6;
          window.addEventListener('onLocalStorageChange',event=>{
            const detail=event.detail;
            if(!detail || detail.key!=='KWR_Display_Settings')return;
            if(!detail.value || typeof detail.value!=='object'){fixtureInvalidHookDetails++;return;}
            fixtureHookIndices.push(detail.value.fontSizeIndex);
            // The public hook updates the preference object; the visible
            // native range has separate state and changes only on real A±.
            window.fixtureNativePreferenceIndex=detail.value.fontSizeIndex;
          });
          for(const button of font.querySelectorAll('button'))button.addEventListener('click',()=>{
            const prefs=JSON.parse(localStorage.getItem('KWR_Display_Settings'));
            prefs.fontSize=20+Number(font.value);
            localStorage.setItem('KWR_Display_Settings',JSON.stringify(prefs));
          });
          window.fixtureResizeWrite=()=>{
            const prefs=JSON.parse(localStorage.getItem('KWR_Display_Settings'));
            prefs.fontSizeIndex=5;prefs.fontSize=25;prefs.sideMarginsSize='wide';
            localStorage.setItem('KWR_Display_Settings',JSON.stringify(prefs));
            window.dispatchEvent(new CustomEvent('onLocalStorageChange',{detail:{key:'KWR_Display_Settings',value:prefs}}));
          };
          return true;
        })()
        """)
        _ = try await model.webView.evaluateJavaScript(KindleReadingSettingsScript.resizePreferenceCompatibilityBootstrap)
        _ = try await model.webView.evaluateJavaScript("""
        window.addEventListener('resize',event=>{if(event.isTrusted)fixtureTrustedResizes++;window.fixtureResizeWrite();}); true
        """)
    }

    private func awaitFontResizeTurn() async throws {
        _ = try await model.webView.evaluateJavaScript("window.fixtureResizeTurnDone=false;setTimeout(()=>{window.fixtureResizeTurnDone=true;},0);true")
        for _ in 0..<100 {
            if (try await model.webView.evaluateJavaScript("window.fixtureResizeTurnDone")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.timedOut("pending font resize timer")
    }

    private func fontResizeSnapshot() async throws -> [String: Any] {
        try await settingsJSON("""
        (() => {
          const prefs=JSON.parse(localStorage.getItem('KWR_Display_Settings'));
          return JSON.stringify({index:prefs.fontSizeIndex,size:prefs.fontSize,margin:prefs.sideMarginsSize,theme:prefs.theme,
            nativeIndex:fixtureNativePreferenceIndex,visibleIndex:Number(font.value),hookIndices:fixtureHookIndices,invalidHookDetails:fixtureInvalidHookDetails,trustedResizes:fixtureTrustedResizes});
        })()
        """)
    }

    /// Native Ionic buttons own the update and optional persistence. The real
    /// production script must discover and click them; tests never inject a
    /// pending state or replace the production Close/relock implementation.
    private func loadNativeFontCommitFixture(persistChanges: Bool = true) async throws {
        model.webView.navigationDelegate = nil
        try await loadFixture()
        XCTAssertFalse(model.webView.configuration.websiteDataStore.isPersistent)
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          const old=document.getElementById('font'), range=document.createElement('ion-range');
          range.id='font';range.setAttribute('aria-label','Font size');
          range.setAttribute('min','1');range.setAttribute('max','10');range.setAttribute('step','1');
          range.value=6;range.style.cssText='display:block;width:260px;height:48px';
          window.fixtureFontClicks=0;window.fixtureCommitEvents=[];
          localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:6,fontId:'Bookerly'}));
          for(const [delta,label] of [[-1,'Decrease font size'],[1,'Increase font size']]){
            const button=document.createElement('button');button.setAttribute('aria-label',label);
            button.textContent=delta>0?'A+':'A−';button.style.cssText='width:100px;height:44px';
            button.onclick=()=>{
              fixtureFontClicks++;range.value=Number(range.value)+delta;
              fixtureCommitEvents.push('font:'+range.value);commits.push(String(range.value));
              if(\(persistChanges ? "true" : "false")){
                const prefs=JSON.parse(localStorage.getItem('KWR_Display_Settings'));
                prefs.fontSizeIndex=Number(range.value);localStorage.setItem('KWR_Display_Settings',JSON.stringify(prefs));
              }
            };
            range.appendChild(button);
          }
          old.replaceWith(range);
          aa.addEventListener('click',()=>{if(panel.hidden)fixtureCommitEvents.push('close');});
          const nativeLock=window.__crKindleSetPageModeLocked;
          window.__crKindleSetPageModeLocked=(value,notifyResize)=>{
            const result=nativeLock(value,notifyResize);fixtureCommitEvents.push('lock:'+value);return result;
          };
          return true;
        })()
        """)
    }

    private func openAndCommitNativeFont() async throws {
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        model.changeReaderFont(by: 1)
        try await waitUntil { self.model.readerFontValue == 7 && !self.model.isApplyingReadingSettings }
        XCTAssertNil(model.readingSettingsError)
    }

    private func nativeFontCommitSnapshot() async throws -> [String: Any] {
        try await settingsJSON("""
        JSON.stringify({value:Number(font.value),saved:JSON.parse(localStorage.getItem('KWR_Display_Settings')).fontSizeIndex,
          fontClicks:fixtureFontClicks,events:fixtureCommitEvents,closeClicks,panelHidden:panel.hidden,
          locked:!!window.__crKindleProbe.pageModeLocked})
        """)
    }

    private func assertNoAdditionalNavigation(_ navigation: SettingsReloadNavigationSpy, count: Int) async throws {
        // Barrier through the real WebContent process, then leave time for a
        // forbidden queued reload to reach its policy callback. Every request
        // is cancelled by the spy, so a regression cannot access Amazon.
        _ = try await model.webView.evaluateJavaScript("true")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(navigation.urls.count, count)
    }

    private func assertAaRetainsAppliedPortraitViewport(presentationFit: KindleViewportPresentationFit) async throws {
        try await loadFixture()
        let landscapeSize = CGSize(width: 750, height: 269)
        let portraitSize = CGSize(width: 402, height: 653)
        let landscapeCrop = KindleViewportCrop(
            scale: 1.25, heightScale: 419.0 / 269.0, offsetX: -93.75, offsetY: -60
        )
        // Seed the concrete delayed-model state from the rotation failure. The
        // real container then renders the model's effective portrait prediction,
        // just as SwiftUI can before its onChange callback commits the new size.
        model.viewportCrop = landscapeCrop
        let host = KindleWebViewContainer(webView: model.webView, crop: landscapeCrop)
        host.frame = CGRect(origin: .zero, size: landscapeSize)
        window.rootViewController!.view.addSubview(host)
        host.layoutIfNeeded()
        host.frame = CGRect(origin: .zero, size: portraitSize)
        let visibleCrop = model.effectiveViewportCrop(forSurfaceSize: portraitSize)
        XCTAssertNotEqual(visibleCrop, landscapeCrop)
        host.crop = visibleCrop
        host.presentationFit = presentationFit
        host.setNeedsLayout()
        host.layoutIfNeeded()
        let canonical = KindleViewportPresentationPolicy.canonicalFrame(surfaceSize: portraitSize, crop: visibleCrop)
        XCTAssertEqual(canonical.width, 502.5, accuracy: 0.01)
        XCTAssertEqual(canonical.height, 803, accuracy: 0.01)
        try await waitForCSSViewport(canonical.size)
        let oldBounds = model.webView.bounds
        let oldCenter = model.webView.center
        let oldTransform = model.webView.transform

        model.openReadingSettings()
        XCTAssertTrue(model.isReadingSettingsPresented)
        XCTAssertEqual(model.viewportCrop, visibleCrop, "Aa must freeze the applied portrait crop, not the stale landscape model")
        XCTAssertEqual(model.effectiveViewportPresentationFit(forSurfaceSize: portraitSize), presentationFit)
        host.crop = model.effectiveViewportCrop(forSurfaceSize: portraitSize)
        host.presentationFit = model.effectiveViewportPresentationFit(forSurfaceSize: portraitSize)
        host.layoutIfNeeded()
        XCTAssertEqual(model.webView.bounds, oldBounds)
        XCTAssertEqual(model.webView.center, oldCenter)
        XCTAssertEqual(model.webView.transform, oldTransform)
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        try await assertCSSViewport(canonical.size)

        // A late size callback must not undo the snapshot while settings owns
        // the page. Closing without a font change must preserve it as well.
        model.updateReaderSurfaceSize(landscapeSize)
        host.crop = model.effectiveViewportCrop(forSurfaceSize: portraitSize)
        host.presentationFit = model.effectiveViewportPresentationFit(forSurfaceSize: portraitSize)
        host.layoutIfNeeded()
        XCTAssertEqual(model.webView.bounds, oldBounds)
        XCTAssertEqual(model.webView.center, oldCenter)
        model.closeReadingSettings()
        try await waitUntil { !self.model.isReadingSettingsPresented && !self.model.isApplyingReadingSettings }
        host.crop = model.effectiveViewportCrop(forSurfaceSize: portraitSize)
        host.presentationFit = model.effectiveViewportPresentationFit(forSurfaceSize: portraitSize)
        host.layoutIfNeeded()
        XCTAssertEqual(model.webView.bounds, oldBounds)
        XCTAssertEqual(model.webView.center, oldCenter)
        XCTAssertEqual(model.webView.transform, oldTransform)
        try await assertCSSViewport(canonical.size)
        XCTAssertNil(model.readingSettingsError)
    }

    func testAaDefersUntilAttachedContainerHasAppliedItsNewCrop() async throws {
        try await loadFixture()
        let size = CGSize(width: 402, height: 653)
        let host = KindleWebViewContainer(webView: model.webView, crop: .identity)
        host.frame = CGRect(origin: .zero, size: size)
        window.rootViewController!.view.addSubview(host)
        host.layoutIfNeeded()
        host.crop = model.effectiveViewportCrop(forSurfaceSize: size)
        // The new crop has not reached layoutSubviews yet. Opening now must
        // not capture it as if WebKit had already applied the matching frame.
        model.openReadingSettings()
        XCTAssertFalse(model.isReadingSettingsPresented)
        let before = try await snapshot()
        XCTAssertEqual(before["openClicks"] as? Int, 0)

        host.layoutIfNeeded()
        model.openReadingSettings()
        XCTAssertTrue(model.isReadingSettingsPresented)
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        let after = try await snapshot()
        XCTAssertEqual(after["openClicks"] as? Int, 1)
    }

    private func waitForCSSViewport(_ size: CGSize) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let viewport = try await settingsJSON("JSON.stringify({width:innerWidth,height:innerHeight})")
            if let width = viewport["width"] as? NSNumber, let height = viewport["height"] as? NSNumber,
               abs(width.doubleValue - Double(size.width)) <= 1,
               abs(height.doubleValue - Double(size.height)) <= 1 { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw FixtureError.timedOut("waiting for applied WK CSS viewport \(size)")
    }

    private func assertCSSViewport(_ size: CGSize, file: StaticString = #filePath, line: UInt = #line) async throws {
        let viewport = try await settingsJSON("JSON.stringify({width:innerWidth,height:innerHeight})")
        let width = try XCTUnwrap(viewport["width"] as? NSNumber, file: file, line: line)
        let height = try XCTUnwrap(viewport["height"] as? NSNumber, file: file, line: line)
        XCTAssertEqual(width.doubleValue, Double(size.width), accuracy: 1, file: file, line: line)
        XCTAssertEqual(height.doubleValue, Double(size.height), accuracy: 1, file: file, line: line)
    }

    private func assertSettingsRelockPreservesNativeFont(useLightLock: Bool) async throws {
        try await loadFixture()
        if useLightLock {
            _ = try await model.webView.evaluateJavaScript(KindleWebScripts.pageModeLockBootstrap)
        }
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          const mountedFont=Number(font.value);
          window.fixtureSavedFont=mountedFont;
          window.fixtureSyntheticResizes=0;
          // A real button handler owns both the control and its preference.
          // The intentionally stale resize closure models the independent
          // writeback observed in Amazon; no production storage is changed.
          const nativeIncrease=document.createElement('button');
          nativeIncrease.textContent='Increase font size';
          nativeIncrease.onclick=()=>{
            font.value=String(Number(font.value)+1);
            window.fixtureSavedFont=Number(font.value);
          };
          panel.appendChild(nativeIncrease);
          window.addEventListener('resize',event=>{
            if(event.isTrusted)return;
            window.fixtureSyntheticResizes++;
            font.value=String(mountedFont);
            window.fixtureSavedFont=mountedFont;
          });
          nativeIncrease.click();
          return true;
        })()
        """)
        let selected = try await settingsJSON("JSON.stringify({value:Number(font.value),saved:fixtureSavedFont})")
        XCTAssertEqual(selected["value"] as? Int, 7)
        XCTAssertEqual(selected["saved"] as? Int, 7)

        model.closeReadingSettings()
        try await waitUntil { !self.model.isApplyingReadingSettings }
        let preserved = try await settingsJSON("""
        JSON.stringify({value:Number(font.value),saved:fixtureSavedFont,resizes:fixtureSyntheticResizes,
          locked:!!window.__crKindleProbe.pageModeLocked,
          lockClass:document.documentElement.classList.contains('cr-kindle-page-mode-locked'),
          headerHidden:getComputedStyle(document.querySelector('header')).display==='none',panelHidden:panel.hidden})
        """)
        XCTAssertEqual(preserved["resizes"] as? Int, 0)
        XCTAssertEqual(preserved["value"] as? Int, 7)
        XCTAssertEqual(preserved["saved"] as? Int, 7)
        XCTAssertEqual(preserved["locked"] as? Bool, true)
        XCTAssertEqual(preserved["lockClass"] as? Bool, true)
        XCTAssertEqual(preserved["headerHidden"] as? Bool, true)
        XCTAssertEqual(preserved["panelHidden"] as? Bool, true)
        XCTAssertNil(model.readingSettingsError)

        // Existing viewport/rotation callers omit the second argument. Their
        // resize behavior must remain intact, and proves this fixture would
        // detect the prior settings relock regression rather than merely
        // observing a nonfunctional resize handler.
        _ = try await model.webView.evaluateJavaScript("""
        window.__crKindleSetPageModeLocked(false);
        window.__crKindleSetPageModeLocked(true);
        true
        """)
        let defaultLock = try await settingsJSON("JSON.stringify({value:Number(font.value),saved:fixtureSavedFont,resizes:fixtureSyntheticResizes})")
        XCTAssertEqual(defaultLock["resizes"] as? Int, 1)
        XCTAssertEqual(defaultLock["value"] as? Int, 6)
        XCTAssertEqual(defaultLock["saved"] as? Int, 6)
    }

    func testPageModeLockHidesAaUntilModelUnlocksAndDoneRelocks() async throws {
        try await loadFixture()
        _ = try await model.webView.evaluateJavaScript(KindleWebScripts.pageModeLockBootstrap)
        _ = try await model.webView.evaluateJavaScript("window.__crKindleSetPageModeLocked(true)")
        let lockedRead = try await settingsJSON(KindleReadingSettingsScript.read)
        XCTAssertEqual(lockedRead["ok"] as? Bool, false)
        XCTAssertEqual(lockedRead["reason"] as? String, "settings-unavailable")
        let before = try await snapshot()
        XCTAssertEqual(before["openClicks"] as? Int, 0)

        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        let open = try await snapshot()
        XCTAssertEqual(open["locked"] as? Bool, false)
        XCTAssertEqual(open["panelHidden"] as? Bool, false)
        XCTAssertEqual(open["openClicks"] as? Int, 1)
        model.changeReaderFont(by: 1)
        try await waitUntil { self.model.readerFontValue == 7 && !self.model.isApplyingReadingSettings }
        model.closeReadingSettings()
        try await waitUntil { !self.model.isApplyingReadingSettings }
        let closed = try await snapshot()
        XCTAssertEqual(closed["locked"] as? Bool, true)
        XCTAssertEqual(closed["panelHidden"] as? Bool, true)
        XCTAssertEqual(closed["closeClicks"] as? Int, 1)
        XCTAssertEqual(closed["value"] as? String, "7")
        XCTAssertEqual(closed["commits"] as? [String], ["7"])
        XCTAssertNil(model.readingSettingsError)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
    }

    func testSameDocumentToolbarReplacementRevokesDetachedMenuDispatchFlag() async throws {
        try await loadFixture()
        _ = try await model.webView.evaluateJavaScript("window.__crKindleSetPageModeLocked(false)")
        _ = try await settingsJSON(KindleReadingSettingsScript.read)
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          const oldButton=document.getElementById('aa'), oldPanel=document.getElementById('panel');
          const button=oldButton.cloneNode(true), panel=oldPanel.cloneNode(true);
          button.setAttribute('aria-expanded','false'); panel.hidden=true;
          oldButton.replaceWith(button); oldPanel.replaceWith(panel);
          panel.querySelector('input').value='9';
          button.onclick=()=>{
            if(panel.hidden){openClicks++;panel.hidden=false;button.setAttribute('aria-expanded','true');}
            else{closeClicks++;panel.hidden=true;button.setAttribute('aria-expanded','false');}
          };
          return true;
        })()
        """)
        let staleRead = try await settingsJSON(KindleReadingSettingsScript.read)
        XCTAssertEqual(staleRead["reason"] as? String, "opening-settings")
        let stale = try await snapshot()
        XCTAssertEqual(stale["openClicks"] as? Int, 1,
                       "The old document-global flag suppresses the replacement button before ownership is refreshed")

        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 9 && !self.model.isApplyingReadingSettings }
        let refreshed = try await snapshot()
        XCTAssertEqual(refreshed["openClicks"] as? Int, 2, "Exactly one click belongs to the replacement menu")
        XCTAssertEqual(refreshed["panelHidden"] as? Bool, false)
        XCTAssertNil(model.readingSettingsError)
    }

    func testSyncDialogPreemptsCloseReplyWithoutRelockingItsNewOwner() async throws {
        try await loadFixture()
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          window.fixtureRelockCount=0;
          const nativeLock=window.__crKindleSetPageModeLocked;
          window.__crKindleSetPageModeLocked=(value,notifyResize)=>{
            if(value)fixtureRelockCount++;
            return nativeLock(value,notifyResize);
          };
          aa.addEventListener('click',()=>{
            if(!panel.hidden)return;
            window.fixtureShowSyncDialog();
            window.webkit.messageHandlers.castReaderKindle.postMessage({
              type:'kindle-sync-dialog',visible:true,localLocation:1635,cloudLocation:1111
            });
            const until=performance.now()+250;
            while(performance.now()<until){}
          });
          return true;
        })()
        """)
        model.closeReadingSettings()
        try await waitUntil { self.model.isKindleSyncDialogVisible && !self.model.isApplyingReadingSettings }
        try await Task.sleep(for: .milliseconds(400))
        let relockCount = try await model.webView.evaluateJavaScript("window.fixtureRelockCount") as? Int
        XCTAssertEqual(relockCount, 0, "A completed old Close reply must not lock the sync dialog's page")
        let current = try await snapshot()
        XCTAssertEqual(current["locked"] as? Bool, false)
        XCTAssertFalse(model.isReadingSettingsPresented)
        XCTAssertNil(model.readingSettingsError)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
    }

    func testImmediateCloseCancelsUndispatchedReadAndReopenAdoptsFreshValue() async throws {
        try await loadFixture()

        // No suspension between these calls: close must revoke the queued
        // MainActor read task before it can open Amazon's settings control.
        model.openReadingSettings()
        XCTAssertTrue(model.isApplyingReadingSettings)
        model.closeReadingSettings()
        XCTAssertFalse(model.isReadingSettingsPresented)
        XCTAssertTrue(model.isApplyingReadingSettings)
        try await waitUntil { !self.model.isApplyingReadingSettings }

        let closed = try await snapshot()
        XCTAssertEqual(closed["openClicks"] as? Int, 0)
        XCTAssertEqual(closed["closeClicks"] as? Int, 0)
        XCTAssertEqual(closed["panelHidden"] as? Bool, true)
        XCTAssertNil(model.readerFontValue)
        XCTAssertNil(model.readingSettingsError)

        _ = try await model.webView.evaluateJavaScript("font.value='9'")
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 9 && !self.model.isApplyingReadingSettings }
        XCTAssertTrue(model.isReadingSettingsPresented)
        XCTAssertNil(model.readingSettingsError)
        let reopened = try await snapshot()
        XCTAssertEqual(reopened["openClicks"] as? Int, 1)
        XCTAssertEqual(reopened["commits"] as? [String], [])
    }

    func testImmediateCloseCancelsUndispatchedChangeWithoutMutatingNativeFont() async throws {
        try await loadFixture()
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }

        // The old change task must not dispatch its DOM mutation after Done.
        model.changeReaderFont(by: 1)
        XCTAssertTrue(model.isApplyingReadingSettings)
        model.closeReadingSettings()
        try await waitUntil { !self.model.isApplyingReadingSettings }

        let closed = try await snapshot()
        XCTAssertEqual(closed["value"] as? String, "6")
        XCTAssertEqual(closed["commits"] as? [String], [])
        XCTAssertEqual(closed["closeClicks"] as? Int, 1)
        XCTAssertEqual(closed["panelHidden"] as? Bool, true)
        XCTAssertFalse(model.isReadingSettingsPresented)
        XCTAssertNil(model.readingSettingsError)

        // A new revision owns the value; the cancelled confirmation loop must
        // not later restore its previous value or publish a stale error.
        _ = try await model.webView.evaluateJavaScript("font.value='4'")
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 4 && !self.model.isApplyingReadingSettings }
        XCTAssertNil(model.readingSettingsError)
        let reopened = try await snapshot()
        XCTAssertEqual(reopened["value"] as? String, "4")
        XCTAssertEqual(reopened["commits"] as? [String], [])
    }

    func testFailedCloseObservesFiveTimesClicksOnceKeepsGateAndExplicitDoneCanRetry() async throws {
        try await loadFixture()
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        _ = try await model.webView.evaluateJavaScript("window.closeWorks=false")

        model.closeReadingSettings()
        XCTAssertTrue(model.isApplyingReadingSettings)
        XCTAssertFalse(model.isReadingSettingsPresented)
        try await assertPlaybackIsGated()
        try await waitUntil { self.model.isReadingSettingsPresented && !self.model.isApplyingReadingSettings }

        let failed = try await snapshot()
        XCTAssertEqual(failed["closeObservations"] as? Int, 5)
        XCTAssertEqual(failed["closeClicks"] as? Int, 1)
        XCTAssertEqual(failed["panelHidden"] as? Bool, false)
        XCTAssertNotNil(model.readingSettingsError)
        try await assertPlaybackIsGated()
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)

        // Only this new explicit Done may dispatch one more native click.
        _ = try await model.webView.evaluateJavaScript("window.closeWorks=true")
        model.closeReadingSettings()
        try await waitUntil { !self.model.isApplyingReadingSettings }
        let recovered = try await snapshot()
        XCTAssertEqual(recovered["closeObservations"] as? Int, 6)
        XCTAssertEqual(recovered["closeClicks"] as? Int, 2)
        XCTAssertEqual(recovered["panelHidden"] as? Bool, true)
        XCTAssertFalse(model.isReadingSettingsPresented)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
    }

    func testLateSyncDismissesSettingsRevokesFontReplyAndDoesNotChooseForUser() async throws {
        try await loadFixture()
        let footnotePreference = model.skipsFootnoteReferences
        let storedFootnotePreference = UserDefaults.standard.object(forKey: "kindle.skipFootnoteReferences.v1") as? Bool
        model.openReadingSettings()
        try await waitUntil { self.model.readerFontValue == 6 && !self.model.isApplyingReadingSettings }
        model.changeReaderFont(by: 1)
        try await waitUntil { self.model.readerFontValue == 7 && !self.model.isApplyingReadingSettings }
        model.closeReadingSettings()
        try await waitUntil { !self.model.isApplyingReadingSettings }

        // The real read script will encounter this getter after opening Aa.
        // Hold its WK reply while a real bridge message preempts the sheet;
        // the stale value 9 must never become the model's confirmed font.
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          window.syncChoices=[];
          const dialog=document.createElement('div');
          dialog.id='fixtureSync';
          dialog.setAttribute('role','dialog');
          dialog.hidden=true;
          dialog.style.cssText='position:fixed;inset:0;z-index:999;background:white';
          dialog.innerHTML='<span data-location="1635"></span><span data-location="1111"></span><button id="fixtureNo">No</button><button id="fixtureYes">Yes</button>';
          document.body.appendChild(dialog);
          fixtureNo.onclick=()=>syncChoices.push('no');
          fixtureYes.onclick=()=>syncChoices.push('yes');
          let sent=false;
          Object.defineProperty(font,'value',{
            configurable:true,
            get(){
              if(!sent){
                sent=true;dialog.hidden=false;
                window.webkit.messageHandlers.castReaderKindle.postMessage({
                  type:'kindle-sync-dialog',visible:true,localLocation:1635,cloudLocation:1111
                });
                const until=performance.now()+250;
                while(performance.now()<until){}
              }
              return '9';
            }
          });
          return true;
        })()
        """)
        model.openReadingSettings()
        try await waitUntil { self.model.isKindleSyncDialogVisible }
        XCTAssertFalse(model.isReadingSettingsPresented, "The sheet must expose Amazon's sync choice")
        XCTAssertFalse(model.isApplyingReadingSettings)
        // Exercise the actual sheet's onDismiss callback after preemption.
        model.closeReadingSettings()
        model.openReadingSettings()
        XCTAssertFalse(model.isReadingSettingsPresented, "Aa cannot reopen over a visible sync dialog")
        try await Task.sleep(for: .milliseconds(1_100))

        let raw = try await model.webView.evaluateJavaScript("""
        JSON.stringify({choices:syncChoices,dialogHidden:fixtureSync.hidden,closeClicks,commits,
          nativeValue:Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').get.call(font)})
        """)
        let json = try XCTUnwrap(raw as? String)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(result["choices"] as? [String], [])
        XCTAssertEqual(result["dialogHidden"] as? Bool, false)
        XCTAssertEqual(result["closeClicks"] as? Int, 1, "Preempted onDismiss must not dispatch another native close")
        XCTAssertEqual(result["commits"] as? [String], ["7"])
        XCTAssertEqual(result["nativeValue"] as? String, "7")
        XCTAssertNil(model.readerFontValue, "The late read result 9 has lost its settings revision")
        XCTAssertNil(model.readingSettingsError, "A cancelled font loop must not publish a later timeout")
        XCTAssertEqual(model.skipsFootnoteReferences, footnotePreference)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "kindle.skipFootnoteReferences.v1") as? Bool, storedFootnotePreference)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
    }

    func testSettingsOpenedAndClosedDuringLightLockRevokesPendingPageAction() async throws {
        try await loadFixture()
        var observedLock = false
        let observer = LightLockObserver { [unowned self] in
            observedLock = true
            // Both calls happen before the original lock's JS reply. Even if
            // the sheet has gone away, its revision has revoked the old turn.
            self.model.openReadingSettings()
            self.model.closeReadingSettings()
        }
        try await installDelayedLightLock(observer)
        do {
            _ = try await model.requestKindlePageTurn(.next)
            XCTFail("A settings revision must revoke the page action waiting on the lock bridge")
        } catch { }
        XCTAssertTrue(observedLock)
        let count = try await model.webView.evaluateJavaScript("window.fixturePageActions") as? Int
        XCTAssertEqual(count, 0)
        try await waitUntil { !self.model.isApplyingReadingSettings }
    }

    func testReparentDuringLightLockRevokesPendingPageAction() async throws {
        try await loadFixture()
        let replacement = UIView(frame: window.bounds)
        window.rootViewController!.view.addSubview(replacement)
        var observedLock = false
        let observer = LightLockObserver { [unowned self] in
            observedLock = true
            replacement.addSubview(self.model.webView)
        }
        try await installDelayedLightLock(observer)
        do {
            _ = try await model.requestKindlePageTurn(.previous)
            XCTFail("A replacement host must not receive an old host's delayed page action")
        } catch { }
        XCTAssertTrue(observedLock)
        XCTAssertTrue(model.webView.superview === replacement)
        let count = try await model.webView.evaluateJavaScript("window.fixturePageActions") as? Int
        XCTAssertEqual(count, 0)
    }

    func testUnchangedOwnerDispatchesExactlyOnceAfterLightLock() async throws {
        try await loadFixture()
        var observedLock = false
        let observer = LightLockObserver { observedLock = true }
        try await installDelayedLightLock(observer)
        let result = try await model.requestKindlePageTurn(.next)
        XCTAssertTrue(observedLock)
        XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        let count = try await model.webView.evaluateJavaScript("window.fixturePageActions") as? Int
        XCTAssertEqual(count, 1)
    }

    private func installDelayedLightLock(_ observer: LightLockObserver) async throws {
        model.webView.configuration.userContentController.add(observer, name: "fixtureLightLock")
        _ = try await model.webView.evaluateJavaScript("""
        (function(){
          window.fixturePageActions=0;
          window.__crKindleSemanticPageTurn=function(){
            fixturePageActions++;
            return JSON.stringify({ok:true,dispatchCount:1});
          };
          var lockFunction;
          Object.defineProperty(window,'__crKindleSetPageModeLocked',{
            configurable:true,
            get:function(){return lockFunction;},
            set:function(nativeLock){
              lockFunction=function(value,notifyResize){
                var result=nativeLock(value,notifyResize);
                if(window.fixtureDelayedLockObserved)return result;
                window.fixtureDelayedLockObserved=true;
                window.webkit.messageHandlers.fixtureLightLock.postMessage('entered');
                // Hold the actual WebContent reply while the native observer
                // opens settings or replaces the host on the main actor.
                var until=performance.now()+250;
                while(performance.now()<until){}
                return result;
              };
            }
          });
        })()
        """)
    }

    private func assertPlaybackIsGated() async throws {
        do {
            _ = try await model.startCurrentMode()
            XCTFail("Settings ownership must block playback before capture or TTS")
        } catch {
            // KindleBookError is private to the model's source file. Assert its
            // public LocalizedError result, not a test-only internal cast.
            XCTAssertEqual(error.localizedDescription, AppLocalized("请先处理 Amazon 的 Cookie 提示。"))
        }
    }

    private func loadFixture(initializeControls: Bool = true) async throws {
        let fixtureID = UUID().uuidString
        model.webView.loadHTMLString("""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
        <style>[hidden]{display:none!important}button,input{width:220px;height:44px}section{padding:12px}</style>
        </head><body>
        <header style="height:50px"><button id="aa" aria-label="Reading settings" aria-controls="panel" aria-expanded="false">Aa</button></header>
        <section id="panel" hidden>
          <input id="font" aria-label="Font size" type="range" min="1" max="10" step="1" value="6">
        </section>
        <script>
          window.openClicks=0; window.closeClicks=0; window.closeWorks=true;
          window.commits=[]; window.closeObservations=0;
          let lastCloseAttempt='', observedCloseThisJob=false;
          Object.defineProperty(window,'__crKindleFontCloseAttempt',{
            configurable:true,
            // Count one native close evaluation, not how many times its
            // synchronous helpers read the same attempt within that JS job.
            get(){
              if(!observedCloseThisJob){
                window.closeObservations++;observedCloseThisJob=true;
                queueMicrotask(()=>observedCloseThisJob=false);
              }
              return lastCloseAttempt;
            },
            set(value){lastCloseAttempt=value;}
          });
          aa.addEventListener('click',()=>{
            if(panel.hidden){
              window.openClicks++;panel.hidden=false;aa.setAttribute('aria-expanded','true');
            }else{
              window.closeClicks++;
              if(window.closeWorks){panel.hidden=true;aa.setAttribute('aria-expanded','false');}
            }
          });
          font.addEventListener('change',()=>window.commits.push(font.value));
          window.__crKindleLiveClear=()=>JSON.stringify({ok:true});
          window.fixtureSyncChoices=[];
          window.fixtureShowSyncDialog=()=>{
            const dialog=document.createElement('div');
            dialog.id='fixtureObservedSync';dialog.setAttribute('role','dialog');
            dialog.style.cssText='position:fixed;inset:60px 0 0;z-index:999;background:white';
            dialog.innerHTML='<span data-location="1635"></span><span data-location="1111"></span><button>No</button><button>Yes</button>';
            dialog.querySelectorAll('button').forEach(button=>button.onclick=()=>fixtureSyncChoices.push(button.textContent));
            document.body.appendChild(dialog);
          };
          window.fixtureLoadID='\(fixtureID)';
          window.fixtureReady=true;
        </script></body></html>
        """, baseURL: fixtureReaderURL)
        for _ in 0..<100 {
            if (try? await model.webView.evaluateJavaScript("window.fixtureReady===true && window.fixtureLoadID==='\(fixtureID)'")) as? Bool == true,
               !model.webView.isLoading, !model.isNavigating {
                if initializeControls {
                    let ready = await model.prepareReaderControls(reason: "local-settings-fixture")
                    XCTAssertTrue(ready, "The fixture must install the real capture/sync bootstrap before opening Aa")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw FixtureError.timedOut("loading local WKWebView fixture")
    }

    private func settingsJSON(_ script: String) async throws -> [String: Any] {
        let value = try await model.webView.evaluateJavaScript(script)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func snapshot() async throws -> [String: Any] {
        let value = try await model.webView.evaluateJavaScript("""
        JSON.stringify({openClicks,closeClicks,closeObservations,commits,
                        panelHidden:panel.hidden,value:font.value,
                        locked:!!(window.__crKindleProbe && window.__crKindleProbe.pageModeLocked)})
        """)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.timedOut("waiting for settings task")
    }

    private enum FixtureError: Error {
        case timedOut(String)
    }
}

@MainActor
private final class LightLockObserver: NSObject, WKScriptMessageHandler {
    private let onLock: () -> Void
    init(onLock: @escaping () -> Void) { self.onLock = onLock }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onLock()
    }
}

/// A real local WK navigation invokes the production invalidation callback;
/// didFinish stays under the fixture's explicit, network-free bootstrap phase.
@MainActor
private final class SettingsFixtureNavigationObserver: NSObject, WKNavigationDelegate {
    private weak var model: KindleBookViewModel?
    init(model: KindleBookViewModel) { self.model = model }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        model?.webView(webView, didStartProvisionalNavigation: navigation)
    }
}

/// Installed only after local HTML is ready. All main-frame requests are
/// recorded and cancelled before network loading, including accidental reloads.
@MainActor
private final class SettingsReloadNavigationSpy: NSObject, WKNavigationDelegate {
    private(set) var urls: [URL] = []
    private(set) var types: [WKNavigationType] = []

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url {
            urls.append(url)
            types.append(navigationAction.navigationType)
        }
        decisionHandler(.cancel)
    }
}
