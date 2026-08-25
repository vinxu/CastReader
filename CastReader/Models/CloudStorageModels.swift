//
//  CloudStorageModels.swift
//  CastReader
//
//  Provider-neutral value types for device-only cloud document imports.
//  OAuth tokens and provider SDK objects deliberately never cross these DTOs.
//

import CryptoKit
import Foundation

// MARK: - Provider and capability

enum CloudProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case googleDrive = "google_drive"
    case dropbox
    case oneDrive = "onedrive"

    /// This release exposes the verified Google integration only. The other
    /// cases remain decodable so old device-local records do not become corrupt.
    static let allCases: [CloudProviderID] = [.googleDrive]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .googleDrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "Microsoft OneDrive"
        }
    }
}

enum CloudSelectionCapability: String, Codable, Equatable, Sendable {
    /// Legacy atomic Picker capability retained for migration and tests.
    case authorizeAndPickInSystemBrowser

    /// Establish a durable connection, then browse with CastReader's native
    /// file browser.
    case persistentConnectionAndNativeBrowser
}

struct CloudAtomicPickResult: Equatable, Sendable {
    let account: CloudAccount
    let item: CloudItem
    let requiresAccountSwitchConfirmation: Bool
}

// MARK: - Account and connection

struct CloudAccount: Codable, Equatable, Sendable {
    let provider: CloudProviderID

    /// A provider account identifier hashed locally before it reaches this
    /// model. It is suitable for local association matching, not analytics.
    let stableAccountKey: String
    let displayName: String?
    let maskedEmail: String?

    init(
        provider: CloudProviderID,
        stableAccountKey: String,
        displayName: String? = nil,
        maskedEmail: String? = nil
    ) {
        self.provider = provider
        self.stableAccountKey = stableAccountKey
        self.displayName = displayName
        self.maskedEmail = maskedEmail
    }
}

enum CloudConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(CloudAccount)
    case needsReauthorization(CloudAccount?)
}

enum CloudRemoteRevocationStatus: String, Codable, Equatable, Sendable {
    case confirmed
    case unconfirmed
    case unsupported
}

/// Disconnect always removes the active association on this device. The
/// separate remote status prevents the UI from falsely claiming that provider
/// authorization was revoked when that network operation failed or timed out.
struct CloudDisconnectResult: Codable, Equatable, Sendable {
    let provider: CloudProviderID
    let localAssociationRemoved: Bool
    let remoteRevocationStatus: CloudRemoteRevocationStatus
    let retryable: Bool
    let diagnosticCode: String?

    init(
        provider: CloudProviderID,
        localAssociationRemoved: Bool = true,
        remoteRevocationStatus: CloudRemoteRevocationStatus,
        retryable: Bool = false,
        diagnosticCode: String? = nil
    ) {
        self.provider = provider
        self.localAssociationRemoved = localAssociationRemoved
        self.remoteRevocationStatus = remoteRevocationStatus
        self.retryable = retryable
        self.diagnosticCode = diagnosticCode
    }
}

// MARK: - Browser values

enum CloudItemKind: String, Codable, Equatable, Sendable {
    case file
    case folder
    case exportableDocument
    case unsupported
}

enum CloudExportFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case pdf
    case docx

    var documentFormat: SupportedDocumentFormat {
        switch self {
        case .pdf: return .pdf
        case .docx: return .docx
        }
    }
}

enum SupportedDocumentFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case pdf
    case docx
    case epub
    /// Reflowable text documents. The concrete filename extension remains the
    /// parser hint, so TXT, Markdown and RTF share one reader/history format
    /// without losing their individual decoding rules.
    case text

    init?(fileExtension: String) {
        switch fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pdf": self = .pdf
        case "docx": self = .docx
        case "epub": self = .epub
        case "txt", "text", "md", "markdown", "rtf",
             "html", "htm", "xhtml",
             "csv", "tsv",
             "json", "jsonl", "ndjson",
             "xml", "yaml", "yml",
             "log", "ini", "conf", "cfg",
             "srt", "vtt", "tex":
            self = .text
        default: return nil
        }
    }

    /// Resolves a document format from either a trustworthy filename suffix
    /// or the provider MIME facet. Cloud providers do not consistently keep
    /// an extension on text files, so MIME is a required fallback for those
    /// otherwise-readable documents.
    static func resolve(filename: String, mimeType: String?) -> Self? {
        if let format = Self(
            fileExtension: URL(fileURLWithPath: filename).pathExtension
        ) {
            return format
        }

        let normalizedMIME = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedMIME?.hasPrefix("text/") == true {
            return .text
        }
        switch normalizedMIME {
        case "application/pdf", "application/x-pdf":
            return .pdf
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return .docx
        case "application/epub+zip", "application/x-epub+zip":
            return .epub
        case "application/rtf", "application/x-rtf",
             "application/json", "application/ld+json",
             "application/x-ndjson", "application/jsonl",
             "application/xml", "application/xhtml+xml",
             "application/yaml", "application/x-yaml", "application/x-tex":
            return .text
        default:
            return nil
        }
    }

    /// Keeps a useful parser hint on the device-only temporary file. For
    /// example, an extensionless `text/html` item must become `.html`, not a
    /// generic `.text`, so the local builder removes markup before reading.
    static func normalizedFilename(
        _ filename: String,
        format: Self,
        mimeType: String?
    ) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = URL(fileURLWithPath: trimmed.isEmpty ? "document" : trimmed)
            .lastPathComponent
        let existingExtension = URL(fileURLWithPath: leaf).pathExtension.lowercased()
        if Self(fileExtension: existingExtension) == format {
            if format == .text,
               let preferred = preferredTextExtension(for: mimeType),
               !textExtensionsEquivalent(existingExtension, preferred) {
                return replacingExtension(of: leaf, with: preferred)
            }
            return leaf
        }

        let preferredExtension = format == .text
            ? (preferredTextExtension(for: mimeType) ?? format.preferredFileExtension)
            : format.preferredFileExtension
        return replacingExtension(of: leaf, with: preferredExtension)
    }

    private static func preferredTextExtension(for mimeType: String?) -> String? {
        let normalized = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        // Preserve a meaningful existing suffix for generic plain text.
        case "text/plain": return nil
        case "text/markdown", "text/x-markdown": return "md"
        case "application/rtf", "text/rtf", "application/x-rtf": return "rtf"
        case "text/html", "application/xhtml+xml": return "html"
        case "text/csv": return "csv"
        case "text/tab-separated-values": return "tsv"
        case "application/json", "application/ld+json": return "json"
        case "application/x-ndjson", "application/jsonl": return "jsonl"
        case "application/xml", "text/xml": return "xml"
        case "application/yaml", "application/x-yaml", "text/yaml": return "yaml"
        case "text/vtt": return "vtt"
        case "application/x-tex", "text/x-tex": return "tex"
        default: return nil
        }
    }

    private static func textExtensionsEquivalent(_ existing: String, _ preferred: String) -> Bool {
        switch preferred {
        case "md": return existing == "md" || existing == "markdown"
        case "html": return ["html", "htm", "xhtml"].contains(existing)
        case "jsonl": return ["jsonl", "ndjson"].contains(existing)
        case "yaml": return existing == "yaml" || existing == "yml"
        default: return existing == preferred
        }
    }

    private static func replacingExtension(of filename: String, with newExtension: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "document" : base) + "." + newExtension
    }

    var preferredFileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .epub: return "epub"
        case .text: return "txt"
        }
    }

    var preferredMIMEType: String {
        switch self {
        case .pdf: return "application/pdf"
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .epub: return "application/epub+zip"
        case .text: return "text/plain"
        }
    }

    /// Parser/rendering-aware compressed input cap. DOCX is intentionally
    /// much lower because the current reader retains the archive, creates a
    /// base64 copy and passes it into WKWebView/mammoth. These values apply to
    /// local files and every cloud provider alike.
    var maximumInputBytes: Int64 {
        switch self {
        case .pdf: return 200 * 1_024 * 1_024
        case .docx: return 40 * 1_024 * 1_024
        case .epub: return 120 * 1_024 * 1_024
        // Text is decoded and retained as Swift String plus paragraph storage;
        // keep the input cap conservative to avoid multi-copy memory spikes.
        case .text: return 20 * 1_024 * 1_024
        }
    }
}

struct CloudCursor: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct CloudFolder: Identifiable, Codable, Equatable, Sendable {
    let provider: CloudProviderID
    let accountKey: String
    let driveID: String?
    let id: String
    let name: String

    init(
        provider: CloudProviderID,
        accountKey: String,
        driveID: String? = nil,
        id: String,
        name: String
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.driveID = driveID
        self.id = id
        self.name = name
    }
}

/// A user-owned OneDrive returned by Microsoft Graph `/me/drives`. This list
/// is intentionally not a SharePoint/Teams discovery surface.
struct CloudDrive: Identifiable, Codable, Equatable, Sendable {
    let provider: CloudProviderID
    let accountKey: String
    let id: String
    let name: String
    let isDefault: Bool

    init(
        provider: CloudProviderID,
        accountKey: String,
        id: String,
        name: String,
        isDefault: Bool = false
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

struct CloudItem: Identifiable, Codable, Equatable, Sendable {
    let provider: CloudProviderID
    let accountKey: String
    let driveID: String?
    let id: String
    let name: String
    let mimeType: String?
    let size: Int64?
    let modifiedAt: Date?
    let revision: String?
    /// Google Drive link-shared files may require this value on subsequent
    /// metadata and content requests. Other providers leave it nil.
    let resourceKey: String?
    let kind: CloudItemKind
    let exportOptions: [CloudExportFormat]

    init(
        provider: CloudProviderID,
        accountKey: String,
        driveID: String? = nil,
        id: String,
        name: String,
        mimeType: String? = nil,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        revision: String? = nil,
        resourceKey: String? = nil,
        kind: CloudItemKind,
        exportOptions: [CloudExportFormat] = []
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.driveID = driveID
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.resourceKey = resourceKey
        self.kind = kind
        self.exportOptions = exportOptions
    }
}

struct CloudPage: Equatable, Sendable {
    let folders: [CloudFolder]
    let items: [CloudItem]
    let nextCursor: CloudCursor?

    init(
        folders: [CloudFolder] = [],
        items: [CloudItem] = [],
        nextCursor: CloudCursor? = nil
    ) {
        self.folders = folders
        self.items = items
        self.nextCursor = nextCursor
    }
}

// MARK: - Device resource limits

/// ZIP limits are deliberately based on the archive directory metadata, so a
/// hostile DOCX/EPUB is rejected before the first entry is inflated. Callers
/// that do inflate entries must additionally enforce these byte budgets while
/// consuming chunks because ZIP metadata is untrusted.
struct DocumentArchiveResourceLimits: Equatable, Sendable {
    let maximumEntryCount: Int
    let maximumEntryUncompressedBytes: UInt64
    let maximumTotalUncompressedBytes: UInt64
    let maximumCompressionRatio: UInt64
    let compressionRatioMinimumBytes: UInt64
}

/// One policy is shared by local file imports and all cloud providers. Keeping
/// it provider-neutral prevents a remote source from bypassing the same memory
/// safety boundary that applies to Files.app imports.
enum DocumentResourceLimits {
    /// The parsers retain the original payload and may create decoded working
    /// copies, so cap the compressed/input file well below typical iOS memory.
    static let maximumInputBytes: Int64 = SupportedDocumentFormat.allCases
        .map(\.maximumInputBytes)
        .max() ?? 200 * 1_024 * 1_024

    static let archive = DocumentArchiveResourceLimits(
        maximumEntryCount: 20_000,
        maximumEntryUncompressedBytes: 64 * 1_024 * 1_024,
        maximumTotalUncompressedBytes: 512 * 1_024 * 1_024,
        maximumCompressionRatio: 200,
        // Tiny XML files can legitimately compress by a high ratio. Apply the
        // ratio heuristic only once an entry is large enough to be dangerous.
        compressionRatioMinimumBytes: 1 * 1_024 * 1_024
    )

    static let docxArchive = DocumentArchiveResourceLimits(
        maximumEntryCount: 20_000,
        maximumEntryUncompressedBytes: 32 * 1_024 * 1_024,
        maximumTotalUncompressedBytes: 256 * 1_024 * 1_024,
        maximumCompressionRatio: 200,
        compressionRatioMinimumBytes: 1 * 1_024 * 1_024
    )

    static func maximumInputBytes(
        for item: CloudItem,
        exportFormat: CloudExportFormat?
    ) -> Int64 {
        if let exportFormat { return exportFormat.documentFormat.maximumInputBytes }
        if let format = SupportedDocumentFormat(
            fileExtension: URL(fileURLWithPath: item.name).pathExtension
        ) {
            return format.maximumInputBytes
        }
        switch item.mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .lowercased() {
        case "application/pdf", "application/x-pdf":
            return SupportedDocumentFormat.pdf.maximumInputBytes
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return SupportedDocumentFormat.docx.maximumInputBytes
        case "application/epub+zip", "application/x-epub+zip":
            return SupportedDocumentFormat.epub.maximumInputBytes
        case let value? where value.hasPrefix("text/"):
            return SupportedDocumentFormat.text.maximumInputBytes
        case "application/rtf", "application/x-rtf",
             "application/json", "application/ld+json",
             "application/x-ndjson", "application/jsonl",
             "application/xml", "application/xhtml+xml",
             "application/yaml", "application/x-yaml", "application/x-tex":
            return SupportedDocumentFormat.text.maximumInputBytes
        default:
            return maximumInputBytes
        }
    }
}

// MARK: - Download and document origin

struct CloudDocumentOrigin: Codable, Equatable, Sendable {
    let provider: CloudProviderID
    let accountKey: String
    /// Optional, already-masked account label for device-only History UI.
    /// Never use an unmasked email or provider account identifier here.
    let maskedAccountHint: String?
    let driveID: String?
    let remoteItemID: String
    let revision: String?
    let resourceKey: String?
    let originalName: String
    let mimeType: String?
    let modifiedAt: Date?

    init(
        provider: CloudProviderID,
        accountKey: String,
        maskedAccountHint: String? = nil,
        driveID: String? = nil,
        remoteItemID: String,
        revision: String? = nil,
        resourceKey: String? = nil,
        originalName: String,
        mimeType: String? = nil,
        modifiedAt: Date? = nil
    ) {
        self.provider = provider
        self.accountKey = accountKey
        self.maskedAccountHint = maskedAccountHint
        self.driveID = driveID
        self.remoteItemID = remoteItemID
        self.revision = revision
        self.resourceKey = resourceKey
        self.originalName = originalName
        self.mimeType = mimeType
        self.modifiedAt = modifiedAt
    }

    var stableDocumentID: String {
        CloudStableIdentifier.documentID(
            provider: provider,
            accountKey: accountKey,
            driveID: driveID,
            remoteItemID: remoteItemID
        )
    }

    func replacingRevision(_ revision: String?) -> CloudDocumentOrigin {
        CloudDocumentOrigin(
            provider: provider,
            accountKey: accountKey,
            maskedAccountHint: maskedAccountHint,
            driveID: driveID,
            remoteItemID: remoteItemID,
            revision: revision,
            resourceKey: resourceKey,
            originalName: originalName,
            mimeType: mimeType,
            modifiedAt: modifiedAt
        )
    }

    /// Keeps the stable remote identity while refreshing the descriptive
    /// fields that may change between selecting and finishing a download.
    /// For provider-native exports, retain the provider MIME type so a later
    /// History reopen still chooses the export API instead of blob download.
    func replacingDownloadedMetadata(
        revision: String?,
        effectiveFilename: String,
        effectiveMIMEType: String?,
        isExport: Bool
    ) -> CloudDocumentOrigin {
        CloudDocumentOrigin(
            provider: provider,
            accountKey: accountKey,
            maskedAccountHint: maskedAccountHint,
            driveID: driveID,
            remoteItemID: remoteItemID,
            revision: revision,
            resourceKey: resourceKey,
            originalName: effectiveFilename,
            mimeType: isExport ? mimeType : (effectiveMIMEType ?? mimeType),
            modifiedAt: modifiedAt
        )
    }
}

struct CloudDownloadReceipt: Equatable, Sendable {
    let localURL: URL
    let effectiveFilename: String
    let effectiveExtension: String
    let effectiveMIMEType: String
    let effectiveFormat: SupportedDocumentFormat
    let exportFormat: CloudExportFormat?
    let finalRevision: String?
    let byteCount: Int64

    init(
        localURL: URL,
        effectiveFilename: String,
        effectiveExtension: String? = nil,
        effectiveMIMEType: String,
        effectiveFormat: SupportedDocumentFormat,
        exportFormat: CloudExportFormat? = nil,
        finalRevision: String? = nil,
        byteCount: Int64
    ) {
        self.localURL = localURL
        self.effectiveFilename = effectiveFilename
        self.effectiveExtension = effectiveExtension
            ?? URL(fileURLWithPath: effectiveFilename).pathExtension.lowercased()
        self.effectiveMIMEType = effectiveMIMEType
        self.effectiveFormat = effectiveFormat
        self.exportFormat = exportFormat
        self.finalRevision = finalRevision
        self.byteCount = byteCount
    }
}

struct CloudDownloadProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64?

    init(completedBytes: Int64, totalBytes: Int64? = nil) {
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

typealias CloudDownloadProgressHandler = @Sendable (CloudDownloadProgress) -> Void

// MARK: - Persistence and identifiers

enum DocumentPersistencePolicy: String, Codable, Equatable, Sendable {
    case localPayload
    case remoteReference
}

enum DocumentImportTransportPolicy: String, Codable, Equatable, Sendable {
    /// Read and parse only from a device-local URL. No backend upload fallback
    /// exists in DocumentImportPipeline.
    case deviceOnly
}

enum CloudStableIdentifier {
    static func accountKey(provider: CloudProviderID, rawAccountID: String) -> String {
        digest([provider.rawValue, rawAccountID])
    }

    static func documentID(
        provider: CloudProviderID,
        accountKey: String,
        driveID: String?,
        remoteItemID: String
    ) -> String {
        digest([provider.rawValue, accountKey, driveID ?? "", remoteItemID])
    }

    static func contentSessionKey(
        documentID: String,
        revision: String?,
        format: SupportedDocumentFormat
    ) -> String {
        digest([documentID, revision ?? "", format.rawValue])
    }

    private static func digest(_ components: [String]) -> String {
        // Length-prefixing prevents ambiguous component boundaries while
        // preserving deterministic identifiers across launches.
        let canonical = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        let hash = SHA256.hash(data: Data(canonical.utf8))
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.byteCount * 2)
        for value in hash {
            bytes.append(alphabet[Int(value >> 4)])
            bytes.append(alphabet[Int(value & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
