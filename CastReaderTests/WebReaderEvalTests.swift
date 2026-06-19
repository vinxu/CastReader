//
//  WebReaderEvalTests.swift
//  CastReaderTests
//
//  WebView 阅读器自测：在真实 WKWebView（模拟器 WebKit）里加载测试 HTML、注入 app bundle 的扩展 JS，
//  数值化验证 M1 链路：①正文提取段落数 ②CSS Custom Highlight API 在 WKWebView 可用 ③CR.init 不抛
//  ④句子级高亮生效（CSS.highlights.size>0）⑤解读手写标注 SVG 渲染（需 layout，best-effort）。
//

import XCTest
import WebKit
@testable import CastReader

@MainActor
final class WebReaderEvalTests: XCTestCase {

    // 接近真实微信文章的结构：标题 h1/h2 + 署名 + 引用块 + 多段正文。
    private let testHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>t</title></head><body>
    <article>
    <h1>用 Fable 5 设计循环</h1>
    <p>Original 硅识AI 2026年6月10日</p>
    <h2>Claude Fable 5 把模型用到极致：自我纠正循环与记忆</h2>
    <blockquote><p>本文编译自工程师分享的长文，介绍两条有效技巧。文中实验数据与结论均来自原作者，供参考。</p></blockquote>
    <p>像 Claude Fable 5 这样的模型，已经改变了我们的工作方式。我想分享两条技巧，帮助你把模型用到极致。</p>
    <p>第二段正文，用于验证句子级高亮在多段之间覆盖式推进，前一段高亮应被覆盖、不累积。</p>
    </article>
    </body></html>
    """

    func testWebReaderPipeline() async throws {
        let js = try XCTUnwrap(WebReaderView.loadBundleJS(), "WebAssets/bundle.js 未打进 app bundle")

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)

        // 加到真实 window 以触发 layout（标注 getClientRects 需要）。
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadHTMLString(testHTML, baseURL: URL(string: "https://example.com/article"))

        // ① 等正文提取（bundle 注入后 ready→doExtract）
        var rendered = -1
        for _ in 0..<50 {
            if await webView.jsBool("typeof window.__crLastRendered !== 'undefined'") {
                rendered = await webView.jsInt("window.__crLastRendered.length")
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("[EVAL][Web] rendered paragraphs=\(rendered)")
        let extractMethod = await webView.jsString("window.__crExtractMethod || '?'")
        print("[EVAL][Web] extract method=\(extractMethod)（zone=Visual Zone 生效；read-all/vtb=回退）")
        XCTAssertGreaterThanOrEqual(rendered, 3, "正文提取段落数过少（extractor 未工作）")

        // ② CSS Custom Highlight API 可用性（决定句/词高亮主路径成立）
        let hasAPI = await webView.jsBool("typeof CSS !== 'undefined' && !!CSS.highlights")
        print("[EVAL][Web] CSS.highlights available=\(hasAPI)")
        XCTAssertTrue(hasAPI, "WKWebView 不支持 CSS Custom Highlight API（需降级路径）")

        // ③④ CR.init + 句子级高亮
        let paras = await webView.jsString("JSON.stringify((window.__crLastRendered||[]).map(p=>({paragraphIndex:p.paragraphIndex,text:p.text})))")
        await webView.jsRun("window.CR.init({\"segments\":\(paras),\"color\":\"#FD5F01\"})")

        // 探针：返回当前 overlay 高亮所在段的 data-cr-para（overlay pointer-events:none，elementFromPoint 穿透到文字）。
        let probe = "(()=>{var o=document.querySelector('.cr-hl-ov');if(!o)return'-none';var r=o.getBoundingClientRect();var e=document.elementFromPoint(r.left+2,r.top+2);var p=e&&e.closest&&e.closest('[data-cr-para]');return p?p.getAttribute('data-cr-para'):'-noattr'})()"

        // 遍历每段 highlightRange，断言 overlay 不累积（每次清旧）+ 落在当前段。
        let n = await webView.jsInt("(window.__crLastRendered||[]).length")
        var maxOv = 0
        var lastPara = "-"
        var allOnTarget = true
        for i in 0..<n {
            await webView.jsRun("var P=window.__crLastRendered||[];if(P[\(i)])window.CR.highlightRange({paragraphIndex:P[\(i)].paragraphIndex,charStart:0,charEnd:6})")
            let ov = await webView.jsInt("document.querySelectorAll('.cr-hl-ov').length")
            let cur = await webView.jsString(probe)
            maxOv = max(maxOv, ov)
            lastPara = cur
            if cur != String(i) && cur != "-none" && cur != "-noattr" { allOnTarget = false }
        }
        print("[EVAL][Web] 遍历\(n)段：overlay 最大数=\(maxOv)，末段=\(lastPara)，逐段落点正确=\(allOnTarget)")
        XCTAssertGreaterThan(maxOv, 0, "overlay 未画出高亮（高亮看不见）")
        XCTAssertLessThan(maxOv, 8, "overlay 累积未清除（真机每段顶部残留橙线的根因）")
        XCTAssertTrue(allOnTarget, "某段 overlay 未落在对应段")

        // clearHighlight 必须把所有 overlay div 清空（不留残留）。
        await webView.jsRun("window.CR.clearHighlight()")
        let leftover = await webView.jsInt("document.querySelectorAll('.cr-hl-ov').length")
        print("[EVAL][Web] clearHighlight 后残留 overlay=\(leftover)")
        XCTAssertEqual(leftover, 0, "clearHighlight 后仍有 overlay 残留")

        // ⑤ 解读手写标注：对最长段整段下划线，验证跨行逐行画（path 数==视觉行数；修复前只画第一行=1）。
        let markIdx = await webView.jsInt("(()=>{var P=window.__crLastRendered||[];var i0=0,ml=0;P.forEach((p,i)=>{var l=(p.text||'').length;if(l>ml){ml=l;i0=i}});return i0})()")
        let markLen = await webView.jsInt("(window.__crLastRendered[\(markIdx)]||{}).text ? window.__crLastRendered[\(markIdx)].text.length : 0")
        let lineCount = await webView.jsInt("(()=>{var el=document.querySelector('[data-cr-para=\"\(markIdx)\"]');if(!el)return 0;var r=document.createRange();r.selectNodeContents(el);return Array.from(r.getClientRects()).filter(rc=>rc.width>=2&&rc.height>=2).length})()")
        await webView.jsRun("window.CR.clearMarks()")
        await webView.jsRun("window.CR.showMark({\"id\":\"mUL\",\"paragraphIndex\":\(markIdx),\"charStart\":0,\"charEnd\":\(markLen),\"action\":\"underline\",\"seed\":12345})")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let svgPaths = await webView.jsInt("document.querySelectorAll('svg[data-cr-marks] path').length")
        print("[EVAL][Web] 跨行下划线：最长段#\(markIdx) len=\(markLen) 视觉行数=\(lineCount) underline path 数=\(svgPaths)")
        XCTAssertGreaterThanOrEqual(lineCount, 2, "最长段应跨行（否则验证不到跨行绘制）")
        XCTAssertEqual(svgPaths, lineCount, "下划线 path 数应=视觉行数（跨行逐行画；修复前只画第一行 path=1 → 换行处断）")
    }

    /// DOCX 本地渲染端到端：空页注入 bundle → CR.renderDocx(最小 DOCX base64) → mammoth 转 HTML → Visual Zone 提取。
    func testDocxRender() async throws {
        let js = try XCTUnwrap(WebReaderView.loadBundleJS(), "WebAssets/bundle.js 未打进 app bundle")
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>", baseURL: URL(string: "https://castreader.local/docx"))

        var ready = false
        for _ in 0..<60 {
            if await webView.jsBool("typeof window.CR !== 'undefined' && typeof window.CR.renderDocx === 'function'") { ready = true; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(ready, "[Docx] CR.renderDocx 未注入（bundle 未含 mammoth？）")

        let docxB64 = "UEsDBBQAAAAAAPCV0VzMVIwQnAEAAJwBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04Ij8+PFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMiPjxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9uc2hpcHMreG1sIi8+PERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz48T3ZlcnJpZGUgUGFydE5hbWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJvY2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+PC9UeXBlcz5QSwMEFAAAAAAA8JXRXDZX3twYAQAAGAEAAAsAAABfcmVscy8ucmVsczw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04Ij8+PFJlbGF0aW9uc2hpcHMgeG1sbnM9Imh0dHA6Ly9zY2hlbWFzLm9wZW54bWxmb3JtYXRzLm9yZy9wYWNrYWdlLzIwMDYvcmVsYXRpb25zaGlwcyI+PFJlbGF0aW9uc2hpcCBJZD0icklkMSIgVHlwZT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcy9vZmZpY2VEb2N1bWVudCIgVGFyZ2V0PSJ3b3JkL2RvY3VtZW50LnhtbCIvPjwvUmVsYXRpb25zaGlwcz5QSwMEFAAAAAAA8JXRXIUt8ZKFAQAAhQEAABEAAAB3b3JkL2RvY3VtZW50LnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04Ij8+PHc6ZG9jdW1lbnQgeG1sbnM6dz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL3dvcmRwcm9jZXNzaW5nbWwvMjAwNi9tYWluIj48dzpib2R5Pjx3OnA+PHc6cj48dzp0PkRPQ1jmnKzlnLDmuLLmn5PmtYvor5XmoIfpopg8L3c6dD48L3c6cj48L3c6cD48dzpwPjx3OnI+PHc6dD7nrKzkuIDmrrXmraPmlofnlKjmnaXpqozor4FtYW1tb3Ro6L2sSFRNTOWQjuiDveiiq1Zpc3VhbFpvbmXmj5Dlj5blubbmnJfor7s8L3c6dD48L3c6cj48L3c6cD48dzpwPjx3OnI+PHc6dD7nrKzkuozmrrXmraPmlofnoa7orqTlpJrmrrXokL3pg73lnKg8L3c6dD48L3c6cj48L3c6cD48L3c6Ym9keT48L3c6ZG9jdW1lbnQ+UEsBAhQDFAAAAAAA8JXRXMxUjBCcAQAAnAEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAAAADwldFcNlfe3BgBAAAYAQAACwAAAAAAAAAAAAAAgAHNAQAAX3JlbHMvLnJlbHNQSwECFAMUAAAAAADwldFchS3xkoUBAACFAQAAEQAAAAAAAAAAAAAAgAEOAwAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAMAAwC5AAAAwgQAAAAA"
        await webView.jsRun("window.CR.renderDocx({base64:'\(docxB64)'})")

        var rendered = -1
        for _ in 0..<60 {
            if await webView.jsBool("typeof window.__crLastRendered !== 'undefined' && window.__crLastRendered.length > 0") {
                rendered = await webView.jsInt("window.__crLastRendered.length"); break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // 诊断：renderDocx 内部状态（cr-dbg2 红条文本：noConv/ERR/EXC/ok）
        let dbg = await webView.jsString("(document.getElementById('cr-dbg2')||{}).textContent || ''")
        let pCount = await webView.jsInt("document.querySelectorAll('p,article,h1,h2').length")
        let allText = await webView.jsString("(window.__crLastRendered||[]).map(p=>p.text).join(' ')")
        print("[EVAL][Docx] rendered=\(rendered) dbg=[\(dbg)] p/article=\(pCount) 含正文=\(allText.contains("第一段正文"))")
        XCTAssertGreaterThanOrEqual(rendered, 2, "[Docx] mammoth 渲染后 Zone 提取段落过少")
        XCTAssertTrue(allText.contains("第一段正文") || allText.contains("第二段正文"), "[Docx] 提取内容不含 DOCX 正文（mammoth 转换失败？）")
    }

    /// 词级高亮（英文）：JS 在 DOM 虚拟全文按词文本前向匹配。词数组含大小写/标点差异，验证回退后命中率 ≥0.9。
    func testWordHighlight() async throws {
        let js = try XCTUnwrap(WebReaderView.loadBundleJS(), "WebAssets/bundle.js 未打进 app bundle")
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        let html = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body><article><p>The Investor shall have the right to purchase its pro rata share of Standard Preference Shares being sold in the Equity Financing.</p></article></body></html>"
        webView.loadHTMLString(html, baseURL: URL(string: "https://castreader.local/wh"))

        var ready = false
        for _ in 0..<50 {
            if await webView.jsBool("typeof window.CR !== 'undefined' && typeof window.CR.highlightWord === 'function' && (window.__crLastRendered||[]).length>0") { ready = true; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(ready, "[WH] CR.highlightWord / 段落未就绪")

        // 模拟 TTS 词（混大小写 + 带标点，测匹配回退）
        let words = ["the","Investor","shall","have","THE","right","to","purchase","its","pro","rata","share,","of","standard","preference","Shares","being","sold","in","the","equity","financing."]
        let wordsJSON = (try? String(data: JSONSerialization.data(withJSONObject: words), encoding: .utf8)) ?? "[]"
        var hit = 0
        for i in 0..<words.count {
            await webView.jsRun("window.CR.highlightWord({paragraphIndex:0,segSeq:0,words:\(wordsJSON),wordIndex:\(i)})")
            let ov = await webView.jsInt("document.querySelectorAll('.cr-hl-ov').length")
            if ov > 0 { hit += 1 } else { print("[EVAL][WH] MISS word#\(i)=\(words[i])") }
        }
        let rate = Double(hit) / Double(words.count)
        print("[EVAL][WH] 词级命中 \(hit)/\(words.count) rate=\(String(format: "%.2f", rate))")
        XCTAssertGreaterThanOrEqual(rate, 0.9, "[WH] 词级高亮命中率过低（应≥0.9，对齐扩展 DOM 前向匹配）")
    }

    /// EPUB 本地渲染端到端：空页注入 bundle → CR.renderEpub(最小 EPUB base64) → epub.js 逐章 HTML → Visual Zone 提取。
    func testEpubRender() async throws {
        let js = try XCTUnwrap(WebReaderView.loadBundleJS(), "WebAssets/bundle.js 未打进 app bundle")
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>", baseURL: URL(string: "https://castreader.local/epub"))

        var ready = false
        for _ in 0..<60 {
            if await webView.jsBool("typeof window.CR !== 'undefined' && typeof window.CR.renderEpub === 'function'") { ready = true; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(ready, "[Epub] CR.renderEpub 未注入（bundle 未含 epubjs？）")

        let epubB64 = "UEsDBBQAAAAAAAAAIQBvYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAAAABAv9FcHgvXyd0AAADdAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWw8P3htbCB2ZXJzaW9uPSIxLjAiPz48Y29udGFpbmVyIHZlcnNpb249IjEuMCIgeG1sbnM9InVybjpvYXNpczpuYW1lczp0YzpvcGVuZG9jdW1lbnQ6eG1sbnM6Y29udGFpbmVyIj48cm9vdGZpbGVzPjxyb290ZmlsZSBmdWxsLXBhdGg9Ik9FQlBTL2NvbnRlbnQub3BmIiBtZWRpYS10eXBlPSJhcHBsaWNhdGlvbi9vZWJwcy1wYWNrYWdlK3htbCIvPjwvcm9vdGZpbGVzPjwvY29udGFpbmVyPlBLAwQUAAAAAABAv9FcmQkqgOgBAADoAQAAEQAAAE9FQlBTL2NvbnRlbnQub3BmPD94bWwgdmVyc2lvbj0iMS4wIj8+PHBhY2thZ2UgeG1sbnM9Imh0dHA6Ly93d3cuaWRwZi5vcmcvMjAwNy9vcGYiIHZlcnNpb249IjIuMCIgdW5pcXVlLWlkZW50aWZpZXI9ImlkIj48bWV0YWRhdGEgeG1sbnM6ZGM9Imh0dHA6Ly9wdXJsLm9yZy9kYy9lbGVtZW50cy8xLjEvIj48ZGM6dGl0bGU+dGVzdDwvZGM6dGl0bGU+PGRjOmlkZW50aWZpZXIgaWQ9ImlkIj50ZXN0PC9kYzppZGVudGlmaWVyPjxkYzpsYW5ndWFnZT56aDwvZGM6bGFuZ3VhZ2U+PC9tZXRhZGF0YT48bWFuaWZlc3Q+PGl0ZW0gaWQ9ImMxIiBocmVmPSJjaDEueGh0bWwiIG1lZGlhLXR5cGU9ImFwcGxpY2F0aW9uL3hodG1sK3htbCIvPjxpdGVtIGlkPSJjMiIgaHJlZj0iY2gyLnhodG1sIiBtZWRpYS10eXBlPSJhcHBsaWNhdGlvbi94aHRtbCt4bWwiLz48L21hbmlmZXN0PjxzcGluZT48aXRlbXJlZiBpZHJlZj0iYzEiLz48aXRlbXJlZiBpZHJlZj0iYzIiLz48L3NwaW5lPjwvcGFja2FnZT5QSwMEFAAAAAAAQL/RXGYj1Wv+AAAA/gAAAA8AAABPRUJQUy9jaDEueGh0bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJ1dGYtOCI/PjwhRE9DVFlQRSBodG1sPjxodG1sIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5L3hodG1sIj48aGVhZD48dGl0bGU+YzE8L3RpdGxlPjwvaGVhZD48Ym9keT48aDE+56ys5LiA56ug5qCH6aKYPC9oMT48cD7nrKzkuIDnq6DmraPmlofnlKjmnaXpqozor4FlcHViLmpz6Kej5p6Q5ZCO6IO96KKrVmlzdWFsWm9uZeaPkOWPluW5tuacl+ivu+OAgjwvcD48L2JvZHk+PC9odG1sPlBLAwQUAAAAAABAv9Fckmmd+tUAAADVAAAADwAAAE9FQlBTL2NoMi54aHRtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9InV0Zi04Ij8+PCFET0NUWVBFIGh0bWw+PGh0bWwgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGh0bWwiPjxoZWFkPjx0aXRsZT5jMjwvdGl0bGU+PC9oZWFkPjxib2R5PjxoMT7nrKzkuoznq6DmoIfpopg8L2gxPjxwPuesrOS6jOeroOato+aWh+ehruiupOWkmueroOmDveWcqOOAgjwvcD48L2JvZHk+PC9odG1sPlBLAQIUAxQAAAAAAAAAIQBvYassFAAAABQAAAAIAAAAAAAAAAAAAACAAQAAAABtaW1ldHlwZVBLAQIUAxQAAAAAAEC/0VweC9fJ3QAAAN0AAAAWAAAAAAAAAAAAAACAAToAAABNRVRBLUlORi9jb250YWluZXIueG1sUEsBAhQDFAAAAAAAQL/RXJkJKoDoAQAA6AEAABEAAAAAAAAAAAAAAIABSwEAAE9FQlBTL2NvbnRlbnQub3BmUEsBAhQDFAAAAAAAQL/RXGYj1Wv+AAAA/gAAAA8AAAAAAAAAAAAAAIABYgMAAE9FQlBTL2NoMS54aHRtbFBLAQIUAxQAAAAAAEC/0VySaZ361QAAANUAAAAPAAAAAAAAAAAAAACAAY0EAABPRUJQUy9jaDIueGh0bWxQSwUGAAAAAAUABQAzAQAAjwUAAAAA"
        await webView.jsRun("window.CR.renderEpub({base64:'\(epubB64)'})")

        var rendered = -1
        for _ in 0..<80 {   // epub.js 解 zip + 逐章 load 较慢，等久一点
            if await webView.jsBool("typeof window.__crLastRendered !== 'undefined' && window.__crLastRendered.length > 0") {
                rendered = await webView.jsInt("window.__crLastRendered.length"); break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let dbg = await webView.jsString("(document.querySelector('article')||{}).innerHTML ? 'hasArticle' : 'noArticle'")
        let allText = await webView.jsString("(window.__crLastRendered||[]).map(p=>p.text).join(' ')")
        print("[EVAL][Epub] rendered=\(rendered) \(dbg) 含正文=\(allText.contains("第一章正文"))")
        XCTAssertGreaterThanOrEqual(rendered, 2, "[Epub] epub.js 渲染后 Zone 提取段落过少")
        XCTAssertTrue(allText.contains("第一章正文") || allText.contains("第二章"), "[Epub] 提取不含 EPUB 正文（epub.js 解析失败？）")
    }

    /// 把 Swift 字符串编码成合法 JS 字符串字面量。
    private func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // 去掉 [ ]
    }
}

private extension WKWebView {
    func jsInt(_ js: String) async -> Int {
        await withCheckedContinuation { c in
            evaluateJavaScript(js) { r, _ in c.resume(returning: (r as? NSNumber)?.intValue ?? -1) }
        }
    }
    func jsBool(_ js: String) async -> Bool {
        await withCheckedContinuation { c in
            evaluateJavaScript(js) { r, _ in c.resume(returning: (r as? Bool) ?? false) }
        }
    }
    func jsString(_ js: String) async -> String {
        await withCheckedContinuation { c in
            evaluateJavaScript(js) { r, _ in c.resume(returning: (r as? String) ?? "") }
        }
    }
    func jsRun(_ js: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            evaluateJavaScript(js) { _, _ in c.resume() }
        }
    }
}
