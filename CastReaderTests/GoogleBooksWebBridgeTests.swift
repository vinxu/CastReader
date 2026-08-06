//
//  GoogleBooksWebBridgeTests.swift
//  CastReaderTests
//
//  在真实 WKWebView 里跑 CastReaderTests 专用 bundle，用一个复刻 Play 图书
//  DOM 结构的 fixture 验证阅读帧契约；随 App 发布的 WebAssets/bundle.js
//  另有断言确保不暴露测试 API：
//    · 只读**当前可见页**（Google 把整章渲进同一容器再裁剪分页）
//    · 末段跨页时给出补句文本与来源坐标
//    · CR.gbNextPage() 能翻页，并在新页稳定后再报一次 rendered
//  没有网络、不需要 Google 账号，可在 CI 长期跑。
//

import XCTest
import UIKit
import WebKit
@testable import CastReader

@MainActor
final class GoogleBooksWebBridgeTests: XCTestCase {

    private static let fixtureAPINames = [
        "__fixtureManualIntent",
        "__fixtureBeginManualSwipe",
        "__fixtureEndManualSwipe",
    ]

    private static func loadXCTestBundleJS() throws -> String {
        let testBundle = Bundle(for: GoogleBooksWebBridgeTests.self)
        let url = testBundle.url(
            forResource: "google-books-webreader-xctest",
            withExtension: "js"
        ) ?? testBundle.url(
            forResource: "google-books-webreader-xctest",
            withExtension: "js",
            subdirectory: "Fixtures"
        )
        let fixtureURL = try XCTUnwrap(
            url,
            "CastReaderTests fixture bundle 必须只加入测试 target Resources"
        )
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }

    /// 复刻 books.googleusercontent.com 阅读帧：一个 reader-rendered-page 里放整章
    /// .gb-segment，靠 translateY 分页；另外两个屏外副本模拟 Google 的排版测量页。
    private static let fixtureHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><style>
      html,body{margin:0;padding:0;height:100%;overflow:hidden;font-family:-apple-system,serif}
      reader-app{display:block;position:relative;height:100%}
      reader-rendered-page{display:block;position:absolute;overflow:hidden;background:#fff;box-sizing:border-box}
      #visible{left:0;top:0;width:100%;height:100%}
      #measureA{left:-3000px;top:0;width:448px;height:787px}
      .gb-segment{position:absolute;left:0;width:100%;padding:0 18px;box-sizing:border-box}
      .gb-segment p{font-size:20px;line-height:32px;margin:0 0 20px 0;text-align:justify;white-space:pre-wrap}
    </style></head><body>
    <reader-app>
      <reader-rendered-page id="visible"><div class="gb-segment" id="seg"></div></reader-rendered-page>
      <reader-rendered-page id="measureA"><div class="gb-segment"></div></reader-rendered-page>
      <button aria-label="Previous Page" id="prev" style="position:absolute;left:2px;bottom:2px">p</button>
      <button aria-label="Next Page" id="next" style="position:absolute;right:2px;bottom:2px">n</button>
    </reader-app>
    <script>
      // 每段都远长于一页：这样页底必定切在段落中间，才能测到「可见区裁剪 + 跨页补句」。
      // 句子约 180 字符（< 补句上限 260），保证被切断处一定能找到自然句末。
      var SENTENCES = [
        'The morning tide had gone out a full hour before dawn that day, leaving behind it a wide and shining plain of wet sand which mirrored the pale sky above the harbour wall.',
        'Gulls walked across the flats in careful and unhurried lines, stopping now and then to consider something buried beneath the surface, and then moving on again without it.',
        'Marguerite counted the boats as she always did, first the painted ones nearest the wall and afterwards the working hulls that lay further out towards the open grey water.',
        'When the number matched the number she had counted on the evening before, she allowed herself to go back inside the cottage and put the heavy kettle on the iron stove.',
        'There had been a time within living memory when the island still supported four hundred families, two schoolteachers, a chapel with benches enough for every feast day.',
        'Now the ferry came only when the weather allowed it, which through the winter months meant almost never, and the schoolroom held six children of five different ages.',
        'She set the cup down carefully beside the window and watched the light change across the water while the wind moved the loose grass along the top of the low sea wall.',
        'Somewhere behind the headland a boat engine started up, coughed twice in the cold air, and then settled into a steady working rhythm that carried across the morning.'
      ];
      var seg = document.getElementById('seg');
      for (var i = 0; i < 4; i++) {
        var p = document.createElement('p');
        p.className = 'para' + i;
        var parts = [];
        for (var s = 0; s < SENTENCES.length; s++) parts.push(SENTENCES[(i + s) % SENTENCES.length]);
        // 首段保留空白 + surrogate pair，验证 trim 后的坐标仍精确使用 UTF-16。
        p.textContent = (i === 0 ? '  😀  ' : '') + parts.join(' ') + '  ';
        seg.appendChild(p);
      }
      window.fixturePage = 0;
      document.getElementById('next').addEventListener('click', function () {
        window.fixturePage += 1;
        seg.style.transform = 'translateY(' + (-window.fixturePage * window.innerHeight) + 'px)';
      });
      document.getElementById('prev').addEventListener('click', function () {
        window.fixturePage = Math.max(0, window.fixturePage - 1);
        seg.style.transform = 'translateY(' + (-window.fixturePage * window.innerHeight) + 'px)';
      });
    </script>
    </body></html>
    """

    /// Google 横向分页：一个固定高度的 CSS columns segment，靠 translateX 切页。
    /// 翻页动作延迟 1.5s 才落地，并让方向键也能翻页，专门防回归旧版 1.2s ladder 双翻。
    private static let horizontalFixtureHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><style>
      html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;font-family:-apple-system,serif}
      reader-app{display:block;position:relative;width:100%;height:100%}
      reader-rendered-page{display:block;position:absolute;left:0;top:0;width:100%;height:100%;overflow:hidden;background:#fff}
      .gb-segment{
        position:absolute;left:18px;top:0;width:354px;height:100%;
        column-width:354px;column-gap:36px;column-fill:auto;
        box-sizing:border-box;will-change:transform
      }
      .gb-segment p{font-size:20px;line-height:32px;margin:0;white-space:pre-wrap;text-align:justify}
      #next{position:absolute;z-index:10;right:2px;bottom:2px}
    </style></head><body>
    <reader-app>
      <reader-rendered-page id="horizontal">
        <div class="gb-segment" id="hseg"><p class="para0" id="hpara"></p></div>
      </reader-rendered-page>
      <button aria-label="Next Page" id="next">n</button>
    </reader-app>
    <script>
      var unit = 'Horizontal pagination must expose only the glyphs in the current CSS column, including emoji 😀, while preserving exact UTF-16 source coordinates for every extracted slice.';
      document.getElementById('hpara').textContent = '   ' + Array.from(
        {length: 32},
        function (_, index) { return '[' + index + '] ' + unit; }
      ).join(' ') + '   ';
      window.fixturePage = 0;
      window.turnActions = 0;
      function queueTurn() {
        var target = ++window.turnActions;
        [0.25, 0.55, 0.8, 1].forEach(function (progress, index) {
          setTimeout(function () {
            if (progress === 1) window.fixturePage = target;
            document.getElementById('hseg').style.transform =
              'translateX(' + (-target * 390 * progress) + 'px)';
          }, 1350 + index * 180);
        });
      }
      document.getElementById('next').addEventListener('click', queueTurn);
      document.addEventListener('keydown', function (event) {
        if (event.key === 'ArrowRight') queueTurn();
      });
    </script>
    </body></html>
    """

    /// 模拟线上出现过的布局：DOM source 已有后续句子，但 Google 尚未给下一页文字
    /// 可用的 geometry。Range 只暴露当前 viewport 的 rect，因而完整页预测应 miss；
    /// source-stream fallback 仍能只读同一真实 segment 的下一自然句。
    private static let sourceStreamOnlyFixtureHTML = """
    <!doctype html><html data-cr-test-fixture="1"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><style>
      html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;font-family:-apple-system,serif}
      reader-app{display:block;position:relative;width:100%;height:100%}
      reader-rendered-page{display:block;position:absolute;inset:0;overflow:hidden;background:#fff}
      .gb-segment{position:absolute;left:18px;top:0;width:354px;box-sizing:border-box}
      .gb-segment p{font-size:20px;line-height:32px;margin:0;white-space:pre-wrap}
      #next{position:absolute;z-index:10;right:2px;bottom:2px}
    </style></head><body>
    <reader-app>
      <reader-rendered-page id="sourcePage">
        <div class="gb-segment" id="sourceSeg"><p id="sourcePara"></p></div>
      </reader-rendered-page>
      <button aria-label="Next Page" id="next">n</button>
    </reader-app>
    <script>
      var sentences = Array.from({length: 48}, function (_, index) {
        return '[' + index + '] Exact source sentence with emoji 😀 remains in DOM order and ends here.';
      });
      document.getElementById('sourcePara').textContent =
        '   ' + sentences.join(' ') + '   ';
      window.turnActions = 0;
      document.getElementById('next').addEventListener('click', function () {
        window.turnActions += 1;
        document.getElementById('sourceSeg').style.transform =
          'translateY(-700px)';
      });

      // Google can withhold off-viewport layout fragments until the next page
      // is materialized. Preserve current-page extraction while making every
      // adjacent virtual clip miss exactly as that production state does.
      var originalGetClientRects = Range.prototype.getClientRects;
      Range.prototype.getClientRects = function () {
        return Array.prototype.filter.call(
          originalGetClientRects.call(this),
          function (rect) {
            return rect.right > 0 && rect.left < window.innerWidth &&
              rect.bottom > 0 && rect.top < window.innerHeight;
          }
        );
      };
    </script>
    </body></html>
    """

    /// 线上另一种 geometry miss：当前段已经结束，下一页原文位于 DOM 顺序中的
    /// 后续独立 segment，但 Google 尚未给该页任何 viewport geometry。
    private static let followingSegmentSourceFixtureHTML = """
    <!doctype html><html data-cr-test-fixture="1"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><style>
      html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;font-family:-apple-system,serif}
      reader-app{display:block;position:relative;width:100%;height:100%}
      reader-rendered-page{display:block;position:absolute;left:0;width:100%;height:100%;overflow:hidden;background:#fff}
      #currentPage{top:0}
      #futurePage{top:5000px}
      .gb-segment{position:absolute;left:18px;top:0;width:354px;box-sizing:border-box}
      .gb-segment p{font-size:20px;line-height:32px;margin:0;white-space:pre-wrap}
      #next{position:absolute;z-index:10;right:2px;bottom:2px}
    </style></head><body>
    <reader-app>
      <reader-rendered-page id="currentPage">
        <div class="gb-segment" id="currentSeg">
          <p id="currentPara">The current immutable segment ends here.</p>
        </div>
      </reader-rendered-page>
      <reader-rendered-page id="futurePage">
        <div class="gb-segment" id="futureSeg">
          <p id="futurePara">Next segment sentence keeps emoji 😀 and ends here. A later sentence remains.</p>
        </div>
      </reader-rendered-page>
      <button aria-label="Next Page" id="next">n</button>
    </reader-app>
    <script>
      window.turnActions = 0;
      document.getElementById('next').addEventListener('click', function () {
        window.turnActions += 1;
      });
      var originalGetClientRects = Range.prototype.getClientRects;
      Range.prototype.getClientRects = function () {
        return Array.prototype.filter.call(
          originalGetClientRects.call(this),
          function (rect) {
            return rect.right > 0 && rect.left < window.innerWidth &&
              rect.bottom > 0 && rect.top < window.innerHeight;
          }
        );
      };
    </script>
    </body></html>
    """

    /// Google 的 page clip 落在一行中间时，当前页只能接纳完整行。第 4 行
    /// 故意只露出一半，用来验证提取、高亮和动态视觉 guard 使用同一条边界。
    private static let partialBottomLineFixtureHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><style>
      html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden}
      reader-app{display:block;position:relative;width:100%;height:100%}
      reader-rendered-page{
        display:block;position:absolute;left:0;top:0;width:100%;height:112px;
        overflow:hidden;background:rgb(248,247,243)
      }
      .gb-segment{position:absolute;inset:0}
      p{margin:0;font:20px/32px -apple-system,sans-serif;white-space:pre-wrap}
      .line{display:block;height:32px;line-height:32px}
    </style></head><body>
    <reader-app>
      <reader-rendered-page id="partialPage">
        <div class="gb-segment"><p id="partialPara"><span class="line">First complete line. </span><span class="line">Second complete line. </span><span class="line">Third complete line. </span><span class="line">Fourth clipped line must move. </span></p></div>
      </reader-rendered-page>
    </reader-app>
    </body></html>
    """

    private final class Inbox: NSObject, WKScriptMessageHandler {
        var messages: [(type: String, payload: [String: Any])] = []
        var onMessage: ((String, [String: Any]) -> Void)?
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            let payload = body["payload"] as? [String: Any] ?? [:]
            messages.append((type, payload))
            onMessage?(type, payload)
        }
    }

    private var webView: WKWebView!
    private var inbox: Inbox!
    private var auxiliaryWebViews: [WKWebView] = []
    private var hostingWindows: [UIWindow] = []

    private func makeReaderWebView(inbox: Inbox) throws -> WKWebView {
        let bundleJS = try Self.loadXCTestBundleJS()
        let controller = WKUserContentController()
        controller.add(inbox, name: WebReaderBridge.handlerName)
        controller.addUserScript(
            WKUserScript(source: bundleJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            configuration: config
        )
        // An unattached WKWebView is eligible for WebKit process freezing.
        // These fixtures intentionally use timers to model a slow Google page
        // turn, so keep every test reader in a visible window just like the
        // production reader. Otherwise the final stability sample can be
        // suspended between turn acknowledgement and rendered-page commit.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            window = UIWindow(windowScene: scene)
            window.frame = webView.frame
        } else {
            window = UIWindow(frame: webView.frame)
        }
        let viewController = UIViewController()
        window.rootViewController = viewController
        viewController.view.frame = window.bounds
        webView.frame = viewController.view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewController.view.addSubview(webView)
        window.isHidden = false
        hostingWindows.append(window)
        return webView
    }

    override func setUp() async throws {
        try await super.setUp()
        inbox = Inbox()
        webView = try makeReaderWebView(inbox: inbox)
    }

    override func tearDown() async throws {
        for auxiliaryWebView in auxiliaryWebViews {
            auxiliaryWebView.configuration.userContentController
                .removeScriptMessageHandler(forName: WebReaderBridge.handlerName)
        }
        auxiliaryWebViews.removeAll()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: WebReaderBridge.handlerName)
        for window in hostingWindows {
            window.isHidden = true
            window.rootViewController = nil
        }
        hostingWindows.removeAll()
        webView = nil
        inbox = nil
        try await super.tearDown()
    }

    func testProductionBundleDoesNotExposeFixtureAPI() throws {
        let productionBundle = try XCTUnwrap(
            WebReaderView.loadBundleJS(),
            "随 App 发布的 WebAssets/bundle.js 必须存在"
        )
        let fixtureBundle = try Self.loadXCTestBundleJS()
        for name in Self.fixtureAPINames {
            XCTAssertFalse(
                productionBundle.contains(name),
                "生产 bundle 不得包含 XCTest API：\(name)"
            )
            XCTAssertTrue(
                fixtureBundle.contains(name),
                "测试 bundle 必须保留 XCTest API：\(name)"
            )
        }
    }

    func testReaderFramePathRequiresSegmentBoundary() async throws {
        let isolatedInbox = Inbox()
        let isolatedWebView = try makeReaderWebView(inbox: isolatedInbox)
        auxiliaryWebViews.append(isolatedWebView)
        isolatedWebView.loadHTMLString(
            Self.fixtureHTML,
            baseURL: URL(string: "https://books.googleusercontent.com/books/readerevil")
        )

        var loadedPath = ""
        for _ in 0..<20 {
            loadedPath = (try? await isolatedWebView.evaluateJavaScript(
                "window.location.pathname"
            )) as? String ?? ""
            if loadedPath == "/books/readerevil" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(loadedPath, "/books/readerevil")

        let installed = try await isolatedWebView.evaluateJavaScript(
            "typeof window.CastReaderGoogleBooks !== 'undefined'"
        ) as? Bool
        XCTAssertEqual(
            installed,
            false,
            "路径前缀相似但不在 reader segment 内时不得安装 Google Books API"
        )
        XCTAssertFalse(
            isolatedInbox.messages.contains { $0.type == "rendered" },
            "非 reader segment 不得提交 Google Books 页面"
        )
    }

    @discardableResult
    private func loadReaderFrame(_ html: String? = nil) async throws -> [String: Any] {
        try await loadReaderFrame(html, in: webView, inbox: inbox)
    }

    @discardableResult
    private func loadReaderFrame(
        _ html: String?,
        in targetWebView: WKWebView,
        inbox targetInbox: Inbox
    ) async throws -> [String: Any] {
        targetWebView.loadHTMLString(
            html ?? Self.fixtureHTML,
            // 阅读帧的 host 门控就是靠这个 origin 命中的。
            baseURL: URL(string: "https://books.googleusercontent.com/books/reader/frame")
        )
        return try await waitForRendered(reason: "initial", inbox: targetInbox)
    }

    @discardableResult
    private func waitForRendered(reason: String, timeout: TimeInterval = 12) async throws -> [String: Any] {
        try await waitForRendered(reason: reason, inbox: inbox, timeout: timeout)
    }

    @discardableResult
    private func waitForRendered(
        reason: String,
        inbox targetInbox: Inbox,
        timeout: TimeInterval = 12
    ) async throws -> [String: Any] {
        let expectation = expectation(description: "rendered:\(reason)")
        var captured: [String: Any] = [:]
        targetInbox.onMessage = { type, payload in
            guard type == "rendered", (payload["reason"] as? String) == reason else { return }
            captured = payload
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: timeout)
        targetInbox.onMessage = nil
        return captured
    }

    private func paragraphs(_ payload: [String: Any]) -> [[String: Any]] {
        payload["paragraphs"] as? [[String: Any]] ?? []
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private func javaScriptStringLiteral(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// DOM 里每个 `<p>` 的完整长度（不是可见片段），用来证明确实发生了裁剪。
    private func paragraphFullLengths() async throws -> [Int] {
        let value = try await webView.evaluateJavaScript(
            "Array.prototype.map.call(document.querySelectorAll('#seg > p'), function (p) { return (p.textContent || '').length })"
        )
        return (value as? [Int]) ?? (value as? [NSNumber])?.map(\.intValue) ?? []
    }

    // MARK: - 测试

    func testOnlyTheVisiblePageIsExtracted() async throws {
        let payload = try await loadReaderFrame()
        XCTAssertEqual(payload["source"] as? String, "google-books")
        let frameSessionID = try XCTUnwrap(payload["frameSessionID"] as? String)
        XCTAssertFalse(frameSessionID.isEmpty)
        let paras = paragraphs(payload)
        XCTAssertFalse(paras.isEmpty, "阅读帧必须提取到段落")
        // DOM 里是整章 4 大段，每段都比一屏长；首屏只能看到其中一小部分。
        let fullLengths = try await paragraphFullLengths()
        let visibleTotal = paras.reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) }
        XCTAssertLessThan(
            visibleTotal,
            fullLengths.reduce(0, +) / 2,
            "整章被当成一页读完 = 可见区裁剪失效"
        )

        let signature = try XCTUnwrap(payload["signature"] as? String)
        XCTAssertFalse(signature.isEmpty)

        // 每段都要带来源坐标，跨页裁剪才有依据。
        for para in paras {
            XCTAssertNotNil(para["sourceParagraphIndex"], "缺 sourceParagraphIndex 就无法裁掉已读前缀")
            XCTAssertNotNil(para["sourceUTF16Start"])
            XCTAssertNotNil(para["sourceUTF16End"])
        }
    }

    func testPartialBottomLineIsDeferredAndNeverHighlighted() async throws {
        let payload = try await loadReaderFrame(Self.partialBottomLineFixtureHTML)
        let para = try XCTUnwrap(paragraphs(payload).first)
        let text = try XCTUnwrap(para["text"] as? String)
        XCTAssertTrue(text.contains("Third complete line."))
        XCTAssertFalse(
            text.contains("Fourth clipped line"),
            "只露出半行的文字必须完整移到下一页"
        )

        let expectedEndValue = try await webView.evaluateJavaScript(
            """
            Array.prototype.slice.call(
              document.querySelectorAll('#partialPara .line'),
              0,
              3
            ).map(function (line) {
              return line.textContent || '';
            }).join('').trimEnd().length
            """
        )
        XCTAssertEqual(
            int(para["sourceUTF16End"]),
            int(expectedEndValue),
            "sourceEnd 必须停在最后一条完整行"
        )

        let fullLengthValue = try await webView.evaluateJavaScript(
            "(document.getElementById('partialPara').textContent || '').length"
        )
        let fullLength = try XCTUnwrap(int(fullLengthValue))
        _ = try await webView.evaluateJavaScript(
            """
            window.CR.highlightRange({
              paragraphIndex: 0,
              charStart: 0,
              charEnd: \(fullLength),
              domCharStart: 0,
              domCharEnd: \(fullLength)
            })
            """
        )
        let visualState = try await webView.evaluateJavaScript(
            """
            (function () {
              var guard = document.querySelector('.cr-gb-page-edge-guard');
              var clippedLine = document.querySelectorAll(
                '#partialPara .line'
              )[3];
              var clippedRange = document.createRange();
              clippedRange.selectNodeContents(clippedLine);
              var clippedRect = clippedRange.getClientRects()[0];
              var pageRect = document.getElementById(
                'partialPage'
              ).getBoundingClientRect();
              var overlays = Array.prototype.map.call(
                document.querySelectorAll('.cr-hl-ov'),
                function (node) {
                  var rect = node.getBoundingClientRect();
                  return {top:rect.top,bottom:rect.bottom};
                }
              );
              var rect = guard && guard.getBoundingClientRect();
              return {
                guardTop: rect && rect.top,
                guardBottom: rect && rect.bottom,
                guardPointerEvents: guard && getComputedStyle(guard).pointerEvents,
                guardBackground: guard && getComputedStyle(guard).backgroundColor,
                expectedGuardTop: clippedRect && clippedRect.top,
                expectedGuardBottom: pageRect.bottom,
                overlays: overlays
              };
            })()
            """
        ) as? [String: Any]
        let guardTop = try XCTUnwrap(
            (visualState?["guardTop"] as? NSNumber)?.doubleValue
        )
        let guardBottom = try XCTUnwrap(
            (visualState?["guardBottom"] as? NSNumber)?.doubleValue
        )
        let expectedGuardTop = try XCTUnwrap(
            (visualState?["expectedGuardTop"] as? NSNumber)?.doubleValue
        )
        let expectedGuardBottom = try XCTUnwrap(
            (visualState?["expectedGuardBottom"] as? NSNumber)?.doubleValue
        )
        XCTAssertEqual(guardTop, expectedGuardTop, accuracy: 1)
        XCTAssertEqual(guardBottom, expectedGuardBottom, accuracy: 1)
        XCTAssertEqual(visualState?["guardPointerEvents"] as? String, "none")
        XCTAssertEqual(
            visualState?["guardBackground"] as? String,
            "rgb(248, 247, 243)"
        )
        let overlayRects =
            visualState?["overlays"] as? [[String: Any]] ?? []
        XCTAssertFalse(overlayRects.isEmpty)
        XCTAssertTrue(overlayRects.allSatisfy {
            (($0["bottom"] as? NSNumber)?.doubleValue ?? .infinity)
                <= expectedGuardTop + 0.5
        })

        _ = try await webView.evaluateJavaScript(
            """
            document.getElementById('partialPage').style.height = '128px';
            window.CR.extract('refresh');
            true
            """
        )
        let resizedState = try await webView.evaluateJavaScript(
            """
            ({
              guards: document.querySelectorAll('.cr-gb-page-edge-guard').length,
              text: (
                window.__crLastRendered &&
                window.__crLastRendered[0] &&
                window.__crLastRendered[0].text
              ) || ''
            })
            """
        ) as? [String: Any]
        XCTAssertEqual(int(resizedState?["guards"]), 0)
        XCTAssertTrue(
            (resizedState?["text"] as? String)?
                .contains("Fourth clipped line") == true
        )
    }

    func testTrimmedExactTextKeepsPreciseUTF16SourceCoordinates() async throws {
        let payload = try await loadReaderFrame()
        let paras = paragraphs(payload)
        XCTAssertFalse(paras.isEmpty)
        var foundTrimmedPrefix = false

        for (index, para) in paras.enumerated() {
            let text = try XCTUnwrap(para["text"] as? String)
            let start = try XCTUnwrap(int(para["sourceUTF16Start"]))
            let end = try XCTUnwrap(int(para["sourceUTF16End"]))
            let domSlice = try await webView.evaluateJavaScript(
                """
                (function () {
                  var el = document.querySelector('[data-cr-para="\(index)"]');
                  return el ? (el.textContent || '').slice(\(start), \(end)) : null;
                })()
                """
            ) as? String

            XCTAssertEqual(domSlice, text, "exactText 与 DOM source range 必须逐 UTF-16 code unit 对齐")
            XCTAssertEqual(end - start, (text as NSString).length)
            if start > 0, text.hasPrefix("😀") { foundTrimmedPrefix = true }
        }
        XCTAssertTrue(foundTrimmedPrefix, "fixture 首段的保留空白应被 trim，并同步推进 sourceStart")
    }

    func testLastParagraphCarriesTheSentenceAcrossThePageBreak() async throws {
        let payload = try await loadReaderFrame()
        let tail = try XCTUnwrap(paragraphs(payload).last)
        let visible = try XCTUnwrap(tail["text"] as? String)
        let lengths = try await paragraphFullLengths()
        let fullLength = try XCTUnwrap(lengths.max())
        let sourceEnd = try XCTUnwrap(tail["sourceUTF16End"] as? Int)
        // fixture 前提：末段一定被页底切断（DOM 里这段远长于一屏）。
        XCTAssertLessThan(sourceEnd, fullLength, "fixture 前提：末段应当被页底切断")
        guard !visible.hasSuffix(".") else {
            // 极少数情况下切点正好落在句末，此时没有补句是正确行为。
            XCTAssertNil(tail["speechText"])
            return
        }
        let speech = try XCTUnwrap(
            tail["speechText"] as? String,
            "被切断的末段必须给出补到句末的朗读文本"
        )
        XCTAssertTrue(speech.hasPrefix(visible))
        XCTAssertTrue(speech.hasSuffix("."), "补句必须停在自然句末")
        let boundary = try XCTUnwrap(tail["boundaryUTF16Offset"] as? Int)
        let extended = try XCTUnwrap(tail["extendedUTF16Length"] as? Int)
        XCTAssertGreaterThan(extended, boundary)

        // native 侧据此得到的「已读到哪」游标。
        let cursor = GoogleBooksCrossPageContract.consumedCursor(
            boundary: LiveWebPageSpeechBoundary(
                paragraphIndex: 0,
                visibleUTF16Offset: boundary,
                speechUTF16Length: extended
            ),
            sourceParagraphIndex: tail["sourceParagraphIndex"] as? Int,
            sourceVisibleEnd: tail["sourceUTF16End"] as? Int
        )
        XCTAssertNotNil(cursor)
    }

    func testNextPageTurnsAndReportsTheNewPage() async throws {
        let first = try await loadReaderFrame()
        let firstSignature = first["signature"] as? String ?? ""
        let firstTexts = paragraphs(first).compactMap { $0["text"] as? String }

        _ = try await webView.evaluateJavaScript("window.CastReaderGoogleBooks.nextPage()")
        let second = try await waitForRendered(reason: "auto")

        let secondSignature = second["signature"] as? String ?? ""
        XCTAssertFalse(secondSignature.isEmpty)
        XCTAssertNotEqual(secondSignature, firstSignature, "翻页后可见区指纹必须变化")

        let secondTexts = paragraphs(second).compactMap { $0["text"] as? String }
        XCTAssertFalse(secondTexts.isEmpty, "新页必须提取到段落")
        XCTAssertNotEqual(secondTexts, firstTexts)

        // native 契约层要接受这次提交。
        XCTAssertTrue(GoogleBooksPageTurnContract.shouldCommit(
            reason: .auto,
            previousSignature: firstSignature,
            incomingSignature: secondSignature,
            paragraphCount: secondTexts.count
        ))
    }

    func testNextPagePreviewArrivesBeforeAnyPhysicalTurnAndMatchesCommit()
        async throws {
        let first = try await loadReaderFrame(Self.horizontalFixtureHTML)
        let firstSignature = try XCTUnwrap(first["signature"] as? String)

        var preview = inbox.messages.last {
            $0.type == "googleBooksPagePreview"
        }?.payload
        if preview == nil {
            let previewExpectation = expectation(
                description: "next-page preview before turn"
            )
            inbox.onMessage = { type, payload in
                guard type == "googleBooksPagePreview" else { return }
                preview = payload
                previewExpectation.fulfill()
            }
            await fulfillment(of: [previewExpectation], timeout: 4)
            inbox.onMessage = nil
        }
        let capturedPreview = try XCTUnwrap(preview)
        XCTAssertEqual(
            capturedPreview["sourceSignature"] as? String,
            firstSignature
        )
        let previewTexts = paragraphs(capturedPreview).compactMap {
            $0["text"] as? String
        }
        XCTAssertFalse(previewTexts.isEmpty)

        let beforeTurn = try await webView.evaluateJavaScript(
            """
            ({
              transform: document.getElementById('hseg').style.transform,
              page: window.fixturePage,
              actions: window.turnActions
            })
            """
        ) as? [String: Any]
        XCTAssertEqual(beforeTurn?["transform"] as? String, "")
        XCTAssertEqual(int(beforeTurn?["page"]), 0)
        XCTAssertEqual(int(beforeTurn?["actions"]), 0)

        _ = try await webView.evaluateJavaScript(
            "window.CastReaderGoogleBooks.nextPage()"
        )
        let committed = try await waitForRendered(reason: "auto")
        let committedTexts = paragraphs(committed).compactMap {
            $0["text"] as? String
        }
        XCTAssertEqual(
            previewTexts,
            committedTexts,
            "只读预测必须与随后真实提交的同一页全文一致"
        )
    }

    func testGeometryPreviewMissFallsBackToExactReadOnlySourceSentence()
        async throws {
        let first = try await loadReaderFrame(Self.sourceStreamOnlyFixtureHTML)
        let firstSignature = try XCTUnwrap(first["signature"] as? String)
        let frameSessionID = try XCTUnwrap(first["frameSessionID"] as? String)
        let tail = try XCTUnwrap(paragraphs(first).last)
        let tailSourceStart = try XCTUnwrap(int(tail["sourceUTF16Start"]))
        let tailSourceEnd = try XCTUnwrap(int(tail["sourceUTF16End"]))
        let consumedEnd: Int
        if let speechLength = int(tail["extendedUTF16Length"]) {
            consumedEnd = tailSourceStart + speechLength
        } else {
            consumedEnd = tailSourceEnd
        }

        var speechPreview = inbox.messages.last {
            $0.type == "googleBooksSpeechPreview"
        }?.payload
        if speechPreview == nil {
            let previewExpectation = expectation(
                description: "source-stream speech preview"
            )
            inbox.onMessage = { type, payload in
                guard type == "googleBooksSpeechPreview" else { return }
                speechPreview = payload
                previewExpectation.fulfill()
            }
            await fulfillment(of: [previewExpectation], timeout: 4)
            inbox.onMessage = nil
        }
        let captured = try XCTUnwrap(speechPreview)
        let text = try XCTUnwrap(captured["text"] as? String)
        let start = try XCTUnwrap(int(captured["sourceUTF16Start"]))
        let end = try XCTUnwrap(int(captured["sourceUTF16End"]))

        XCTAssertEqual(captured["sourceSignature"] as? String, firstSignature)
        XCTAssertEqual(captured["exactText"] as? Bool, true)
        XCTAssertEqual(captured["frameSessionID"] as? String, frameSessionID)
        XCTAssertEqual(
            captured["originFrameSessionID"] as? String,
            frameSessionID
        )
        XCTAssertEqual(
            int(captured["sourceParagraphIndex"]),
            int(tail["sourceParagraphIndex"]),
            "fallback 必须沿当前 tail 所在的同一个真实 source paragraph 前进"
        )
        XCTAssertGreaterThanOrEqual(start, consumedEnd)
        XCTAssertEqual(end - start, (text as NSString).length)
        XCTAssertTrue(text.contains("😀"), "fixture 的下一自然句应保留 surrogate pair")
        XCTAssertTrue(text.hasSuffix("."), "fallback 只能发出完整自然句")
        XCTAssertNotNil(
            (captured["contentFingerprint"] as? String)?
                .range(of: #"^[0-9a-f]{8}$"#, options: .regularExpression)
        )

        let exactSourceSlice = try await webView.evaluateJavaScript(
            """
            (document.getElementById('sourcePara').textContent || '')
              .slice(\(start), \(end))
            """
        ) as? String
        XCTAssertEqual(exactSourceSlice, text, "text 必须是 UTF-16 坐标对应的 DOM 原文精确切片")
        let skippedBoundary = try await webView.evaluateJavaScript(
            """
            (document.getElementById('sourcePara').textContent || '')
              .slice(\(consumedEnd), \(start))
            """
        ) as? String
        XCTAssertTrue(
            skippedBoundary?.allSatisfy {
                $0.isWhitespace || "\"'”’」』）)】》〉]".contains($0)
            } ?? false,
            "从 sourceSpeechEnd/sourceEnd 到下一句只能跳过空白或上一句闭合符"
        )

        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(
            inbox.messages.contains { $0.type == "googleBooksPagePreview" },
            "fixture 明确没有下一页 geometry，不能伪造 full-page preview"
        )
        XCTAssertTrue(
            inbox.messages.contains {
                $0.type == "googleBooksPreviewDiagnostic" &&
                ($0.payload["event"] as? String) == "geometry-miss" &&
                ($0.payload["sourceSignature"] as? String) == firstSignature
            }
        )
        XCTAssertTrue(
            inbox.messages.contains {
                $0.type == "googleBooksPreviewDiagnostic" &&
                ($0.payload["event"] as? String) == "source-preview" &&
                ($0.payload["contentFingerprint"] as? String) ==
                    (captured["contentFingerprint"] as? String)
            }
        )

        let state = try await webView.evaluateJavaScript(
            """
            ({
              transform: document.getElementById('sourceSeg').style.transform,
              actions: window.turnActions,
              scrollX: window.scrollX,
              scrollY: window.scrollY
            })
            """
        ) as? [String: Any]
        XCTAssertEqual(state?["transform"] as? String, "")
        XCTAssertEqual(int(state?["actions"]), 0, "source preview 不得触发翻页按钮")
        XCTAssertEqual(int(state?["scrollX"]), 0)
        XCTAssertEqual(int(state?["scrollY"]), 0)
    }

    func testGeometryMissCanReadExactFirstSentenceFromFollowingUniqueSegment()
        async throws {
        let first = try await loadReaderFrame(
            Self.followingSegmentSourceFixtureHTML
        )
        let firstSignature = try XCTUnwrap(first["signature"] as? String)
        let currentSourceID = try XCTUnwrap(
            int(paragraphs(first).first?["sourceParagraphIndex"])
        )

        var speechPreview = inbox.messages.last {
            $0.type == "googleBooksSpeechPreview"
        }?.payload
        if speechPreview == nil {
            let previewExpectation = expectation(
                description: "following segment source preview"
            )
            inbox.onMessage = { type, payload in
                guard type == "googleBooksSpeechPreview" else { return }
                speechPreview = payload
                previewExpectation.fulfill()
            }
            await fulfillment(of: [previewExpectation], timeout: 4)
            inbox.onMessage = nil
        }
        let captured = try XCTUnwrap(speechPreview)
        let text = try XCTUnwrap(captured["text"] as? String)
        let sourceID = try XCTUnwrap(
            int(captured["sourceParagraphIndex"])
        )
        let start = try XCTUnwrap(int(captured["sourceUTF16Start"]))
        let end = try XCTUnwrap(int(captured["sourceUTF16End"]))

        XCTAssertEqual(captured["sourceSignature"] as? String, firstSignature)
        XCTAssertEqual(captured["exactText"] as? Bool, true)
        XCTAssertNotEqual(
            sourceID,
            currentSourceID,
            "当前 segment 已结束时只允许沿 DOM 顺序读取下一个唯一 source segment"
        )
        XCTAssertTrue(text.hasPrefix("Next segment sentence"))
        XCTAssertTrue(text.contains("😀"))
        XCTAssertTrue(text.hasSuffix("."))
        XCTAssertEqual(end - start, (text as NSString).length)
        let exactSourceSlice = try await webView.evaluateJavaScript(
            """
            (document.getElementById('futurePara').textContent || '')
              .slice(\(start), \(end))
            """
        ) as? String
        XCTAssertEqual(exactSourceSlice, text)
        XCTAssertFalse(
            inbox.messages.contains { $0.type == "googleBooksPagePreview" },
            "没有 viewport geometry 时仍不能伪造完整下一页"
        )

        let state = try await webView.evaluateJavaScript(
            """
            ({
              currentTransform:
                document.getElementById('currentSeg').style.transform,
              futureTransform:
                document.getElementById('futureSeg').style.transform,
              actions: window.turnActions,
              scrollX: window.scrollX,
              scrollY: window.scrollY
            })
            """
        ) as? [String: Any]
        XCTAssertEqual(state?["currentTransform"] as? String, "")
        XCTAssertEqual(state?["futureTransform"] as? String, "")
        XCTAssertEqual(int(state?["actions"]), 0)
        XCTAssertEqual(int(state?["scrollX"]), 0)
        XCTAssertEqual(int(state?["scrollY"]), 0)
    }

    func testHorizontalColumnsAreClippedAndOneRequestPerformsOnlyOneTurnAction() async throws {
        let first = try await loadReaderFrame(Self.horizontalFixtureHTML)
        let frameSessionID = try XCTUnwrap(first["frameSessionID"] as? String)
        let firstPara = try XCTUnwrap(paragraphs(first).first)
        let firstText = try XCTUnwrap(firstPara["text"] as? String)
        let fullLengthValue = try await webView.evaluateJavaScript(
            "(document.getElementById('hpara').textContent || '').length"
        )
        let fullLength = try XCTUnwrap(int(fullLengthValue))
        XCTAssertLessThan(
            (firstText as NSString).length,
            fullLength / 2,
            "CSS columns 的屏外列不得被当作当前页正文"
        )

        _ = try await webView.evaluateJavaScript("window.CastReaderGoogleBooks.nextPage()")
        let second = try await waitForRendered(reason: "auto")
        XCTAssertEqual(second["frameSessionID"] as? String, frameSessionID)
        let secondPara = try XCTUnwrap(paragraphs(second).first)
        let secondText = try XCTUnwrap(secondPara["text"] as? String)
        XCTAssertNotEqual(secondText, firstText)
        XCTAssertGreaterThan(try XCTUnwrap(int(secondPara["sourceUTF16Start"])), 0)

        // 旧 ladder 会在慢动画落地前再发 ArrowRight，1.2s 后造成第二次翻页。
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let state = try await webView.evaluateJavaScript(
            "({ page: window.fixturePage, actions: window.turnActions })"
        ) as? [String: Any]
        XCTAssertEqual(int(state?["page"]), 1, "一次自动翻页请求不得越过一页")
        XCTAssertEqual(int(state?["actions"]), 1, "button 后不得再补发 key/hotspot")
        let requested = inbox.messages.last { $0.type == "googleBooksTurnRequested" }
        XCTAssertEqual(requested?.payload["frameSessionID"] as? String, frameSessionID)
        let changed = inbox.messages.last { $0.type == "googleBooksPageChanging" }
        XCTAssertEqual(changed?.payload["reason"] as? String, "auto")
        XCTAssertEqual(changed?.payload["phase"] as? String, "changed")
        XCTAssertEqual(changed?.payload["frameSessionID"] as? String, frameSessionID)
    }

    func testNativePlayerPageButtonsUseOneManualIdentityInBothDirections() async throws {
        let initial = try await loadReaderFrame()
        let frameSessionID = try XCTUnwrap(initial["frameSessionID"] as? String)
        let initialSignature = try XCTUnwrap(initial["signature"] as? String)

        let nextAccepted = try await webView.evaluateJavaScript(
            "window.CastReaderGoogleBooks.userPage({direction:'next'})"
        ) as? Bool
        XCTAssertEqual(nextAccepted, true)
        let nextPage = try await waitForRendered(reason: "manual")
        let nextSignature = try XCTUnwrap(nextPage["signature"] as? String)
        XCTAssertNotEqual(nextSignature, initialSignature)

        let nextIntent = try XCTUnwrap(
            inbox.messages.last {
                $0.type == "googleBooksPageChanging"
                    && ($0.payload["reason"] as? String) == "manual"
                    && ($0.payload["phase"] as? String) == "intent"
                    && ($0.payload["direction"] as? String) == "next"
            }
        )
        XCTAssertEqual(
            nextPage["manualIntentID"] as? String,
            nextIntent.payload["manualIntentID"] as? String
        )
        XCTAssertEqual(
            nextPage["baselineSignature"] as? String,
            nextIntent.payload["baselineSignature"] as? String
        )
        XCTAssertEqual(
            nextPage["originFrameSessionID"] as? String,
            frameSessionID
        )

        let previousAccepted = try await webView.evaluateJavaScript(
            "window.CastReaderGoogleBooks.userPage({direction:'prev'})"
        ) as? Bool
        XCTAssertEqual(previousAccepted, true)
        let previousPage = try await waitForRendered(reason: "manual")
        XCTAssertEqual(previousPage["signature"] as? String, initialSignature)

        let previousIntent = try XCTUnwrap(
            inbox.messages.last {
                $0.type == "googleBooksPageChanging"
                    && ($0.payload["reason"] as? String) == "manual"
                    && ($0.payload["phase"] as? String) == "intent"
                    && ($0.payload["direction"] as? String) == "prev"
            }
        )
        XCTAssertEqual(
            previousPage["manualIntentID"] as? String,
            previousIntent.payload["manualIntentID"] as? String
        )
        XCTAssertEqual(
            previousPage["baselineSignature"] as? String,
            nextSignature
        )
        let fixturePage = try await webView.evaluateJavaScript(
            "window.fixturePage"
        )
        XCTAssertEqual(int(fixturePage), 0)
        XCTAssertFalse(
            inbox.messages.contains { $0.type == "googleBooksTurnRequested" },
            "Native page buttons are manual navigation and must not consume the automatic-turn pipeline"
        )
    }

    func testLateAutomaticTurnKeepsStrictIdentityAfterJavaScriptTimeout() async throws {
        let initial = try await loadReaderFrame(Self.horizontalFixtureHTML)
        let frameSessionID = try XCTUnwrap(initial["frameSessionID"] as? String)
        let baseline = try XCTUnwrap(initial["signature"] as? String)
        let turnID = "native-turn-late-fixture"
        let failedExpectation = expectation(description: "javascript timeout")
        let renderedExpectation = expectation(description: "late automatic rendered")
        var failedPayload: [String: Any] = [:]
        var renderedPayload: [String: Any] = [:]
        inbox.onMessage = { type, payload in
            if type == "googleBooksTurnFailed" {
                failedPayload = payload
                failedExpectation.fulfill()
            } else if type == "rendered",
                      (payload["reason"] as? String) == "auto" {
                renderedPayload = payload
                renderedExpectation.fulfill()
            }
        }

        let turnIDLiteral = try javaScriptStringLiteral(turnID)
        let baselineLiteral = try javaScriptStringLiteral(baseline)
        let sessionLiteral = try javaScriptStringLiteral(frameSessionID)
        let accepted = try await webView.evaluateJavaScript(
            """
            (function () {
              window.__fixtureOriginalSetTimeout = window.setTimeout;
              window.setTimeout = function (callback, delay) {
                var args = Array.prototype.slice.call(arguments, 2);
                return window.__fixtureOriginalSetTimeout.apply(
                  window,
                  [callback, delay === 5200 ? 40 : delay].concat(args)
                );
              };
              return window.CastReaderGoogleBooks.nextPage({
                turnID: \(turnIDLiteral),
                baselineSignature: \(baselineLiteral),
                originFrameSessionID: \(sessionLiteral)
              });
            })()
            """
        ) as? Bool
        XCTAssertEqual(accepted, true)

        await fulfillment(
            of: [failedExpectation, renderedExpectation],
            timeout: 6,
            enforceOrder: true
        )
        inbox.onMessage = nil
        _ = try await webView.evaluateJavaScript(
            "window.setTimeout = window.__fixtureOriginalSetTimeout; true"
        )

        XCTAssertEqual(failedPayload["turnID"] as? String, turnID)
        XCTAssertEqual(failedPayload["baselineSignature"] as? String, baseline)
        XCTAssertEqual(
            failedPayload["originFrameSessionID"] as? String,
            frameSessionID
        )
        XCTAssertEqual(failedPayload["lateEligible"] as? Bool, true)
        XCTAssertEqual(renderedPayload["turnID"] as? String, turnID)
        XCTAssertEqual(
            renderedPayload["baselineSignature"] as? String,
            baseline,
            "wire baseline must stay immutable after the pending timer is cleared"
        )
        XCTAssertEqual(
            renderedPayload["originFrameSessionID"] as? String,
            frameSessionID
        )
        XCTAssertNotEqual(renderedPayload["signature"] as? String, baseline)
    }

    func testAutomaticTurnPreservesOpaqueBaselineWhitespace() async throws {
        let initial = try await loadReaderFrame(Self.horizontalFixtureHTML)
        let frameSessionID = try XCTUnwrap(initial["frameSessionID"] as? String)
        let turnID = "native-turn-opaque-baseline"
        let baseline = "0,66,430,593,66,24,775,visible text \t"
        let requestedExpectation = expectation(
            description: "automatic turn acknowledges exact identity"
        )
        let renderedExpectation = expectation(
            description: "automatic turn commits exact identity"
        )
        var requestedPayload: [String: Any] = [:]
        var renderedPayload: [String: Any] = [:]
        inbox.onMessage = { type, payload in
            if type == "googleBooksTurnRequested" {
                requestedPayload = payload
                requestedExpectation.fulfill()
            } else if type == "rendered",
                      (payload["reason"] as? String) == "auto" {
                renderedPayload = payload
                renderedExpectation.fulfill()
            }
        }

        let turnIDLiteral = try javaScriptStringLiteral(turnID)
        let baselineLiteral = try javaScriptStringLiteral(baseline)
        let sessionLiteral = try javaScriptStringLiteral(frameSessionID)
        let accepted = try await webView.evaluateJavaScript(
            """
            window.CastReaderGoogleBooks.nextPage({
              turnID: \(turnIDLiteral),
              baselineSignature: \(baselineLiteral),
              originFrameSessionID: \(sessionLiteral)
            })
            """
        ) as? Bool
        XCTAssertEqual(accepted, true)

        await fulfillment(
            of: [requestedExpectation, renderedExpectation],
            timeout: 6,
            enforceOrder: true
        )
        inbox.onMessage = nil

        for payload in [requestedPayload, renderedPayload] {
            XCTAssertEqual(payload["turnID"] as? String, turnID)
            XCTAssertEqual(
                payload["baselineSignature"] as? String,
                baseline,
                "page signatures are opaque wire identities; trim changes ownership"
            )
            XCTAssertEqual(
                payload["originFrameSessionID"] as? String,
                frameSessionID
            )
        }
    }

    func testEquivalentLateRefreshRetargetsDetectionBaselineWithoutChangingWireIdentity() async throws {
        let initial = try await loadReaderFrame(Self.horizontalFixtureHTML)
        let frameSessionID = try XCTUnwrap(initial["frameSessionID"] as? String)
        let wireBaseline = try XCTUnwrap(initial["signature"] as? String)
        let turnID = "native-turn-retarget-fixture"
        let turnIDLiteral = try javaScriptStringLiteral(turnID)
        let baselineLiteral = try javaScriptStringLiteral(wireBaseline)
        let sessionLiteral = try javaScriptStringLiteral(frameSessionID)

        let firstDepartureExpectation = expectation(description: "late reflow departure")
        var firstDeparture: [String: Any] = [:]
        inbox.onMessage = { type, payload in
            guard type == "rendered",
                  (payload["reason"] as? String) == "auto" else { return }
            firstDeparture = payload
            firstDepartureExpectation.fulfill()
        }
        _ = try await webView.evaluateJavaScript(
            """
            (function () {
              window.__fixtureOriginalSetTimeout = window.setTimeout;
              window.setTimeout = function (callback, delay) {
                var args = Array.prototype.slice.call(arguments, 2);
                var mappedDelay = delay;
                if (delay === 5200) mappedDelay = 40;
                else if (delay >= 1350 && delay <= 1900) {
                  // 此用例单独控制两次 geometry departure；屏蔽 fixture 自带动画，
                  // 避免 WKWebView timer coalescing 把“协议”测试变成“时序”测试。
                  mappedDelay = 30000;
                }
                return window.__fixtureOriginalSetTimeout.apply(
                  window,
                  [callback, mappedDelay].concat(args)
                );
              };
              var accepted = window.CastReaderGoogleBooks.nextPage({
                turnID: \(turnIDLiteral),
                baselineSignature: \(baselineLiteral),
                originFrameSessionID: \(sessionLiteral)
              });
              // 先让 5.2s（fixture 映射成 40ms）确认超时并留下 late token，
              // 再模拟一次不改变逻辑内容的 1px 排版重流。
              window.__fixtureOriginalSetTimeout(function () {
                document.getElementById('hseg').style.top = '1px';
              }, 100);
              return accepted;
            })()
            """
        )
        await fulfillment(of: [firstDepartureExpectation], timeout: 3)
        inbox.onMessage = nil

        let retargetedBaseline = try XCTUnwrap(
            firstDeparture["signature"] as? String
        )
        XCTAssertNotEqual(retargetedBaseline, wireBaseline)
        let retargetedLiteral = try javaScriptStringLiteral(retargetedBaseline)
        _ = try await webView.evaluateJavaScript(
            """
            window.CastReaderGoogleBooks.retargetTurnBaseline({
              turnID: \(turnIDLiteral),
              detectionBaselineSignature: \(retargetedLiteral)
            })
            """
        )

        let physicalDepartureExpectation = expectation(description: "physical departure after retarget")
        var physicalDeparture: [String: Any] = [:]
        inbox.onMessage = { type, payload in
            guard type == "rendered",
                  (payload["reason"] as? String) == "auto",
                  (payload["signature"] as? String) != retargetedBaseline else {
                return
            }
            physicalDeparture = payload
            physicalDepartureExpectation.fulfill()
        }
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('hseg').style.transform = 'translateX(-390px)'; true"
        )
        await fulfillment(of: [physicalDepartureExpectation], timeout: 3)
        inbox.onMessage = nil
        _ = try await webView.evaluateJavaScript(
            "window.setTimeout = window.__fixtureOriginalSetTimeout; true"
        )

        XCTAssertEqual(physicalDeparture["turnID"] as? String, turnID)
        XCTAssertEqual(
            physicalDeparture["baselineSignature"] as? String,
            wireBaseline,
            "retarget changes logical geometry only; strict native match uses immutable wire baseline"
        )
        XCTAssertEqual(
            physicalDeparture["originFrameSessionID"] as? String,
            frameSessionID
        )
    }

    func testRelayRoutesTurnToOnlyTheMatchingReaderFrameSession() async throws {
        let firstPayload = try await loadReaderFrame()
        let firstSessionID = try XCTUnwrap(firstPayload["frameSessionID"] as? String)

        let secondInbox = Inbox()
        let secondWebView = try makeReaderWebView(inbox: secondInbox)
        auxiliaryWebViews.append(secondWebView)
        let secondPayload = try await loadReaderFrame(
            Self.fixtureHTML,
            in: secondWebView,
            inbox: secondInbox
        )
        let secondSessionID = try XCTUnwrap(secondPayload["frameSessionID"] as? String)
        XCTAssertNotEqual(firstSessionID, secondSessionID, "每个 reader frame 必须有独立会话 id")

        let targetLiteral = try javaScriptStringLiteral(firstSessionID)
        let targetedTurn = """
        window.dispatchEvent(new MessageEvent('message', {
          origin: 'https://play.google.com',
          data: {
            __castreaderGB: 1,
            fn: 'gbNextPage',
            arg: { __gbFrameSessionID: \(targetLiteral) }
          }
        }))
        """
        _ = try await webView.evaluateJavaScript(targetedTurn)
        _ = try await secondWebView.evaluateJavaScript(targetedTurn)
        try await Task.sleep(nanoseconds: 700_000_000)

        let firstTransform = try await webView.evaluateJavaScript(
            "document.getElementById('seg').style.transform"
        ) as? String
        let secondTransform = try await secondWebView.evaluateJavaScript(
            "document.getElementById('seg').style.transform"
        ) as? String
        XCTAssertFalse(firstTransform?.isEmpty ?? true, "目标 frame 应执行一次翻页")
        XCTAssertTrue(secondTransform?.isEmpty ?? false, "非目标 sibling frame 不得翻页")
        XCTAssertTrue(
            inbox.messages.contains {
                $0.type == "googleBooksTurnRequested" &&
                ($0.payload["frameSessionID"] as? String) == firstSessionID
            }
        )
        XCTAssertFalse(
            secondInbox.messages.contains { $0.type == "googleBooksTurnRequested" },
            "同一条 relay 广播不得让两个 reader frame 同时动作"
        )

        // 目标缺失时翻页 fail-closed，不能退化为对所有 reader 广播。
        let untargetedTurn = """
        window.dispatchEvent(new MessageEvent('message', {
          origin: 'https://play.google.com',
          data: { __castreaderGB: 1, fn: 'gbNextPage', arg: {} }
        }))
        """
        _ = try await secondWebView.evaluateJavaScript(untargetedTurn)
        try await Task.sleep(nanoseconds: 200_000_000)
        let transformAfterUntargeted = try await secondWebView.evaluateJavaScript(
            "document.getElementById('seg').style.transform"
        ) as? String
        XCTAssertTrue(transformAfterUntargeted?.isEmpty ?? false)

        // 无可用翻页结果时，requested / failed 也必须和 rendered 使用同一个 session id。
        let secondTargetLiteral = try javaScriptStringLiteral(secondSessionID)
        let failureExpectation = expectation(description: "targeted turn failure carries frame session")
        var failurePayload: [String: Any] = [:]
        secondInbox.onMessage = { type, payload in
            guard type == "googleBooksTurnFailed" else { return }
            failurePayload = payload
            failureExpectation.fulfill()
        }
        _ = try await secondWebView.evaluateJavaScript(
            """
            (function () {
              document.getElementById('next').remove();
              window.__fixtureOriginalSetTimeout = window.setTimeout;
              window.setTimeout = function (callback, delay) {
                var args = Array.prototype.slice.call(arguments, 2);
                return window.__fixtureOriginalSetTimeout.apply(
                  window,
                  [callback, delay === 5200 ? 40 : delay].concat(args)
                );
              };
              window.dispatchEvent(new MessageEvent('message', {
                origin: 'https://play.google.com',
                data: {
                  __castreaderGB: 1,
                  fn: 'gbNextPage',
                  arg: { __gbFrameSessionID: \(secondTargetLiteral) }
                }
              }));
            })()
            """
        )
        await fulfillment(of: [failureExpectation], timeout: 2)
        secondInbox.onMessage = nil
        _ = try await secondWebView.evaluateJavaScript(
            "window.setTimeout = window.__fixtureOriginalSetTimeout; true"
        )
        XCTAssertEqual(failurePayload["frameSessionID"] as? String, secondSessionID)
        let failedRequest = secondInbox.messages.last { $0.type == "googleBooksTurnRequested" }
        XCTAssertEqual(failedRequest?.payload["frameSessionID"] as? String, secondSessionID)

        // 首次探测尚无 active session id，gbRefresh 仍允许无目标广播并回报自己的 id。
        let refreshExpectation = expectation(description: "untargeted gbRefresh probes reader")
        secondInbox.onMessage = { type, payload in
            guard type == "rendered",
                  (payload["reason"] as? String) == "refresh" else { return }
            XCTAssertEqual(payload["frameSessionID"] as? String, secondSessionID)
            refreshExpectation.fulfill()
        }
        _ = try await secondWebView.evaluateJavaScript(
            """
            window.dispatchEvent(new MessageEvent('message', {
              origin: 'https://play.google.com',
              data: { __castreaderGB: 1, fn: 'gbRefresh', arg: {} }
            }))
            """
        )
        await fulfillment(of: [refreshExpectation], timeout: 4)
        secondInbox.onMessage = nil
    }

    func testRelayTraversesAnIntermediateGoogleContainerOneHopAtATime() async throws {
        webView.loadHTMLString(
            "<!doctype html><html><body></body></html>",
            baseURL: URL(string: "https://play.google.com/books/reader?id=relay-fixture")
        )
        var shellReady = false
        for _ in 0..<20 where !shellReady {
            shellReady = (try await webView.evaluateJavaScript(
                "!!(window.CR && typeof window.CR.gbRefresh === 'function')"
            ) as? Bool) == true
            if !shellReady { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertTrue(shellReady)

        _ = try await webView.evaluateJavaScript(
            """
            (function () {
              var middle = document.createElement('iframe');
              middle.id = 'relay-middle';
              middle.srcdoc = '<!doctype html><html><body><iframe id="relay-leaf"></iframe></body></html>';
              document.body.appendChild(middle);
            })()
            """
        )
        try await Task.sleep(nanoseconds: 600_000_000)
        let middleReady = try await webView.evaluateJavaScript(
            """
            (function () {
              var middle = document.getElementById('relay-middle');
              return !!(middle && middle.contentWindow.CR &&
                typeof middle.contentWindow.CR.gbRefresh === 'function');
            })()
            """
        ) as? Bool
        XCTAssertEqual(middleReady, true, "中间 Google frame 必须安装逐层 forwarder")

        _ = try await webView.evaluateJavaScript(
            """
            (function () {
              var middle = document.getElementById('relay-middle');
              var leaf = middle.contentDocument.getElementById('relay-leaf');
              leaf.srcdoc = '<!doctype html><script>' +
                'window.__relayMessages=[];' +
                'window.addEventListener("message",function(e){' +
                  'if(e.data&&e.data.__castreaderGB===1)window.__relayMessages.push(e.data);' +
                '});' +
                '<\\/script>';
            })()
            """
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try await webView.evaluateJavaScript(
            "window.CR.gbRefresh({probe:'nested-hop'})"
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let forwarded = try await webView.evaluateJavaScript(
            """
            (function () {
              var middle = document.getElementById('relay-middle');
              var leaf = middle.contentDocument.getElementById('relay-leaf');
              var messages = leaf.contentWindow.__relayMessages || [];
              return messages.filter(function(message) {
                return message.fn === 'gbRefresh' &&
                  message.arg && message.arg.probe === 'nested-hop';
              }).length;
            })()
            """
        )
        XCTAssertEqual(int(forwarded), 1, "relay 必须逐层到达孙 reader，且每层只转发一次")
    }

    func testRelayHandsTurnIdentityOnlyToReplacementInTheSameBrowsingContext() async throws {
        webView.loadHTMLString(
            "<!doctype html><html><body></body></html>",
            baseURL: URL(string: "https://play.google.com/books/reader?id=relay-owner-fixture")
        )
        var shellReady = false
        for _ in 0..<20 where !shellReady {
            shellReady = (try await webView.evaluateJavaScript(
                "!!(window.CR && typeof window.CR.gbRefresh === 'function')"
            ) as? Bool) == true
            if !shellReady { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertTrue(shellReady)

        _ = try await webView.evaluateJavaScript(
            """
            (function () {
              function makeFrame(id) {
                var frame = document.createElement('iframe');
                frame.id = id;
                frame.srcdoc = '<!doctype html><script>' +
                  'window.__relayMessages=[];' +
                  'window.addEventListener("message",function(e){' +
                    'if(e.data&&e.data.__castreaderGB===1)' +
                      'window.__relayMessages.push(e.data);' +
                  '});' +
                  '<\\/script>';
                document.body.appendChild(frame);
              }
              makeFrame('turn-owner');
              makeFrame('preloaded-sibling');
            })()
            """
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let routingResult = try await webView.evaluateJavaScript(
            """
            (function () {
              var owner = document.getElementById('turn-owner').contentWindow;
              var sibling = document.getElementById('preloaded-sibling').contentWindow;
              var metadata = {
                turnID: 'strict-relay-turn',
                baselineSignature: 'baseline-a',
                originFrameSessionID: 'origin-reader-a'
              };
              window.dispatchEvent(new MessageEvent('message', {
                origin: 'https://books.googleusercontent.com',
                source: owner,
                data: { __castreaderGB: 1, kind: 'turn-owner', arg: metadata }
              }));
              window.dispatchEvent(new MessageEvent('message', {
                origin: 'https://books.googleusercontent.com',
                source: sibling,
                data: {
                  __castreaderGB: 1,
                  kind: 'reader-ready',
                  frameSessionID: 'sibling-new-session'
                }
              }));
              window.dispatchEvent(new MessageEvent('message', {
                origin: 'https://books.googleusercontent.com',
                source: owner,
                data: {
                  __castreaderGB: 1,
                  kind: 'reader-ready',
                  frameSessionID: 'owner-new-session'
                }
              }));
              return true;
            })()
            """
        ) as? Bool
        XCTAssertEqual(routingResult, true)
        try await Task.sleep(nanoseconds: 300_000_000)

        let result = try await webView.evaluateJavaScript(
            """
            (function () {
              function refreshes(id) {
                var frame = document.getElementById(id);
                return (frame.contentWindow.__relayMessages || []).filter(function (message) {
                  return message.fn === 'gbRefresh';
                });
              }
              var owner = refreshes('turn-owner');
              var sibling = refreshes('preloaded-sibling');
              return {
                ownerCount: owner.length,
                siblingCount: sibling.length,
                ownerArg: owner.length ? owner[0].arg : null
              };
            })()
            """
        ) as? [String: Any]
        XCTAssertEqual(int(result?["ownerCount"]), 1)
        XCTAssertEqual(int(result?["siblingCount"]), 0)
        let ownerArg = try XCTUnwrap(result?["ownerArg"] as? [String: Any])
        XCTAssertEqual(ownerArg["turnID"] as? String, "strict-relay-turn")
        XCTAssertEqual(
            ownerArg["baselineSignature"] as? String,
            "baseline-a"
        )
        XCTAssertEqual(
            ownerArg["originFrameSessionID"] as? String,
            "origin-reader-a"
        )
        XCTAssertEqual(
            ownerArg["__gbFrameSessionID"] as? String,
            "owner-new-session"
        )
    }

    func testPureViewportResizeIsRefreshRatherThanManualTurn() async throws {
        _ = try await loadReaderFrame()
        let expectation = expectation(description: "rendered:refresh-after-resize")
        var refreshed: [String: Any] = [:]
        var fulfilled = false
        inbox.onMessage = { type, payload in
            guard !fulfilled, type == "rendered",
                  (payload["reason"] as? String) == "refresh" else { return }
            fulfilled = true
            refreshed = payload
            expectation.fulfill()
        }

        webView.frame = CGRect(x: 0, y: 0, width: 430, height: 700)
        webView.layoutIfNeeded()
        await fulfillment(of: [expectation], timeout: 12)
        inbox.onMessage = nil

        XCTAssertFalse(paragraphs(refreshed).isEmpty)
        let changed = inbox.messages.last { $0.type == "googleBooksPageChanging" }
        XCTAssertEqual(changed?.payload["reason"] as? String, "refresh")
        XCTAssertEqual(changed?.payload["phase"] as? String, "changed")
        XCTAssertFalse(
            inbox.messages.contains {
                $0.type == "googleBooksPageChanging" &&
                ($0.payload["reason"] as? String) == "manual"
            },
            "纯 resize/reflow 不得触发手动翻页停播"
        )
    }

    func testCancelledManualRubberBandReturnsToBaselineWithoutPageCommit() async throws {
        let initial = try await loadReaderFrame()
        let frameSessionID = try XCTUnwrap(initial["frameSessionID"] as? String)
        let baseline = try XCTUnwrap(initial["signature"] as? String)
        let cancelledExpectation = expectation(description: "manual rubber-band cancelled")
        var cancelledPayload: [String: Any] = [:]
        inbox.onMessage = { type, payload in
            guard type == "googleBooksPageChanging",
                  (payload["phase"] as? String) == "cancelled" else { return }
            cancelledPayload = payload
            cancelledExpectation.fulfill()
        }

        _ = try await webView.evaluateJavaScript(
            """
            (function () {
              document.documentElement.setAttribute('data-cr-test-fixture', '1');
              window.CastReaderGoogleBooks.__fixtureBeginManualSwipe('next');
              var segment = document.getElementById('seg');
              setTimeout(function () {
                segment.style.transform = 'translateY(-96px)';
              }, 40);
              setTimeout(function () {
                segment.style.transform = '';
                window.CastReaderGoogleBooks.__fixtureEndManualSwipe();
              }, 430);
            })()
            """
        )
        await fulfillment(of: [cancelledExpectation], timeout: 4)
        inbox.onMessage = nil

        XCTAssertEqual(cancelledPayload["reason"] as? String, "manual")
        XCTAssertEqual(cancelledPayload["frameSessionID"] as? String, frameSessionID)
        XCTAssertEqual(cancelledPayload["signature"] as? String, baseline)
        XCTAssertEqual(cancelledPayload["baselineSignature"] as? String, baseline)
        let manualIntentID = try XCTUnwrap(
            cancelledPayload["manualIntentID"] as? String
        )
        XCTAssertFalse(manualIntentID.isEmpty)
        XCTAssertEqual(
            cancelledPayload["originFrameSessionID"] as? String,
            frameSessionID
        )
        XCTAssertFalse(
            inbox.messages.contains {
                $0.type == "googleBooksPageChanging" &&
                ($0.payload["reason"] as? String) == "manual" &&
                ($0.payload["phase"] as? String) == "changed"
            },
            "rubber-band 瞬时几何不得被宣布为真正换页"
        )
        XCTAssertFalse(
            inbox.messages.contains {
                $0.type == "rendered" &&
                ($0.payload["reason"] as? String) == "manual"
            },
            "回到 intent baseline 时不得提交一张伪新页"
        )
    }

    func testSlowManualSwipeDoesNotCommitWhileTheFingerIsStillDown() async throws {
        let initial = try await loadReaderFrame()
        let frameSessionID = try XCTUnwrap(initial["frameSessionID"] as? String)

        let began = try await webView.evaluateJavaScript(
            """
            (function () {
              document.documentElement.setAttribute('data-cr-test-fixture', '1');
              var began = window.CastReaderGoogleBooks.__fixtureBeginManualSwipe('next');
              document.getElementById('seg').style.transform = 'translateY(-96px)';
              return began;
            })()
            """
        ) as? Bool
        XCTAssertEqual(began, true)

        // 中间位移已稳定超过 native 旧版 2 秒恢复阈值，但手指仍按住；
        // 它不能被当成最终新页，也必须保留同一个 manual intent。
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertFalse(
            inbox.messages.contains {
                $0.type == "rendered" &&
                ($0.payload["reason"] as? String) == "manual"
            },
            "长按拖拽的稳定中间位移不得提交正文"
        )
        XCTAssertFalse(
            inbox.messages.contains {
                $0.type == "googleBooksPageChanging" &&
                ($0.payload["reason"] as? String) == "manual" &&
                ($0.payload["phase"] as? String) == "changed"
            },
            "手指抬起前不得宣布手动翻页完成"
        )

        let renderedExpectation = expectation(description: "slow manual swipe commits after release")
        var renderedPayload: [String: Any] = [:]
        inbox.onMessage = { type, payload in
            guard type == "rendered",
                  (payload["reason"] as? String) == "manual" else { return }
            renderedPayload = payload
            renderedExpectation.fulfill()
        }
        _ = try await webView.evaluateJavaScript(
            """
            (function () {
              document.getElementById('seg').style.transform = 'translateY(-700px)';
              return window.CastReaderGoogleBooks.__fixtureEndManualSwipe();
            })()
            """
        )
        await fulfillment(of: [renderedExpectation], timeout: 4)
        inbox.onMessage = nil

        XCTAssertEqual(renderedPayload["frameSessionID"] as? String, frameSessionID)
        let intent = try XCTUnwrap(
            inbox.messages.first {
                $0.type == "googleBooksPageChanging"
                    && ($0.payload["phase"] as? String) == "intent"
            }
        )
        let manualIntentID = try XCTUnwrap(
            intent.payload["manualIntentID"] as? String
        )
        XCTAssertEqual(
            renderedPayload["manualIntentID"] as? String,
            manualIntentID
        )
        XCTAssertEqual(
            renderedPayload["baselineSignature"] as? String,
            intent.payload["baselineSignature"] as? String
        )
        XCTAssertEqual(
            renderedPayload["originFrameSessionID"] as? String,
            frameSessionID
        )
        XCTAssertFalse(paragraphs(renderedPayload).isEmpty)
        let currentSignature = try await webView.evaluateJavaScript(
            "window.CastReaderGoogleBooks ? String(document.getElementById('seg').style.transform) : ''"
        ) as? String
        XCTAssertEqual(currentSignature, "translateY(-700px)")
        XCTAssertEqual(
            inbox.messages.filter {
                $0.type == "rendered" &&
                ($0.payload["reason"] as? String) == "manual"
            }.count,
            1,
            "一次慢滑只允许提交最终页一次"
        )
    }

    func testAlreadySpokenSentenceIsRemovedFromTheNextPage() async throws {
        let first = try await loadReaderFrame()
        let tail = try XCTUnwrap(paragraphs(first).last)
        let cursor = GoogleBooksCrossPageContract.consumedCursor(
            boundary: LiveWebPageSpeechBoundary(
                paragraphIndex: 0,
                visibleUTF16Offset: try XCTUnwrap(tail["boundaryUTF16Offset"] as? Int),
                speechUTF16Length: try XCTUnwrap(tail["extendedUTF16Length"] as? Int)
            ),
            sourceParagraphIndex: tail["sourceParagraphIndex"] as? Int,
            sourceVisibleEnd: tail["sourceUTF16End"] as? Int
        )

        _ = try await webView.evaluateJavaScript("window.CastReaderGoogleBooks.nextPage()")
        let second = try await waitForRendered(reason: "auto")

        let slices = paragraphs(second).enumerated().map { index, item in
            LiveWebPageSourceSlice(
                visibleParagraphIndex: index,
                sourceParagraphIndex: item["sourceParagraphIndex"] as? Int,
                sourceUTF16Start: item["sourceUTF16Start"] as? Int,
                sourceUTF16End: item["sourceUTF16End"] as? Int,
                text: (item["text"] as? String) ?? ""
            )
        }
        let consumption = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: slices,
            through: cursor
        )
        // 上一页已经把那句读完了；新页的同一段落不得整句重复朗读。
        let repeated = zip(slices, consumption.texts).contains { slice, text in
            slice.sourceParagraphIndex == cursor?.sourceParagraphIndex && text == slice.text
        }
        XCTAssertFalse(repeated, "跨页句子在新页被重复朗读了")
    }

    /// 真实 play.google.com 冒烟（需要网络，默认跳过）：
    ///   CASTREADER_NETWORK_SMOKE=1 xcodebuild test -only-testing:CastReaderTests/GoogleBooksWebBridgeTests/testRealPlayBooksShellInstallsRelayOnly
    /// 只验证注入分流：主帧必须装上转发壳，且**绝不**把阅读器 UI 当正文上报。
    /// 未登录时 Google 会显示「Can't open this book」，这条断言依然成立。
    func testRealPlayBooksShellInstallsRelayOnly() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CASTREADER_NETWORK_SMOKE"] == "1",
            "需要网络，按需手动运行"
        )
        webView.customUserAgent = GoogleBooksWebScripts.mobileSafariUserAgent
        let url = try XCTUnwrap(URL(
            string: "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PP1.w.1.1.9_250"
        ))
        webView.load(URLRequest(url: url))

        // 给 SPA 足够时间加载壳与跨源阅读帧。
        try await Task.sleep(nanoseconds: 12_000_000_000)

        let hasRelay = try await webView.evaluateJavaScript(
            "!!(window.CR && typeof window.CR.gbNextPage === 'function')"
        ) as? Bool
        XCTAssertEqual(hasRelay, true, "主帧必须安装 window.CR 转发壳")

        let renderedFromShell = inbox.messages.filter { $0.type == "rendered" }
        XCTAssertTrue(
            renderedFromShell.allSatisfy { ($0.payload["source"] as? String) == "google-books" },
            "阅读器 UI 被当成正文提取了：\(renderedFromShell.map { $0.payload["reason"] ?? "?" })"
        )
    }

    func testHighlightUsesTheVisibleParagraphOffset() async throws {
        let payload = try await loadReaderFrame()
        let paras = paragraphs(payload)
        let index = max(0, paras.count - 1)
        let text = try XCTUnwrap(paras[index]["text"] as? String)
        let probe = String(text.prefix(12))

        _ = try await webView.evaluateJavaScript(
            "window.CR.highlightRange({paragraphIndex:\(index),charStart:0,charEnd:\(probe.count)})"
        )
        let overlays = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.cr-hl-ov').length"
        ) as? Int
        XCTAssertEqual(overlays, 1, "高亮必须落在可见页内且只画当前范围")

        _ = try await webView.evaluateJavaScript("window.CR.clearHighlight()")
        let cleared = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.cr-hl-ov').length"
        ) as? Int
        XCTAssertEqual(cleared, 0)
    }

    func testAutomaticTurnClearsOldHighlightBeforeSlowAnimationStarts() async throws {
        let payload = try await loadReaderFrame(Self.horizontalFixtureHTML)
        let text = try XCTUnwrap(paragraphs(payload).first?["text"] as? String)
        let length = max(1, min(12, (text as NSString).length))

        _ = try await webView.evaluateJavaScript(
            "window.CR.highlightRange({paragraphIndex:0,charStart:0,charEnd:\(length)})"
        )
        let painted = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.cr-hl-ov').length"
        ) as? Int
        XCTAssertEqual(painted, 1)

        _ = try await webView.evaluateJavaScript(
            "window.CastReaderGoogleBooks.nextPage()"
        )
        let earlyState = try await webView.evaluateJavaScript(
            """
            ({
              overlays: document.querySelectorAll('.cr-hl-ov').length,
              page: window.fixturePage,
              transform: document.getElementById('hseg').style.transform
            })
            """
        ) as? [String: Any]
        XCTAssertEqual(earlyState?["overlays"] as? Int, 0)
        XCTAssertEqual(earlyState?["page"] as? Int, 0)
        XCTAssertEqual(
            earlyState?["transform"] as? String,
            "",
            "旧高亮必须在 1.35 秒慢动画真正开始前已经清掉"
        )
    }

    func testAReplacementExtractionCannotRetainAnOldOverlay() async throws {
        let payload = try await loadReaderFrame()
        let text = try XCTUnwrap(paragraphs(payload).first?["text"] as? String)
        let length = max(1, min(12, (text as NSString).length))
        _ = try await webView.evaluateJavaScript(
            "window.CR.highlightRange({paragraphIndex:0,charStart:0,charEnd:\(length)})"
        )
        let overlayCountBeforeReplacement = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.cr-hl-ov').length"
        ) as? Int
        XCTAssertEqual(overlayCountBeforeReplacement, 1)

        _ = try await webView.evaluateJavaScript(
            "window.CR.extract('refresh')"
        )
        let overlayCountAfterReplacement = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.cr-hl-ov').length"
        ) as? Int
        XCTAssertEqual(
            overlayCountAfterReplacement,
            0,
            "重建页面 DOM 映射时必须同步销毁上一映射的 body overlay"
        )
    }

    func testAbsoluteCarryHighlightRangeDoesNotDoubleApplyThePageOffset() async throws {
        _ = try await loadReaderFrame()
        _ = try await webView.evaluateJavaScript("window.CastReaderGoogleBooks.nextPage()")
        let payload = try await waitForRendered(reason: "auto")
        let paras = paragraphs(payload)
        let pair = try XCTUnwrap(paras.enumerated().first {
            (int($0.element["sourceUTF16Start"]) ?? 0) > 0 &&
            (($0.element["text"] as? NSString)?.length ?? 0) > 180
        })
        let index = pair.offset
        let para = pair.element
        let sourceStart = try XCTUnwrap(int(para["sourceUTF16Start"]))
        let absoluteStart = sourceStart + 40
        let initOverride = sourceStart + 120

        let matched = try await webView.evaluateJavaScript(
            """
            (function () {
              window.CR.init({segments:[{
                paragraphIndex:\(index),
                text:'',
                domCharOffset:\(initOverride)
              }]});
              window.CR.highlightRange({
                paragraphIndex:\(index),
                charStart:0,
                charEnd:12,
                domCharStart:\(absoluteStart),
                domCharEnd:\(absoluteStart + 12)
              });
              var el = document.querySelector('[data-cr-para="\(index)"]');
              function rangeRect(start, end) {
                var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
                var node, offset = 0, startNode = null, startOff = 0, endNode = null, endOff = 0;
                while ((node = walker.nextNode())) {
                  var len = (node.textContent || '').length;
                  if (!startNode && offset + len > start) {
                    startNode = node; startOff = start - offset;
                  }
                  if (offset + len >= end) {
                    endNode = node; endOff = end - offset; break;
                  }
                  offset += len;
                }
                if (!startNode || !endNode) return null;
                var range = document.createRange();
                range.setStart(startNode, startOff); range.setEnd(endNode, endOff);
                return range.getClientRects()[0] || null;
              }
              var expected = rangeRect(\(absoluteStart), \(absoluteStart + 12));
              var overlay = document.querySelector('.cr-hl-ov');
              if (!expected || !overlay) return false;
              var actual = overlay.getBoundingClientRect();
              return Math.abs(actual.left - expected.left) < 2 &&
                Math.abs(actual.top - expected.top) < 2 &&
                Math.abs(actual.width - expected.width) < 2 &&
                Math.abs(actual.height - expected.height) < 2;
            })()
            """
        ) as? Bool
        XCTAssertEqual(
            matched,
            true,
            "跨页句子的绝对 DOM range 必须覆盖 init offset，不能再重复叠加当前页起点"
        )
    }

    func testNonzeroOffsetMarkAndInitOverrideStayOnTheVisiblePage() async throws {
        _ = try await loadReaderFrame()
        _ = try await webView.evaluateJavaScript("window.CastReaderGoogleBooks.nextPage()")
        let payload = try await waitForRendered(reason: "auto")
        let paras = paragraphs(payload)
        let pair = try XCTUnwrap(paras.enumerated().first {
            (int($0.element["sourceUTF16Start"]) ?? 0) > 0 &&
            (($0.element["text"] as? NSString)?.length ?? 0) > 80
        })
        let index = pair.offset
        let para = pair.element
        let sourceStart = try XCTUnwrap(int(para["sourceUTF16Start"]))
        let text = try XCTUnwrap(para["text"] as? String)
        let delta = min(120, max(40, (text as NSString).length / 3))
        let override = sourceStart + delta

        let matched = try await webView.evaluateJavaScript(
            """
            (function () {
              window.CR.init({segments:[{
                paragraphIndex:\(index),
                text:'',
                domCharOffset:\(override)
              }]});
              window.CR.showMark({
                id:'offset-mark',
                paragraphIndex:\(index),
                charStart:0,
                charEnd:12,
                action:'underline',
                seed:17
              });
              var el = document.querySelector('[data-cr-para="\(index)"]');
              var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
              var node, offset = 0, startNode = null, startOff = 0, endNode = null, endOff = 0;
              while ((node = walker.nextNode())) {
                var len = (node.textContent || '').length;
                if (!startNode && offset + len > \(override)) {
                  startNode = node; startOff = \(override) - offset;
                }
                if (offset + len >= \(override + 12)) {
                  endNode = node; endOff = \(override + 12) - offset; break;
                }
                offset += len;
              }
              var range = document.createRange();
              range.setStart(startNode, startOff); range.setEnd(endNode, endOff);
              var expected = range.getClientRects()[0];
              var path = document.querySelector('[data-cr-marks] path');
              if (!expected || !path) return false;
              var actual = path.getBoundingClientRect();
              var expectedCenterY = (expected.top + expected.bottom) / 2;
              var actualCenterY = (actual.top + actual.bottom) / 2;
              return actual.right > 0 && actual.left < innerWidth &&
                actual.bottom > 0 && actual.top < innerHeight &&
                Math.abs(actual.left - expected.left) < 14 &&
                Math.abs(actualCenterY - expectedCenterY) < expected.height;
            })()
            """
        ) as? Bool
        XCTAssertEqual(
            matched,
            true,
            "showMark 必须叠加 CR.init 覆盖后的绝对 DOM UTF-16 offset，而不是画到上一页"
        )
    }

    func testSourceParagraphIdentitySurvivesDOMCloneAndRerender() async throws {
        let first = try await loadReaderFrame()
        let before = paragraphs(first).compactMap { int($0["sourceParagraphIndex"]) }
        XCTAssertFalse(before.isEmpty)

        let value = try await webView.evaluateJavaScript(
            """
            (function () {
              var oldSegment = document.getElementById('seg');
              var clone = oldSegment.cloneNode(true);
              clone.removeAttribute('data-cr-gb-src');
              clone.removeAttribute('data-cr-para');
              clone.querySelectorAll('[data-cr-gb-src],[data-cr-para]').forEach(function (el) {
                el.removeAttribute('data-cr-gb-src');
                el.removeAttribute('data-cr-para');
              });
              oldSegment.replaceWith(clone);
              window.CR.extract('refresh');
              return window.__crLastRendered;
            })()
            """
        )
        let rerendered = value as? [[String: Any]] ?? []
        let after = rerendered.compactMap { int($0["sourceParagraphIndex"]) }
        XCTAssertEqual(after, before, "同一 segment 的 DOM clone 不得获得新的来源段落 id")
    }
}
