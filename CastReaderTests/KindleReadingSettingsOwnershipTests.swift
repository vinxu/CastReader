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

    override func setUp() {
        super.setUp()
        AudioPlayerService.shared.stop()
        previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let book = KindleBook(
            id: "settings-ownership-\(UUID().uuidString)",
            asin: "B000000001",
            title: "Local settings fixture",
            author: "",
            coverURL: nil,
            readerURL: "https://read.amazon.com/sample/B000000001",
            progressLabel: "",
            storefrontID: "us",
            lastOpenedAt: nil,
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
        model = KindleBookViewModel(book: book)
        model.webView.navigationDelegate = nil
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        model.webView.frame = window.bounds
        controller.view.addSubview(model.webView)
    }

    override func tearDown() {
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
          window.__crKindleSetPageModeLocked=value=>{
            if(value)fixtureRelockCount++;
            return nativeLock(value);
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
              lockFunction=function(value){
                var result=nativeLock(value);
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
          let lastCloseAttempt='';
          Object.defineProperty(window,'__crKindleFontCloseAttempt',{
            configurable:true,
            get(){window.closeObservations++;return lastCloseAttempt;},
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
        """, baseURL: URL(string: "https://read.amazon.com/sample/B000000001"))
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
