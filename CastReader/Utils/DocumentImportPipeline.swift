//
//  DocumentImportPipeline.swift
//  CastReader
//
//  The only common parser entry for PDF, DOCX, EPUB and reflowable text. It accepts a local URL
//  and has no API capable of uploading bytes or falling back to backend import.
//

import Foundation
import PDFKit
import ZIPFoundation

enum DocumentResourceLimitReason: String, Equatable, Sendable {
    case inputFileTooLarge
    case insufficientDeviceStorage
    case archiveHasTooManyEntries
    case archiveEntryTooLarge
    case archiveExpandedSizeTooLarge
    case suspiciousCompressionRatio
}

enum DocumentImportError: Error, Equatable, Sendable {
    case cancelled
    case invalidLocalURL
    case fileReadFailed
    case emptyFile
    case unsupportedExtension(String)
    case extensionMismatch(expected: SupportedDocumentFormat, actual: String)
    case mimeTypeMismatch(expected: SupportedDocumentFormat, actual: String)
    case byteCountMismatch(expected: Int64, actual: Int64)
    case resourceLimitExceeded(DocumentResourceLimitReason)
    case invalidPDF
    case invalidDOCX(reason: String)
    case invalidEPUB(reason: String)
    case parseFailed(SupportedDocumentFormat)
}

struct ValidatedDocumentFile: Equatable, Sendable {
    let data: Data
    let format: SupportedDocumentFormat
    let filename: String
    let mimeType: String?
}

/// Validates only ZIP directory metadata and therefore never inflates an
/// entry. DOCX and EPUB both pass through this gate before inspecting their
/// required XML files. Metadata is untrusted, so extraction sites also retain
/// bounded chunk accounting.
enum DocumentArchiveValidator {
    static func validate(
        _ archive: Archive,
        limits: DocumentArchiveResourceLimits = DocumentResourceLimits.archive
    ) throws {
        try Task.checkCancellation()
        var entryCount = 0
        var totalUncompressedBytes: UInt64 = 0

        for entry in archive {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw DocumentImportError.resourceLimitExceeded(.archiveHasTooManyEntries)
            }

            let uncompressedBytes = entry.uncompressedSize
            guard uncompressedBytes <= limits.maximumEntryUncompressedBytes else {
                throw DocumentImportError.resourceLimitExceeded(.archiveEntryTooLarge)
            }

            let (newTotal, overflowed) = totalUncompressedBytes.addingReportingOverflow(
                uncompressedBytes
            )
            guard !overflowed, newTotal <= limits.maximumTotalUncompressedBytes else {
                throw DocumentImportError.resourceLimitExceeded(.archiveExpandedSizeTooLarge)
            }
            totalUncompressedBytes = newTotal

            guard entry.isCompressed,
                  uncompressedBytes >= limits.compressionRatioMinimumBytes else {
                continue
            }
            let compressedBytes = entry.compressedSize
            guard compressedBytes > 0 else {
                throw DocumentImportError.resourceLimitExceeded(.suspiciousCompressionRatio)
            }
            let (maximumSafeBytes, ratioOverflowed) = compressedBytes.multipliedReportingOverflow(
                by: limits.maximumCompressionRatio
            )
            if !ratioOverflowed, uncompressedBytes > maximumSafeBytes {
                throw DocumentImportError.resourceLimitExceeded(.suspiciousCompressionRatio)
            }
        }
        try Task.checkCancellation()
    }
}

enum DocumentFormatValidator {
    private static let genericBinaryMIMEs: Set<String> = [
        "application/octet-stream",
        "binary/octet-stream"
    ]

    static func validate(
        data: Data,
        filename: String,
        declaredExtension: String? = nil,
        mimeType: String? = nil,
        expectedFormat: SupportedDocumentFormat? = nil,
        expectedByteCount: Int64? = nil
    ) throws -> ValidatedDocumentFile {
        try Task.checkCancellation()
        let filenameExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard let extensionFormat = SupportedDocumentFormat(fileExtension: filenameExtension) else {
            throw DocumentImportError.unsupportedExtension(filenameExtension)
        }
        if let declaredExtension {
            let normalized = declaredExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == filenameExtension else {
                throw DocumentImportError.extensionMismatch(
                    expected: extensionFormat,
                    actual: normalized
                )
            }
        }
        if let expectedFormat, expectedFormat != extensionFormat {
            throw DocumentImportError.extensionMismatch(
                expected: expectedFormat,
                actual: filenameExtension
            )
        }

        let format = expectedFormat ?? extensionFormat
        let maximumInputBytes = format.maximumInputBytes
        guard Int64(data.count) <= maximumInputBytes else {
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
        if let expectedByteCount,
           expectedByteCount > maximumInputBytes {
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
        guard !data.isEmpty else { throw DocumentImportError.emptyFile }
        if let expectedByteCount, expectedByteCount >= 0,
           expectedByteCount != Int64(data.count) {
            throw DocumentImportError.byteCountMismatch(
                expected: expectedByteCount,
                actual: Int64(data.count)
            )
        }

        let normalizedMIME = normalizeMIME(mimeType)
        if let normalizedMIME,
           !acceptedMIMETypes(for: format).contains(normalizedMIME),
           !(format == .text && normalizedMIME.hasPrefix("text/")) {
            throw DocumentImportError.mimeTypeMismatch(
                expected: format,
                actual: normalizedMIME
            )
        }

        switch format {
        case .pdf:
            try validatePDF(data)
        case .docx:
            try validateDOCX(data)
        case .epub:
            try validateEPUB(data)
        case .text:
            // Text decoding is extension-aware (Markdown versus RTF) and is
            // performed by DocumentBuilder after this shared size/MIME gate.
            break
        }
        try Task.checkCancellation()

        return ValidatedDocumentFile(
            data: data,
            format: format,
            filename: filename,
            mimeType: normalizedMIME
        )
    }

    static func validate(
        fileAt url: URL,
        filename: String,
        declaredExtension: String? = nil,
        mimeType: String? = nil,
        expectedFormat: SupportedDocumentFormat? = nil,
        expectedByteCount: Int64? = nil
    ) throws -> ValidatedDocumentFile {
        try Task.checkCancellation()
        guard url.isFileURL else { throw DocumentImportError.invalidLocalURL }
        let filenameExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard let extensionFormat = SupportedDocumentFormat(fileExtension: filenameExtension) else {
            throw DocumentImportError.unsupportedExtension(filenameExtension)
        }
        if let expectedFormat, expectedFormat != extensionFormat {
            throw DocumentImportError.extensionMismatch(
                expected: expectedFormat,
                actual: filenameExtension
            )
        }
        let resolvedFormat = expectedFormat ?? extensionFormat
        let maximumInputBytes = resolvedFormat.maximumInputBytes
        if let expectedByteCount,
           expectedByteCount > maximumInputBytes {
            // Cloud metadata is checked before touching the downloaded file.
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            try Task.checkCancellation()
            throw DocumentImportError.fileReadFailed
        }
        try Task.checkCancellation()
        guard resourceValues.isRegularFile == true,
              let fileSize = resourceValues.fileSize,
              fileSize >= 0 else {
            throw DocumentImportError.fileReadFailed
        }
        let actualByteCount = Int64(fileSize)
        guard actualByteCount <= maximumInputBytes else {
            // fileSize is the logical size, so sparse files cannot evade this
            // preflight by consuming only a few allocated blocks.
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
        if let expectedByteCount, expectedByteCount >= 0,
           expectedByteCount != actualByteCount {
            throw DocumentImportError.byteCountMismatch(
                expected: expectedByteCount,
                actual: actualByteCount
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            try Task.checkCancellation()
            throw DocumentImportError.fileReadFailed
        }
        try Task.checkCancellation()
        return try validate(
            data: data,
            filename: filename,
            declaredExtension: declaredExtension,
            mimeType: mimeType,
            expectedFormat: expectedFormat,
            expectedByteCount: expectedByteCount
        )
    }

    private static func normalizeMIME(_ mimeType: String?) -> String? {
        guard let value = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty else { return nil }
        return value
    }

    private static func acceptedMIMETypes(for format: SupportedDocumentFormat) -> Set<String> {
        var values = genericBinaryMIMEs
        switch format {
        case .pdf:
            values.formUnion(["application/pdf", "application/x-pdf"])
        case .docx:
            values.formUnion([
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "application/zip",
                "application/x-zip-compressed"
            ])
        case .epub:
            values.formUnion([
                "application/epub+zip",
                "application/x-epub+zip",
                "application/zip",
                "application/x-zip-compressed"
            ])
        case .text:
            values.formUnion([
                "text/plain",
                "text/markdown",
                "text/x-markdown",
                "application/rtf",
                "text/rtf",
                "application/x-rtf",
                "application/json",
                "application/ld+json",
                "application/x-ndjson",
                "application/jsonl",
                "application/xml",
                "application/xhtml+xml",
                "application/yaml",
                "application/x-yaml",
                "application/x-tex"
            ])
        }
        return values
    }

    private static func validatePDF(_ data: Data) throws {
        try Task.checkCancellation()
        guard data.starts(with: Data("%PDF-".utf8)),
              let document = PDFDocument(data: data),
              document.pageCount > 0,
              !document.isLocked else {
            try Task.checkCancellation()
            throw DocumentImportError.invalidPDF
        }
        try Task.checkCancellation()
    }

    private static func validateDOCX(_ data: Data) throws {
        try Task.checkCancellation()
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read, pathEncoding: nil)
        } catch {
            try Task.checkCancellation()
            throw DocumentImportError.invalidDOCX(reason: "invalid_zip")
        }
        try Task.checkCancellation()
        try DocumentArchiveValidator.validate(
            archive,
            limits: DocumentResourceLimits.docxArchive
        )
        guard let contentTypes = archive["[Content_Types].xml"], contentTypes.type == .file else {
            throw DocumentImportError.invalidDOCX(reason: "missing_content_types")
        }
        guard let document = archive["word/document.xml"],
              document.type == .file,
              document.uncompressedSize > 0 else {
            throw DocumentImportError.invalidDOCX(reason: "missing_word_document")
        }
        let contentTypeData = try readEntry(
            contentTypes,
            from: archive,
            maximumUncompressedBytes: 1_048_576,
            error: .invalidDOCX(reason: "invalid_content_types")
        )
        guard let xml = String(data: contentTypeData, encoding: .utf8),
              xml.contains("word/document.xml"),
              xml.localizedCaseInsensitiveContains("wordprocessingml.document.main+xml") else {
            throw DocumentImportError.invalidDOCX(reason: "not_wordprocessing_document")
        }
        try Task.checkCancellation()
    }

    private static func validateEPUB(_ data: Data) throws {
        try Task.checkCancellation()
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read, pathEncoding: nil)
        } catch {
            try Task.checkCancellation()
            throw DocumentImportError.invalidEPUB(reason: "invalid_zip")
        }
        try Task.checkCancellation()
        try DocumentArchiveValidator.validate(archive)
        guard let mimetypeEntry = archive["mimetype"], mimetypeEntry.type == .file else {
            throw DocumentImportError.invalidEPUB(reason: "missing_mimetype")
        }
        let mimetypeData = try readEntry(
            mimetypeEntry,
            from: archive,
            maximumUncompressedBytes: 256,
            error: .invalidEPUB(reason: "invalid_mimetype")
        )
        guard String(data: mimetypeData, encoding: .utf8) == "application/epub+zip" else {
            throw DocumentImportError.invalidEPUB(reason: "invalid_mimetype")
        }
        guard let containerEntry = archive["META-INF/container.xml"], containerEntry.type == .file else {
            throw DocumentImportError.invalidEPUB(reason: "missing_container")
        }
        let containerData = try readEntry(
            containerEntry,
            from: archive,
            maximumUncompressedBytes: 1_048_576,
            error: .invalidEPUB(reason: "invalid_container")
        )
        guard let xml = String(data: containerData, encoding: .utf8),
              xml.localizedCaseInsensitiveContains("<rootfile"),
              xml.localizedCaseInsensitiveContains("full-path") else {
            throw DocumentImportError.invalidEPUB(reason: "invalid_container")
        }
        try Task.checkCancellation()
    }

    private static func readEntry(
        _ entry: Entry,
        from archive: Archive,
        maximumUncompressedBytes: UInt64,
        error: DocumentImportError
    ) throws -> Data {
        try Task.checkCancellation()
        guard entry.uncompressedSize <= maximumUncompressedBytes else { throw error }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                let chunkBytes = UInt64(chunk.count)
                guard UInt64(result.count) <= maximumUncompressedBytes,
                      chunkBytes <= maximumUncompressedBytes - UInt64(result.count) else {
                    throw error
                }
                result.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return result
    }
}

/// `Task.detached` does not inherit cancellation from its awaiting parent.
/// Parser work is intentionally detached from the main actor, but every use
/// goes through this bridge so cancellation is forwarded to the child and a
/// late non-cancellation result cannot escape a cancelled parent task.
enum DocumentImportDetachedTask {
    static func run<Value>(
        priority: TaskPriority? = .userInitiated,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let child = Task.detached(priority: priority, operation: operation)

        do {
            let value = try await withTaskCancellationHandler {
                try await child.value
            } onCancel: {
                child.cancel()
            }
            try Task.checkCancellation()
            return value
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

enum DocumentImportStage: Equatable, Sendable {
    case checkingFile
    case parsing(SupportedDocumentFormat)
    case preparingReader
}

struct DocumentImportProgress: Equatable, Sendable {
    let stage: DocumentImportStage
}

typealias DocumentImportProgressHandler = @Sendable (DocumentImportProgress) -> Void

struct DocumentImportRequest: Sendable {
    let localURL: URL
    let effectiveFilename: String
    let declaredExtension: String?
    let effectiveMIMEType: String?
    let expectedFormat: SupportedDocumentFormat?
    let expectedByteCount: Int64?
    let finalRevision: String?
    let exportFormat: CloudExportFormat?
    let origin: CloudDocumentOrigin?
    let persistencePolicy: DocumentPersistencePolicy
    let transportPolicy: DocumentImportTransportPolicy
    let requiresSecurityScopedAccess: Bool
    let session: ImportSession?

    init(
        localURL: URL,
        effectiveFilename: String? = nil,
        declaredExtension: String? = nil,
        effectiveMIMEType: String? = nil,
        expectedFormat: SupportedDocumentFormat? = nil,
        expectedByteCount: Int64? = nil,
        finalRevision: String? = nil,
        exportFormat: CloudExportFormat? = nil,
        origin: CloudDocumentOrigin? = nil,
        persistencePolicy: DocumentPersistencePolicy? = nil,
        transportPolicy: DocumentImportTransportPolicy = .deviceOnly,
        requiresSecurityScopedAccess: Bool = false,
        session: ImportSession? = nil
    ) {
        self.localURL = localURL
        self.effectiveFilename = effectiveFilename ?? localURL.lastPathComponent
        self.declaredExtension = declaredExtension
        self.effectiveMIMEType = effectiveMIMEType
        self.expectedFormat = expectedFormat
        self.expectedByteCount = expectedByteCount
        self.finalRevision = finalRevision
        self.exportFormat = exportFormat
        self.origin = origin
        self.persistencePolicy = persistencePolicy
            ?? (origin == nil ? .localPayload : .remoteReference)
        self.transportPolicy = transportPolicy
        self.requiresSecurityScopedAccess = requiresSecurityScopedAccess
        self.session = session
    }

    init(
        receipt: CloudDownloadReceipt,
        origin: CloudDocumentOrigin,
        session: ImportSession
    ) {
        self.init(
            localURL: receipt.localURL,
            effectiveFilename: receipt.effectiveFilename,
            declaredExtension: receipt.effectiveExtension,
            effectiveMIMEType: receipt.effectiveMIMEType,
            expectedFormat: receipt.effectiveFormat,
            expectedByteCount: receipt.byteCount,
            finalRevision: receipt.finalRevision,
            exportFormat: receipt.exportFormat,
            origin: origin,
            persistencePolicy: .remoteReference,
            transportPolicy: .deviceOnly,
            requiresSecurityScopedAccess: false,
            session: session
        )
    }
}

/// 保留独立结果字段便于调用方打点，同一组元数据也会附到
/// `document` 上，避免进入播放器或历史库后丢失云盘身份。
struct DocumentImportResult: Equatable, @unchecked Sendable {
    let document: ReadingDocument
    let format: SupportedDocumentFormat
    let origin: CloudDocumentOrigin?
    let persistencePolicy: DocumentPersistencePolicy
    let contentSessionKey: String
    let effectiveFilename: String
    let finalRevision: String?
    let exportFormat: CloudExportFormat?
    let byteCount: Int64
    let session: ImportSession?
}

struct DocumentImportPipeline: Sendable {
    func importDocument(
        _ request: DocumentImportRequest,
        progress: @escaping DocumentImportProgressHandler = { _ in }
    ) async throws -> DocumentImportResult {
        do {
            try Task.checkCancellation()
            // This explicit guard remains valuable if transport policies gain
            // cases later: cloud callers cannot silently inherit an upload fallback.
            guard request.transportPolicy == .deviceOnly else {
                throw DocumentImportError.invalidLocalURL
            }
            guard request.localURL.isFileURL else {
                throw DocumentImportError.invalidLocalURL
            }

            let didAccess = request.requiresSecurityScopedAccess
                && request.localURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess { request.localURL.stopAccessingSecurityScopedResource() }
            }

            progress(DocumentImportProgress(stage: .checkingFile))
            let validated = try await DocumentImportDetachedTask.run {
                try DocumentFormatValidator.validate(
                    fileAt: request.localURL,
                    filename: request.effectiveFilename,
                    declaredExtension: request.declaredExtension,
                    mimeType: request.effectiveMIMEType,
                    expectedFormat: request.expectedFormat,
                    expectedByteCount: request.expectedByteCount
                )
            }

            try Task.checkCancellation()
            progress(DocumentImportProgress(stage: .parsing(validated.format)))
            let built: ReadingDocument?
            switch validated.format {
            case .pdf:
                built = try await DocumentBuilder.fromPDFWithOCR(
                    data: validated.data,
                    fallbackTitle: fallbackTitle(for: validated.filename)
                )
            case .docx:
                let title = try await DocumentImportDetachedTask.run {
                    try DocumentBuilder.docxTitleCancellable(data: validated.data)
                } ?? fallbackTitle(for: validated.filename)
                built = ReadingDocument(
                    title: title,
                    sourceKind: .docx,
                    paragraphs: [],
                    fileData: validated.data
                )
            case .epub:
                built = try await DocumentImportDetachedTask.run {
                    try DocumentBuilder.fromEPUBCancellable(
                        data: validated.data,
                        title: fallbackTitle(for: validated.filename)
                    )
                }
            case .text:
                built = try await DocumentImportDetachedTask.run {
                    guard let document = try DocumentBuilder.fromTextDataCancellable(
                        data: validated.data,
                        filename: validated.filename,
                        title: fallbackTitle(for: validated.filename)
                    ), !document.isEmpty else { return nil }
                    return document
                }
            }

            try Task.checkCancellation()
            guard let built else { throw DocumentImportError.parseFailed(validated.format) }
            let stableDocumentID = request.origin?.stableDocumentID ?? built.id
            let revision = request.finalRevision ?? request.origin?.revision
            let resolvedOrigin = request.origin?.replacingDownloadedMetadata(
                revision: revision,
                effectiveFilename: validated.filename,
                effectiveMIMEType: request.effectiveMIMEType,
                isExport: request.exportFormat != nil
            )
            let resolvedPersistencePolicy: DocumentPersistencePolicy = resolvedOrigin == nil
                ? request.persistencePolicy
                : .remoteReference
            let sessionKey = resolvedOrigin == nil
                ? stableDocumentID
                : CloudStableIdentifier.contentSessionKey(
                    documentID: stableDocumentID,
                    revision: revision,
                    format: validated.format
                )
            var document = replacingID(of: built, with: stableDocumentID)
            // Cloud History represents the remote file, so its visible title
            // follows a provider-side rename instead of remaining pinned to an
            // embedded PDF/Office title from an earlier revision.
            if resolvedOrigin != nil {
                document.title = fallbackTitle(for: validated.filename)
            }
            document.origin = resolvedOrigin
            document.persistencePolicy = resolvedPersistencePolicy
            document.effectiveFormat = validated.format
            document.exportFormat = request.exportFormat
            document.contentRevision = revision
            document.contentSessionKey = sessionKey

            try Task.checkCancellation()
            progress(DocumentImportProgress(stage: .preparingReader))
            try Task.checkCancellation()
            return DocumentImportResult(
                document: document,
                format: validated.format,
                origin: resolvedOrigin,
                persistencePolicy: resolvedPersistencePolicy,
                contentSessionKey: sessionKey,
                effectiveFilename: validated.filename,
                finalRevision: revision,
                exportFormat: request.exportFormat,
                byteCount: Int64(validated.data.count),
                session: request.session
            )
        } catch is CancellationError {
            throw DocumentImportError.cancelled
        } catch let error as DocumentImportError {
            if error == .cancelled || Task.isCancelled {
                throw DocumentImportError.cancelled
            }
            throw error
        } catch {
            if Task.isCancelled {
                throw DocumentImportError.cancelled
            }
            throw error
        }
    }

    private func fallbackTitle(for filename: String) -> String {
        let title = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Document" : title
    }

    /// DocumentBuilder currently creates a fresh UUID and ReadingDocument.id
    /// is immutable. Rebuild the value so cloud history receives its stable ID.
    private func replacingID(of document: ReadingDocument, with id: String) -> ReadingDocument {
        guard document.id != id else { return document }
        return ReadingDocument(
            id: id,
            title: document.title,
            sourceKind: document.sourceKind,
            language: document.language,
            paragraphs: document.paragraphs,
            imageData: document.imageData,
            imagePixelSize: document.imagePixelSize,
            sourceURL: document.sourceURL,
            coverURL: document.coverURL,
            fileData: document.fileData,
            origin: document.origin,
            persistencePolicy: document.persistencePolicy,
            effectiveFormat: document.effectiveFormat,
            exportFormat: document.exportFormat,
            contentRevision: document.contentRevision,
            contentSessionKey: document.contentSessionKey,
            youtubeTranscript: document.youtubeTranscript,
            youtubeCacheHit: document.youtubeCacheHit,
            layoutColumnCount: document.layoutColumnCount,
            createdAt: document.createdAt
        )
    }
}
