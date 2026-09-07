import XCTest
import WebKit
@testable import CastReader

@MainActor
final class KindleReadingSettingsScriptTests: XCTestCase {
    private var window: UIWindow!
    private var web: WKWebView!

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: window.bounds, configuration: config)
        controller.view.addSubview(web)
    }

    override func tearDown() {
        web.stopLoading()
        web.removeFromSuperview()
        window.isHidden = true
        web = nil
        window = nil
        super.tearDown()
    }

    private func load(_ controls: String, setup: String = "") async throws {
        let fixtureToken = UUID().uuidString
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <button id="aa" aria-label="Reading settings" onclick="panel.hidden=!panel.hidden">Aa</button>
        <section id="panel" hidden>\(controls)</section>
        <script>window.fixtureReady=true; window.fixtureToken="\(fixtureToken)"; window.commits=[]; \(setup)</script>
        """, baseURL: URL(string: "https://fixture.invalid"))
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("window.fixtureToken==='\(fixtureToken)'")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Local WKWebView fixture did not load")
    }

    private func json(_ js: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(js)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(value as? String).utf8)) as? [String: Any])
    }

    func testSettingsButtonSelectionIgnoresOffscreenDuplicateButRejectsVisibleAmbiguity() async throws {
        try await load("<input aria-label='Font size' type='range' value='6'>", setup: """
        window.openClicks=0; aa.onclick=()=>{openClicks++;panel.hidden=false;};
        const duplicate=aa.cloneNode(true);duplicate.id='duplicate';
        duplicate.style.cssText='position:fixed;left:10000px;top:10px';
        document.body.prepend(duplicate);duplicate.onclick=()=>commits.push('wrong');
        """)
        let opening = try await json(KindleReadingSettingsScript.read)
        let probe = try XCTUnwrap(opening["probe"] as? [String: Any])
        XCTAssertEqual(probe["candidateCount"] as? Int, 2)
        XCTAssertEqual(probe["eligibleCount"] as? Int, 1)
        let clicks = try await web.evaluateJavaScript("openClicks") as? Int
        XCTAssertEqual(clicks, 1)
        _ = try await web.evaluateJavaScript("panel.hidden=true;window.__crKindleFontOpenedByNative=false;duplicate.style.left='180px';true")
        let ambiguous = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(ambiguous["reason"] as? String, "ambiguous-settings-button")
        let after = try await web.evaluateJavaScript("openClicks") as? Int
        let wrong = try await web.evaluateJavaScript("commits.length") as? Int
        XCTAssertEqual(after, 1)
        XCTAssertEqual(wrong, 0)
    }

    func testSettingsButtonRejectsDisabledInertHiddenAndBroadFontMatches() async throws {
        for mutation in [
            "aa.disabled=true", "aa.parentElement.setAttribute('inert','')",
            "aa.parentElement.setAttribute('aria-disabled','true')",
            "aa.parentElement.style.visibility='hidden'", "aa.parentElement.setAttribute('aria-hidden','true')",
            "aa.textContent='';aa.setAttribute('aria-label','Display font preferences')"
        ] {
            try await load("<input aria-label='Font size' type='range' value='6'>", setup: mutation)
            let result = try await json(KindleReadingSettingsScript.read)
            XCTAssertEqual(result["reason"] as? String, "settings-unavailable", mutation)
            let hidden = try await web.evaluateJavaScript("panel.hidden") as? Bool
            XCTAssertEqual(hidden, true)
        }
    }

    func testDisabledSplitPaneKeepsItsEnabledSettingsButtonOperable() async throws {
        try await load("<input aria-label='Font size' type='range' value='6'>", setup: """
        const split=document.createElement('ion-split-pane');
        split.setAttribute('disabled','true');split.disabled=true;split.style.display='block';
        const host=document.createElement('ion-button');host.setAttribute('aria-label','Reader settings');
        host.style.cssText='display:inline-block;width:44px;height:44px';
        host.attachShadow({mode:'open'}).innerHTML='<button style="width:44px;height:44px"><slot></slot></button>';
        host.textContent='Aa';window.openClicks=0;
        host.onclick=()=>{openClicks++;panel.hidden=false;};
        aa.replaceWith(split);split.appendChild(host);
        """)
        let opening = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(opening["reason"] as? String, "opening-settings")
        let read = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(read["ok"] as? Bool, true)
        XCTAssertEqual(read["value"] as? Int, 6)
        let clicks = try await web.evaluateJavaScript("openClicks") as? Int
        XCTAssertEqual(clicks, 1)
        let probe = try XCTUnwrap(opening["probe"] as? [String: Any])
        let button = try XCTUnwrap(probe["button"] as? [String: Any])
        let ancestors = try XCTUnwrap(button["ancestors"] as? [[String: Any]])
        let split = try XCTUnwrap(ancestors.first { $0["tag"] as? String == "ION-SPLIT-PANE" })
        XCTAssertEqual(split["disabled"] as? Bool, true)
        XCTAssertEqual(split["disabledAttribute"] as? Bool, true)
        XCTAssertEqual(button["eligible"] as? Bool, true)
    }

    func testNativeDisabledFieldsetHonorsOnlyItsFirstLegendException() async throws {
        for placement in ["outside", "first", "second"] {
            try await load("<input aria-label='Font size' type='range' value='6'>", setup: """
            const field=document.createElement('fieldset');field.disabled=true;
            const first=document.createElement('legend');first.textContent='Group';field.appendChild(first);
            const second=document.createElement('legend');second.textContent='Other';field.appendChild(second);
            (('\(placement)'==='first')?first:(('\(placement)'==='second')?second:field)).appendChild(aa);
            document.body.prepend(field);window.openClicks=0;
            aa.onclick=()=>{openClicks++;panel.hidden=false;};
            """)
            let browserDisabled = try await web.evaluateJavaScript("aa.matches(':disabled')") as? Bool
            XCTAssertEqual(browserDisabled, placement != "first", placement)
            let result = try await json(KindleReadingSettingsScript.read)
            XCTAssertEqual(result["reason"] as? String, placement == "first" ? "opening-settings" : "settings-unavailable", placement)
            let clicks = try await web.evaluateJavaScript("openClicks") as? Int
            XCTAssertEqual(clicks, placement == "first" ? 1 : 0, placement)
        }
    }

    func testEnabledIonicHostCannotBypassItsDisabledNativeShadowButton() async throws {
        try await load("<input aria-label='Font size' type='range' value='6'>", setup: """
        const host=document.createElement('ion-button');host.setAttribute('aria-label','Reader settings');
        host.style.cssText='display:inline-block;width:44px;height:44px';host.textContent='Aa';
        host.attachShadow({mode:'open'}).innerHTML='<button disabled style="width:44px;height:44px"><slot></slot></button>';
        window.openClicks=0;host.onclick=()=>{openClicks++;panel.hidden=false;};aa.replaceWith(host);
        window.nativeButton=host.shadowRoot.querySelector('button');
        """)
        let rejected = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(rejected["reason"] as? String, "settings-unavailable")
        let probe = try XCTUnwrap(rejected["probe"] as? [String: Any])
        let button = try XCTUnwrap(probe["button"] as? [String: Any])
        XCTAssertEqual(button["rejectionReason"] as? String, "disabled-shadow-button")
        let before = try await web.evaluateJavaScript("openClicks") as? Int
        XCTAssertEqual(before, 0)
        _ = try await web.evaluateJavaScript("nativeButton.disabled=false;true")
        let opening = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(opening["reason"] as? String, "opening-settings")
        let after = try await web.evaluateJavaScript("openClicks") as? Int
        XCTAssertEqual(after, 1)
    }

    func testSettingsButtonUsesExactLocalizedLabels() async throws {
        for label in ["Reader settings", "Leseeinstellungen", "Paramètres de lecture", "Configuración de lectura", "Configurações de leitura", "Impostazioni di lettura", "読書設定", "阅读设置", "पढ़ने की सेटिंग"] {
            try await load("<input aria-label='Font size' type='range' value='6'>", setup: "aa.textContent='';aa.setAttribute('aria-label','\(label)');")
            let opening = try await json(KindleReadingSettingsScript.read)
            XCTAssertEqual(opening["reason"] as? String, "opening-settings", label)
            let read = try await json(KindleReadingSettingsScript.read)
            XCTAssertEqual(read["ok"] as? Bool, true, label)
        }
    }

    func testUniqueTranslatedNativeHeaderCanOpenButCannotBypassHiddenOrDisabledState() async throws {
        for mutation in ["", "header.hidden=true", "header.setAttribute('inert','')", "header.setAttribute('aria-disabled','true')", "header.style.display='none'", "header.setAttribute('aria-hidden','true')"] {
            try await load("<input aria-label='Font size' type='range' value='6'>", setup: """
            const header=document.createElement('ion-header');header.style.cssText='display:block;position:fixed;top:0;left:0;transform:translateY(-64px)';
            const host=document.createElement('ion-button');host.setAttribute('aria-label','Reader settings');
            host.style.cssText='display:block;width:44px;height:44px';
            host.attachShadow({mode:'open'}).innerHTML='<button style="width:44px;height:44px"><slot></slot></button>';
            host.textContent='Aa';window.openClicks=0;host.onclick=()=>{openClicks++;panel.hidden=false;};
            aa.replaceWith(header);header.appendChild(host);\(mutation);
            """)
            let result = try await json(KindleReadingSettingsScript.read)
            XCTAssertEqual(result["reason"] as? String, mutation.isEmpty ? "opening-settings" : "settings-unavailable", mutation)
            let clicks = try await web.evaluateJavaScript("openClicks") as? Int
            XCTAssertEqual(clicks, mutation.isEmpty ? 1 : 0, mutation)
        }
    }

    func testDuplicateTranslatedNativeHeadersCannotDispatchEitherAa() async throws {
        try await load("", setup: """
        aa.remove();window.openClicks=0;
        for(let i=0;i<2;i++){
          const header=document.createElement('ion-header');header.style.cssText='display:block;position:fixed;top:-64px;left:0';
          const host=document.createElement('ion-button');host.setAttribute('aria-label','Reader settings');
          host.style.cssText='display:block;width:44px;height:44px';host.textContent='Aa';host.onclick=()=>openClicks++;
          header.appendChild(host);document.body.appendChild(header);
        }
        """)
        let result = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(result["reason"] as? String, "settings-unavailable")
        let probe = try XCTUnwrap(result["probe"] as? [String: Any])
        XCTAssertEqual(probe["candidateCount"] as? Int, 2)
        XCTAssertEqual(probe["eligibleCount"] as? Int, 0)
        let clicks = try await web.evaluateJavaScript("openClicks") as? Int
        XCTAssertEqual(clicks, 0)
    }

    func testIonicOuterAriaHiddenDoesNotRejectOpenMenuButInnerHiddenDoes() async throws {
        for hideInside in [false, true] {
            try await load("<input aria-label='Font size' type='range' value='6'>", setup: """
            const outside=document.createElement('div');outside.setAttribute('aria-hidden','true');
            const menu=document.createElement('ion-menu');menu.className='show-menu';
            menu.style.cssText='display:block;position:fixed;left:0;top:0;width:240px;height:80px';
            const inner=document.createElement('div');
            if(\(hideInside ? "true" : "false"))inner.setAttribute('aria-hidden','true');
            inner.appendChild(aa);menu.appendChild(inner);outside.appendChild(menu);document.body.appendChild(outside);
            """)
            let result = try await json(KindleReadingSettingsScript.read)
            XCTAssertEqual(result["reason"] as? String, hideInside ? "settings-unavailable" : "opening-settings")
        }
    }

    func testSuccessProbeReportsShadowStructureWithoutContentOrStorage() async throws {
        try await load("<input aria-label='Font size' type='range' value='6'>", setup: """
        const host=document.createElement('ion-button');host.textContent='Aa';host.setAttribute('aria-label','Reading settings');
        host.style.cssText='display:inline-block;width:60px;height:44px';
        host.attachShadow({mode:'open'}).innerHTML='<button><slot></slot></button>';
        aa.replaceWith(host);host.onclick=()=>panel.hidden=false;
        document.body.appendChild(document.createTextNode('PRIVATE_FIXTURE_CONTENT'));
        localStorage.setItem('PRIVATE_FIXTURE_STORAGE','SECRET');
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.read)
        let probe = try XCTUnwrap(result["probe"] as? [String: Any])
        let button = try XCTUnwrap(probe["button"] as? [String: Any])
        XCTAssertEqual(button["hasShadowRoot"] as? Bool, true)
        XCTAssertEqual(button["shadowButtonCount"] as? Int, 1)
        let data = try JSONSerialization.data(withJSONObject: probe)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_FIXTURE"))
        XCTAssertFalse(text.contains("fixture.invalid"))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertNotNil(probe["viewport"])
        XCTAssertNotNil(probe["documentHidden"])
    }

    func testNativePanelOwnsCloseAcrossInnerSectionAndShadowAnimation() async throws {
        try await load("""
        <ion-menu id='nativePanel' class='show-menu' style='display:block;width:300px;height:180px'>
          <section><input aria-label='Font size' type='range' value='6'></section>
          <button id='nativeClose' aria-label='Side panel close'>×</button>
        </ion-menu>
        """, setup: """
        nativePanel.attachShadow({mode:'open'}).innerHTML='<div id="inner"><slot></slot></div>';
        window.nativeCloseClicks=0;
        nativeClose.onclick=()=>{
          nativeCloseClicks++;
          window.closing=nativePanel.shadowRoot.querySelector('#inner').animate([{opacity:1},{opacity:0}],{duration:60000});
          nativePanel.style.visibility='hidden';nativePanel.classList.remove('show-menu');
        };
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        let read = try await json(KindleReadingSettingsScript.read)
        let probe = try XCTUnwrap(read["probe"] as? [String: Any])
        XCTAssertEqual(probe["panelTag"] as? String, "ION-MENU", "The nested section cannot own native close")
        _ = try await web.evaluateJavaScript("window.opening=nativePanel.shadowRoot.querySelector('#inner').animate([{opacity:0},{opacity:1}],{duration:60000});true")
        let opening = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(opening["reason"] as? String, "settings-menu-animating")
        let before = try await web.evaluateJavaScript("nativeCloseClicks") as? Int
        XCTAssertEqual(before, 0)
        _ = try await web.evaluateJavaScript("opening.finish();true")
        let closing = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(closing["ok"] as? Bool, false, "CSS hiding does not prove that native close animation completed")
        _ = try await web.evaluateJavaScript("closing.finish();true")
        let closed = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(closed["ok"] as? Bool, true)
        let clicks = try await web.evaluateJavaScript("nativeCloseClicks") as? Int
        XCTAssertEqual(clicks, 1)
    }

    func testEmptyOpenedMenuRetainsOwnershipAfterAaReplacementAndClosesOnce() async throws {
        try await load("", setup: """
        const menu=document.createElement('ion-menu');menu.id='emptyMenu';menu.hidden=true;
        menu.style.cssText='width:280px;height:160px';
        menu.innerHTML='<button aria-label="Side panel close">×</button>';
        menu.attachShadow({mode:'open'}).innerHTML='<div><slot></slot></div>';
        document.body.appendChild(menu);window.openClicks=0;window.closeClicks=0;
        const opener=aa;opener.onclick=()=>{
          openClicks++;menu.hidden=false;menu.style.display='block';menu.classList.add('show-menu');
          window.opening=menu.shadowRoot.querySelector('div').animate([{opacity:0},{opacity:1}],{duration:60000});
          opener.replaceWith(opener.cloneNode(true));
        };
        menu.querySelector('button').onclick=()=>{
          closeClicks++;menu.classList.remove('show-menu');menu.style.visibility='hidden';
          window.closing=menu.shadowRoot.querySelector('div').animate([{opacity:1},{opacity:0}],{duration:60000});
        };
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        let pending = try await json(KindleReadingSettingsScript.read)
        let probe = try XCTUnwrap(pending["probe"] as? [String: Any])
        XCTAssertEqual(probe["panelTag"] as? String, "ION-MENU")
        XCTAssertEqual(probe["panelConnected"] as? Bool, true)
        XCTAssertEqual(probe["rangeCount"] as? Int, 0)
        // The read probe describes its current candidate, while the dispatch
        // owner must still be the detached original Aa that opened this menu.
        let currentButton = try XCTUnwrap(probe["button"] as? [String: Any])
        XCTAssertEqual(currentButton["connected"] as? Bool, true)
        let savedButtonConnected = try await web.evaluateJavaScript("window.__crKindleFontSettingsButton.isConnected") as? Bool
        XCTAssertEqual(savedButtonConnected, false)
        let blocked = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(blocked["reason"] as? String, "settings-menu-animating")
        let before = try await web.evaluateJavaScript("closeClicks") as? Int
        XCTAssertEqual(before, 0)
        _ = try await web.evaluateJavaScript("opening.finish();true")
        let closing = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(closing["ok"] as? Bool, false)
        _ = try await json(KindleReadingSettingsScript.close(attempt: 1))
        _ = try await web.evaluateJavaScript("closing.finish();true")
        let closed = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(closed["ok"] as? Bool, true)
        let counts = try await web.evaluateJavaScript("[openClicks,closeClicks]") as? [Int]
        XCTAssertEqual(counts, [1, 1])
    }

    func testEmptyMenuRecoveryNeverAcquiresPreexistingMenuAndPrefersExplicitTarget() async throws {
        for target in ["none", "aria-controls", "menu"] {
            try await load("", setup: """
            const previous=document.createElement('ion-menu');previous.id='previousMenu';
            previous.style.cssText='display:block;width:280px;height:80px';previous.className='show-menu';
            previous.innerHTML='<button aria-label="Side panel close" onclick="wrongCloses++">×</button>';
            const owned=previous.cloneNode(true);owned.id='ownedMenu';owned.hidden=true;owned.className='';owned.style.display='none';
            owned.setAttribute('menu-id','reader-panel');
            const extra=owned.cloneNode(true);extra.id='extraMenu';extra.setAttribute('menu-id','other-panel');
            document.body.append(previous,owned,extra);window.wrongCloses=0;window.ownedCloses=0;window.openClicks=0;
            if('\(target)'==='aria-controls')aa.setAttribute('aria-controls','ownedMenu');
            if('\(target)'==='menu'){
              const toggle=document.createElement('ion-menu-toggle');toggle.setAttribute('menu','reader-panel');
              const opener=aa;opener.replaceWith(toggle);toggle.appendChild(opener);
            }
            aa.onclick=()=>{
              openClicks++;owned.hidden=false;owned.style.display='block';owned.classList.add('show-menu');
              if('\(target)'!=='none'){extra.hidden=false;extra.style.display='block';extra.classList.add('show-menu');}
            };
            owned.querySelector('button').onclick=()=>{ownedCloses++;owned.hidden=true;owned.style.display='none';owned.classList.remove('show-menu');};
            """)
            _ = try await json(KindleReadingSettingsScript.read)
            _ = try await json(KindleReadingSettingsScript.read)
            let closed = try await json(KindleReadingSettingsScript.close(attempt: 1))
            XCTAssertEqual(closed["ok"] as? Bool, true, target)
            let counts = try await web.evaluateJavaScript("[openClicks,ownedCloses,wrongCloses]") as? [Int]
            XCTAssertEqual(counts, [1, 1, 0], target)
            let previousOpen = try await web.evaluateJavaScript("previousMenu.classList.contains('show-menu')") as? Bool
            XCTAssertEqual(previousOpen, true, target)
            if target != "none" {
                let extraOpen = try await web.evaluateJavaScript("extraMenu.classList.contains('show-menu')") as? Bool
                XCTAssertEqual(extraOpen, true, target)
            }
        }
    }

    func testAmbiguousNewEmptyMenusCannotBeClosedOrRetoggleAa() async throws {
        try await load("", setup: """
        window.openClicks=0;window.closeClicks=0;
        aa.onclick=()=>{
          openClicks++;
          for(let i=0;i<2;i++){
            const menu=document.createElement('ion-menu');menu.className='show-menu';
            menu.style.cssText='display:block;width:280px;height:80px';
            menu.innerHTML='<button aria-label="Side panel close" onclick="closeClicks++">×</button>';
            document.body.appendChild(menu);
          }
        };
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await json(KindleReadingSettingsScript.read)
        let closed = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(closed["ok"] as? Bool, false)
        XCTAssertEqual(closed["reason"] as? String, "settings-panel-ambiguous")
        _ = try await json(KindleReadingSettingsScript.close(attempt: 1))
        let counts = try await web.evaluateJavaScript("[openClicks,closeClicks,document.querySelectorAll('ion-menu.show-menu').length]") as? [Int]
        XCTAssertEqual(counts, [1, 0, 2])
    }

    func testEmptyMenuPublicCloseWaitsForPromiseNativeStateAndAnimationWithoutRedispatch() async throws {
        try await load("", setup: """
        const menu=document.createElement('ion-menu');menu.id='apiMenu';menu.hidden=true;
        menu.style.cssText='width:280px;height:160px';menu.attachShadow({mode:'open'}).innerHTML='<div><slot></slot></div>';
        document.body.appendChild(menu);window.apiCalls=0;window.apiOpen=true;
        menu.isOpen=()=>Promise.resolve(apiOpen);
        menu.close=()=>{
          apiCalls++;menu.style.visibility='hidden';menu.classList.remove('show-menu');
          return new Promise(resolve=>window.resolveClose=resolve);
        };
        aa.onclick=()=>{menu.hidden=false;menu.style.display='block';menu.classList.add('show-menu');};
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        let first = try await json(KindleReadingSettingsScript.close(attempt: 1))
        XCTAssertEqual(first["reason"] as? String, "closing-native-menu")
        let pending = try await json(KindleReadingSettingsScript.close(attempt: 2))
        XCTAssertEqual(pending["ok"] as? Bool, false, "A second Done cannot bypass the unresolved native close")
        _ = try await web.evaluateJavaScript("resolveClose(true);true")
        let stillOpen = try await json(KindleReadingSettingsScript.close(attempt: 2))
        XCTAssertEqual(stillOpen["ok"] as? Bool, false, "The public isOpen state still owns completion")
        _ = try await web.evaluateJavaScript("apiOpen=false;window.closing=apiMenu.shadowRoot.querySelector('div').animate([{opacity:1},{opacity:0}],{duration:60000});true")
        let animating = try await json(KindleReadingSettingsScript.close(attempt: 2))
        XCTAssertEqual(animating["reason"] as? String, "settings-menu-animating")
        _ = try await web.evaluateJavaScript("closing.finish();true")
        var closed = false
        for _ in 0..<20 {
            closed = try await json(KindleReadingSettingsScript.close(attempt: 2))["ok"] as? Bool == true
            if closed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(closed)
        let calls = try await web.evaluateJavaScript("apiCalls") as? Int
        XCTAssertEqual(calls, 1)
    }

    func testPublicCloseFailureStaysUnclosedAndOldReplyCannotCompleteReplacementOwner() async throws {
        for failure in ["false", "reject"] {
            try await load("", setup: """
            const menu=document.createElement('ion-menu');menu.id='apiMenu';menu.hidden=true;menu.style.cssText='width:280px;height:100px';
            document.body.appendChild(menu);window.apiCalls=0;menu.isOpen=()=>Promise.resolve(true);
            menu.close=()=>{apiCalls++;return '\(failure)'==='reject'?Promise.reject(new Error('fixture')):Promise.resolve(false);};
            aa.onclick=()=>{menu.hidden=false;menu.style.display='block';menu.classList.add('show-menu');};
            """)
            _ = try await json(KindleReadingSettingsScript.read)
            for _ in 0..<5 {
                let result = try await json(KindleReadingSettingsScript.close(attempt: 1))
                XCTAssertEqual(result["ok"] as? Bool, false, failure)
            }
            let calls = try await web.evaluateJavaScript("apiCalls") as? Int
            XCTAssertEqual(calls, 1, failure)
        }
        try await load("", setup: """
        window.oldChecks=0;window.apiCalls=0;
        const old=document.createElement('ion-menu');old.id='oldMenu';old.hidden=true;old.style.cssText='width:280px;height:100px';
        old.isOpen=()=>{oldChecks++;return Promise.resolve(false);};
        old.close=()=>new Promise(resolve=>window.oldResolve=resolve);document.body.appendChild(old);
        aa.onclick=()=>{old.hidden=false;old.style.display='block';old.classList.add('show-menu');};
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await json(KindleReadingSettingsScript.close(attempt: 1))
        _ = try await web.evaluateJavaScript("""
        oldMenu.hidden=true;oldMenu.style.display='none';oldMenu.classList.remove('show-menu');
        const next=document.createElement('ion-menu');next.id='nextMenu';next.hidden=true;next.style.cssText='width:280px;height:100px';
        next.isOpen=()=>Promise.resolve(true);next.close=()=>{apiCalls++;return new Promise(()=>{});};document.body.appendChild(next);
        aa.onclick=()=>{next.hidden=false;next.style.display='block';next.classList.add('show-menu');};true
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await json(KindleReadingSettingsScript.close(attempt: 2))
        _ = try await web.evaluateJavaScript("oldResolve(true);true")
        let replacement = try await json(KindleReadingSettingsScript.close(attempt: 2))
        XCTAssertEqual(replacement["ok"] as? Bool, false)
        let counts = try await web.evaluateJavaScript("[oldChecks,apiCalls]") as? [Int]
        XCTAssertEqual(counts, [0, 1], "The obsolete Promise cannot probe or complete the new owner")
    }

    func testPublicMenuCloseCannotBypassLabelledControlsOrAcquireUnrelatedMenu() async throws {
        for kind in ["normal", "disabled", "hidden", "ambiguous", "unrelated"] {
            try await load("", setup: """
            const menu=document.createElement('ion-menu');menu.id='apiMenu';menu.hidden=true;menu.style.cssText='width:280px;height:100px';
            document.body.appendChild(menu);window.apiCalls=0;window.buttonCalls=0;
            menu.isOpen=()=>Promise.resolve(true);menu.close=()=>{apiCalls++;return Promise.resolve(true);};
            if('\(kind)'!=='unrelated'){
              const close=document.createElement('button');close.setAttribute('aria-label','Side panel close');close.textContent='×';
              close.disabled='\(kind)'==='disabled';close.hidden='\(kind)'==='hidden';
              close.onclick=()=>{buttonCalls++;menu.hidden=true;menu.style.display='none';menu.classList.remove('show-menu');};menu.appendChild(close);
              if('\(kind)'==='ambiguous')menu.appendChild(close.cloneNode(true));
            }
            if('\(kind)'==='unrelated'){menu.hidden=false;menu.style.display='block';menu.classList.add('show-menu');aa.onclick=()=>{};}
            else aa.onclick=()=>{menu.hidden=false;menu.style.display='block';menu.classList.add('show-menu');};
            """)
            _ = try await json(KindleReadingSettingsScript.read)
            let result = try await json(KindleReadingSettingsScript.close(attempt: 1))
            if ["disabled", "hidden", "ambiguous"].contains(kind) { XCTAssertEqual(result["ok"] as? Bool, false, kind) }
            let counts = try await web.evaluateJavaScript("[apiCalls,buttonCalls]") as? [Int]
            XCTAssertEqual(counts, [0, kind == "normal" ? 1 : 0], kind)
            if kind == "unrelated" {
                let open = try await web.evaluateJavaScript("apiMenu.classList.contains('show-menu')") as? Bool
                XCTAssertEqual(open, true)
            }
        }
    }

    func testLiveNativeRangeWinsOverStaleStorageAndCommitsOneStep() async throws {
        try await load("<input id='font' aria-label='Font size' type='range' min='1' max='10' step='1' value='6'>", setup: "localStorage.setItem('fontSize','5'); font.addEventListener('change',()=>commits.push(font.value));")
        let opening = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(opening["reason"] as? String, "opening-settings")
        let initial = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(initial["value"] as? Int, 6)
        let changed = try await json(KindleReadingSettingsScript.change(by: 1))
        XCTAssertEqual(changed["value"] as? Int, 7)
        let commits = try await web.evaluateJavaScript("commits") as? [String]
        XCTAssertEqual(commits, ["7"])
        _ = try await json(KindleReadingSettingsScript.close)
        _ = try await json(KindleReadingSettingsScript.read)
        let reopened = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(reopened["value"] as? Int, 7)
        let observed1 = try await web.evaluateJavaScript("localStorage.getItem('fontSize')") as? String
        XCTAssertEqual(observed1, "5")
    }

    func testFractionalStepClampsAtBoundsAndDoesNotRedispatchNoOp() async throws {
        try await load("<input id='font' aria-label='Font size' type='range' min='0.5' max='1.5' step='0.5' value='1'>", setup: "font.addEventListener('change',()=>commits.push(font.value));")
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await json(KindleReadingSettingsScript.change(by: 1))
        _ = try await json(KindleReadingSettingsScript.change(by: 1))
        let observed2 = try await web.evaluateJavaScript("commits") as? [String]
        XCTAssertEqual(observed2, ["1.5"])
    }

    func testIonicFontUsesOneNativeButtonCommitThatSurvivesControlRecreation() async throws {
        try await load("""
        <ion-range id='font' aria-label='Font size' min='1' max='10' step='1' style='display:block;width:200px;height:40px'>
          <button aria-label='Decrease font size' onclick='commitFont(-1)'>A−</button>
          <button aria-label='Increase font size' onclick='commitFont(1)'>A+</button>
        </ion-range>
        """, setup: """
        font.value=6;
        window.syntheticChanges=0;
        localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:6}));
        window.commitFont=delta=>{
          font.value+=delta; commits.push(font.value);
          localStorage.setItem('KWR_Display_Settings',JSON.stringify({fontSizeIndex:font.value}));
        };
        font.addEventListener('ionChange',()=>syntheticChanges++);
        """)
        _ = try await json(KindleReadingSettingsScript.read)
        let changed = try await json(KindleReadingSettingsScript.change(by: -1))
        XCTAssertEqual(changed["value"] as? Int, 5)
        let commits = try await web.evaluateJavaScript("commits") as? [Int]
        XCTAssertEqual(commits, [5], "Only Kindle's native button owns the durable preference")
        let syntheticChanges = try await web.evaluateJavaScript("syntheticChanges") as? Int
        XCTAssertEqual(syntheticChanges, 0)
        _ = try await web.evaluateJavaScript("""
        const replacement=font.cloneNode(true); font.replaceWith(replacement);
        replacement.value=JSON.parse(localStorage.getItem('KWR_Display_Settings')).fontSizeIndex; true
        """)
        let restored = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(restored["value"] as? Int, 5)
        XCTAssertEqual(restored["persistedValue"] as? Int, 5)
    }

    func testIonicRangeWithoutNativeFontButtonIsNotMutated() async throws {
        try await load("<ion-range id='font' aria-label='Font size' min='1' max='10' style='display:block;width:200px;height:40px'></ion-range>", setup: "font.value=6; font.addEventListener('ionChange',()=>commits.push('unexpected'));")
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.change(by: 1))
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, "font-button-unavailable")
        let actual = try await web.evaluateJavaScript("font.value") as? Int
        let count = try await web.evaluateJavaScript("commits.length") as? Int
        XCTAssertEqual(actual, 6)
        XCTAssertEqual(count, 0)
    }

    func testAmbiguousOrDisabledNativeButtonsCannotFallBackToSyntheticMutation() async throws {
        for buttons in [
            "<button aria-label='Increase font size' disabled>A+</button>",
            "<button aria-label='Increase font size'>A+</button><button aria-label='Increase font size'>A+</button>"
        ] {
            try await load("<ion-range id='font' aria-label='Font size' min='1' max='10' style='display:block;width:200px;height:40px'>\(buttons)</ion-range>", setup: "font.value=6; font.addEventListener('ionChange',()=>commits.push('unexpected'));")
            _ = try await json(KindleReadingSettingsScript.read)
            let result = try await json(KindleReadingSettingsScript.change(by: 1))
            XCTAssertEqual(result["ok"] as? Bool, false)
            let actual = try await web.evaluateJavaScript("font.value") as? Int
            XCTAssertEqual(actual, 6)
        }
    }

    func testLocalizedNativeFontButtonCommitsExactlyOneStep() async throws {
        for label in ["Schriftgröße erhöhen", "Augmenter la taille de la police", "Aumentar el tamaño de fuente", "Aumentar tamanho da fonte", "Aumenta dimensione carattere", "文字サイズを大きくする", "增大字号", "फ़ॉन्ट आकार बढ़ाएँ"] {
            try await load("<ion-range id='font' aria-label='Font size' min='1' max='10' style='display:block;width:200px;height:40px'><button aria-label='\(label)' onclick='font.value++;commits.push(font.value)'>A+</button></ion-range>", setup: "font.value=6;")
            _ = try await json(KindleReadingSettingsScript.read)
            let changed = try await json(KindleReadingSettingsScript.change(by: 1))
            XCTAssertEqual(changed["value"] as? Int, 7)
            let commits = try await web.evaluateJavaScript("commits") as? [Int]
            XCTAssertEqual(commits, [7], label)
        }
    }

    func testNativeSettingsCloseUsesPanelControlWithoutRetogglingAa() async throws {
        try await load("<input aria-label='Font size' type='range' value='6'><button aria-label='Side panel close' onclick='panel.hidden=true;commits.push(\"close\")'>×</button>", setup:"window.aaClicks=0;aa.addEventListener('click',()=>aaClicks++);")
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await json(KindleReadingSettingsScript.read)
        let closed = try await json(KindleReadingSettingsScript.close(attempt:1))
        _ = try await json(KindleReadingSettingsScript.close(attempt:1))
        let aaClicks = try await web.evaluateJavaScript("aaClicks") as? Int
        let commits = try await web.evaluateJavaScript("commits") as? [String]
        XCTAssertEqual(closed["ok"] as? Bool,true)
        XCTAssertEqual(aaClicks,1,"Opening Aa is not repeated while closing the native panel")
        XCTAssertEqual(commits,["close"])
    }

    func testUnlabelledAmbiguousRangesAreNotChanged() async throws {
        try await load("<input id='a' type='range'><input id='b' type='range'>", setup: "a.addEventListener('change',()=>commits.push('a')); b.addEventListener('change',()=>commits.push('b'));")
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.change(by: 1))
        XCTAssertEqual(result["ok"] as? Bool, false)
        let observed4 = try await web.evaluateJavaScript("commits.length") as? Int
        XCTAssertEqual(observed4, 0)
    }

    func testSingleNonFontRangeIsNeverMistakenForFontSize() async throws {
        try await load("<input id='font' aria-label='Reading progress' type='range' value='50'>")
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.change(by: -1))
        let actual = try await web.evaluateJavaScript("font.value") as? String
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(actual, "50")
    }

    func testDefaultNativeRangeBoundsRetainOneStepSemantics() async throws {
        try await load("<input id='font' aria-label='Font size' type='range' value='50'>")
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.change(by: -1))
        XCTAssertEqual(result["value"] as? Int, 49)
        XCTAssertEqual(result["max"] as? Int, 100)
    }

    func testCloseCannotReopenAnAlreadyClosedAmazonPanel() async throws {
        try await load("<input aria-label='Font size' type='range' min='1' max='10' value='6'>")
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await web.evaluateJavaScript("panel.hidden=true")
        let result = try await json(KindleReadingSettingsScript.close)
        let hidden = try await web.evaluateJavaScript("panel.hidden") as? Bool
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(hidden, true)
    }
}
