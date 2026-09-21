import XCTest
import UIKit
import WebKit
@testable import CastReader

/// Real WK navigation/messages enter the real model's startup and sync paths.
/// Sync scenarios control slow preparation awaits; no Amazon, OCR or TTS is invoked.
@MainActor
final class KindleInitialStartSyncTests: XCTestCase {
    private enum FixtureError: Error { case reachedRestart, timedOut, prerequisite(String) }

    @MainActor
    private final class Preparation {
        var calls = 0
        var pending: CheckedContinuation<ReadingDocument, Error>?
        func prepare() async throws -> ReadingDocument {
            calls += 1
            guard calls == 1 else { throw FixtureError.reachedRestart }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func finish() {
            pending?.resume(returning: ReadingDocument(
                title: "Local sync fixture", sourceKind: .kindle,
                language: "en", paragraphs: [ReadingParagraph(id: 0, text: "Local fixture.")]
            ))
            pending = nil
        }
    }

    func testPausingAtAParagraphBoundaryThenSwitchingModeDoesNotAutostart() {
        let book = KindleBook(id: "paused-mode-\(UUID().uuidString)", asin: "B000000001",
            title: "Public pause fixture", author: "", coverURL: nil,
            readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "", storefrontID: "us",
            lastOpenedAt: nil, lastSyncedAt: Date(timeIntervalSince1970: 0), lastReadPageKey: nil, lastReadURL: nil)
        let model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent())
        defer { model.destroy() }
        let document = ReadingDocument(title: book.title, sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "A public paragraph still waiting for audio.")])
        let vm = ReadAloudViewModel(document: document)
        model.readVM = vm
        vm.status = .loading
        model.pauseReadPlayback()
        XCTAssertTrue(vm.isPlaybackPausedByUser)
        XCTAssertEqual(vm.status, .loading, "The pending request can remain loading after an explicit pause")
        model.selectMode(.explain)
        XCTAssertEqual(model.mode, .explain, "A paused switch is immediate; it must not begin an asynchronous playback restart")
        XCTAssertFalse(model.explainVM?.isPlaying ?? false)
        XCTAssertFalse(model.explainVM?.ownsPlaybackSession ?? false)
    }

    func testInitialPlaySurvivesLateSyncAndOldPreparationCannotCommit() async throws {
        try await runScenario(cancellation: nil)
    }

    func testSettingsRevokesDeferredInitialPlay() async throws {
        try await runScenario(cancellation: "settings")
    }

    func testCallerCancellationAndDestroyEachRevokeDeferredInitialPlay() async throws {
        try await runScenario(cancellation: "caller")
        try await runScenario(cancellation: "destroy")
    }

    /// Exercises WK navigation -> the real model's didFinish -> reader setup.
    /// No preparation override or direct prepareReaderControls call can bypass
    /// startup preference mutation. The page raster is generated locally.
    func testRealReaderNavigationPreservesPreferencesWithoutOpeningSettings() async throws {
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        // Exercise the real navigation policy with its canonical asin/ref_
        // entry. A /sample/ URL is rejected before didFinish and opens rebind UI.
        let storefront = try XCTUnwrap(KindleStorefront.entry(id: "us"))
        let readerURL = storefront.readerURL(asin: "B000000001")
        XCTAssertTrue(KindleStorefrontNavigationPolicy.allowsReaderMainFrame(
            readerURL, expectedStorefrontID: storefront.id, expectedASIN: "B000000001"
        ))
        let book = KindleBook(
            id: "startup-prefs-\(UUID().uuidString)", asin: "B000000001",
            title: "Local startup preference fixture", author: "", coverURL: nil,
            readerURL: readerURL.absoluteString, progressLabel: "", storefrontID: "us",
            lastOpenedAt: nil, lastSyncedAt: Date(timeIntervalSince1970: 0),
            lastReadPageKey: nil, lastReadURL: nil
        )
        let model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        model.webView.frame = window.bounds
        window.rootViewController!.view.addSubview(model.webView)
        defer {
            model.destroy()
            model.webView.removeFromSuperview()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        XCTAssertFalse(model.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(model.webView.navigationDelegate === model)

        // The second load is a real replacement document on the same model,
        // covering both an already-selected default and a user's wider spread.
        for (columns, margins) in [(1, "narrow"), (2, "wide")] {
            let token = UUID().uuidString
            model.webView.loadHTMLString("""
            <!doctype html><html><head>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
              [hidden]{display:none!important} body{margin:0}
              button{min-width:80px;min-height:40px}
              #panel{position:fixed;inset:50px 10px auto;background:white;z-index:10}
              #page{display:block;width:350px;height:560px;margin:10px auto}
            </style></head><body>
            <button id="aa" aria-label="Reading settings" aria-expanded="false">Aa</button>
            <section id="panel" role="dialog" aria-label="Reading settings" hidden>
              <input id="font" aria-label="Font size" type="range" min="1" max="10" value="6">
              <button id="single" role="radio" aria-label="Single column" aria-checked="\(columns == 1 ? "true" : "false")">Single column</button>
              <button id="narrow" role="radio" aria-label="Narrow" aria-checked="\(margins == "narrow" ? "true" : "false")">Narrow</button>
              <button id="nativeClose" aria-label="Close reading settings">Close</button>
            </section>
            <div class="kg-full-page-img"><img id="page"></div>
            <script>
              window.fixtureToken='\(token)';
              window.fixtureClicks={aa:0,single:0,narrow:0,close:0};
              window.fixtureStorageWrites=0;window.fixtureViolations=0;
              document.addEventListener('securitypolicyviolation',()=>fixtureViolations++);
              window.fixtureInitialPrefs=JSON.stringify({fontSizeIndex:6,fontSize:22,fontId:'Bookerly',sideMarginsSize:'\(margins)',maxNumberColumns:\(columns),theme:1});
              localStorage.setItem('KWR_Display_Settings',fixtureInitialPrefs);
              const originalSetItem=Storage.prototype.setItem;
              Storage.prototype.setItem=function(key,value){
                if(key==='KWR_Display_Settings')fixtureStorageWrites++;
                return originalSetItem.call(this,key,value);
              };
              aa.onclick=()=>{fixtureClicks.aa++;panel.hidden=!panel.hidden;aa.setAttribute('aria-expanded',String(!panel.hidden));};
              function commitLayout(name,value){
                const prefs=JSON.parse(localStorage.getItem('KWR_Display_Settings'));
                prefs[name]=value;localStorage.setItem('KWR_Display_Settings',JSON.stringify(prefs));
              }
              single.onclick=()=>{fixtureClicks.single++;commitLayout('maxNumberColumns',1);single.setAttribute('aria-checked','true');};
              narrow.onclick=()=>{fixtureClicks.narrow++;commitLayout('sideMarginsSize','narrow');narrow.setAttribute('aria-checked','true');};
              nativeClose.onclick=()=>{fixtureClicks.close++;panel.hidden=true;aa.setAttribute('aria-expanded','false');};
              const canvas=document.createElement('canvas');canvas.width=700;canvas.height=1120;
              const context=canvas.getContext('2d');context.fillStyle='white';context.fillRect(0,0,700,1120);
              context.fillStyle='black';context.font='28px serif';
              for(let row=0;row<12;row++)context.fillText('Local page line '+row,30,60+row*70);
              const binary=atob(canvas.toDataURL('image/png').split(',')[1]);
              const bytes=Uint8Array.from(binary,character=>character.charCodeAt(0));
              page.src=URL.createObjectURL(new Blob([bytes],{type:'image/png'}));
              window.fixtureSnapshot=()=>JSON.stringify({
                token:fixtureToken,clicks:fixtureClicks,writes:fixtureStorageWrites,
                preferencesUnchanged:localStorage.getItem('KWR_Display_Settings')===fixtureInitialPrefs,
                fontValue:Number(font.value),panelHidden:panel.hidden,
                decoded:page.complete&&page.naturalWidth===700,
                lock:!!(window.__crKindleProbe&&window.__crKindleProbe.pageModeLocked),
                stateInstalled:typeof window.__crKindleState==='function',
                violations:fixtureViolations
              });
            </script></body></html>
            """, baseURL: readerURL)

            var snapshot: [String: Any]?
            var lastSnapshot = "not-returned"
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if let raw = try? await model.webView.evaluateJavaScript("window.fixtureSnapshot&&window.fixtureSnapshot()"),
                   let json = raw as? String,
                   let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                    lastSnapshot = json
                    if result["token"] as? String == token,
                       result["decoded"] as? Bool == true,
                       result["stateInstalled"] as? Bool == true,
                       result["lock"] as? Bool == true,
                       model.readerControlsReady, !model.webView.isLoading, !model.isNavigating {
                        snapshot = result
                        break
                    }
                }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            let result = try XCTUnwrap(snapshot, "Real didFinish must install controls on navigation, columns=\(columns), controlsReady=\(model.readerControlsReady), loading=\(model.webView.isLoading), navigating=\(model.isNavigating), fixture=\(lastSnapshot)")
            let clicks = try XCTUnwrap(result["clicks"] as? [String: Int])
            XCTAssertEqual(clicks, ["aa": 0, "single": 0, "narrow": 0, "close": 0])
            XCTAssertEqual(result["writes"] as? Int, 0)
            XCTAssertEqual(result["preferencesUnchanged"] as? Bool, true)
            XCTAssertEqual(result["fontValue"] as? Int, 6)
            XCTAssertEqual(result["panelHidden"] as? Bool, true)
            XCTAssertEqual(result["lock"] as? Bool, true)
            XCTAssertEqual(result["violations"] as? Int, 0)
            XCTAssertFalse(model.isReadingSettingsPresented)
            XCTAssertNil(model.readVM, "Reader setup must not create or start a TTS reader")
        }
    }

    func testHealthySameSizeExpandPreservesNativeFontWithoutSyntheticEvents() async throws {
        try await withLayoutRepairFixture { model in
            let bounds = model.webView.bounds
            let result = try await model.refreshReaderLayoutState(reason: "expand")
            XCTAssertEqual(result["repairMode"] as? String, "retained")
            let state = try await self.layoutFixtureSnapshot(model)
            XCTAssertEqual(state["font"] as? Int, 6)
            XCTAssertEqual(state["saved"] as? Int, 6)
            XCTAssertEqual(state["resizes"] as? Int, 0)
            XCTAssertEqual(state["visibilityChanges"] as? Int, 0)
            XCTAssertEqual(state["overlayRefreshes"] as? Int, 1)
            XCTAssertEqual(model.webView.bounds, bounds)
            XCTAssertEqual(state["locked"] as? Bool, true)
        }
    }

    func testExpandWithUnusablePageKeepsRecoveryEvents() async throws {
        try await withLayoutRepairFixture { model in
            _ = try await model.webView.evaluateJavaScript("document.getElementById('pageHost').remove(); true")
            let result = try await model.refreshReaderLayoutState(reason: "expand")
            XCTAssertEqual(result["repairMode"] as? String, "poked")
            try await self.assertLayoutFixtureWasPoked(model)
        }
    }

    func testExpandWithBrokenImageInLargeCSSFrameKeepsRecoveryEvents() async throws {
        try await withLayoutRepairFixture { model in
            _ = try await model.webView.evaluateJavaScript("""
            (() => {
              window.fixtureImageError=false;
              page.addEventListener('error',()=>{window.fixtureImageError=true;},{once:true});
              page.src=URL.createObjectURL(new Blob([new Uint8Array([1,2,3,4])],{type:'image/png'}));
              return true;
            })()
            """)
            var broken = false
            for _ in 0..<100 {
                broken = (try await model.webView.evaluateJavaScript("""
                (() => {
                  const rect=page.getBoundingClientRect();
                  const state=JSON.parse(window.__crKindleState());
                  return fixtureImageError && page.complete && page.naturalWidth===0 &&
                    rect.width>300 && rect.height>500 && state.naturalSize &&
                    state.naturalSize.width===0 && state.naturalSize.height===0;
                })()
                """)) as? Bool == true
                if broken { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard broken else {
                throw FixtureError.prerequisite("The real candidate must retain its large CSS frame after image decode fails")
            }
            let result = try await model.refreshReaderLayoutState(reason: "expand")
            XCTAssertEqual(result["repairMode"] as? String, "poked")
            try await self.assertLayoutFixtureWasPoked(model)
        }
    }

    func testExpandWithRealCSSViewportMismatchKeepsRecoveryEvents() async throws {
        try await withLayoutRepairFixture { model in
            // The desktop reader UA ignores a late viewport-meta mutation.
            // Public WK pageZoom changes the real CSS-pixel mapping instead.
            let originalZoom = model.webView.pageZoom
            model.webView.pageZoom = 1.5
            defer { model.webView.pageZoom = originalZoom }
            var mismatched = false
            for _ in 0..<100 {
                let width = try await model.webView.evaluateJavaScript("innerWidth") as? NSNumber
                if let width, abs(width.doubleValue - Double(model.webView.bounds.width)) > 2 {
                    mismatched = true
                    break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard mismatched else {
                throw FixtureError.prerequisite("WK pageZoom did not produce an actual CSS/native viewport mismatch")
            }
            let result = try await model.refreshReaderLayoutState(reason: "expand")
            XCTAssertEqual(result["repairMode"] as? String, "poked")
            try await self.assertLayoutFixtureWasPoked(model)
        }
    }

    func testOrientationStillPokesEvenWhenCurrentPageIsUsable() async throws {
        try await withLayoutRepairFixture { model in
            let result = try await model.refreshReaderLayoutState(reason: "orientation")
            XCTAssertEqual(result["repairMode"] as? String, "poked")
            try await self.assertLayoutFixtureWasPoked(model)
        }
    }

    func testCancelledLayoutRefreshCannotPokeOrOverwriteFont() async throws {
        try await withLayoutRepairFixture { model in
            let operation = Task { @MainActor in
                try await model.refreshReaderLayoutState(reason: "orientation")
            }
            operation.cancel()
            do {
                _ = try await operation.value
                XCTFail("A cancelled repair must not dispatch into the current document")
            } catch is CancellationError {
                // The production core checks cancellation before any JS work.
            }
            let state = try await self.layoutFixtureSnapshot(model)
            XCTAssertEqual(state["resizes"] as? Int, 0)
            XCTAssertEqual(state["visibilityChanges"] as? Int, 0)
            XCTAssertEqual(state["overlayRefreshes"] as? Int, 0)
            XCTAssertEqual(state["saved"] as? Int, 6)
        }
    }

    private func assertLayoutFixtureWasPoked(_ model: KindleBookViewModel) async throws {
        let state = try await layoutFixtureSnapshot(model)
        XCTAssertEqual(state["resizes"] as? Int, 1)
        XCTAssertEqual(state["visibilityChanges"] as? Int, 1)
        XCTAssertEqual(state["overlayRefreshes"] as? Int, 1)
        XCTAssertEqual(state["font"] as? Int, 5, "The stale native resize closure must be effective in this fixture")
        XCTAssertEqual(state["saved"] as? Int, 5)
    }

    private func layoutFixtureSnapshot(_ model: KindleBookViewModel) async throws -> [String: Any] {
        let raw = try await model.webView.evaluateJavaScript("""
        JSON.stringify({font:Number(font.value),saved:JSON.parse(localStorage.getItem('KWR_Display_Settings')).fontSizeIndex,
          resizes:fixtureResizes,visibilityChanges:fixtureVisibilityChanges,overlayRefreshes:fixtureOverlayRefreshes,
          locked:!!window.__crKindleProbe.pageModeLocked})
        """)
        let json = try XCTUnwrap(raw as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Real decoded geometry and the real capture bootstrap feed the production
    /// core. Calling that core directly intentionally avoids didLoad's network
    /// preflight rather than letting a local fixture silently skip the repair.
    private func withLayoutRepairFixture(
        _ check: (KindleBookViewModel) async throws -> Void
    ) async throws {
        AudioPlayerService.shared.stop()
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let storefront = try XCTUnwrap(KindleStorefront.entry(id: "us"))
        let readerURL = storefront.readerURL(asin: "B000000001")
        let book = KindleBook(
            id: "layout-font-\(UUID().uuidString)", asin: "B000000001",
            title: "Local layout font fixture", author: "", coverURL: nil,
            readerURL: readerURL.absoluteString, progressLabel: "", storefrontID: "us",
            lastOpenedAt: nil, lastSyncedAt: Date(timeIntervalSince1970: 0),
            lastReadPageKey: nil, lastReadURL: nil
        )
        let model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        model.webView.scrollView.contentInsetAdjustmentBehavior = .never
        model.webView.scrollView.contentInset = .zero
        let host = KindleWebViewContainer(webView: model.webView)
        host.frame = window.bounds
        window.rootViewController!.view.addSubview(host)
        host.layoutIfNeeded()
        defer {
            model.destroy()
            model.webView.removeFromSuperview()
            AudioPlayerService.shared.stop()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        model.webView.loadHTMLString("""
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0} #pageHost{position:fixed;inset:10px} #page{display:block;width:100%;height:100%} #font{position:fixed;top:0;left:0;width:1px;height:1px;opacity:0}</style>
        </head><body><input id="font" type="range" min="0" max="13" value="5">
        <div id="pageHost" class="kg-full-page-img"><img id="page"></div>
        <script>
          const canvas=document.createElement('canvas');canvas.width=740;canvas.height=1360;
          const context=canvas.getContext('2d');context.fillStyle='white';context.fillRect(0,0,740,1360);
          context.fillStyle='black';context.font='28px serif';
          for(let row=0;row<16;row++)context.fillText('Local layout line '+row,30,60+row*70);
          const bytes=Uint8Array.from(atob(canvas.toDataURL('image/png').split(',')[1]),c=>c.charCodeAt(0));
          page.src=URL.createObjectURL(new Blob([bytes],{type:'image/png'}));
        </script></body></html>
        """, baseURL: readerURL)
        var usable = false
        var lastState = "unavailable"
        for _ in 0..<200 {
            if model.readerControlsReady, !model.webView.isLoading, !model.isNavigating,
               let json = try? await model.webView.evaluateJavaScript("window.__crKindleState&&window.__crKindleState()") as? String,
               let state = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                lastState = json
                let area = (state["visibleArea"] as? NSNumber)?.doubleValue ?? 0
                let count = (state["orderedCount"] as? NSNumber)?.intValue ?? 0
                if !(state["key"] as? String ?? "").isEmpty, count > 0,
                   area >= Double(host.bounds.width * host.bounds.height) * 0.82,
                   (try? await model.webView.evaluateJavaScript("page.complete && page.naturalWidth===740")) as? Bool == true {
                    usable = true
                    break
                }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(usable, "Real decoded page and bootstrap must be usable before repair: \(lastState)")
        guard usable else { throw FixtureError.timedOut }
        AudioPlayerService.shared.setBook(id: book.id, title: book.title, chapterTitle: nil, coverUrl: nil)
        _ = try await model.webView.evaluateJavaScript("""
        (() => {
          const mountedFont=5;
          window.fixtureResizes=0;window.fixtureVisibilityChanges=0;window.fixtureOverlayRefreshes=0;
          const originalOverlay=window.crKindleUpdateLiveOverlay;
          window.crKindleUpdateLiveOverlay=function(){fixtureOverlayRefreshes++;if(originalOverlay)return originalOverlay.apply(this,arguments);};
          window.addEventListener('resize',event=>{
            if(event.isTrusted)return;
            fixtureResizes++;font.value=String(mountedFont);
            localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:mountedFont}));
          });
          document.addEventListener('visibilitychange',event=>{if(!event.isTrusted)fixtureVisibilityChanges++;});
          const nativeIncrease=document.createElement('button');
          nativeIncrease.onclick=()=>{font.value='6';localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:6}));};
          nativeIncrease.click();
          return true;
        })()
        """)
        let before = try await layoutFixtureSnapshot(model)
        XCTAssertEqual(before["font"] as? Int, 6)
        XCTAssertEqual(before["saved"] as? Int, 6)
        try await check(model)
    }

    private func runScenario(cancellation: String?) async throws {
        AudioPlayerService.shared.stop()
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let book = KindleBook(
            id: "start-sync-\(UUID().uuidString)", asin: "B000000001",
            title: "Local initial start fixture", author: "", coverURL: nil,
            readerURL: "https://read.amazon.com/sample/B000000001", progressLabel: "", storefrontID: "us",
            lastOpenedAt: nil, lastSyncedAt: Date(timeIntervalSince1970: 0),
            lastReadPageKey: nil, lastReadURL: nil
        )
        let model = KindleBookViewModel(book: book)
        model.webView.navigationDelegate = nil
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        model.webView.frame = window.bounds
        window.rootViewController!.view.addSubview(model.webView)
        let preparation = Preparation()
        model.startDocumentPreparationForTesting = { try await preparation.prepare() }
        model.syncDialogReadinessForTesting = {
            // Keep a real WebKit await in the readiness path as well.
            _ = try await model.webView.evaluateJavaScript("window.fixtureReady")
        }
        defer {
            preparation.finish()
            model.startDocumentPreparationForTesting = nil
            model.syncDialogReadinessForTesting = nil
            model.destroy()
            model.webView.removeFromSuperview()
            AudioPlayerService.shared.stop()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        model.webView.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <button id="aa" aria-label="Reading settings" onclick="panel.hidden=!panel.hidden">Aa</button>
        <section id="panel" hidden><input aria-label="Font size" type="range" min="1" max="10" value="6"></section>
        <script>
          window.fixtureReady=true;
          window.__crKindleLiveClear=()=>JSON.stringify({ok:true});
          window.sendSync=visible=>webkit.messageHandlers.castReaderKindle.postMessage({
            type:'kindle-sync-dialog',visible,localLocation:1635,cloudLocation:1111
          });
          window.chooseNo=()=>webkit.messageHandlers.castReaderKindle.postMessage({
            type:'kindle-sync-dialog-choice',visible:true,choice:'no',localLocation:1635,cloudLocation:1111
          });
        </script>
        """, baseURL: URL(string: "https://read.amazon.com/sample/B000000001"))
        var loaded = false
        for _ in 0..<100 {
            loaded = (try? await model.webView.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true
            if loaded && !model.webView.isLoading && !model.isNavigating { break }
            loaded = false
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard loaded else { throw FixtureError.timedOut }
        let controlsReady = await model.prepareReaderControls(reason: "initial-sync-fixture")
        XCTAssertTrue(controlsReady, "Use the real bootstrap before the settings cancellation scenario")
        let initialStart = Task { try await model.startCurrentMode() }
        defer { initialStart.cancel() }
        try await waitUntil { preparation.calls == 1 }
        NSLog("CRDBG SYNC_FIXTURE first preparation held scenario=%@", cancellation ?? "resume")
        XCTAssertNil(model.readVM, "The pending intent exists before OCR has created a Read VM")
        XCTAssertFalse(model.isPreparing, "Generic isPreparing is not used as evidence of a Play request")
        // A repeated Play coalesces without creating a second producer or Pause.
        let repeated = try await model.startCurrentMode()
        guard case .deferred = repeated else { return XCTFail("Repeated pending Play must coalesce") }
        XCTAssertEqual(preparation.calls, 1)
        NSLog("CRDBG SYNC_FIXTURE repeated start coalesced")
        // postMessage returns undefined. Return a supported primitive from the
        // evaluation rather than making the async WK result bridge marshal it.
        _ = try await model.webView.evaluateJavaScript("sendSync(true); true")
        try await waitUntil { model.isKindleSyncDialogVisible }
        NSLog("CRDBG SYNC_FIXTURE sync visible")
        if cancellation == "caller" { initialStart.cancel() }
        _ = try await model.webView.evaluateJavaScript("chooseNo();sendSync(false); true")
        try await waitUntil { !model.isKindleSyncDialogVisible }
        NSLog("CRDBG SYNC_FIXTURE sync hidden")
        if cancellation == "settings" {
            model.openReadingSettings()
            XCTAssertTrue(model.isReadingSettingsPresented)
        } else if cancellation == "destroy" {
            model.destroy()
        }
        preparation.finish()
        let oldOutcome = try await initialStart.value
        guard case .deferred = oldOutcome else { return XCTFail("The old capture must lose startup ownership") }
        if cancellation == nil {
            try await waitUntil { preparation.calls == 2 }
        } else {
            // Covers the resolver's 650 ms settle and a complete main/WK turn.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertEqual(preparation.calls, 1, "Cancelled intent must not start again: \(cancellation!)")
        }
        XCTAssertNil(model.readVM)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
        XCTAssertEqual(preparation.calls, cancellation == nil ? 2 : 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard predicate() else { throw FixtureError.timedOut }
    }
}
