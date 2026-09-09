import XCTest
import UIKit
import WebKit
@testable import CastReader

final class KindlePageTurnEvidenceTests: XCTestCase {
    func testProgressMustAgreeWithRequestedDirection() {
        for (direction, expectedLocation, unexpectedLocation) in [
            (KindlePageTurnDirection.next, 102, 100), (.previous, 100, 102)
        ] {
            let accepted = KindleTurnContract.progress(
                beforeLocation: 101, afterLocation: expectedLocation,
                beforeRenderer: nil, afterRenderer: nil, direction: direction
            )
            let rejected = KindleTurnContract.progress(
                beforeLocation: 101, afterLocation: unexpectedLocation,
                beforeRenderer: nil, afterRenderer: nil, direction: direction
            )
            XCTAssertEqual(accepted, .forward)
            XCTAssertEqual(rejected, .backward)
            XCTAssertTrue(confirms(accepted, before: "page101", after: "new", samples: 1))
            XCTAssertFalse(confirms(rejected, before: "page101", after: "new", samples: 3))
        }
    }

    func testPreviousUsesRendererEvidenceOnlyWhenLocationDidNotChange() {
        XCTAssertEqual(KindleTurnContract.progress(
            beforeLocation: 101, afterLocation: 101, beforeRenderer: 8, afterRenderer: 7,
            direction: .previous
        ), .forward)
        XCTAssertEqual(KindleTurnContract.progress(
            beforeLocation: 101, afterLocation: 102, beforeRenderer: 8, afterRenderer: 7,
            direction: .previous
        ), .backward, "Visible location evidence takes precedence over renderer position")
        XCTAssertEqual(KindleTurnContract.progress(
            beforeLocation: 101, afterLocation: 102, beforeRenderer: nil, afterRenderer: nil
        ), .forward, "Existing callers retain forward-turn behavior")
    }

    func testBothDirectionsRequireChangedPixelsAndStableFallbackEvidence() {
        for direction in [KindlePageTurnDirection.next, .previous] {
            let noProgress = KindleTurnContract.progress(
                beforeLocation: nil, afterLocation: nil, beforeRenderer: nil, afterRenderer: nil,
                direction: direction
            )
            XCTAssertFalse(confirms(noProgress, before: "old", after: "new", samples: 1))
            XCTAssertTrue(confirms(noProgress, before: "old", after: "new", samples: 2))
            XCTAssertFalse(confirms(.forward, before: "same", after: "same", samples: 3))
            XCTAssertFalse(confirms(.forward, before: nil, after: "new", samples: 3))
            XCTAssertFalse(KindleTurnContract.confirms(
                progress: noProgress, beforeFingerprint: "old", afterFingerprint: "new",
                semanticActionDispatched: false, stableVisualSamples: 3
            ))
        }
    }

    private func confirms(_ progress: KindleForwardProgress, before: String?, after: String?, samples: Int) -> Bool {
        KindleTurnContract.confirms(
            progress: progress, beforeFingerprint: before, afterFingerprint: after,
            semanticActionDispatched: true, stableVisualSamples: samples
        )
    }

    @MainActor
    func testFreshActionThatChangesPageThenThrowsNeverDispatchesAgain() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        try await fixture.installActions(throwAfterMutation: true)
        let before = try await fixture.state()
        let result = try await fixture.turn("next")
        let after = try await fixture.waitForChangedPixels(from: before)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        XCTAssertEqual(result["dispatchUncertain"] as? Bool, true)
        XCTAssertEqual(result["strategy"] as? String, "react-paired-action")
        XCTAssertEqual(result["reason"] as? String, "semantic-action-threw")
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["right"] as? Int, 1)
        XCTAssertEqual(counts["left"] as? Int, 0)
        XCTAssertEqual(counts["keyboard"] as? Int, 0)
        XCTAssertEqual(KindleTurnContract.progressNumber(after["progress"] as? String), 102)
    }

    @MainActor
    func testCachedActionThatThrowsIsStillOneDispatch() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        try await fixture.installActions(throwAfterMutation: true)
        let primed = try await fixture.webView.evaluateJavaScript("window.__crKindlePrimeTurnCapability()") as? Bool
        XCTAssertEqual(primed, true)
        _ = try await fixture.webView.evaluateJavaScript("document.getElementById('kr-chevron-right').remove()")
        let result = try await fixture.turn("previous")
        XCTAssertEqual(result["strategy"] as? String, "react-cached-action")
        XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        XCTAssertEqual(result["dispatchUncertain"] as? Bool, true)
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["left"] as? Int, 1)
        XCTAssertEqual(counts["right"] as? Int, 0)
        XCTAssertEqual(counts["keyboard"] as? Int, 0)
    }

    @MainActor
    func testThrowBeforeVisibleMutationDoesNotAuthorizeAnotherAction() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        try await fixture.installActions(throwBeforeMutation: true)
        let result = try await fixture.turn("next")
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["right"] as? Int, 1)
        XCTAssertEqual(counts["keyboard"] as? Int, 0)
        XCTAssertEqual(counts["location"] as? Int, 101)
    }

    @MainActor
    func testMissingPairedCapabilityUsesOneKeyboardAction() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        let result = try await fixture.turn("previous")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["strategy"] as? String, "keyboard-fallback")
        XCTAssertEqual(result["semanticAction"] as? String, "ArrowLeft")
        XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["keyboard"] as? Int, 1)
        XCTAssertEqual(counts["keyups"] as? Int, 1)
        XCTAssertEqual(counts["location"] as? Int, 100)
    }

    @MainActor
    func testKeyboardExceptionAfterKeyDownPreservesDispatchedEvidence() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        _ = try await fixture.webView.evaluateJavaScript("""
        (function() {
          var original = document.body.dispatchEvent;
          document.body.dispatchEvent = function(event) {
            var value = original.call(this, event);
            if (event.type === 'keydown') throw new Error('after-keydown');
            return value;
          };
        })()
        """)
        let result = try await fixture.turn("next")
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        XCTAssertEqual(result["dispatchUncertain"] as? Bool, true)
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["keyboard"] as? Int, 1)
        XCTAssertEqual(counts["location"] as? Int, 102)
    }

    @MainActor
    func testPreviousConfirmsActualChangedImageAndDecreasedLocation() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        try await fixture.installActions()
        let before = try await fixture.state()
        let result = try await fixture.turn("previous")
        let after = try await fixture.waitForChangedPixels(from: before)
        let progress = KindleTurnContract.progress(
            beforeLocation: KindleTurnContract.progressNumber(before["progress"] as? String),
            afterLocation: KindleTurnContract.progressNumber(after["progress"] as? String),
            beforeRenderer: nil, afterRenderer: nil, direction: .previous
        )
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(progress, .forward)
        XCTAssertTrue(KindleTurnContract.confirms(
            progress: progress,
            beforeFingerprint: before["pixelFingerprint"] as? String,
            afterFingerprint: after["pixelFingerprint"] as? String,
            semanticActionDispatched: true, stableVisualSamples: 1
        ))
    }

    @MainActor
    func testCompatibilityAliasDoesNotRepeatThrowingSemanticAction() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        try await fixture.installActions(throwAfterMutation: true)
        let result = try await fixture.json("window.__crKindleForceAdjacentPage('right')")
        XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["right"] as? Int, 1)
        XCTAssertEqual(counts["keyboard"] as? Int, 0)
    }

    @MainActor
    func testObjectFitFillReportsActualStretchedPageContentRect() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        let geometry = try await fixture.imageGeometry(fit: "fill", box: CGRect(x: 40, y: 80, width: 300, height: 300))
        assertContentRect(geometry, equals: CGRect(x: 40, y: 80, width: 300, height: 300))
        let candidate = try XCTUnwrap(geometry["candidate"] as? [String: Any])
        let scales = try XCTUnwrap(candidate["displayScale"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(scales["x"]), 300.0 / 320.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(scales["y"]), 300.0 / 640.0, accuracy: 0.001,
                       "OCR Y coordinates must follow the rendered stretch, not a reconstructed natural aspect")
        await attachSnapshot(fixture, name: "object-fit-fill-300x300-source-320x640")
    }

    @MainActor
    func testObjectFitContainKeepsLetterboxingInContentCoordinates() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        let geometry = try await fixture.imageGeometry(fit: "contain", box: CGRect(x: 40, y: 80, width: 300, height: 300))
        assertContentRect(geometry, equals: CGRect(x: 115, y: 80, width: 150, height: 300))
    }

    @MainActor
    func testObjectFitCoverRetainsOverflowForSourceCoordinateMapping() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        let geometry = try await fixture.imageGeometry(fit: "cover", box: CGRect(x: 40, y: 80, width: 300, height: 300))
        assertContentRect(geometry, equals: CGRect(x: 40, y: -70, width: 300, height: 600))
    }

    @MainActor
    func testObjectFitNoneRetainsNaturalDimensionsAndObjectPosition() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        let geometry = try await fixture.imageGeometry(fit: "none", box: CGRect(x: 40, y: 80, width: 300, height: 300))
        assertContentRect(geometry, equals: CGRect(x: 30, y: -90, width: 320, height: 640))
    }

    @MainActor
    func testObjectFitScaleDownDoesNotUpscaleSmallPage() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        let geometry = try await fixture.imageGeometry(fit: "scale-down", box: CGRect(x: 10, y: 20, width: 360, height: 720))
        assertContentRect(geometry, equals: CGRect(x: 30, y: 60, width: 320, height: 640))
    }

    @MainActor
    func testPresentationEvidenceMapsBothDecodedPagesWithoutUsingTransformedFrame() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        _ = try await fixture.imageGeometry(fit: "fill", box: CGRect(x: 10, y: 60, width: 150, height: 650))
        _ = try await fixture.webView.evaluateJavaScript("""
        (function(){
          var second=document.getElementById('page').cloneNode();
          second.id='page2';second.style.position='absolute';second.style.left='220px';document.body.appendChild(second);
        })()
        """)
        try await fixture.waitForImages()
        let geometry = try await fixture.json("window.__crKindleGeometry()")
        attachGeometryEvidence(geometry, name: "decoded-spread-geometry")
        let secondRect = try await fixture.json("JSON.stringify((function(){var image=document.getElementById('page2');var r=image.getBoundingClientRect();return {position:getComputedStyle(image).position,left:r.left,top:r.top,width:r.width,height:r.height};})())")
        XCTAssertEqual(secondRect["position"] as? String, "absolute")
        XCTAssertEqual(secondRect["left"] as? Double, 220)
        XCTAssertEqual(secondRect["top"] as? Double, 60)
        let canonical = CGRect(x: -40, y: -60, width: 390, height: 800)
        let measurement = try XCTUnwrap(KindleViewportPresentationPolicy.measurement(from: geometry, canonicalFrame: canonical))
        XCTAssertEqual(measurement.pages.count, 2)
        XCTAssertEqual(measurement.union.minX, -30, accuracy: 0.5)
        XCTAssertEqual(measurement.union.maxX, 330, accuracy: 0.5)
        XCTAssertEqual(measurement.currentPage.minY, 0, accuracy: 0.5)
        XCTAssertTrue(measurement.isStable(with: measurement))
    }

    @MainActor
    func testPresentationEvidenceRejectsAncestorClipAndPartiallyVisibleSpread() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        _ = try await fixture.imageGeometry(fit: "fill", box: CGRect(x: 20, y: 60, width: 150, height: 650))
        _ = try await fixture.webView.evaluateJavaScript("""
        (function(){
          var second=document.getElementById('page').cloneNode();
          second.id='page2';second.style.position='absolute';second.style.left='320px';document.body.appendChild(second);
        })()
        """)
        try await fixture.waitForImages()
        let partial = try await fixture.json("window.__crKindleGeometry()")
        attachGeometryEvidence(partial, name: "partially-visible-spread-geometry")
        let extendsBeyondViewport = try await fixture.webView.evaluateJavaScript(
            "document.getElementById('page2').getBoundingClientRect().right > innerWidth"
        ) as? Bool
        XCTAssertEqual(extendsBeyondViewport, true, "The fixture must actually place its second page beyond the CSS viewport")
        XCTAssertTrue(partial["presentation"] is NSNull,
                      "Native fit cannot reveal pixels already clipped outside the CSS viewport")
        _ = try await fixture.webView.evaluateJavaScript("""
        (function(){
          document.getElementById('page2').remove();
          var wrapper=document.createElement('div');
          wrapper.style.cssText='position:absolute;left:0;top:0;width:390px;height:300px;overflow:hidden';
          document.body.appendChild(wrapper);wrapper.appendChild(document.getElementById('page'));
        })()
        """)
        let clipped = try await fixture.json("window.__crKindleGeometry()")
        attachGeometryEvidence(clipped, name: "ancestor-clipped-page-geometry")
        XCTAssertTrue(clipped["presentation"] is NSNull)
    }

    @MainActor
    func testHeldPrefetchRasterHasSameFingerprintAsItsVisiblePage() async throws {
        let fixture = try await TurnWebFixture.make()
        defer { fixture.close() }
        // Create held images through the actual bootstrap's Blob hook, then
        // return to the prior page. The next image is detached when prefetched.
        _ = try await fixture.webView.evaluateJavaScript("drawPage(101)")
        try await fixture.waitForImages()
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = try await fixture.webView.evaluateJavaScript("drawPage(102)")
        try await fixture.waitForImages()
        try await Task.sleep(nanoseconds: 150_000_000)
        let next = try await fixture.state()
        let nextFingerprint = try XCTUnwrap(next["pixelFingerprint"] as? String)
        XCTAssertFalse(nextFingerprint.isEmpty)
        _ = try await fixture.webView.evaluateJavaScript("drawPage(101)")
        try await fixture.waitForImages()
        try await Task.sleep(nanoseconds: 150_000_000)
        let current = try await fixture.state()
        let key = try XCTUnwrap(current["key"] as? String)
        var pages: [[String: Any]] = []
        for _ in 0..<10 {
            let candidates = try await fixture.json("window.__crKindleCandidateSnapshotsAfterKey('\(key)',12,1400,1)")
            pages = candidates["pages"] as? [[String: Any]] ?? []
            if !pages.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(pages.isEmpty, "Real held Blob candidates must be available")
        XCTAssertTrue(pages.contains { $0["pixelFingerprint"] as? String == nextFingerprint },
                      "Detached prefetch must pass the same pixel identity gate as visible OCR")
        _ = try await fixture.webView.evaluateJavaScript("""
        window.__pngEncodes = 0;
        const originalEncode = HTMLCanvasElement.prototype.toDataURL;
        HTMLCanvasElement.prototype.toDataURL = function(...args) {
          window.__pngEncodes++;
          return originalEncode.apply(this, args);
        };
        true;
        """)
        let metadata = try await fixture.json("window.__crKindleCandidateSnapshotsAfterKey('\(key)',12,1400,1,true)")
        let identities = try XCTUnwrap(metadata["pages"] as? [[String: Any]])
        XCTAssertEqual(identities.compactMap { $0["key"] as? String }, pages.compactMap { $0["key"] as? String })
        XCTAssertTrue(identities.allSatisfy { $0["image"] == nil })
        let beforeEncodes = try await fixture.webView.evaluateJavaScript("window.__pngEncodes") as? Int
        XCTAssertEqual(beforeEncodes, 0, "Cache identity checks must never encode full rasters")
        let identity = try XCTUnwrap(identities.first { $0["pixelFingerprint"] as? String == nextFingerprint })
        let nextKey = try XCTUnwrap(identity["key"] as? String)
        let raster = try await fixture.json("window.__crKindlePrefetchSnapshotForKey('\(nextKey)',1400,1)")
        XCTAssertEqual(raster["key"] as? String, nextKey)
        XCTAssertEqual(raster["pixelFingerprint"] as? String, nextFingerprint)
        XCTAssertTrue((raster["image"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        let afterEncodes = try await fixture.webView.evaluateJavaScript("window.__pngEncodes") as? Int
        XCTAssertEqual(afterEncodes, 1)
        let after = try await fixture.state()
        XCTAssertEqual(after["key"] as? String, current["key"] as? String)
        XCTAssertEqual(after["pixelFingerprint"] as? String, current["pixelFingerprint"] as? String,
                       "Speculative capture must preserve the current visible page")
    }

    @MainActor
    func testSyncDecisionsNeverAlsoEmitManualNavigationWithEitherBootstrap() async throws {
        for includeLightBootstrap in [false, true] {
            let fixture = try await TurnWebFixture.make()
            defer { fixture.close() }
            if includeLightBootstrap {
                _ = try await fixture.webView.evaluateJavaScript(KindleWebScripts.pageModeLockBootstrap)
            }
            for choice in ["No", "Yes"] {
                let result = try await fixture.webView.evaluateJavaScript("""
                (() => {
                  __crKindleProbe.pageModeLocked=true;
                  __crKindleProbe.navigationSeq=0;
                  __crKindleProbe.navigationAt=0;
                  const dialog=document.createElement('section');
                  dialog.setAttribute('role','dialog');
                  dialog.innerHTML='<h2>Most Recent Page Read</h2><p>You are on location 1792. Go to location 1787?</p><button id="syncChoice"><span>\(choice)</span></button>';
                  document.body.appendChild(dialog);
                  dialog.querySelector('button').onclick=()=>dialog.remove();
                  dialog.querySelector('span').click();
                  const syncSequence=__crKindleProbe.navigationSeq;
                  const toc=document.createElement('nav');
                  toc.innerHTML='<button><span>Chapter 20</span></button>';
                  document.body.appendChild(toc);
                  toc.querySelector('span').click();
                  const tocSequence=__crKindleProbe.navigationSeq;
                  toc.remove();
                  return {syncSequence,tocSequence,dialogRemoved:!dialog.isConnected};
                })()
                """) as? [String: Any]
                XCTAssertEqual(result?["dialogRemoved"] as? Bool, true)
                XCTAssertEqual(result?["syncSequence"] as? Int, 0,
                               "\(choice), light=\(includeLightBootstrap): one decision must not restart at page zero")
                XCTAssertEqual(result?["tocSequence"] as? Int, 1,
                               "Real chapter navigation must still be observed")
            }
        }
    }

    private func attachGeometryEvidence(_ geometry: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertContentRect(_ geometry: [String: Any], equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let candidate = geometry["candidate"] as? [String: Any],
              let rect = candidate["rect"] as? [String: Double] else {
            XCTFail("Production geometry did not return an image candidate", file: file, line: line)
            return
        }
        for (key, value) in ["left": expected.minX, "top": expected.minY, "width": expected.width, "height": expected.height] {
            XCTAssertEqual(rect[key] ?? .nan, Double(value), accuracy: 0.5, key, file: file, line: line)
        }
        if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: text)
            attachment.name = "production-image-geometry"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func attachSnapshot(_ fixture: TurnWebFixture, name: String) async {
        let snapshot: UIImage? = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            fixture.webView.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? NSError(domain: "KindleSnapshot", code: 1)) }
            }
        }
        if let snapshot {
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

/// Real WebKit fixture: the production bootstrap discovers paired handlers on
/// a DOM fiber, changes a decoded blob image, and reports visible pixel evidence.
@MainActor
private final class TurnWebFixture {
    let webView: WKWebView
    private let window: UIWindow

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.isHidden = false
        window.addSubview(webView)
    }

    static func make() async throws -> TurnWebFixture {
        let fixture = TurnWebFixture()
        fixture.webView.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0}#page{position:absolute;left:35px;top:60px;width:320px;height:640px}</style>
        </head><body><div id="progress">Location 101</div>
        <img id="page" class="kg-full-page-img"><button id="kr-chevron-right"><span id="leaf">Next page</span></button>
        <script>
        window.fixtureLocation=101; window.leftCount=0; window.rightCount=0;
        window.keyboardCount=0; window.keyupCount=0;
        window.drawPage=function(location) {
          window.fixtureLocation=location;
          document.getElementById('progress').textContent='Location '+location;
          var canvas=document.createElement('canvas'); canvas.width=320; canvas.height=640;
          var ctx=canvas.getContext('2d');
          ctx.fillStyle=location%2 ? '#ffffff' : '#333333'; ctx.fillRect(0,0,320,640);
          ctx.fillStyle='#990000'; ctx.fillRect(12+(location%4)*18,22,80,400);
          var bytes=atob(canvas.toDataURL('image/png').split(',')[1]);
          var data=new Uint8Array(bytes.length);
          for(var i=0;i<bytes.length;i++) data[i]=bytes.charCodeAt(i);
          document.getElementById('page').src=URL.createObjectURL(new Blob([data],{type:'image/png'}));
        };
        window.addEventListener('keydown',function(event) {
          if(event.key!=='ArrowLeft' && event.key!=='ArrowRight') return;
          window.keyboardCount++; drawPage(window.fixtureLocation+(event.key==='ArrowRight'?1:-1));
        });
        window.addEventListener('keyup',function(){window.keyupCount++;});
        drawPage(101);
        </script></body></html>
        """, baseURL: URL(string: "https://read.amazon.com"))
        do {
            var loaded = false
            for _ in 0..<80 {
                if (try? await fixture.webView.evaluateJavaScript(
                    "!!(document.getElementById('page') && document.getElementById('page').complete && document.getElementById('page').naturalWidth===320)"
                ) as? Bool) == true {
                    loaded = true
                    break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            guard loaded else { throw NSError(domain: "TurnWebFixture", code: 1) }
            _ = try await fixture.webView.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap)
            let state = try await fixture.state()
            XCTAssertFalse((state["pixelFingerprint"] as? String ?? "").isEmpty)
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    func close() {
        webView.stopLoading()
        webView.removeFromSuperview()
        window.isHidden = true
    }

    func installActions(throwAfterMutation: Bool = false, throwBeforeMutation: Bool = false) async throws {
        _ = try await webView.evaluateJavaScript("""
        (function() {
          window.__crKindleTurnCapability=null;
          function action(next) {
            if(next) window.rightCount++; else window.leftCount++;
            if(\(throwBeforeMutation)) throw new Error('before-mutation');
            drawPage(window.fixtureLocation+(next?1:-1));
            if(\(throwAfterMutation)) throw new Error('after-mutation');
          }
          document.getElementById('leaf').__reactFiber$fixture={memoizedProps:{
            leftAction:function(){action(false);}, rightAction:function(){action(true);},
            pageProgressionDirection:'ltr'
          },return:null,type:{name:'PaginationFixture'}};
        })()
        """)
    }

    func turn(_ direction: String) async throws -> [String: Any] {
        try await json("window.__crKindleSemanticPageTurn('\(direction)','ltr')")
    }

    func counts() async throws -> [String: Any] {
        try await json("JSON.stringify({left:leftCount,right:rightCount,keyboard:keyboardCount,keyups:keyupCount,location:fixtureLocation})")
    }

    func state() async throws -> [String: Any] {
        try await json("window.__crKindleState()")
    }

    func imageGeometry(fit: String, box: CGRect) async throws -> [String: Any] {
        _ = try await webView.evaluateJavaScript("""
        (function(){
          var s=document.getElementById('page').style;
          s.objectFit='\(fit)';s.objectPosition='50% 50%';
          s.left='\(box.minX)px';s.top='\(box.minY)px';
          s.width='\(box.width)px';s.height='\(box.height)px';
        })()
        """)
        return try await json("window.__crKindleGeometry()")
    }

    func waitForImages() async throws {
        for _ in 0..<40 {
            if (try await webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('img')).every(function(img){return img.complete && img.naturalWidth>0;})"
            ) as? Bool) == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(domain: "TurnWebFixture.imageDecode", code: 3)
    }

    func json(_ script: String) async throws -> [String: Any] {
        let raw = try await webView.evaluateJavaScript(script)
        let text = try XCTUnwrap(raw as? String)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func waitForChangedPixels(from before: [String: Any]) async throws -> [String: Any] {
        let oldFingerprint = try XCTUnwrap(before["pixelFingerprint"] as? String)
        for _ in 0..<80 {
            let after = try await state()
            if let fingerprint = after["pixelFingerprint"] as? String,
               !fingerprint.isEmpty, fingerprint != oldFingerprint {
                return after
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(domain: "TurnWebFixture.unchangedPixels", code: 2)
    }
}
