//
//  EpubNativeEngineTests.swift
//  CastReaderTests
//
//  EPUB 原生解析自检（ZIPFoundation + SwiftSoup）：用真实 EPUB 验证段落/图片/文本健全/id 连续性。
//  对齐 memory「eval-harness-readaloud-explain：改完先跑」。
//

import XCTest
@testable import CastReader

final class EpubNativeEngineTests: XCTestCase {

    /// 候选真实 EPUB（host 绝对路径；iOS 模拟器单测可读 mac 文件系统）。带图古登堡书优先（验证图片解码）。
    private func loadSampleEpub() -> (data: Data, name: String)? {
        let candidates = [
            "/Users/xuxuheng/Downloads/pg4300-images.epub",      // Ulysses（带图）
            "/Users/xuxuheng/Downloads/pg26110-images-3.epub",
            "/Users/xuxuheng/Downloads/pg25852-images.epub",
            "/Users/xuxuheng/Downloads/pg52323-images.epub",
            "/Users/xuxuheng/Downloads/pg43740-images.epub",
            "/Users/xuxuheng/Documents/CastReader-Android/app/src/main/assets/cr_test.epub",
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return (data, (path as NSString).lastPathComponent)
            }
        }
        return nil
    }

    func testParseRealEpub() throws {
        guard let sample = loadSampleEpub() else {
            throw XCTSkip("无可用测试 EPUB（host 路径不可达，跳过）")
        }
        guard let parsed = EpubNativeEngine.parse(data: sample.data, fallbackTitle: sample.name) else {
            return XCTFail("EPUB 解析返回 nil：\(sample.name)")
        }

        let total = parsed.paragraphs.count
        let imageCount = parsed.paragraphs.filter { $0.type == .image }.count
        let imageWithData = parsed.paragraphs.filter { $0.type == .image && $0.imageData != nil }.count
        let readable = parsed.paragraphs.filter { $0.type.isReadable && !$0.text.isEmpty }
        let headings = parsed.paragraphs.filter { if case .heading = $0.type { return true }; return false }.count

        print("📗 EPUB[\(sample.name)] title=\(parsed.title ?? "nil") 段落=\(total) 可朗读=\(readable.count) 标题=\(headings) 图片段=\(imageCount)(有字节 \(imageWithData))")
        print("📗 前 6 段可朗读文本:")
        for p in readable.prefix(6) { print("   [\(p.id)] \(p.text.prefix(90))") }

        XCTAssertGreaterThan(total, 0, "段落数为 0")
        XCTAssertGreaterThan(readable.count, 0, "无可朗读段落")

        // 文本健全性：前 20 段可朗读文本应含字母或汉字（非全乱码/全符号 → 证明解码 + DOM 抽取正确）
        let joined = readable.prefix(20).map(\.text).joined()
        let hasLetters = joined.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        XCTAssertTrue(hasLetters, "解析文本疑似乱码（无字母/汉字）")

        // id 连续性（mark 锚定 + pdfBatch 续批依赖 id == 数组下标）
        for (i, p) in parsed.paragraphs.enumerated() {
            XCTAssertEqual(p.id, i, "段落 id 不连续（@\(i)），mark 锚定会错位")
        }

        // 图片段必须带字节（无字节的图片段在 parse 阶段已被跳过）
        XCTAssertEqual(imageCount, imageWithData, "存在无字节的图片段（应已跳过）")

        // 带 images 的古登堡书应解出图片字节
        if sample.name.contains("images") {
            XCTAssertGreaterThan(imageWithData, 0, "带图 EPUB 未解出任何图片字节（href 解析/资源匹配有误）")
        }
    }

    func testDocumentBuilderFromEPUB() throws {
        guard let sample = loadSampleEpub() else { throw XCTSkip("无可用测试 EPUB") }
        let doc = DocumentBuilder.fromEPUB(data: sample.data, title: sample.name)
        XCTAssertNotNil(doc, "DocumentBuilder.fromEPUB 返回 nil")
        XCTAssertEqual(doc?.sourceKind, .epub)
        XCTAssertFalse(doc?.isEmpty ?? true, "EPUB 文档无可朗读内容")
        print("📗 DocumentBuilder.fromEPUB: lang=\(doc?.language ?? "?") 段落=\(doc?.paragraphs.count ?? 0) readable=\(doc?.readableParagraphs.count ?? 0)")
    }
}
