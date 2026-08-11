//
//  EpubNativeEngineTests.swift
//  CastReaderTests
//
//  EPUB 原生解析自检（ZIPFoundation + SwiftSoup）：用真实 EPUB 验证段落/图片/文本健全/id 连续性。
//  对齐 memory「eval-harness-readaloud-explain：改完先跑」。
//

import XCTest
import ZIPFoundation
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

    func testRejectsEPUBWithOversizedEntryMetadataBeforeExtraction() throws {
        let normalData = try makeMinimalEPUB(extraEntries: [
            "OEBPS/oversized.bin": Data([0x42]),
        ])
        let maliciousData = try replacingCentralDirectoryUncompressedSize(
            in: normalData,
            path: "OEBPS/oversized.bin",
            with: UInt32(DocumentResourceLimits.archive.maximumEntryUncompressedBytes + 1)
        )

        XCTAssertThrowsError(try DocumentFormatValidator.validate(
            data: maliciousData,
            filename: "oversized.epub",
            expectedFormat: .epub
        )) { error in
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.archiveEntryTooLarge)
            )
        }
        XCTAssertNil(
            EpubNativeEngine.parse(data: maliciousData, fallbackTitle: "oversized"),
            "Direct EPUB parsing must retain the same pre-extraction archive limit"
        )
    }

    private func makeMinimalEPUB(extraEntries: [String: Data]) throws -> Data {
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
                </container>
                """.utf8),
            "OEBPS/content.opf": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <package xmlns="http://www.idpf.org/2007/opf">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Safe fixture</dc:title></metadata>
                  <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
                  <spine><itemref idref="chapter"/></spine>
                </package>
                """.utf8),
            "OEBPS/chapter.xhtml": Data("""
                <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Readable fixture.</p></body></html>
                """.utf8),
        ]
        for (path, data) in extraEntries {
            entries[path] = data
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpubNativeEngineLimits-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = root.appendingPathExtension("epub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: archiveURL)
        }
        for (path, data) in entries {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for path in entries.keys.sorted() {
            try archive.addEntry(
                with: path,
                fileURL: root.appendingPathComponent(path),
                compressionMethod: .none
            )
        }
        return try Data(contentsOf: archiveURL)
    }

    /// Change only the central-directory declaration. The physical entry stays
    /// one byte, proving validation rejects hostile metadata before extraction
    /// or allocation based on the declared expanded size.
    private func replacingCentralDirectoryUncompressedSize(
        in data: Data,
        path: String,
        with value: UInt32
    ) throws -> Data {
        var result = data
        let signature: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        var offset = 0

        while offset + 46 <= result.count {
            if Array(result[offset..<(offset + 4)]) != signature {
                offset += 1
                continue
            }
            let filenameLength = littleEndianUInt16(in: result, at: offset + 28)
            let extraLength = littleEndianUInt16(in: result, at: offset + 30)
            let commentLength = littleEndianUInt16(in: result, at: offset + 32)
            let filenameStart = offset + 46
            let filenameEnd = filenameStart + Int(filenameLength)
            guard filenameEnd <= result.count else { break }
            let filename = String(
                data: result[filenameStart..<filenameEnd],
                encoding: .utf8
            )
            if filename == path {
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes in
                    result.replaceSubrange((offset + 24)..<(offset + 28), with: bytes)
                }
                return result
            }
            offset = filenameEnd + Int(extraLength) + Int(commentLength)
        }
        throw NSError(
            domain: "EpubNativeEngineLimitsTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Fixture central-directory entry was not found"]
        )
    }

    private func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
