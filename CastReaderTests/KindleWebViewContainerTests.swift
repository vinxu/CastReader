import XCTest
import UIKit
import SwiftUI
import WebKit
@testable import CastReader

@MainActor
final class KindleWebViewContainerTests: XCTestCase {
    func testExplainInkKeepsNativePathWeightAndOpacityAcrossLiveRedraw() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        try await installMarkPage(in: fixture.webView)
        let web = fixture.webView
        let canvas = try await markJSON(web, payload: ["paragraphIndex": 0, "canvasOnly": true])
        XCTAssertEqual(canvas["ok"] as? Bool, true)
        let width = try XCTUnwrap(canvas["width"] as? Double)
        let height = try XCTUnwrap(canvas["height"] as? Double)
        let size = CGSize(width: width, height: height)
        let rects = [CGRect(x: 30, y: 80, width: 185, height: 22),
                     CGRect(x: 30, y: 110, width: 135, height: 22)]
        let actions = ["circle", "underline", "highlight", "number", "wave", "strike", "star"]
        for weight in ["primary", "secondary", "tertiary"] {
            for action in actions {
                let ink = HandwrittenMark.stroke(action: action, rects: rects,
                                                 seed: 0xFEDCBA9876543210, n: 3, weight: weight)
                let data = ink.svgPayload(canvasSize: size)
                var payload: [String: Any] = ["paragraphIndex": 0, "id": "fixture-mark", "animate": true,
                    "canvasKey": canvas["key"]!, "canvasWidth": width, "canvasHeight": height, "ink": data]
                _ = try await web.evaluateJavaScript("window.__crKindleLiveClearMarks()")
                let drawn = try await markJSON(web, payload: payload)
                XCTAssertEqual(drawn["ok"] as? Bool, true, "\(action)/\(weight)")
                let animated = try await markPathAttributes(web)
                XCTAssertEqual(animated["d"] as? String, data["path"] as? String)
                XCTAssertEqual(animated["width"] as? Double, Double(ink.lineWidth))
                XCTAssertEqual(animated["opacity"] as? Double, ink.opacity)
                XCTAssertEqual(animated["vectorEffect"] as? String, "",
                               "The page viewBox must carry the same point-sized ink through presentation scaling")
                _ = try await web.evaluateJavaScript("window.__crKindleLiveClearMarks()")
                payload["animate"] = false
                let redrawn = try await markJSON(web, payload: payload)
                XCTAssertEqual(redrawn["ok"] as? Bool, true)
                let settled = try await markPathAttributes(web)
                XCTAssertEqual(NSDictionary(dictionary: animated), NSDictionary(dictionary: settled),
                               "Settling/redrawing \(action)/\(weight) must not change the native stroke")
            }
        }
    }

    func testExplainInkRejectsPageOrGeometryChangedBeforeDraw() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        try await installMarkPage(in: fixture.webView)
        let canvas = try await markJSON(fixture.webView, payload: ["paragraphIndex": 0, "canvasOnly": true])
        let width = try XCTUnwrap(canvas["width"] as? Double)
        let height = try XCTUnwrap(canvas["height"] as? Double)
        let ink = HandwrittenMark.stroke(action: "circle", rects: [CGRect(x: 30, y: 80, width: 120, height: 22)], seed: 42)
        var payload: [String: Any] = ["paragraphIndex": 0, "id": "stale-mark", "animate": false,
            "canvasKey": "previous-page", "canvasWidth": width, "canvasHeight": height,
            "ink": ink.svgPayload(canvasSize: CGSize(width: width, height: height))]
        let wrongPage = try await markJSON(fixture.webView, payload: payload)
        XCTAssertEqual(wrongPage["reason"] as? String, "mark-canvas-changed")
        payload["canvasKey"] = canvas["key"]
        payload["canvasWidth"] = width + 10
        let wrongFit = try await markJSON(fixture.webView, payload: payload)
        XCTAssertEqual(wrongFit["reason"] as? String, "mark-canvas-changed")
        let count = try await fixture.webView.evaluateJavaScript("document.querySelectorAll('[data-cr-mark-id]').length")
        XCTAssertEqual(count as? Int, 0)
    }

    func testExplainLiveAndNativeHoldHaveSameVisibleInk() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        fixture.container.presentationFit = KindleViewportPresentationFit(scale: 0.8, translationX: 15, translationY: 20)
        fixture.container.layoutIfNeeded()
        try await installMarkPage(in: fixture.webView)
        let canvas = try await markJSON(fixture.webView, payload: ["paragraphIndex": 0, "canvasOnly": true])
        let width = try XCTUnwrap(canvas["width"] as? Double)
        let height = try XCTUnwrap(canvas["height"] as? Double)
        let size = CGSize(width: width * 0.8, height: height * 0.8)
        let actions = ["circle", "underline", "highlight"]
        let rects = actions.indices.map { [CGRect(x: 30, y: 70 + $0 * 75, width: 170, height: 22)] }
        for i in actions.indices {
            let ink = HandwrittenMark.stroke(action: actions[i], rects: rects[i], seed: UInt64(i + 17))
            let result = try await markJSON(fixture.webView, payload: ["paragraphIndex": 0, "id": "visual-\(i)",
                "animate": false, "canvasKey": canvas["key"]!, "canvasWidth": width, "canvasHeight": height,
                "ink": ink.svgPayload(canvasSize: size)])
            XCTAssertEqual(result["ok"] as? Bool, true)
        }
        let rawBounds = try await fixture.webView.evaluateJavaScript("""
        (function(){var r=window.__crKindleProbe.liveOverlay.getBoundingClientRect();
          return {x:r.left,y:r.top,width:r.width,height:r.height};})()
        """)
        let bounds = try XCTUnwrap(rawBounds as? [String: Double])
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: bounds["x"]!, y: bounds["y"]!, width: width, height: height)
        let webImage: UIImage = try await withCheckedThrowingContinuation { continuation in
            fixture.webView.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? NSError(domain: "MarkSnapshot", code: 1)) }
            }
        }
        let root = ZStack(alignment: .topLeading) {
            Color.white
            ForEach(actions.indices, id: \.self) { i in
                MarkInkView(rects: rects[i], action: actions[i], seed: UInt64(i + 17), n: nil,
                            animateOnAppear: false)
            }
        }.frame(width: size.width, height: size.height).ignoresSafeArea()
        let host = UIHostingController(rootView: root)
        host.view.frame = CGRect(origin: .zero, size: size)
        fixture.window.addSubview(host.view)
        defer { host.view.removeFromSuperview() }
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let live = renderer.image { _ in webImage.draw(in: CGRect(origin: .zero, size: size)) }
        let native = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        for (name, image) in [("explain-live-svg", live), ("explain-native-hold", native)] {
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Compare orange coverage per tool; black page text is deliberately
        // ignored. A 6.5 -> 2.4 stroke switch would exceed this tolerance widely.
        for i in actions.indices {
            let band = CGRect(x: 0, y: 50 + i * 75, width: Int(size.width), height: 65)
            let liveMass = orangeCoverage(live, band: band)
            let nativeMass = orangeCoverage(native, band: band)
            XCTAssertGreaterThan(nativeMass, 20, "\(actions[i]) must really render on the native hold")
            XCTAssertEqual(liveMass / max(nativeMass, 1), 1, accuracy: 0.08,
                           "\(actions[i]) must retain visible ink thickness/opacity when switching renderers")
        }
    }

    private func orangeCoverage(_ image: UIImage, band: CGRect) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let mass: Double = pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let p = bytes.bindMemory(to: UInt8.self)
            var total = 0.0
            for y in max(0, Int(band.minY))..<min(height, Int(band.maxY)) {
                for x in max(0, Int(band.minX))..<min(width, Int(band.maxX)) {
                    let offset = (y * width + x) * 4
                    total += Double(max(0, Int(p[offset]) - Int(p[offset + 1]))) / 255
                }
            }
            return total
        }
        return mass
    }

    private func installMarkPage(in web: WKWebView) async throws {
        // Production Kindle pages are blob images; use the same discovery path.
        _ = try await web.evaluateJavaScript("""
        (function(){var page=document.getElementById('page'), raw=atob(page.src.split(',')[1]);
          var bytes=new Uint8Array(raw.length);for(var i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);
          page.src=URL.createObjectURL(new Blob([bytes],{type:'image/png'}));return true;})()
        """)
        for _ in 0..<50 {
            if (try await web.evaluateJavaScript("document.getElementById('page').complete") as? Bool) == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await web.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap + ";true")
        let result = try await web.evaluateJavaScript("""
        window.__crKindleLiveSetPage({key:'',paragraphs:[{id:0,text:'sample text',words:[
          {text:'sample',bboxNorm:{x:0.1,y:0.7,width:0.2,height:0.05}},
          {text:'text',bboxNorm:{x:0.3,y:0.7,width:0.1,height:0.05}}
        ]}]})
        """)
        let json = try XCTUnwrap(result as? String)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, true, json)
    }

    private func markJSON(_ web: WKWebView, payload: [String: Any]) async throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let result = try await web.evaluateJavaScript("window.__crKindleLiveShowMark(\(json))")
        let response = try XCTUnwrap(result as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func markPathAttributes(_ web: WKWebView) async throws -> [String: Any] {
        let result = try await web.evaluateJavaScript("""
        (function(){var p=document.querySelector('[data-cr-mark-id] path');return {
          d:p.getAttribute('d'), width:Number(p.getAttribute('stroke-width')),
          opacity:Number(p.getAttribute('opacity')), color:p.getAttribute('stroke'),
          vectorEffect:p.getAttribute('vector-effect')||'', viewBox:p.parentElement.getAttribute('viewBox')
        };})()
        """)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testFailedCoverKeepsLiveHighlightAndDefersRepeatedTicksUntilAudioBoundary() {
        var preparation = KindleReadVisualPreparation()
        XCTAssertTrue(preparation.begin(atAudioBoundary: false))
        XCTAssertFalse(preparation.suppressesLiveHighlight, "The visible old page owns highlights while a cover is being captured")
        // A boundary arriving during capture must be retried after it finishes.
        XCTAssertFalse(preparation.begin(atAudioBoundary: true))
        preparation.finishCapture(succeeded: false)
        for _ in 0..<408 {
            XCTAssertFalse(preparation.begin(atAudioBoundary: false))
            XCTAssertFalse(preparation.suppressesLiveHighlight)
        }
        XCTAssertTrue(preparation.begin(atAudioBoundary: true), "Deferring early work must not deadlock the concrete queue gate")
        XCTAssertTrue(preparation.suppressesLiveHighlight)
        preparation = KindleReadVisualPreparation()
        XCTAssertTrue(preparation.begin(atAudioBoundary: false), "The next page gets its own capture attempt")
        preparation.finishCapture(succeeded: true)
        XCTAssertTrue(preparation.suppressesLiveHighlight, "Only a successful cover may own the old tail before the audio boundary")
    }

    func testRejectedMaskedSnapshotRestoresSameLiveHighlightNode() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        try await installLiveHighlight(in: fixture.webView)
        let lease = try XCTUnwrap(KindleVisualHoldViewportLease(
            webView: fixture.webView, surfaceSize: fixture.container.bounds.size
        ))
        var ownershipChecks = 0
        let image = await lease.snapshotExcludingLiveHighlight {
            ownershipChecks += 1
            // Reject after the asynchronous mask installation, as a resize or
            // page change can do before WebKit dispatches the snapshot.
            return ownershipChecks == 1
        }
        XCTAssertNil(image)
        XCTAssertGreaterThan(ownershipChecks, 1)
        try await assertLiveHighlightRestored(in: fixture.webView)
    }

    func testCancelledMaskedSnapshotRestoresSameLiveHighlightNode() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        try await installLiveHighlight(in: fixture.webView)
        let lease = try XCTUnwrap(KindleVisualHoldViewportLease(
            webView: fixture.webView, surfaceSize: fixture.container.bounds.size
        ))
        var capture: Task<UIImage?, Never>?
        var ownershipChecks = 0
        capture = Task { @MainActor in
            await lease.snapshotExcludingLiveHighlight {
                ownershipChecks += 1
                if ownershipChecks == 2 { capture?.cancel() }
                return true
            }
        }
        let image = await capture?.value
        XCTAssertNil(image)
        XCTAssertGreaterThan(ownershipChecks, 1)
        try await assertLiveHighlightRestored(in: fixture.webView)
    }

    func testSuccessfulMaskedSnapshotRestoresLiveHighlightAndRemovesMask() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        try await installLiveHighlight(in: fixture.webView)
        let lease = try XCTUnwrap(KindleVisualHoldViewportLease(
            webView: fixture.webView, surfaceSize: fixture.container.bounds.size
        ))
        let image = await lease.snapshotExcludingLiveHighlight { true }
        XCTAssertNotNil(image)
        try await assertLiveHighlightRestored(in: fixture.webView)
    }

    private func installLiveHighlight(in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript("""
        (function(){
          var word = document.createElement('div');
          word.id = 'castreader-kindle-live-word';
          word.style.cssText = 'position:absolute;left:70px;top:100px;width:90px;height:20px;background:orange';
          document.body.appendChild(word);
          window.originalHighlightNode = word;
        })()
        """)
    }

    private func assertLiveHighlightRestored(in webView: WKWebView) async throws {
        let result = try await webView.evaluateJavaScript("""
        (function(){
          var word = document.getElementById('castreader-kindle-live-word');
          return !!word && word === window.originalHighlightNode &&
            getComputedStyle(word).visibility === 'visible' &&
            document.querySelectorAll('style[id^="cr-kindle-snapshot-mask-"]').length === 0;
        })()
        """)
        XCTAssertEqual(result as? Bool, true, "A failed/cancelled cover must leave the existing live word or sentence visible")
    }

    func testTransientZeroSurfaceRetainsNativeFrameAndCSSViewport() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let nativeFrame = fixture.webView.frame
        let before = try await fixture.metrics()

        fixture.container.bounds.size = .zero
        fixture.container.setNeedsLayout()
        fixture.container.layoutIfNeeded()
        XCTAssertEqual(fixture.webView.frame, nativeFrame, "A transient zero surface must not collapse the retained reader")
        try await Task.sleep(nanoseconds: 120_000_000)
        let during = try await fixture.metrics()
        assertSameViewport(before, during)

        fixture.container.bounds.size = ContainerFixture.surfaceSize
        fixture.container.setNeedsLayout()
        fixture.container.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        let after = try await fixture.metrics()
        XCTAssertEqual(fixture.webView.frame, nativeFrame)
        assertSameViewport(before, after)
        XCTAssertEqual(after["resizes"] as? Int, before["resizes"] as? Int)
    }

    func testOldContainerCannotResizeWebViewAfterNewContainerTakesOwnership() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let replacement = KindleWebViewContainer(webView: fixture.webView, crop: .identity)
        replacement.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        fixture.window.addSubview(replacement)
        replacement.setNeedsLayout()
        replacement.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        let retainedFrame = fixture.webView.frame
        let before = try await fixture.metrics()
        XCTAssertTrue(fixture.webView.superview === replacement)

        fixture.container.bounds.size = CGSize(width: 700, height: 450)
        fixture.container.setNeedsLayout()
        fixture.container.layoutIfNeeded()
        XCTAssertEqual(fixture.webView.frame, retainedFrame, "A released host's delayed layout must not resize the new host's reader")
        try await Task.sleep(nanoseconds: 120_000_000)
        let after = try await fixture.metrics()
        assertSameViewport(before, after)
        XCTAssertTrue(fixture.webView.superview === replacement)
        XCTAssertNotNil(fixture.webView.window)
    }

    func testRealSurfaceResizeStillUpdatesNativeFrameAndCSSViewport() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let before = try await fixture.metrics()
        fixture.container.bounds.size = CGSize(width: 430, height: 700)
        fixture.container.setNeedsLayout()
        fixture.container.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        let after = try await fixture.metrics()
        XCTAssertEqual(fixture.webView.frame.width, 430 * 1.25, accuracy: 0.01)
        XCTAssertEqual(fixture.webView.frame.height, 700 * ContainerFixture.crop.heightScale, accuracy: 0.01)
        XCTAssertGreaterThan(try number(after, "width"), try number(before, "width"))
        XCTAssertGreaterThan(try number(after, "height"), try number(before, "height"))
    }

    func testExpectedPageMarginsKeepSmallAndLargeTextInsideVisibleSurface() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        for fontSize in [14, 46] {
            try await fixture.drawPage(fontSize: fontSize, margin: "expected")
            let metrics = try await fixture.metrics()
            let pageRect = try fixture.visiblePageRect(metrics)
            XCTAssertGreaterThanOrEqual(pageRect.minX, -1)
            XCTAssertGreaterThanOrEqual(pageRect.minY, -1)
            XCTAssertLessThanOrEqual(pageRect.maxX, fixture.container.bounds.width + 1)
            XCTAssertLessThanOrEqual(pageRect.maxY, fixture.container.bounds.height + 1)
            attachGeometry(metrics, name: "expected-margins-font-\(fontSize)")
        }
    }

    /// Characterization: the fixed crop assumes Amazon's 10% / 60 / 90 margins.
    /// A page laid out with 20px margins has real edge text outside that window.
    /// This is controlled geometry evidence, not a claim about a live Amazon book.
    func testDifferentNativeMarginsExposeFixedCropClippingAtBothFontSizes() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        for fontSize in [14, 46] {
            try await fixture.drawPage(fontSize: fontSize, margin: "narrow")
            let metrics = try await fixture.metrics()
            let pageRect = try fixture.visiblePageRect(metrics)
            let cssWidth = try number(metrics, "width")
            let nativePerCSS = fixture.webView.bounds.width / cssWidth
            let leftGlyphX = pageRect.minX + 4 * nativePerCSS
            let rightGlyphX = pageRect.maxX - 4 * nativePerCSS
            XCTAssertLessThan(leftGlyphX, 0, "The fixture's left edge text is clipped by the native host")
            XCTAssertGreaterThan(rightGlyphX, fixture.container.bounds.width,
                                 "The fixture's right edge text is clipped by the native host")
            attachGeometry(metrics, name: "fixed-crop-counterexample-font-\(fontSize)")
        }
    }

    func testPresentationFitContainsClippedPageWithoutChangingCSSViewport() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        try await fixture.drawPage(fontSize: 46, margin: "narrow")
        let before = try await fixture.metrics()
        let nativeBounds = fixture.webView.bounds
        let originalPage = try fixture.visiblePageRect(before)
        let fit = try XCTUnwrap(KindleViewportPresentationPolicy.contain(
            contentRect: originalPage, surfaceSize: fixture.container.bounds.size
        ))
        fixture.container.presentationFit = fit
        fixture.container.setNeedsLayout()
        fixture.container.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        let after = try await fixture.metrics()
        let fittedPage = try fixture.visiblePageRect(after)
        XCTAssertTrue(fixture.container.bounds.insetBy(dx: -1, dy: -1).contains(fittedPage))
        XCTAssertEqual(fixture.webView.bounds, nativeBounds)
        assertSameViewport(before, after)
        XCTAssertEqual(before["resizes"] as? Int, after["resizes"] as? Int)
        XCTAssertEqual(KindleViewportPresentationPolicy.contain(
            contentRect: originalPage, surfaceSize: fixture.container.bounds.size, current: fit
        ), fit, "Repeating the same canonical geometry must not create a fit feedback loop")
        attachGeometry(after, name: "contained-page-stable-CSS-viewport")
    }

    func testPresentationFitContainsBothPagesOfVisibleSpread() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        _ = try await fixture.webView.evaluateJavaScript("""
        (function(){
          var first=document.getElementById('page');
          first.style.left='20px';first.style.top='60px';
          first.style.width='210px';first.style.height='650px';
          var second=first.cloneNode();second.id='page2';second.style.left='257px';
          document.body.appendChild(second);
        })()
        """)
        let before = try await fixture.metrics()
        let pages = try XCTUnwrap(before["pages"] as? [[String: Double]])
        XCTAssertEqual(pages.count, 2)
        let canonicalRects = try pages.map { page -> CGRect in
            var metrics = before
            metrics["page"] = page
            return try fixture.visiblePageRect(metrics)
        }
        let union = canonicalRects.reduce(CGRect.null) { $0.union($1) }
        let fit = try XCTUnwrap(KindleViewportPresentationPolicy.contain(
            contentRect: union, surfaceSize: fixture.container.bounds.size
        ))
        fixture.container.presentationFit = fit
        fixture.container.setNeedsLayout()
        fixture.container.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        let after = try await fixture.metrics()
        for page in try XCTUnwrap(after["pages"] as? [[String: Double]]) {
            var metrics = after
            metrics["page"] = page
            XCTAssertTrue(fixture.container.bounds.insetBy(dx: -1, dy: -1).contains(try fixture.visiblePageRect(metrics)))
        }
        assertSameViewport(before, after)
        XCTAssertEqual(before["resizes"] as? Int, after["resizes"] as? Int)
    }

    func testPresentationFitRetainsContainedNextPageAndRejectsInvalidGeometry() {
        let surface = CGSize(width: 390, height: 650)
        let fit = KindleViewportPresentationFit(scale: 0.8, translationX: 30, translationY: 30)
        XCTAssertEqual(KindleViewportPresentationPolicy.contain(
            contentRect: CGRect(x: 0, y: 0, width: 390, height: 650), surfaceSize: surface, current: fit
        ), fit, "A narrower next page must not cause a zoom-up transition")
        XCTAssertEqual(KindleViewportPresentationPolicy.contain(
            contentRect: CGRect(x: -0.6, y: 0, width: 391.2, height: 650), surfaceSize: surface
        ), .identity, "Subpixel layout jitter is not a new fit decision")
        XCTAssertNil(KindleViewportPresentationPolicy.contain(contentRect: .zero, surfaceSize: surface))
        XCTAssertNil(KindleViewportPresentationPolicy.contain(
            contentRect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 650), surfaceSize: surface
        ))
    }

    func testLandscapeDockKeepsActualWebViewAndLastPageLineAboveControls() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let state = DockFixtureState()
        let controls = UIView()
        controls.backgroundColor = .systemOrange
        fixture.container.crop = .identity
        let size = CGSize(width: 874, height: 320)
        let host = UIHostingController(rootView: DockLayoutFixture(
            container: fixture.container, controls: controls, state: state, size: size
        ))
        host.view.frame = CGRect(origin: .zero, size: size)
        fixture.window.addSubview(host.view)
        defer { host.view.removeFromSuperview() }
        try await settleDock(host: host.view, container: fixture.container, size: size)
        _ = try await fixture.webView.evaluateJavaScript("""
        (function(){
          var page=document.getElementById('page');
          Object.assign(page.style,{left:'0px',top:'0px',width:'100vw',height:'100vh'});
          var line=document.createElement('div');line.id='last-line';
          line.textContent='LAST LINE MUST REMAIN ABOVE PLAYBACK CONTROLS';
          Object.assign(line.style,{position:'fixed',left:'8px',right:'8px',bottom:'0px',height:'20px',background:'yellow'});
          document.body.appendChild(line);
          return true;
        })()
        """)
        let readerFrame = fixture.container.convert(fixture.container.bounds, to: host.view)
        let controlFrame = controls.convert(controls.bounds, to: host.view)
        XCTAssertFalse(readerFrame.intersects(controlFrame), "The landscape capsule must reserve space instead of covering the two-column page")
        XCTAssertLessThanOrEqual(readerFrame.maxY, controlFrame.minY)
        XCTAssertEqual(controlFrame.height, 56, accuracy: 0.5)
        let raw = try await fixture.webView.evaluateJavaScript("JSON.stringify((function(){var r=document.getElementById('last-line').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};})())")
        let data = try XCTUnwrap((raw as? String)?.data(using: .utf8))
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        let lineRect = fixture.webView.convert(CGRect(x: line["x"]!, y: line["y"]!, width: line["width"]!, height: line["height"]!), to: host.view)
        XCTAssertTrue(readerFrame.insetBy(dx: -0.5, dy: -0.5).contains(lineRect))
        XCTAssertFalse(lineRect.intersects(controlFrame), "A real DOM line at the very bottom must remain outside the controls")
    }

    func testLandscapeDockKeepsCSSViewportWhenPlaybackControlsAreTemporarilyHidden() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let state = DockFixtureState()
        let controls = UIView()
        fixture.container.crop = .identity
        let size = CGSize(width: 780, height: 300)
        let host = UIHostingController(rootView: DockLayoutFixture(
            container: fixture.container, controls: controls, state: state, size: size
        ))
        host.view.frame = CGRect(origin: .zero, size: size)
        fixture.window.addSubview(host.view)
        defer { host.view.removeFromSuperview() }
        try await settleDock(host: host.view, container: fixture.container, size: size)
        let nativeBounds = fixture.webView.bounds
        let before = try await fixture.metrics()
        state.controlsHidden = true
        try await Task.sleep(nanoseconds: 120_000_000)
        host.view.layoutIfNeeded()
        let hidden = try await fixture.metrics()
        XCTAssertEqual(fixture.webView.bounds, nativeBounds)
        assertSameViewport(before, hidden)
        state.controlsHidden = false
        try await Task.sleep(nanoseconds: 120_000_000)
        host.view.layoutIfNeeded()
        let restored = try await fixture.metrics()
        XCTAssertEqual(fixture.webView.bounds, nativeBounds)
        assertSameViewport(before, restored)
        XCTAssertEqual(before["resizes"] as? Int, restored["resizes"] as? Int)
    }

    private func settleDock(host: UIView, container: KindleWebViewContainer, size: CGSize) async throws {
        for _ in 0..<40 {
            host.setNeedsLayout()
            host.layoutIfNeeded()
            container.layoutIfNeeded()
            if abs(container.bounds.width - size.width) <= 1,
               abs(container.bounds.height - (size.height - ReaderPlaybackBarLayoutContract.landscapeControlHeight)) <= 1 {
                try await Task.sleep(nanoseconds: 120_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("The actual SwiftUI dock did not reserve its fixed landscape control height")
    }

    func testVisualHoldSnapshotAcceptsUnchangedCanonicalHost() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let lease = try XCTUnwrap(KindleVisualHoldViewportLease(
            webView: fixture.webView, surfaceSize: fixture.container.bounds.size
        ))
        let image = await lease.snapshot { true }
        XCTAssertNotNil(image)
        XCTAssertTrue(lease.isCurrent)
        XCTAssertEqual(lease.fit.applying(to: lease.canonical), fixture.webView.frame)
    }

    func testVisualHoldSnapshotRejectsFitChangedWhileSnapshotIsInFlight() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let lease = try XCTUnwrap(KindleVisualHoldViewportLease(
            webView: fixture.webView, surfaceSize: fixture.container.bounds.size
        ))
        let cssBefore = try await fixture.metrics()
        var firstOwnerCheck = true
        var changed = false
        let image = await lease.snapshot {
            if firstOwnerCheck {
                firstOwnerCheck = false
                // Runs after snapshot dispatch yields the main actor, before
                // WebKit completes it. The page/CSS frame stays unchanged.
                DispatchQueue.main.async {
                    fixture.container.presentationFit = KindleViewportPresentationFit(
                        scale: 0.8, translationX: 24, translationY: 35
                    )
                    fixture.container.layoutIfNeeded()
                    changed = true
                }
            }
            return true
        }
        XCTAssertTrue(changed, "The fixture must interleave a real native transform with the snapshot")
        XCTAssertNil(image, "A snapshot using an expired fit must not cover the live reader")
        XCTAssertFalse(lease.isCurrent)
        let cssAfter = try await fixture.metrics()
        assertSameViewport(cssBefore, cssAfter)
        XCTAssertEqual(fixture.webView.bounds, lease.webBounds)
    }

    func testVisualHoldSnapshotRejectsHostAndCropChangesBeforeDispatch() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        let lease = try XCTUnwrap(KindleVisualHoldViewportLease(
            webView: fixture.webView, surfaceSize: fixture.container.bounds.size
        ))
        fixture.container.crop = .identity
        var ownerChecks = 0
        let changedCropImage = await lease.snapshot { ownerChecks += 1; return true }
        XCTAssertNil(changedCropImage)
        XCTAssertEqual(ownerChecks, 0, "Reject stale native geometry before attempting a snapshot")
        fixture.container.crop = lease.crop
        XCTAssertTrue(lease.isCurrent)
        let replacement = KindleWebViewContainer(webView: fixture.webView, crop: lease.crop)
        replacement.frame = fixture.container.frame
        fixture.window.addSubview(replacement)
        replacement.layoutIfNeeded()
        let changedHostImage = await lease.snapshot { true }
        XCTAssertNil(changedHostImage)
        XCTAssertFalse(lease.isCurrent)
    }

    /// Mirrors MainTabView's retained-reader offset. The page counter advances
    /// only inside real RAF callbacks, so timers or cached images cannot make
    /// a stalled render loop appear healthy.
    func testOffscreenRetainedHostKeepsRAFAndViewportUntilItReturns() async throws {
        let fixture = try await ContainerFixture.make()
        defer { fixture.close() }
        _ = try await fixture.webView.evaluateJavaScript("""
        (function(){
          window.fixtureRAF=0;
          window.fixtureAnimation=function(){
            window.fixtureRAF++;
            requestAnimationFrame(window.fixtureAnimation);
          };
          requestAnimationFrame(window.fixtureAnimation);
        })()
        """)
        try await Task.sleep(nanoseconds: 300_000_000)
        let initial = try await fixture.metrics()
        let initialRAF = try XCTUnwrap(initial["raf"] as? Int)
        XCTAssertGreaterThan(initialRAF, 1, "The visible control must render before moving offscreen")
        let frame = fixture.webView.frame
        fixture.container.transform = CGAffineTransform(translationX: 0, y: UIScreen.main.bounds.height)
        var samples: [[String: Any]] = []
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let sample = try await fixture.metrics()
            samples.append(sample)
            XCTAssertNotNil(fixture.webView.window)
            XCTAssertTrue(fixture.webView.superview === fixture.container)
            XCTAssertEqual(fixture.webView.frame, frame)
            assertSameViewport(initial, sample)
        }
        let evidence: [String: Any] = ["initial": initial, "offscreen": samples]
        attachGeometry(evidence, name: "offscreen-RAF-six-seconds")
        let penultimate = try XCTUnwrap(samples[samples.count - 2]["raf"] as? Int)
        let last = try XCTUnwrap(samples.last?["raf"] as? Int)
        XCTAssertGreaterThan(last, penultimate, "Attached but fully offscreen WKWebView must still advance real render frames for continuous page turns")

        fixture.container.transform = .identity
        try await Task.sleep(nanoseconds: 300_000_000)
        let returned = try await fixture.metrics()
        attachGeometry(returned, name: "offscreen-RAF-returned")
        XCTAssertGreaterThan(try XCTUnwrap(returned["raf"] as? Int), last)
        assertSameViewport(initial, returned)
        XCTAssertEqual(fixture.webView.frame, frame)
    }

    private func assertSameViewport(_ before: [String: Any], _ after: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(before["width"] as? Double, after["width"] as? Double, file: file, line: line)
        XCTAssertEqual(before["height"] as? Double, after["height"] as? Double, file: file, line: line)
    }

    private func number(_ metrics: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(metrics[key] as? Double)
    }

    private func attachGeometry(_ metrics: [String: Any], name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: text)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

@MainActor
private final class ContainerFixture {
    static let surfaceSize = CGSize(width: 390, height: 650)
    static let crop = KindleViewportCrop(
        scale: 1.25, heightScale: 800.0 / 650.0, offsetX: -48.75, offsetY: -60
    )
    let webView: WKWebView
    let container: KindleWebViewContainer
    let window: UIWindow

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        // Match KindleWebView.makeUIView: automatic safe-area adjustment is
        // disabled in production, including when its retained host moves.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        container = KindleWebViewContainer(webView: webView, crop: Self.crop)
        container.frame = CGRect(origin: .zero, size: Self.surfaceSize)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        }
        window.isHidden = false
        window.addSubview(container)
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }

    static func make() async throws -> ContainerFixture {
        let fixture = ContainerFixture()
        fixture.webView.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;overflow:hidden}#page{position:absolute;object-fit:fill}</style>
        </head><body><img id="page"><script>
        window.fixtureResizes=0;
        window.addEventListener('resize',function(){window.fixtureResizes++;});
        window.fixtureDraw=function(fontSize,margin) {
          var page=document.getElementById('page');
          var rect=margin==='expected'
            ? {x:innerWidth*.1,y:60,w:innerWidth*.8,h:innerHeight-150}
            : {x:20,y:20,w:innerWidth-40,h:innerHeight-40};
          page.style.left=rect.x+'px'; page.style.top=rect.y+'px';
          page.style.width=rect.w+'px'; page.style.height=rect.h+'px';
          var canvas=document.createElement('canvas');
          canvas.width=Math.ceil(rect.w); canvas.height=Math.ceil(rect.h);
          var ctx=canvas.getContext('2d'); ctx.fillStyle='white';ctx.fillRect(0,0,canvas.width,canvas.height);
          ctx.font=fontSize+'px serif';ctx.fillStyle='black';
          ctx.fillText('LEFT',4,fontSize+4);
          ctx.fillText('RIGHT',canvas.width-4-ctx.measureText('RIGHT').width,fontSize*3+4);
          ctx.fillRect(4,canvas.height-fontSize-4,2,fontSize);
          ctx.fillRect(canvas.width-6,canvas.height-fontSize-4,2,fontSize);
          page.src=canvas.toDataURL('image/png');
          window.fixtureFontSize=fontSize; window.fixtureMargin=margin;
        };
        fixtureDraw(14,'expected');
        window.fixtureReady=true;
        </script></body></html>
        """, baseURL: URL(string: "https://read.amazon.com"))
        do {
            for _ in 0..<80 {
                if (try? await fixture.webView.evaluateJavaScript("window.fixtureReady===true && document.getElementById('page').complete") as? Bool) == true {
                    var stableSamples = 0
                    for _ in 0..<30 {
                        let metrics = try await fixture.metrics()
                        let width = metrics["width"] as? Double ?? 0
                        let height = metrics["height"] as? Double ?? 0
                        if abs(width - fixture.webView.bounds.width) <= 1,
                           abs(height - fixture.webView.bounds.height) <= 1 {
                            stableSamples += 1
                            if stableSamples >= 3 { return fixture }
                        } else { stableSamples = 0 }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    throw NSError(domain: "ContainerFixture.unsettledViewport", code: 3)
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw NSError(domain: "ContainerFixture.load", code: 1)
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

    func drawPage(fontSize: Int, margin: String) async throws {
        _ = try await webView.evaluateJavaScript("fixtureDraw(\(fontSize),'\(margin)')")
        for _ in 0..<40 {
            if (try await webView.evaluateJavaScript("document.getElementById('page').complete && document.getElementById('page').naturalWidth>0") as? Bool) == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw NSError(domain: "ContainerFixture.imageDecode", code: 2)
    }

    func metrics() async throws -> [String: Any] {
        let raw = try await webView.evaluateJavaScript("""
        JSON.stringify((function(){
          var r=document.getElementById('page').getBoundingClientRect();
          var pages=Array.from(document.querySelectorAll('img')).map(function(image){
            var rect=image.getBoundingClientRect();
            return {left:rect.left,top:rect.top,width:rect.width,height:rect.height};
          });
          return {width:innerWidth,height:innerHeight,resizes:fixtureResizes,fontSize:fixtureFontSize,pages:pages,
            raf:Number(window.fixtureRAF||0),hidden:document.hidden,visibility:document.visibilityState,
            margin:fixtureMargin,page:{left:r.left,top:r.top,width:r.width,height:r.height}};
        })())
        """)
        let text = try XCTUnwrap(raw as? String)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func visiblePageRect(_ metrics: [String: Any]) throws -> CGRect {
        let page = try XCTUnwrap(metrics["page"] as? [String: Double])
        let viewportWidth = try XCTUnwrap(metrics["width"] as? Double)
        let viewportHeight = try XCTUnwrap(metrics["height"] as? Double)
        let xScale = webView.bounds.width / viewportWidth
        let yScale = webView.bounds.height / viewportHeight
        let local = CGRect(
            x: (page["left"] ?? 0) * xScale,
            y: (page["top"] ?? 0) * yScale,
            width: (page["width"] ?? 0) * xScale,
            height: (page["height"] ?? 0) * yScale
        )
        return webView.convert(local, to: container)
    }
}

@MainActor
private final class DockFixtureState: ObservableObject {
    @Published var controlsHidden = false
}

private struct DockLayoutFixture: View {
    let container: KindleWebViewContainer
    let controls: UIView
    @ObservedObject var state: DockFixtureState
    let size: CGSize

    var body: some View {
        KindleReaderPlaybackDock(isLandscape: true) {
            DockNativeView(view: container)
        } playback: {
            DockNativeView(view: controls)
                .frame(width: 360, height: 56)
                .padding(.bottom, 8)
                .opacity(state.controlsHidden ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
    }
}

private struct DockNativeView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) { }
}
