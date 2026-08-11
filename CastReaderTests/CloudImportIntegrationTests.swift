//
//  CloudImportIntegrationTests.swift
//  CastReaderTests
//
//  End-to-end contracts for provider-neutral cloud download -> local parsing.
//  Fixtures stay entirely on-device and deliberately expose no upload hook.
//

import Foundation
import UIKit
import XCTest
import ZIPFoundation
@testable import CastReader

final class CloudImportIntegrationTests: XCTestCase {
    func testAtomicPickerDownloadsPDFAndImportsThroughDeviceOnlyPipeline() async throws {
        let data = makePDFData()
        let account = makeAccount(provider: .googleDrive)
        let item = makeItem(
            provider: .googleDrive,
            account: account,
            id: "google-pdf",
            name: "Cloud Paper.pdf",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
            size: Int64(data.count),
            revision: "pdf-revision-1"
        )
        let provider = FakeAtomicCloudProvider(
            account: account,
            item: item,
            fixture: DownloadFixture(
                data: data,
                filename: item.name,
                mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
                format: .pdf,
                revision: item.revision
            )
        )
        let coordinator = CloudImportCoordinator()
        let session = await coordinator.begin(scenario: nil, mode: .read)
        let destination = temporaryFileURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let selection = try await provider.authorizeAndPick()
        XCTAssertEqual(selection.account, account)
        XCTAssertEqual(selection.item, item)
        XCTAssertEqual(
            provider.selectionCapability,
            .authorizeAndPickInSystemBrowser
        )

        let receipt = try await coordinator.run(for: session) {
            try await provider.download(
                selection.item,
                exportFormat: nil,
                to: destination,
                progress: { _ in }
            )
        }
        let origin = makeOrigin(item: selection.item)
        let result = try await coordinator.run(for: session) {
            try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    receipt: receipt,
                    origin: origin,
                    session: session
                )
            )
        }

        XCTAssertTrue(receipt.localURL.isFileURL)
        let atomicDestinations = await provider.downloadDestinations()
        XCTAssertEqual(atomicDestinations, [destination])
        XCTAssertEqual(result.format, .pdf)
        XCTAssertEqual(result.document.sourceKind, .pdf)
        XCTAssertFalse(result.document.paragraphs.isEmpty)
        XCTAssertEqual(result.document.id, origin.stableDocumentID)
        XCTAssertEqual(result.persistencePolicy, .remoteReference)
        XCTAssertEqual(result.session, session)
        XCTAssertEqual(result.byteCount, Int64(data.count))
        XCTAssertEqual(
            result.contentSessionKey,
            CloudStableIdentifier.contentSessionKey(
                documentID: origin.stableDocumentID,
                revision: "pdf-revision-1",
                format: .pdf
            )
        )
    }

    func testBrowsableProviderDownloadsAndImportsDOCXWithStableRemoteIdentity() async throws {
        let data = try makeDOCXData(title: "Cloud DOCX Contract")
        let account = makeAccount(provider: .dropbox)
        let item = makeItem(
            provider: .dropbox,
            account: account,
            id: "dropbox-docx",
            name: "Draft.docx",
            mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
            size: Int64(data.count),
            revision: "docx-revision-1"
        )
        let provider = FakeBrowsableCloudProvider(
            id: .dropbox,
            account: account,
            item: item,
            fixture: DownloadFixture(
                data: data,
                filename: item.name,
                mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
                format: .docx,
                revision: item.revision
            )
        )
        let coordinator = CloudImportCoordinator()
        let firstSession = await coordinator.begin(scenario: .study, mode: .explain)
        let firstDestination = temporaryFileURL(extension: "docx")
        let secondDestination = temporaryFileURL(extension: "docx")
        defer {
            try? FileManager.default.removeItem(at: firstDestination)
            try? FileManager.default.removeItem(at: secondDestination)
        }

        let connectedAccount = try await provider.ensureConnected()
        XCTAssertEqual(connectedAccount, account)
        let page = try await provider.list(folder: nil, cursor: nil)
        XCTAssertEqual(page.items, [item])
        XCTAssertEqual(provider.selectionCapability, .persistentConnectionAndNativeBrowser)

        let firstReceipt = try await coordinator.run(for: firstSession) {
            try await provider.download(item, to: firstDestination)
        }
        let origin = makeOrigin(item: item)
        let first = try await coordinator.run(for: firstSession) {
            try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    receipt: firstReceipt,
                    origin: origin,
                    session: firstSession
                )
            )
        }
        let didFinishFirst = await coordinator.finish(firstSession)
        XCTAssertTrue(didFinishFirst)

        await provider.setRevision("docx-revision-2")
        let secondSession = await coordinator.begin(scenario: nil, mode: .read)
        let secondReceipt = try await coordinator.run(for: secondSession) {
            try await provider.download(item, to: secondDestination)
        }
        let second = try await coordinator.run(for: secondSession) {
            try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    receipt: secondReceipt,
                    origin: origin,
                    session: secondSession
                )
            )
        }

        XCTAssertEqual(first.document.sourceKind, .docx)
        XCTAssertEqual(first.document.fileData, data)
        XCTAssertEqual(first.document.id, origin.stableDocumentID)
        XCTAssertEqual(second.document.id, origin.stableDocumentID)
        XCTAssertEqual(first.finalRevision, "docx-revision-1")
        XCTAssertEqual(second.finalRevision, "docx-revision-2")
        XCTAssertNotEqual(first.contentSessionKey, second.contentSessionKey)
        XCTAssertEqual(
            first.contentSessionKey,
            CloudStableIdentifier.contentSessionKey(
                documentID: origin.stableDocumentID,
                revision: "docx-revision-1",
                format: .docx
            )
        )
        XCTAssertEqual(
            second.contentSessionKey,
            CloudStableIdentifier.contentSessionKey(
                documentID: origin.stableDocumentID,
                revision: "docx-revision-2",
                format: .docx
            )
        )
    }

    func testBrowsableProviderDownloadsAndImportsNativeEPUB() async throws {
        let data = try makeEPUBData()
        let account = makeAccount(provider: .oneDrive)
        let item = makeItem(
            provider: .oneDrive,
            account: account,
            driveID: "shared-drive",
            id: "onedrive-epub",
            name: "Reader Contract.epub",
            mimeType: SupportedDocumentFormat.epub.preferredMIMEType,
            size: Int64(data.count),
            revision: "epub-content-tag"
        )
        let provider = FakeBrowsableCloudProvider(
            id: .oneDrive,
            account: account,
            item: item,
            fixture: DownloadFixture(
                data: data,
                filename: item.name,
                mimeType: SupportedDocumentFormat.epub.preferredMIMEType,
                format: .epub,
                revision: item.revision
            )
        )
        let coordinator = CloudImportCoordinator()
        let session = await coordinator.begin(scenario: .study, mode: .read)
        let destination = temporaryFileURL(extension: "epub")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try await provider.ensureConnected()
        let search = try await provider.search("Reader", cursor: nil)
        let selected = try XCTUnwrap(search.items.first)
        let receipt = try await coordinator.run(for: session) {
            try await provider.download(selected, to: destination)
        }
        let origin = makeOrigin(item: selected)
        let result = try await coordinator.run(for: session) {
            try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(receipt: receipt, origin: origin, session: session)
            )
        }

        XCTAssertEqual(result.format, .epub)
        XCTAssertEqual(result.document.sourceKind, .epub)
        XCTAssertTrue(
            result.document.paragraphs.contains {
                $0.text.contains("device-only EPUB chapter")
            }
        )
        XCTAssertEqual(result.origin?.driveID, "shared-drive")
        XCTAssertEqual(result.document.id, origin.stableDocumentID)
        XCTAssertEqual(result.persistencePolicy, .remoteReference)
    }

    func testPipelineRejectsUnknownExtensionMIMEAndByteCountMismatches() async throws {
        let pdf = makePDFData()
        let unknownURL = temporaryFileURL(extension: "bin")
        let pdfURL = temporaryFileURL(extension: "pdf")
        try pdf.write(to: unknownURL, options: .atomic)
        try pdf.write(to: pdfURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: unknownURL)
            try? FileManager.default.removeItem(at: pdfURL)
        }

        await assertPipelineError(
            .unsupportedExtension("bin"),
            request: DocumentImportRequest(localURL: unknownURL)
        )
        await assertPipelineError(
            .extensionMismatch(expected: .pdf, actual: "epub"),
            request: DocumentImportRequest(
                localURL: pdfURL,
                declaredExtension: "epub",
                expectedFormat: .pdf
            )
        )
        await assertPipelineError(
            .mimeTypeMismatch(expected: .pdf, actual: "text/html"),
            request: DocumentImportRequest(
                localURL: pdfURL,
                effectiveMIMEType: "text/html",
                expectedFormat: .pdf
            )
        )
        await assertPipelineError(
            .byteCountMismatch(
                expected: Int64(pdf.count + 1),
                actual: Int64(pdf.count)
            ),
            request: DocumentImportRequest(
                localURL: pdfURL,
                expectedFormat: .pdf,
                expectedByteCount: Int64(pdf.count + 1)
            )
        )
    }

    func testPipelineImportsTXTMarkdownAndRTFAsNativeReadableText() async throws {
        let fixtures: [(fileExtension: String, mime: String, data: Data, expected: String)] = [
            (
                "txt",
                "text/plain",
                Data("Plain text can be read aloud.".utf8),
                "Plain text can be read aloud."
            ),
            (
                "md",
                "text/markdown",
                Data("# Reading Notes\n\nMarkdown can be read aloud.".utf8),
                "Markdown can be read aloud."
            ),
            (
                "rtf",
                "application/rtf",
                Data(#"{\rtf1\ansi Rich text can be read aloud.}"#.utf8),
                "Rich text can be read aloud."
            ),
        ]

        for fixture in fixtures {
            let url = temporaryFileURL(extension: fixture.fileExtension)
            try fixture.data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    localURL: url,
                    effectiveMIMEType: fixture.mime,
                    expectedFormat: .text
                )
            )

            XCTAssertEqual(result.format, .text)
            XCTAssertEqual(result.document.sourceKind, .text)
            XCTAssertTrue(result.document.fullText.contains(fixture.expected))
            XCTAssertFalse(result.document.readableParagraphs.isEmpty)
        }
    }

    func testPipelineExtractsLocalHTMLAndRejectsBinaryDisguisedAsText() async throws {
        let htmlURL = temporaryFileURL(extension: "html")
        let binaryURL = temporaryFileURL(extension: "txt")
        try Data(
            "<html><head><script>secretScript()</script></head><body><h1>Readable heading</h1><p>Readable body.</p><table><tr><th>Chapter</th><th>Status</th></tr><tr><td>Cloud table text</td><td>Readable</td></tr></table></body></html>".utf8
        ).write(to: htmlURL, options: .atomic)
        try Data(repeating: 0, count: 1_024).write(to: binaryURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: htmlURL)
            try? FileManager.default.removeItem(at: binaryURL)
        }

        let result = try await DocumentImportPipeline().importDocument(
            DocumentImportRequest(
                localURL: htmlURL,
                effectiveMIMEType: "text/html",
                expectedFormat: .text
            )
        )
        XCTAssertTrue(result.document.fullText.contains("Readable heading"))
        XCTAssertTrue(result.document.fullText.contains("Readable body."))
        XCTAssertTrue(result.document.fullText.contains("Cloud table text"))
        XCTAssertFalse(result.document.fullText.contains("secretScript"))

        await assertPipelineError(
            .parseFailed(.text),
            request: DocumentImportRequest(
                localURL: binaryURL,
                effectiveMIMEType: "application/octet-stream",
                expectedFormat: .text
            )
        )
    }

    func testSupportedTextExtensionFamilyRemainsExplicit() {
        let supported = [
            "txt", "text", "md", "markdown", "rtf", "html", "htm", "xhtml",
            "csv", "tsv", "json", "jsonl", "ndjson", "xml", "yaml", "yml",
            "log", "ini", "conf", "cfg", "srt", "vtt", "tex",
        ]
        for fileExtension in supported {
            XCTAssertEqual(
                SupportedDocumentFormat(fileExtension: fileExtension),
                .text,
                fileExtension
            )
        }
        for fileExtension in ["zip", "mp3", "mp4", "pages", "numbers"] {
            XCTAssertNil(
                SupportedDocumentFormat(fileExtension: fileExtension),
                fileExtension
            )
        }
    }

    func testPipelineRejectsOversizedMetadataAndSparseFileBeforeReading() async throws {
        let smallPDFURL = temporaryFileURL(extension: "pdf")
        let sparsePDFURL = temporaryFileURL(extension: "pdf")
        try makePDFData().write(to: smallPDFURL, options: .atomic)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: sparsePDFURL.path,
            contents: Data("%PDF-1.7\n".utf8)
        ))
        let sparseHandle = try FileHandle(forWritingTo: sparsePDFURL)
        try sparseHandle.truncate(
            atOffset: UInt64(DocumentResourceLimits.maximumInputBytes + 1)
        )
        try sparseHandle.close()
        defer {
            try? FileManager.default.removeItem(at: smallPDFURL)
            try? FileManager.default.removeItem(at: sparsePDFURL)
        }

        await assertPipelineError(
            .resourceLimitExceeded(.inputFileTooLarge),
            request: DocumentImportRequest(
                localURL: smallPDFURL,
                expectedFormat: .pdf,
                expectedByteCount: DocumentResourceLimits.maximumInputBytes + 1
            )
        )
        await assertPipelineError(
            .resourceLimitExceeded(.inputFileTooLarge),
            request: DocumentImportRequest(
                localURL: sparsePDFURL,
                expectedFormat: .pdf
            )
        )
    }

    func testPipelineRejectsSuspiciousDOCXCompressionRatioBeforeExtraction() async throws {
        let bombBytes = Data(
            repeating: 0,
            count: Int(DocumentResourceLimits.archive.compressionRatioMinimumBytes * 2)
        )
        let data = try makeDOCXData(
            title: "Compression Ratio Contract",
            extraEntries: ["word/compression-bomb.bin": bombBytes],
            compressedPaths: ["word/compression-bomb.bin"]
        )
        let url = temporaryFileURL(extension: "docx")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        await assertPipelineError(
            .resourceLimitExceeded(.suspiciousCompressionRatio),
            request: DocumentImportRequest(
                localURL: url,
                expectedFormat: .docx
            )
        )
    }

    func testArchiveDirectoryBudgetsEnforceEntryCountAndExpandedTotal() throws {
        let data = try makeZIP(entries: [
            "one.bin": Data([0, 1]),
            "two.bin": Data([2, 3]),
            "three.bin": Data([4, 5]),
        ])
        let archive = try Archive(data: data, accessMode: .read)
        let generousBytes = UInt64(data.count + 100)

        XCTAssertThrowsError(try DocumentArchiveValidator.validate(
            archive,
            limits: DocumentArchiveResourceLimits(
                maximumEntryCount: 2,
                maximumEntryUncompressedBytes: generousBytes,
                maximumTotalUncompressedBytes: generousBytes,
                maximumCompressionRatio: 200,
                compressionRatioMinimumBytes: 1
            )
        )) { error in
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.archiveHasTooManyEntries)
            )
        }

        XCTAssertThrowsError(try DocumentArchiveValidator.validate(
            archive,
            limits: DocumentArchiveResourceLimits(
                maximumEntryCount: 10,
                maximumEntryUncompressedBytes: generousBytes,
                maximumTotalUncompressedBytes: 5,
                maximumCompressionRatio: 200,
                compressionRatioMinimumBytes: 1
            )
        )) { error in
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.archiveExpandedSizeTooLarge)
            )
        }
    }

    func testCloudPathRejectsNonFileDownloadAndImportTargets() async throws {
        let data = makePDFData()
        let account = makeAccount(provider: .googleDrive)
        let item = makeItem(
            provider: .googleDrive,
            account: account,
            id: "remote",
            name: "Remote.pdf",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
            size: Int64(data.count),
            revision: "r1"
        )
        let provider = FakeAtomicCloudProvider(
            account: account,
            item: item,
            fixture: DownloadFixture(
                data: data,
                filename: item.name,
                mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
                format: .pdf,
                revision: item.revision
            )
        )
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/not-local.pdf"))

        do {
            _ = try await provider.download(item, to: remoteURL)
            XCTFail("Cloud providers must require a device-local download destination")
        } catch let error as CloudStorageError {
            XCTAssertEqual(error, .downloadNotAllowed)
        }

        await assertPipelineError(
            .invalidLocalURL,
            request: DocumentImportRequest(localURL: remoteURL)
        )
        let rejectedDestinations = await provider.downloadDestinations()
        XCTAssertTrue(rejectedDestinations.isEmpty)
    }

    func testExplicitCancellationRejectsNonCooperativeLateResult() async throws {
        let coordinator = CloudImportCoordinator()
        let session = await coordinator.begin(scenario: nil, mode: .read)
        let gate = LateResultGate<String>()
        let operation = Task {
            try await coordinator.run(for: session) {
                await gate.wait()
            }
        }

        await gate.waitUntilSuspended()
        let didCancel = await coordinator.cancel(session)
        XCTAssertTrue(didCancel)
        await gate.release("too late")

        do {
            _ = try await operation.value
            XCTFail("A cancelled import must not commit a non-cooperative late result")
        } catch let error as CloudImportCoordinationError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        let currentAfterCancel = await coordinator.currentSession()
        XCTAssertNil(currentAfterCancel)
    }

    func testDetachedParserCancellationStopsChildAndAllowsPromptTemporaryCleanup() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CloudImportCancellation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let childStarted = expectation(description: "detached parser child started")
        let childStopped = expectation(description: "detached parser child stopped")

        let operation = Task<Void, Error> {
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            try await DocumentImportDetachedTask.run {
                childStarted.fulfill()
                defer { childStopped.fulfill() }
                // A hard deadline keeps this regression test from hanging the
                // whole suite if cancellation forwarding is ever removed.
                let safetyDeadline = Date().addingTimeInterval(4)
                while Date() < safetyDeadline {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }

        await fulfillment(of: [childStarted], timeout: 2)
        operation.cancel()
        await fulfillment(of: [childStopped], timeout: 2)

        do {
            try await operation.value
            XCTFail("A cancelled parent must not leave its detached parser running")
        } catch is CancellationError {
            // Expected: the bridge preserves cancellation for pipeline mapping.
        } catch {
            XCTFail("Unexpected detached parser cancellation error: \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: temporaryDirectory.path),
            "Prompt child cancellation must let the caller's defer remove temporary files"
        )
    }

    func testPipelineNormalizesTaskCancellationToDocumentImportCancelled() async throws {
        let data = try makeEPUBData()
        let url = temporaryFileURL(extension: "epub")
        let pdfURL = temporaryFileURL(extension: "pdf")
        try data.write(to: url, options: .atomic)
        try makePDFData().write(to: pdfURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: pdfURL)
        }

        await assertPipelineCancellation(
            DocumentImportRequest(localURL: url)
        )
        await assertPipelineCancellation(
            DocumentImportRequest(localURL: pdfURL)
        )
        await assertPipelineCancellation(
            DocumentImportRequest(
                localURL: try XCTUnwrap(URL(string: "https://example.invalid/cancelled.epub"))
            )
        )
    }

    func testPDFOCRBuilderPropagatesCancellationInsteadOfReturningPartialDocument() async throws {
        let data = makePDFData()
        let gate = LateResultGate<Void>()
        let operation = Task {
            await gate.wait()
            return try await DocumentBuilder.fromPDFWithOCR(
                data: data,
                fallbackTitle: "Cancelled PDF"
            )
        }

        await gate.waitUntilSuspended()
        operation.cancel()
        await gate.release(())

        do {
            _ = try await operation.value
            XCTFail("A cancelled PDF/OCR builder must not return nil or a partial document")
        } catch is CancellationError {
            // Expected: cancellation is an explicit control-flow result.
        } catch {
            XCTFail("Unexpected PDF/OCR cancellation error: \(error)")
        }
    }

    func testEPUBRejectsOversizedMarkupBeforeSynchronousDOMParsing() throws {
        let oversizedChapter = Data(
            repeating: 0x41,
            count: Int(EpubNativeEngine.maximumChapterMarkupBytes + 1)
        )
        let epub = try makeEPUBData(extraEntries: [
            "OEBPS/content.opf": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>Oversized markup contract</dc:title>
                  </metadata>
                  <manifest>
                    <item id="normal" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                    <item id="oversized" href="oversized.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="normal"/><itemref idref="oversized"/></spine>
                </package>
                """.utf8),
            "OEBPS/oversized.xhtml": oversizedChapter,
        ])

        XCTAssertThrowsError(
            try EpubNativeEngine.parseCancellable(
                data: epub,
                fallbackTitle: "Oversized markup"
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentImportError,
                .invalidEPUB(reason: "markup_entry_too_large")
            )
        }
        XCTAssertNil(EpubNativeEngine.parse(data: epub, fallbackTitle: "Oversized markup"))
    }

    func testDOCXAndEPUBParsersObserveInheritedTaskCancellation() async throws {
        let docx = try makeDOCXData(title: "Cancellation contract")
        await assertCancellationObserved {
            _ = try DocumentBuilder.docxTitleCancellable(data: docx)
        }

        let epub = try makeEPUBData()
        await assertCancellationObserved {
            _ = try DocumentFormatValidator.validate(
                data: epub,
                filename: "Cancellation.epub",
                expectedFormat: .epub
            )
        }
        await assertCancellationObserved {
            _ = try EpubNativeEngine.parseCancellable(
                data: epub,
                fallbackTitle: "Cancellation contract"
            )
        }
    }

    func testReplacementRejectsLateResultAndDropsOldSessionProgress() async throws {
        let coordinator = CloudImportCoordinator()
        let first = await coordinator.begin(scenario: nil, mode: .read)
        let gate = LateResultGate<String>()
        let operation = Task {
            try await coordinator.run(for: first) {
                await gate.wait()
            }
        }
        await gate.waitUntilSuspended()

        let progressCount = LockedCounter()
        let staleProgress = coordinator.progressHandler(for: first) { _ in
            progressCount.increment()
        }
        let second = await coordinator.begin(scenario: .study, mode: .explain)
        staleProgress(CloudDownloadProgress(completedBytes: 9, totalBytes: 10))
        await gate.release("late result")

        do {
            _ = try await operation.value
            XCTFail("A replaced import must not commit its late result")
        } catch let error as CloudImportCoordinationError {
            XCTAssertEqual(error, .staleSession)
        } catch {
            XCTFail("Unexpected replacement error: \(error)")
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(progressCount.value, 0)
        let firstIsCurrent = await coordinator.isCurrent(first)
        let secondIsCurrent = await coordinator.isCurrent(second)
        XCTAssertFalse(firstIsCurrent)
        XCTAssertTrue(secondIsCurrent)
    }

    func testCloudImportCoreHasNoBackendUploadDependency() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "CastReader/Models/CloudStorageModels.swift",
            "CastReader/Services/CloudStorageProvider.swift",
            "CastReader/Services/CloudImportCoordinator.swift",
            "CastReader/Services/GoogleDriveProvider.swift",
            "CastReader/Services/DropboxProvider.swift",
            "CastReader/Services/OneDriveProvider.swift",
            "CastReader/Utils/DocumentImportPipeline.swift",
        ]
        let forbiddenTokens = [
            "APIService.shared",
            "readerServiceURL",
            "/async-md-upload-by-url",
            "async-md-upload-by-url",
            "uploadToCOS",
            "uploadDocument",
        ]

        for relativePath in relativePaths {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Cloud source contract is available only in host tests")
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(
                    source.contains(token),
                    "\(relativePath) must remain device-only; found \(token)"
                )
            }
        }
    }

    @MainActor
    func testMarkedPDFDOCXAndEPUBStayDeviceOnlyAcrossTTSAndQuickRead() async throws {
        let account = makeAccount(provider: .googleDrive)
        let accessToken = "provider-access-token-must-not-leave-provider"
        let refreshToken = "provider-refresh-token-must-not-leave-provider"
        let resourceKey = "provider-resource-key-must-not-leave-provider"

        var markedPDF = makePDFData()
        let pdfMarker = "CASTREADER-RAW-PDF-MARKER-9D3A"
        markedPDF.append(Data(pdfMarker.utf8))
        let docxMarker = "CASTREADER-RAW-DOCX-MARKER-7B2C"
        let markedDOCX = try makeDOCXData(
            title: "Allowed DOCX reading text",
            extraEntries: ["custom/no-upload-marker.bin": Data(docxMarker.utf8)]
        )
        let epubMarker = "CASTREADER-RAW-EPUB-MARKER-4F1E"
        let markedEPUB = try makeEPUBData(
            extraEntries: ["META-INF/no-upload-marker.bin": Data(epubMarker.utf8)]
        )
        let fixtures: [(format: SupportedDocumentFormat, data: Data, marker: String)] = [
            (.pdf, markedPDF, pdfMarker),
            (.docx, markedDOCX, docxMarker),
            (.epub, markedEPUB, epubMarker),
        ]
        let allMarkers = fixtures.map(\.marker)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudNoUploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        defer { CloudNoUploadURLProtocol.reset() }
        let credentialStore = CloudNoUploadCredentialStore(
            credential: GoogleDriveCredential(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                account: account,
                rawPermissionID: "integration-account"
            )
        )
        let provider = GoogleDriveProvider(
            configuration: GoogleDriveProvider.Configuration(
                clientID: "network-spy.apps.googleusercontent.com",
                redirectURI: "com.example.networkspy:/oauth2redirect",
                callbackScheme: "com.example.networkspy",
                driveAPIBaseURL: URL(string: "https://provider.invalid/drive/v3")!
            ),
            transport: GoogleDriveURLSessionTransport(session: session),
            credentialStore: credentialStore,
            webAuthenticator: CloudNoUploadWebAuthenticator()
        )
        let tts = APIService(session: session)
        let quickRead = QuickReadService(session: session)
        var allRequests: [URLRequest] = []

        for (index, fixture) in fixtures.enumerated() {
            let remoteID = "network-spy-\(fixture.format.rawValue)"
            let filename = "Network Spy.\(fixture.format.rawValue)"
            let item = makeItem(
                provider: .googleDrive,
                account: account,
                id: remoteID,
                name: filename,
                mimeType: fixture.format.preferredMIMEType,
                size: Int64(fixture.data.count),
                revision: "7|2026-08-10T08:00:00.000Z"
            )
            let metadata = """
            {
              "id":"\(remoteID)",
              "name":"\(filename)",
              "mimeType":"\(fixture.format.preferredMIMEType)",
              "size":"\(fixture.data.count)",
              "modifiedTime":"2026-08-10T08:00:00.000Z",
              "version":"7",
              "resourceKey":"\(resourceKey)",
              "capabilities":{"canDownload":true}
            }
            """
            CloudNoUploadURLProtocol.configure(
                metadata: Data(metadata.utf8),
                payload: fixture.data,
                payloadMIMEType: fixture.format.preferredMIMEType
            )

            let destination = temporaryFileURL(extension: fixture.format.rawValue)
            defer { try? FileManager.default.removeItem(at: destination) }
            let receipt = try await provider.download(item, to: destination)
            let result = try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    receipt: receipt,
                    origin: makeOrigin(item: item),
                    session: ImportSession(
                        epoch: UInt64(index + 1),
                        scenario: nil,
                        mode: .read
                    )
                )
            )

            XCTAssertEqual(result.format, fixture.format)
            XCTAssertEqual(try Data(contentsOf: destination), fixture.data)
            XCTAssertFalse(result.document.fullText.contains(fixture.marker))

            let providerRequests = CloudNoUploadURLProtocol.recordedRequests()
            XCTAssertEqual(providerRequests.count, 3)
            XCTAssertTrue(providerRequests.allSatisfy {
                $0.url?.host == "provider.invalid"
            })
            XCTAssertEqual(
                providerRequests.filter {
                    $0.url?.query?.contains("alt=media") == true
                }.count,
                1
            )

            let extractedText = result.document.fullText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowedText = extractedText.isEmpty
                ? result.document.title
                : extractedText
            _ = try await tts.generateTTS(
                text: allowedText,
                voice: "af_heart",
                language: "en"
            )
            let planRequest = ExtractPlanRequest(
                source_url: "castreader://cloud-document",
                title: result.document.title,
                lang: "en",
                depth: "standard",
                text: allowedText,
                fullText: allowedText,
                paragraphs: [QuickreadParagraphDTO(text: allowedText, type: "paragraph")],
                prev_summary: nil,
                content_type: nil
            )
            var receivedBlock0 = false
            _ = try await quickRead.extractPlan(
                planRequest,
                onStage: { _ in },
                onBlock0: { _ in receivedBlock0 = true }
            )
            XCTAssertTrue(receivedBlock0)

            let iterationRequests = CloudNoUploadURLProtocol.recordedRequests()
            let ttsRequest = try XCTUnwrap(iterationRequests.first {
                $0.url?.path == "/api/captioned_speech_partly"
            })
            let quickReadRequest = try XCTUnwrap(iterationRequests.first {
                $0.url?.path == "/api/quickread/extract-plan"
            })
            let decodedTTS = try JSONDecoder().decode(
                TTSRequest.self,
                from: try XCTUnwrap(ttsRequest.httpBody)
            )
            let decodedPlan = try JSONDecoder().decode(
                ExtractPlanRequest.self,
                from: try XCTUnwrap(quickReadRequest.httpBody)
            )
            XCTAssertEqual(
                decodedTTS.input,
                SpeechTextSanitizer.sanitizedForTTS(allowedText)
            )
            XCTAssertEqual(decodedPlan.text, allowedText)
            XCTAssertEqual(decodedPlan.fullText, allowedText)
            XCTAssertEqual(decodedPlan.paragraphs.map(\.text), [allowedText])
            XCTAssertEqual(decodedPlan.source_url, "castreader://cloud-document")

            for serviceRequest in [ttsRequest, quickReadRequest] {
                let envelope = Self.requestEnvelope(serviceRequest)
                for forbidden in allMarkers + [
                    accessToken,
                    refreshToken,
                    resourceKey,
                    remoteID,
                    filename,
                    "provider.invalid",
                ] {
                    XCTAssertFalse(
                        envelope.contains(forbidden),
                        "Service request leaked provider/container value: \(forbidden)"
                    )
                }
            }
            allRequests.append(contentsOf: iterationRequests)
        }

        XCTAssertEqual(
            allRequests.filter { $0.url?.path == "/api/captioned_speech_partly" }.count,
            fixtures.count
        )
        XCTAssertEqual(
            allRequests.filter { $0.url?.path == "/api/quickread/extract-plan" }.count,
            fixtures.count
        )
        for request in allRequests {
            let path = request.url?.path.lowercased() ?? ""
            XCTAssertNotEqual(path, "/sts")
            XCTAssertFalse(path.contains("/async-md-upload-by-url"))
            XCTAssertFalse(path == "/upload" || path.hasPrefix("/upload/"))
        }
    }

    // MARK: - Assertions and fixtures

    private func assertPipelineError(
        _ expected: DocumentImportError,
        request: DocumentImportRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await DocumentImportPipeline().importDocument(request)
            XCTFail("Expected import error \(expected)", file: file, line: line)
        } catch let error as DocumentImportError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected import error: \(error)", file: file, line: line)
        }
    }

    private func assertCancellationObserved(
        by operation: @escaping @Sendable () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let gate = LateResultGate<Void>()
        let task = Task.detached { () throws -> Void in
            await gate.wait()
            try operation()
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.release(())

        do {
            try await task.value
            XCTFail("Parser ignored cancellation", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected parser cancellation error: \(error)", file: file, line: line)
        }
    }

    private func assertPipelineCancellation(
        _ request: DocumentImportRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let gate = LateResultGate<Void>()
        let task = Task {
            await gate.wait()
            return try await DocumentImportPipeline().importDocument(request)
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.release(())

        do {
            _ = try await task.value
            XCTFail("Cancelled imports must not return a document", file: file, line: line)
        } catch let error as DocumentImportError {
            XCTAssertEqual(error, .cancelled, file: file, line: line)
        } catch {
            XCTFail("Unexpected pipeline cancellation error: \(error)", file: file, line: line)
        }
    }

    private func makeAccount(provider: CloudProviderID) -> CloudAccount {
        CloudAccount(
            provider: provider,
            stableAccountKey: CloudStableIdentifier.accountKey(
                provider: provider,
                rawAccountID: "integration-account"
            ),
            displayName: "Cloud Reader",
            maskedEmail: "r***@example.com"
        )
    }

    private func makeItem(
        provider: CloudProviderID,
        account: CloudAccount,
        driveID: String? = nil,
        id: String,
        name: String,
        mimeType: String,
        size: Int64,
        revision: String
    ) -> CloudItem {
        CloudItem(
            provider: provider,
            accountKey: account.stableAccountKey,
            driveID: driveID,
            id: id,
            name: name,
            mimeType: mimeType,
            size: size,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            revision: revision,
            kind: .file
        )
    }

    private func makeOrigin(item: CloudItem) -> CloudDocumentOrigin {
        CloudDocumentOrigin(
            provider: item.provider,
            accountKey: item.accountKey,
            driveID: item.driveID,
            remoteItemID: item.id,
            revision: item.revision,
            resourceKey: item.resourceKey,
            originalName: item.name,
            mimeType: item.mimeType
        )
    }

    private static func requestEnvelope(_ request: URLRequest) -> String {
        let headers = request.allHTTPHeaderFields?
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n") ?? ""
        let body = request.httpBody
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return [request.url?.absoluteString ?? "", headers, body]
            .joined(separator: "\n")
    }

    private func temporaryFileURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudImportIntegrationTests-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private func makePDFData() -> Data {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        return renderer.pdfData { context in
            context.beginPage()
            ("Cloud PDF device-only integration contract has readable text." as NSString).draw(
                at: CGPoint(x: 24, y: 24),
                withAttributes: [.font: UIFont.systemFont(ofSize: 16)]
            )
        }
    }

    private func makeDOCXData(
        title: String,
        extraEntries: [String: Data] = [:],
        compressedPaths: Set<String> = []
    ) throws -> Data {
        var entries: [String: Data] = [
            "[Content_Types].xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
                </Types>
                """.utf8),
            "word/document.xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:body><w:p><w:r><w:t>\(title)</w:t></w:r></w:p></w:body>
                </w:document>
                """.utf8),
        ]
        for (path, data) in extraEntries {
            entries[path] = data
        }
        return try makeZIP(entries: entries, compressedPaths: compressedPaths)
    }

    private func makeEPUBData(
        extraEntries: [String: Data] = [:]
    ) throws -> Data {
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                  </rootfiles>
                </container>
                """.utf8),
            "OEBPS/content.opf": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="book-id">cloud-contract</dc:identifier>
                    <dc:title>Cloud Import Contract</dc:title>
                    <dc:language>en</dc:language>
                  </metadata>
                  <manifest>
                    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="chapter"/></spine>
                </package>
                """.utf8),
            "OEBPS/chapter.xhtml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                  <head><title>Chapter</title></head>
                  <body>
                    <h1>Cloud chapter</h1>
                    <p>This device-only EPUB chapter is parsed locally for reading.</p>
                  </body>
                </html>
                """.utf8),
        ]
        for (path, data) in extraEntries {
            entries[path] = data
        }
        return try makeZIP(entries: entries)
    }

    private func makeZIP(
        entries: [String: Data],
        compressedPaths: Set<String> = []
    ) throws -> Data {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CloudImportIntegrationTests-ZIP-\(UUID().uuidString)",
                isDirectory: true
            )
        let zipURL = root.appendingPathExtension("zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: zipURL)
        }

        for (path, data) in entries {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        let archive = try Archive(url: zipURL, accessMode: .create)
        for path in entries.keys.sorted() {
            try archive.addEntry(
                with: path,
                fileURL: root.appendingPathComponent(path),
                compressionMethod: compressedPaths.contains(path) ? .deflate : .none
            )
        }
        return try Data(contentsOf: zipURL)
    }
}

private struct DownloadFixture: Sendable {
    let data: Data
    let filename: String
    let mimeType: String
    let format: SupportedDocumentFormat
    let revision: String?
}

private actor FakeAtomicCloudProvider: CloudAtomicPickerProvider {
    nonisolated let id = CloudProviderID.googleDrive
    nonisolated let selectionCapability =
        CloudSelectionCapability.authorizeAndPickInSystemBrowser

    private let account: CloudAccount
    private let item: CloudItem
    private let fixture: DownloadFixture
    private var destinations: [URL] = []

    init(account: CloudAccount, item: CloudItem, fixture: DownloadFixture) {
        self.account = account
        self.item = item
        self.fixture = fixture
    }

    func connectionState() async -> CloudConnectionState { .connected(account) }

    func authorizeAndPick() async throws -> (account: CloudAccount, item: CloudItem) {
        (account, item)
    }

    func disconnect() async -> CloudDisconnectResult {
        CloudDisconnectResult(
            provider: id,
            remoteRevocationStatus: .confirmed
        )
    }

    func download(
        _ requestedItem: CloudItem,
        exportFormat: CloudExportFormat?,
        to destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt {
        guard destination.isFileURL else { throw CloudStorageError.downloadNotAllowed }
        guard requestedItem == item else { throw CloudStorageError.itemUnavailable }
        destinations.append(destination)
        try fixture.data.write(to: destination, options: .atomic)
        progress(CloudDownloadProgress(
            completedBytes: Int64(fixture.data.count),
            totalBytes: Int64(fixture.data.count)
        ))
        return CloudDownloadReceipt(
            localURL: destination,
            effectiveFilename: fixture.filename,
            effectiveMIMEType: fixture.mimeType,
            effectiveFormat: fixture.format,
            exportFormat: exportFormat,
            finalRevision: fixture.revision,
            byteCount: Int64(fixture.data.count)
        )
    }

    func downloadDestinations() -> [URL] { destinations }
}

private actor FakeBrowsableCloudProvider: CloudBrowsableProvider {
    nonisolated let id: CloudProviderID
    nonisolated let selectionCapability =
        CloudSelectionCapability.persistentConnectionAndNativeBrowser

    private let account: CloudAccount
    private let item: CloudItem
    private var fixture: DownloadFixture
    private var destinations: [URL] = []

    init(
        id: CloudProviderID,
        account: CloudAccount,
        item: CloudItem,
        fixture: DownloadFixture
    ) {
        self.id = id
        self.account = account
        self.item = item
        self.fixture = fixture
    }

    func connectionState() async -> CloudConnectionState { .connected(account) }

    func ensureConnected() async throws -> CloudAccount { account }

    func list(folder: CloudFolder?, cursor: CloudCursor?) async throws -> CloudPage {
        CloudPage(items: [item])
    }

    func search(_ query: String, cursor: CloudCursor?) async throws -> CloudPage {
        CloudPage(items: item.name.localizedCaseInsensitiveContains(query) ? [item] : [])
    }

    func disconnect() async -> CloudDisconnectResult {
        CloudDisconnectResult(
            provider: id,
            remoteRevocationStatus: .unsupported
        )
    }

    func download(
        _ requestedItem: CloudItem,
        exportFormat: CloudExportFormat?,
        to destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt {
        guard destination.isFileURL else { throw CloudStorageError.downloadNotAllowed }
        guard requestedItem == item else { throw CloudStorageError.itemUnavailable }
        destinations.append(destination)
        try fixture.data.write(to: destination, options: .atomic)
        progress(CloudDownloadProgress(
            completedBytes: Int64(fixture.data.count),
            totalBytes: Int64(fixture.data.count)
        ))
        return CloudDownloadReceipt(
            localURL: destination,
            effectiveFilename: fixture.filename,
            effectiveMIMEType: fixture.mimeType,
            effectiveFormat: fixture.format,
            exportFormat: exportFormat,
            finalRevision: fixture.revision,
            byteCount: Int64(fixture.data.count)
        )
    }

    func setRevision(_ revision: String?) {
        fixture = DownloadFixture(
            data: fixture.data,
            filename: fixture.filename,
            mimeType: fixture.mimeType,
            format: fixture.format,
            revision: revision
        )
    }

    func downloadDestinations() -> [URL] { destinations }
}

private actor CloudNoUploadCredentialStore: GoogleDriveCredentialStoring {
    private var credential: GoogleDriveCredential?

    init(credential: GoogleDriveCredential) {
        self.credential = credential
    }

    func load() -> GoogleDriveCredential? { credential }
    func save(_ credential: GoogleDriveCredential) { self.credential = credential }
    func delete() { credential = nil }
    func replace(
        expected: GoogleDriveCredential?,
        with replacement: GoogleDriveCredential?
    ) -> Bool {
        guard credential == expected else { return false }
        credential = replacement
        return true
    }
}

@MainActor
private final class CloudNoUploadWebAuthenticator:
    GoogleDriveWebAuthenticating,
    @unchecked Sendable
{
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        throw CloudStorageError.provider(
            code: "network_spy_unexpected_oauth",
            retryable: false
        )
    }

    func cancel() {}
}

private final class CloudNoUploadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var metadata = Data()
    private static var payload = Data()
    private static var payloadMIMEType = "application/octet-stream"
    private static var requests: [URLRequest] = []

    static func configure(
        metadata: Data,
        payload: Data,
        payloadMIMEType: String
    ) {
        lock.lock()
        self.metadata = metadata
        self.payload = payload
        self.payloadMIMEType = payloadMIMEType
        requests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        metadata = Data()
        payload = Data()
        payloadMIMEType = "application/octet-stream"
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recordedRequest = Self.materializedRequest(request)
        Self.lock.lock()
        Self.requests.append(recordedRequest)
        let metadata = Self.metadata
        let payload = Self.payload
        let payloadMIMEType = Self.payloadMIMEType
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/api/captioned_speech_partly" {
            respond(
                to: url,
                contentType: "application/json",
                data: Data(
                    """
                    {"audio":"AA==","audio_format":"mp3","timestamps":[],"duration":0.1,"processed_text":"Allowed spoken text","unprocessed_text":""}
                    """.utf8
                )
            )
            return
        }
        if url.path == "/api/quickread/extract-plan" {
            respond(
                to: url,
                contentType: "text/event-stream",
                data: Data(
                    """
                    event: block0
                    data: {"job_id":"network-spy-job","output_language":"en","total_blocks":1,"block_0":{"id":"block-0","text":"Allowed explanation","style":"explain","cinematic":{"events":[]}}}

                    event: done
                    data: {"job_id":"network-spy-job","total_blocks":1,"model_used":"network-spy","page_summary":null}

                    """.utf8
                )
            )
            return
        }
        guard url.host == "provider.invalid" else {
            respond(
                to: url,
                statusCode: 599,
                contentType: "text/plain",
                data: Data("blocked unexpected request".utf8)
            )
            return
        }

        let isContent = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.contains(where: { $0.name == "alt" && $0.value == "media" }) == true
        let responseData = isContent ? payload : metadata
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": isContent ? payloadMIMEType : "application/json",
                "Content-Length": String(responseData.count),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func materializedRequest(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }

    private func respond(
        to url: URL,
        statusCode: Int = 200,
        contentType: String,
        data: Data
    ) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(data.count),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor LateResultGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func release(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
