import XCTest
import ZIPFoundation
@testable import CastReader

final class EpubNavigationTests: XCTestCase {
    private func epub(nav: String? = nil, ncx: String? = nil,
                      chapter: String = "<h1 id='one'>First chapter</h1><p>First body.</p><h2 id='two'>Second chapter</h2><p>Second body.</p>",
                      extra: [String: String] = [:]) throws -> Data {
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='OPS/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "OPS/Text/正文+1.xhtml": "<html><body>\(chapter)</body></html>"
        ]
        var manifest = "<item id='body' href='Text/%E6%AD%A3%E6%96%87+1.xhtml' media-type='application/xhtml+xml'/>"
        if let nav {
            files["OPS/Nav/nav.xhtml"] = "<html xmlns:epub='http://www.idpf.org/2007/ops'><body>\(nav)</body></html>"
            manifest += "<item id='nav' href='Nav/nav.xhtml' properties='scripted nav' media-type='application/xhtml+xml'/>"
        }
        if let ncx {
            files["OPS/NCX/toc.ncx"] = "<ncx><navMap>\(ncx)</navMap></ncx>"
            manifest += "<item id='ncx' href='NCX/toc.ncx' media-type='application/x-dtbncx+xml'/>"
        }
        files["OPS/book.opf"] = "<package><metadata><dc:title xmlns:dc='http://purl.org/dc/elements/1.1/'>TOC fixture</dc:title></metadata><manifest>\(manifest)</manifest><spine toc='ncx'><itemref idref='body'/></spine></package>"
        files.merge(extra) { _, new in new }
        let archive = try Archive(accessMode: .create)
        for path in files.keys.sorted() {
            let data = Data(files[path]!.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            })
        }
        return try XCTUnwrap(archive.data)
    }
    private func nav(_ rows: String) -> String { "<nav epub:type='toc'><ol>\(rows)</ol></nav>" }
    private func link(_ title: String, _ fragment: String) -> String {
        "<li><a href='../Text/%E6%AD%A3%E6%96%87+1.xhtml#\(fragment)'>\(title)</a></li>"
    }
    private func parse(_ data: Data) throws -> EpubNativeEngine.ParsedEpub {
        try XCTUnwrap(EpubNativeEngine.parse(data: data, fallbackTitle: "fixture"))
    }
    private func text(_ entry: EpubNavigation.Entry, in book: EpubNativeEngine.ParsedEpub) -> String? {
        entry.paragraphIndex.map { book.paragraphs[$0].text }
    }

    func testNAVWinsPreservesGroupsDepthAndIgnoresPageList() throws {
        let markup = "<nav epub:type='page-list'><ol>\(link("Page 9", "two"))</ol></nav>"
            + nav("<li><span>Part one</span><ol>\(link("Original one", "one"))\(link("Original two", "two"))</ol></li>")
        let ncx = "<navPoint><navLabel><text>Old title</text></navLabel><content src='../Text/正文+1.xhtml#one'/></navPoint>"
        let book = try parse(epub(nav: markup, ncx: ncx))
        XCTAssertEqual(book.navigation.source, .nav)
        XCTAssertEqual(book.navigation.entries.map(\.title), ["Part one", "Original one", "Original two"])
        XCTAssertEqual(book.navigation.entries.map(\.depth), [0, 1, 1])
        XCTAssertTrue(book.navigation.entries[0].isGroup)
        XCTAssertEqual(text(book.navigation.entries[1], in: book), "First chapter")
        XCTAssertEqual(text(book.navigation.entries[2], in: book), "Second chapter")
    }

    func testNCXUsesNestedDirectLabelsAndDocumentOrderRatherThanPlayOrder() throws {
        let ncx = """
        <navPoint playOrder='80'><navLabel><text>First</text></navLabel><content src='../Text/正文+1.xhtml#one'/>
          <navPoint playOrder='1'><navLabel><text>Second</text></navLabel><content src='../Text/正文+1.xhtml#two'/></navPoint>
        </navPoint>
        """
        let book = try parse(epub(ncx: ncx))
        XCTAssertEqual(book.navigation.entries.map(\.title), ["First", "Second"])
        XCTAssertEqual(book.navigation.entries.map(\.depth), [0, 1])
        XCTAssertEqual(text(book.navigation.entries[1], in: book), "Second chapter")
    }

    func testExactInlineContainerEmptyAndNamedAnchorsPreserveAllText() throws {
        let content = """
        <section id='one'><h1>Container heading</h1><p>Before <span id='two'>exact inline destination</span> after.</p></section>
        <a id='empty'></a><p>After empty anchor.</p><a name='legacy'></a><p>Named anchor body.</p>
        <div class='navy stock'><header><h2>Retain header</h2></header><table><tr><td>Table text</td><td>Still readable</td></tr></table></div>
        """
        let book = try parse(epub(nav: nav(link("Container", "one") + link("Inline", "two") + link("Empty", "empty") + link("Legacy", "legacy")), chapter: content))
        XCTAssertEqual(book.navigation.entries.compactMap { text($0, in: book) },
                       ["Container heading", "exact inline destination after.", "After empty anchor.", "Named anchor body."])
        XCTAssertTrue(book.paragraphs.contains { $0.text == "Before" })
        XCTAssertTrue(book.paragraphs.contains { $0.text == "Retain header" })
        XCTAssertTrue(book.paragraphs.contains { $0.text == "Table text | Still readable" })
        XCTAssertEqual(book.paragraphs.map(\.id), Array(book.paragraphs.indices))
    }

    func testMissingFragmentAndExternalURLAreDisabledNeverGuessedByTitle() throws {
        let book = try parse(epub(nav: nav(link("Second chapter", "one") + link("First chapter", "missing")
            + "<li><a href='https://example.com/body.xhtml'>External</a></li>")))
        XCTAssertEqual(text(book.navigation.entries[0], in: book), "First chapter")
        XCTAssertNil(book.navigation.entries[1].paragraphIndex)
        XCTAssertNil(book.navigation.entries[2].paragraphIndex)
        XCTAssertFalse(book.navigation.entries[2].isGroup)
    }

    func testUnusableNAVFallsBackToNCXThenHeadings() throws {
        let markup = nav(link("Broken", "absent"))
        let ncx = "<navPoint><navLabel><text>Correct NCX</text></navLabel><content src='../Text/正文+1.xhtml#two'/></navPoint>"
        let book = try parse(epub(nav: markup, ncx: ncx))
        XCTAssertEqual(book.navigation.source, .ncx)
        XCTAssertEqual(text(book.navigation.entries[0], in: book), "Second chapter")
        XCTAssertEqual(try parse(epub(nav: markup)).navigation.source, .headings)
        XCTAssertEqual(try parse(epub(chapter: "<p>Only a paragraph.</p>")).navigation.source, .spine)
    }

    func testURLResolutionPreservesCaseUnicodePlusAndSingleDecoding() {
        XCTAssertEqual(EpubResourceURL.resolve("../Text/%E6%AD%A3%E6%96%87+1.xhtml?x=1#%E7%AC%AC%E4%BA%8C", relativeTo: "OPS/Nav/toc.xhtml"),
                       .init(path: "OPS/Text/正文+1.xhtml", fragment: "第二"))
        XCTAssertEqual(EpubResourceURL.resolve("./A%2520B.xhtml#x%2520y", relativeTo: "OPS/toc.xhtml"),
                       .init(path: "OPS/A%20B.xhtml", fragment: "x%20y"))
        XCTAssertEqual(EpubResourceURL.resolve("#CaseID", relativeTo: "OPS/Nav.xhtml")?.path, "OPS/Nav.xhtml")
        XCTAssertNil(EpubResourceURL.resolve("//example.com/a", relativeTo: "OPS/nav.xhtml"))
        XCTAssertNil(EpubResourceURL.resolve("javascript:alert(1)", relativeTo: "OPS/nav.xhtml"))
    }

    func testAlternativeNamespacePrefixAndBodyAnchors() throws {
        let markup = "<html xmlns:e='http://www.idpf.org/2007/ops'><body><nav e:type='toc'><ol>\(link("One", "one"))</ol></nav></body></html>"
        let navigation = EpubNavigationParser.parse(markup, path: "OPS/Nav/nav.xhtml", source: .nav)
        XCTAssertEqual(navigation?.entries.count, 1)
        let blocks = try EpubContentParser.parse("<html><body id='body'><p>Body destination.</p></body></html>", referencedFragments: ["body"])
        XCTAssertEqual(blocks.first?.anchors, ["body"])
    }

    func testSystematicallyShiftedNCXUsesCorroboratedGuideWithoutGuessingLinks() {
        let paragraphs = ["One", "Two", "Three", "Four"].enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element, type: .heading(1)) }
        func navigation(_ source: EpubNavigation.Source, shift: Int) -> EpubNavigation {
            .init(source: source, entries: paragraphs.map { p in
                .init(id: "\(p.id)", title: p.text, depth: p.id == 0 ? 0 : 1, href: "chapter\(p.id).xhtml",
                      fragment: nil, paragraphIndex: (p.id + shift) % 4, isGroup: false)
            })
        }
        let broken = navigation(.ncx, shift: 1), correct = navigation(.guide, shift: 0)
        let chosen = EpubNavigationSelection.select([broken, correct], paragraphs: paragraphs)
        XCTAssertEqual(chosen?.source, .guide)
        XCTAssertEqual(chosen?.repairedFrom, .ncx)
        XCTAssertEqual(chosen?.entries.map(\.paragraphIndex), [0, 1, 2, 3])
        XCTAssertEqual(chosen?.entries.map(\.depth), [0, 1, 1, 1])
        XCTAssertEqual(EpubNavigationSelection.select([correct, broken], paragraphs: paragraphs)?.source, .guide)
    }

    func testNavigationRespectsHTMLBaseAndNCXXMLBase() {
        let html = "<html xmlns:epub='http://www.idpf.org/2007/ops'><head><base href='../Text/'/></head><body>\(nav("<li><a href='Book.xhtml#start'>Start</a></li>"))</body></html>"
        XCTAssertEqual(EpubNavigationParser.parse(html, path: "OPS/Nav/nav.xhtml", source: .nav)?.entries.first?.href, "OPS/Text/Book.xhtml")
        let ncx = "<ncx xml:base='../Text/'><navMap><navPoint><navLabel><text>Start</text></navLabel><content src='Book.xhtml#start'/></navPoint></navMap></ncx>"
        XCTAssertEqual(EpubNavigationParser.parse(ncx, path: "OPS/Nav/toc.ncx", source: .ncx)?.entries.first?.href, "OPS/Text/Book.xhtml")
    }

    /// Converter regression: NCX targets drift, with several links pointing at
    /// empty end-of-file page breaks. The guide retains exact content anchors,
    /// but the publisher styles its headings as blockquotes and paragraphs.
    private func convertedEPUB() throws -> Data {
        let titles = ["Chapter A", "Chapter B", "Chapter C", "三", "四"]
        let chapter = titles.enumerated().map { index, title in
            let tag = index.isMultiple(of: 2) ? "blockquote" : "p"
            return "<\(tag) id='c\(index)'><span>\(title)</span></\(tag)><p>Body \(index).</p>"
        }.joined() + "<div class='mbp_pagebreak' id='end'></div>"
        let ncx = titles.enumerated().map { index, title in
            "<navPoint><navLabel><text>\(title)</text></navLabel><content src='../Text/正文+1.xhtml#\(index < 3 ? "c\(index + 1)" : "end")'/></navPoint>"
        }.joined()
        let guide = "<html><body><ul>" + titles.enumerated().map { index, title in
            "<li><a href='Text/正文+1.xhtml#c\(index)'>\(title)</a></li>"
        }.joined() + "</ul></body></html>"
        let opf = """
        <package><manifest>
        <item id='body' href='Text/正文+1.xhtml' media-type='application/xhtml+xml'/>
        <item id='ncx' href='NCX/toc.ncx' media-type='application/x-dtbncx+xml'/>
        <item id='guide' href='contents.xhtml' media-type='application/xhtml+xml'/>
        </manifest><spine toc='ncx'><itemref idref='body'/></spine>
        <guide><reference type='toc' href='contents.xhtml'/></guide></package>
        """
        return try epub(ncx: ncx, chapter: chapter, extra: ["OPS/book.opf": opf, "OPS/contents.xhtml": guide])
    }

    func testConvertedNCXUsesExactGuideAnchorsWithoutSemanticHeadingTags() throws {
        let book = try parse(convertedEPUB())
        XCTAssertEqual(book.navigation.source, .guide)
        XCTAssertEqual(book.navigation.repairedFrom, .ncx)
        XCTAssertEqual(book.navigation.entries.compactMap { text($0, in: book) },
                       ["Chapter A", "Chapter B", "Chapter C", "三", "四"])
        XCTAssertEqual(book.navigation.entries.compactMap(\.paragraphIndex), [0, 2, 4, 6, 8])
    }

    @MainActor
    func testOldEPUBDirectoryCacheRebuildsAndPreservesPosition() async throws {
        let document = try XCTUnwrap(DocumentBuilder.fromEPUB(data: convertedEPUB(), title: "Converted fixture"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(directory: root)
        history.record(document)
        _ = try await history.reopen(try XCTUnwrap(history.records.first))
        history.updateReadingPosition(documentID: document.id, paragraphIndex: 6)
        let cache = LocalDocumentCache.url(id: document.id, in: root)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: cache), format: nil) as? [String: Any])
        plist.removeValue(forKey: "epubNavigationVersion")
        plist.removeValue(forKey: "epubNavigation")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: cache)
        let cold = HistoryStore(directory: root)
        let loaded = try await cold.reopen(try XCTUnwrap(cold.records.first))
        let reopened = try XCTUnwrap(loaded)
        XCTAssertEqual(reopened.epubNavigation?.source, .guide)
        XCTAssertEqual(reopened.epubNavigation?.entries.compactMap(\.paragraphIndex), [0, 2, 4, 6, 8])
        XCTAssertEqual(cold.records.first?.lastParagraphIndex, 6)
        XCTAssertEqual(reopened.paragraphs, document.paragraphs)
        let vm = ReadAloudViewModel(document: reopened, historyStore: cold)
        vm.navigateToEpubParagraph(8)
        XCTAssertEqual(vm.currentParagraphIndex, 8)
        XCTAssertFalse(vm.isPlaying)
        vm.stop()
    }

    @MainActor
    func testReportedEPUBUsesGuideAndEveryDestinationResolves() throws {
        guard let path = ProcessInfo.processInfo.environment["CASTREADER_EPUB_REGRESSION_PATH"] else {
            throw XCTSkip("Set CASTREADER_EPUB_REGRESSION_PATH to the private ocb.epub reproduction file.")
        }
        let started = Date()
        let book = try parse(Data(contentsOf: URL(fileURLWithPath: path, relativeTo:
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)))
        print("EPUB IMPORT seconds=\(Date().timeIntervalSince(started)) paragraphs=\(book.paragraphs.count) entries=\(book.navigation.entries.count)")
        XCTAssertEqual(book.navigation.source, .guide)
        XCTAssertEqual(book.navigation.repairedFrom, .ncx)
        XCTAssertEqual(book.navigation.entries.count, 40)
        XCTAssertTrue(book.navigation.entries.allSatisfy { $0.paragraphIndex != nil })
        for (title, path, fragment) in [("三", "text/part0015.html", "filepos165612"),
                                       ("四", "text/part0016.html", "filepos170876"),
                                       ("欧洲", "text/part0012.html", "filepos136528")] {
            let entry = try XCTUnwrap(book.navigation.entries.first { $0.title == title })
            XCTAssertEqual(entry.href, path)
            XCTAssertEqual(entry.fragment, fragment)
            XCTAssertEqual(text(entry, in: book)?.filter { !$0.isWhitespace }, title)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(directory: root)
        let document = ReadingDocument(title: "Private reproduction", sourceKind: .epub, language: "zh",
                                       paragraphs: book.paragraphs)
        let vm = ReadAloudViewModel(document: document, historyStore: history)
        for entry in book.navigation.entries {
            let target = try XCTUnwrap(entry.paragraphIndex)
            vm.navigateToEpubParagraph(target)
            XCTAssertEqual(vm.epubNavigationParagraphIndex, target)
            XCTAssertEqual(vm.currentParagraphIndex, target)
            XCTAssertFalse(vm.isPlaying)
        }
        vm.stop()
    }

    func testDirectoryRepairDoesNotOverrideValidSourceOrVoteWithRepeatedLabels() {
        let paragraphs = ["A", "B", "C", "D"].enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element, type: .paragraph)
        }
        func navigation(_ source: EpubNavigation.Source, targets: [Int?], repeated: Bool = false) -> EpubNavigation {
            .init(source: source, entries: targets.enumerated().map { index, target in
                .init(id: "\(source)-\(index)", title: repeated ? "A" : paragraphs[index].text, depth: 0,
                      href: "body.xhtml", fragment: "c\(index)", paragraphIndex: target, isGroup: false)
            })
        }
        let valid = navigation(.ncx, targets: [0, 1, 2, 3])
        let guide = navigation(.guide, targets: [0, 1, 2, 3])
        XCTAssertEqual(EpubNavigationSelection.select([valid, guide], paragraphs: paragraphs), valid)
        let singleMistake = navigation(.ncx, targets: [1, 1, 2, 3])
        XCTAssertEqual(EpubNavigationSelection.select([singleMistake, guide], paragraphs: paragraphs), singleMistake)
        let broken = navigation(.ncx, targets: [1, 2, 3, nil])
        let partial = navigation(.guide, targets: [0, 1, nil, nil])
        XCTAssertEqual(EpubNavigationSelection.select([broken, partial], paragraphs: paragraphs), broken)
        let repeated = navigation(.guide, targets: [0, 0, 0, 0], repeated: true)
        XCTAssertEqual(EpubNavigationSelection.select([broken, repeated], paragraphs: paragraphs), broken)
    }

    @MainActor
    func testDirectorySurvivesColdCacheAndSelectionPersistsWithoutAudio() async throws {
        let data = try epub(nav: nav(link("One", "one") + link("Two", "two")))
        let document = try XCTUnwrap(DocumentBuilder.fromEPUB(data: data, title: "fixture"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(directory: directory)
        history.record(document)
        let vm = ReadAloudViewModel(document: document, historyStore: history)
        let target = try XCTUnwrap(document.epubNavigation?.entries[1].paragraphIndex)
        vm.navigateToEpubParagraph(target)
        XCTAssertEqual(vm.currentParagraphIndex, target)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertNil(vm.highlightRange)
        vm.stop()
        let cold = HistoryStore(directory: directory)
        let loaded = try await cold.reopen(try XCTUnwrap(cold.records.first))
        let reopened = try XCTUnwrap(loaded)
        XCTAssertEqual(reopened.epubNavigation, document.epubNavigation)
        let restored = ReadAloudViewModel(document: reopened, historyStore: cold)
        XCTAssertEqual(restored.currentParagraphIndex, target)
        XCTAssertNil(restored.resumeNotice)
        restored.stop()
    }

    func testAllLocalEPUBsProduceSafeIndexedNavigationOrRejectInvalidFiles() throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard let corpusPath = environment["CASTREADER_EPUB_CORPUS_DIRECTORY"], !corpusPath.isEmpty else {
            throw XCTSkip("Set CASTREADER_EPUB_CORPUS_DIRECTORY to run the optional local corpus.")
        }
        let directory = URL(fileURLWithPath: corpusPath, isDirectory: true)
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Local EPUB corpus is unavailable: \(directory.path)")
        }
        var hashes = Set<String>(), rows: [[String: Any]] = []
        for case let file as URL in files where file.pathExtension.lowercased() == "epub" {
            let data = try Data(contentsOf: file)
            guard hashes.insert(ReadingResumeContract.fingerprint(data)).inserted else { continue }
            let started = Date()
            if (try? Archive(data: data, accessMode: .read)) == nil {
                XCTAssertNil(EpubNativeEngine.parse(data: data, fallbackTitle: file.lastPathComponent))
                rows.append(["file": file.path, "rejectedNonZIP": true]); continue
            }
            let parsed: EpubNativeEngine.ParsedEpub?
            do { parsed = try EpubNativeEngine.parseCancellable(data: data, fallbackTitle: file.lastPathComponent) }
            catch {
                rows.append(["file": file.path, "error": String(describing: error)])
                XCTFail("\(file.lastPathComponent): \(error)")
                continue
            }
            guard let book = parsed else {
                rows.append(["file": file.path, "error": "nil parse"])
                XCTFail("\(file.lastPathComponent): nil parse")
                continue
            }
            XCTAssertTrue(book.navigation.isValid(paragraphCount: book.paragraphs.count), file.lastPathComponent)
            XCTAssertFalse(book.navigation.entries.isEmpty, file.lastPathComponent)
            let unresolved = book.navigation.entries.filter { !$0.isGroup && $0.paragraphIndex == nil }
            rows.append(["file": file.path, "source": book.navigation.source.rawValue,
                         "entries": book.navigation.entries.count, "paragraphs": book.paragraphs.count,
                         "destinations": book.navigation.entries.map { entry in
                             ["title": entry.title, "path": entry.href ?? "", "fragment": entry.fragment ?? "",
                              "paragraph": entry.paragraphIndex ?? -1,
                              "rendered": entry.paragraphIndex.map { String(book.paragraphs[$0].text.prefix(180)) } ?? "",
                              "image": entry.paragraphIndex.map { book.paragraphs[$0].type == .image } ?? false] as [String: Any]
                         },
                         "unresolved": unresolved.map { ["title": $0.title, "path": $0.href ?? "", "fragment": $0.fragment ?? ""] },
                         "seconds": Date().timeIntervalSince(started)])
        }
        guard !rows.isEmpty else { throw XCTSkip("Local EPUB corpus contains no EPUB files.") }
        if let outputPath = environment["CASTREADER_EPUB_CORPUS_REPORT"], !outputPath.isEmpty {
            let output = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }
        #else
        throw XCTSkip("The optional local EPUB corpus is a simulator-only test.")
        #endif
    }
}
