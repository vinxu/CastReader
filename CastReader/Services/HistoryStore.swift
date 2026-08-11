//
//  HistoryStore.swift
//  CastReader
//
//  文库 = 本地历史记录：处理/朗读/解读/粘贴过的所有文档都在此留存。
//  历史数据仅在设备上：元数据存 index.json；本地导入的原始数据存 <id>.payload。
//  云盘文档只存非敏感远端引用，不持久化临时下载的文件或封面；重开时由 provider 再获取。
//

import SwiftUI
import UIKit
import PDFKit
import WidgetKit

/// 一条历史记录（元数据）。原始数据另存 payload 文件。
struct HistoryRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var sourceKindRaw: String
    var sourceURL: String?
    var language: String
    var createdAt: Date
    var lastOpenedAt: Date
    /// 封面文件名（History 目录内 <id>.cover.jpg）。三态：nil=未生成；""=已尝试但无封面（用渐变占位、不重复抓取）；非空=有封面。
    var coverPath: String?
    var origin: CloudDocumentOrigin? = nil
    var persistencePolicy: DocumentPersistencePolicy = .localPayload
    var effectiveFormat: SupportedDocumentFormat? = nil
    var contentRevision: String? = nil
    var exportFormat: CloudExportFormat? = nil
    /// 旧 index 中没有该字段，因此允许 nil 并用 record id 作本地兼容值。
    var contentSessionKey: String? = nil
    /// Lightweight YouTube status survives bounded transcript/audio eviction.
    /// It never contains caption text, media bytes, URLs beyond `sourceURL`, or
    /// TTS payloads.
    var youtubeDurationMs: Int? = nil
    var youtubeProgressFraction: Double? = nil
    var youtubeResumeStartMs: Int? = nil

    var sourceKind: ReadingSourceKind { ReadingSourceKind(rawValue: sourceKindRaw) ?? .text }

    var isRemoteReference: Bool {
        origin != nil || persistencePolicy == .remoteReference
    }

    /// 上层必须走 provider 元数据检查 + 重新下载，不得尝试 History payload。
    var requiresRemoteReopen: Bool { isRemoteReference }

    var resolvedContentSessionKey: String { contentSessionKey ?? id }

    /// 云盘重开所需的全部非敏感元数据。OAuth token 始终由 provider 的 Keychain 保管。
    var remoteReference: CloudHistoryReference? {
        guard isRemoteReference, let origin else { return nil }
        return CloudHistoryReference(
            origin: origin,
            effectiveFormat: effectiveFormat,
            contentRevision: contentRevision ?? origin.revision,
            exportFormat: exportFormat,
            contentSessionKey: resolvedContentSessionKey
        )
    }
}

struct CloudHistoryReference: Equatable, Sendable {
    let origin: CloudDocumentOrigin
    let effectiveFormat: SupportedDocumentFormat?
    let contentRevision: String?
    let exportFormat: CloudExportFormat?
    let contentSessionKey: String
}

// Synthesized decoding rejects missing non-optional keys. Keeping the custom
// witnesses in an extension preserves HistoryRecord's convenient memberwise
// initializer while allowing every pre-cloud index.json to load unchanged.
extension HistoryRecord {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceKindRaw
        case sourceURL
        case language
        case createdAt
        case lastOpenedAt
        case coverPath
        case origin
        case persistencePolicy
        case effectiveFormat
        case contentRevision
        case exportFormat
        case contentSessionKey
        case youtubeDurationMs
        case youtubeProgressFraction
        case youtubeResumeStartMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sourceKindRaw = try container.decode(String.self, forKey: .sourceKindRaw)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        language = try container.decode(String.self, forKey: .language)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        // Provider enums evolve independently from an installed app. Keep a
        // future-provider record in the library as an inert remote reference
        // instead of allowing one unknown enum value to reject the whole
        // index. Remembering that an origin was encoded is security-sensitive:
        // it prevents a failed origin decode from falling back to localPayload
        // and opening an unrelated/stale payload with the same record ID.
        let encodedOriginWasPresent: Bool
        if container.contains(.origin) {
            encodedOriginWasPresent = !(try container.decodeNil(forKey: .origin))
        } else {
            encodedOriginWasPresent = false
        }
        if encodedOriginWasPresent {
            origin = try? container.decode(CloudDocumentOrigin.self, forKey: .origin)
        } else {
            origin = nil
        }

        let policyRaw = (try? container.decodeIfPresent(String.self, forKey: .persistencePolicy)) ?? nil
        persistencePolicy = origin == nil && !encodedOriginWasPresent
            ? (policyRaw.flatMap(DocumentPersistencePolicy.init(rawValue:)) ?? .localPayload)
            : .remoteReference

        let formatRaw = (try? container.decodeIfPresent(String.self, forKey: .effectiveFormat)) ?? nil
        effectiveFormat = formatRaw.flatMap(SupportedDocumentFormat.init(rawValue:))
        contentRevision = (try? container.decodeIfPresent(String.self, forKey: .contentRevision)) ?? nil
        let exportRaw = (try? container.decodeIfPresent(String.self, forKey: .exportFormat)) ?? nil
        exportFormat = exportRaw.flatMap(CloudExportFormat.init(rawValue:))
        contentSessionKey = (try? container.decodeIfPresent(String.self, forKey: .contentSessionKey)) ?? nil
        youtubeDurationMs = (try? container.decodeIfPresent(Int.self, forKey: .youtubeDurationMs)) ?? nil
        let decodedYouTubeProgress = (try? container.decodeIfPresent(
            Double.self,
            forKey: .youtubeProgressFraction
        )) ?? nil
        youtubeProgressFraction = decodedYouTubeProgress.flatMap {
            $0.isFinite && (0...1).contains($0) ? $0 : nil
        }
        let decodedResumeStart = (try? container.decodeIfPresent(
            Int.self,
            forKey: .youtubeResumeStartMs
        )) ?? nil
        youtubeResumeStartMs = decodedResumeStart.flatMap { $0 >= 0 ? $0 : nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(sourceKindRaw, forKey: .sourceKindRaw)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encode(language, forKey: .language)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encodeIfPresent(coverPath, forKey: .coverPath)
        try container.encodeIfPresent(origin, forKey: .origin)
        let encodedPolicy: DocumentPersistencePolicy = origin == nil
            ? persistencePolicy
            : .remoteReference
        try container.encode(encodedPolicy.rawValue, forKey: .persistencePolicy)
        try container.encodeIfPresent(effectiveFormat?.rawValue, forKey: .effectiveFormat)
        try container.encodeIfPresent(contentRevision, forKey: .contentRevision)
        try container.encodeIfPresent(exportFormat?.rawValue, forKey: .exportFormat)
        try container.encodeIfPresent(contentSessionKey, forKey: .contentSessionKey)
        try container.encodeIfPresent(youtubeDurationMs, forKey: .youtubeDurationMs)
        try container.encodeIfPresent(youtubeProgressFraction, forKey: .youtubeProgressFraction)
        try container.encodeIfPresent(youtubeResumeStartMs, forKey: .youtubeResumeStartMs)
    }
}

/// Home has dedicated rails for Kindle and WeRead, so neither source may also
/// appear in Continue.  The full local history remains available in Library.
enum HomeContinueContract {
    static func includes(_ sourceKind: ReadingSourceKind) -> Bool {
        sourceKind != .kindle
            && sourceKind != .weread
            && sourceKind != .googleBooks
            && sourceKind != .kobo
            && sourceKind != .oreilly
            && sourceKind != .youtube
    }
}

/// A release-level visibility contract for cloud-backed history. Pausing the
/// cloud feature never deletes saved remote references; it only keeps them out
/// of user and system surfaces until provider review has completed.
enum HistoryVisibilityContract {
    static func includes(
        _ record: HistoryRecord,
        cloudStorageEnabled: Bool = Constants.Features.cloudStorageEnabled
    ) -> Bool {
        cloudStorageEnabled || !record.requiresRemoteReopen
    }
}

enum SystemContinueContract {
    /// An explicit entity ID is authoritative. If it has gone stale, routing
    /// must fail to the import surface instead of silently opening a different
    /// recent document. Only an omitted ID means "use the latest".
    static func record(
        in records: [HistoryRecord],
        itemID: String?,
        cloudStorageEnabled: Bool = Constants.Features.cloudStorageEnabled
    ) -> HistoryRecord? {
        let eligible = records.filter {
            HomeContinueContract.includes($0.sourceKind)
                && HistoryVisibilityContract.includes(
                    $0,
                    cloudStorageEnabled: cloudStorageEnabled
                )
        }
        if let itemID {
            return eligible.first { $0.id == itemID }
        }
        return eligible.first
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [HistoryRecord] = []

    var visibleRecords: [HistoryRecord] {
        records.filter { HistoryVisibilityContract.includes($0) }
    }

    private let dir: URL
    private let indexURL: URL
    private let performsCoverWork: Bool

    private convenience init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(
            directory: docs.appendingPathComponent("History", isDirectory: true),
            performsCoverWork: true
        )
    }

    /// An isolated directory keeps HistoryStore contract tests away from the
    /// app's real Documents/History data. Cover work defaults off so tests do
    /// not launch unrelated metadata requests.
    init(directory: URL, performsCoverWork: Bool = false) {
        dir = directory
        indexURL = dir.appendingPathComponent("index.json")
        self.performsCoverWork = performsCoverWork
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        if performsCoverWork {
            syncContinueSnapshots()
            Task { await backfillCovers() }   // 给升级前的旧记录补封面 + web 真实标题（best-effort）
        }
    }

    private func payloadURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).payload") }
    private func coverFileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).cover.jpg") }

    /// Reads a legacy local payload only after checking its logical file size.
    /// `fileSize` remains the expanded logical size for sparse files, so an
    /// attacker cannot bypass this guard with a tiny on-disk allocation and
    /// force `Data(contentsOf:)` to reserve hundreds of megabytes.
    private func localPayloadData(_ id: String) -> Data? {
        let url = payloadURL(id)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              Int64(fileSize) <= DocumentResourceLimits.maximumInputBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// 卡片读取封面文件 URL（有真实封面才返回；nil = 用渐变占位）。
    func coverURL(for rec: HistoryRecord) -> URL? {
        guard !rec.isRemoteReference,
              rec.sourceKind != .youtube,
              let name = rec.coverPath, !name.isEmpty else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load() {
        guard let values = try? indexURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              Int64(fileSize) <= DocumentResourceLimits.maximumInputBytes,
              let data = try? Data(contentsOf: indexURL, options: .mappedIfSafe) else { return }

        // Decode one envelope at a time. JSONDecoder's normal array witness is
        // all-or-nothing, which historically made one malformed record (or a
        // provider enum added by a newer app version) empty the entire library.
        // The current on-disk format remains the legacy top-level array; a
        // `records` envelope is also accepted for forwards/recovery tooling.
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let rawRecords = (root as? [Any])
                ?? (root as? [String: Any])?["records"] as? [Any] else { return }
        let decoder = JSONDecoder()
        let recs: [HistoryRecord] = rawRecords.compactMap { rawRecord in
            guard JSONSerialization.isValidJSONObject(rawRecord),
                  let recordData = try? JSONSerialization.data(withJSONObject: rawRecord) else {
                return nil
            }
            return try? decoder.decode(HistoryRecord.self, from: recordData)
        }
        records = recs.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        for index in records.indices where records[index].isRemoteReference
            || records[index].sourceKind == .youtube {
            // Enforce bounded/private storage invariants during migration too.
            // Remote files stay provider-owned; YouTube transcripts and artwork
            // stay exclusively in the bounded YouTube cache.
            try? FileManager.default.removeItem(at: payloadURL(records[index].id))
            try? FileManager.default.removeItem(at: coverFileURL(records[index].id))
            records[index].coverPath = nil
        }
    }

    private func save(syncSystemContinue: Bool = true) {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: indexURL) }
        if performsCoverWork, syncSystemContinue { syncContinueSnapshots() }
    }

    /// Widgets and App Intents only need a tiny, privacy-preserving projection
    /// of recent local history. Original documents remain in the app's private
    /// Documents directory and are reopened by the containing app.
    private func syncContinueSnapshots() {
        let snapshots = records
            .filter {
                HomeContinueContract.includes($0.sourceKind)
                    && HistoryVisibilityContract.includes($0)
            }
            .map {
                ContinueSnapshot(
                    id: $0.id,
                    title: $0.title,
                    sourceKind: $0.sourceKindRaw,
                    updatedAt: $0.lastOpenedAt
                )
            }
        ContinueSnapshotStore.shared.replace(with: snapshots)
        WidgetCenter.shared.reloadTimelines(ofKind: "CastReaderContinueWidget")
    }

    /// 记录一次打开：新文档新增、已存在则更新时间并置顶。原始数据存 payload 供重开（web 仅记 URL）。
    func record(_ doc: ReadingDocument) {
        let resolvedPersistencePolicy: DocumentPersistencePolicy = doc.origin == nil
            ? doc.persistencePolicy
            : .remoteReference
        let payload: Data? = {
            guard resolvedPersistencePolicy == .localPayload else { return nil }
            switch doc.sourceKind {
            case .web, .weread, .googleBooks, .kobo, .oreilly: return nil
            // The bounded YouTube cache is the single transcript authority.
            // History keeps only metadata so it cannot grow an uncapped second
            // copy of every transcript outside the 50-video/500 MB policy.
            case .youtube: return nil
            case .text: return doc.fullText.data(using: .utf8)
            case .photo: return doc.imageData
            case .kindle: return doc.fullText.data(using: .utf8)
            case .pdf, .docx, .epub: return doc.fileData
            }
        }()
        if let payload {
            try? payload.write(to: payloadURL(doc.id))
        } else if resolvedPersistencePolicy == .remoteReference
                    || doc.sourceKind == .youtube {
            // Cloud downloads are ephemeral parser inputs, while YouTube text
            // belongs to its bounded cache. Remove any stale duplicate payload
            // left by an older build or an ID collision.
            try? FileManager.default.removeItem(at: payloadURL(doc.id))
            try? FileManager.default.removeItem(at: coverFileURL(doc.id))
        }

        let now = Date()
        let existing = records.first(where: { $0.id == doc.id })
        let createdAt = existing?.createdAt ?? now
        var rec = HistoryRecord(
            id: doc.id,
            title: doc.title.isEmpty ? AppLocalized("未命名") : doc.title,
            sourceKindRaw: doc.sourceKind.rawValue,
            sourceURL: doc.sourceURL,
            language: doc.language,
            createdAt: createdAt,
            lastOpenedAt: now,
            coverPath: nil,
            origin: doc.origin,
            persistencePolicy: resolvedPersistencePolicy,
            effectiveFormat: doc.effectiveFormat,
            contentRevision: doc.contentRevision ?? doc.origin?.revision,
            exportFormat: doc.exportFormat,
            contentSessionKey: doc.contentSessionKey,
            youtubeDurationMs: doc.youtubeTranscript?.metadata.durationMs
                ?? existing?.youtubeDurationMs,
            youtubeProgressFraction: existing?.youtubeProgressFraction,
            youtubeResumeStartMs: existing?.youtubeResumeStartMs
        )
        rec.coverPath = rec.isRemoteReference || doc.sourceKind == .youtube
            ? nil
            : existing?.coverPath
        if let t = existing?.title, !t.isEmpty, rec.coverPath != nil { rec.title = t }  // 已抓到真实标题则保留
        records.removeAll { $0.id == doc.id }
        records.insert(rec, at: 0)
        save()

        if performsCoverWork,
           !rec.isRemoteReference,
           rec.sourceKind != .youtube,
           rec.coverPath == nil {   // 首次记录 → 异步生成封面（+ web 抓取真实标题），best-effort，不阻塞打开
            Task { await generateCover(for: doc) }
        }
    }

    func updateYouTubeListeningSummary(
        documentID: String,
        durationMs: Int?,
        resumeStartMs: Int,
        progressFraction: Double
    ) {
        guard resumeStartMs >= 0,
              progressFraction.isFinite,
              (0...1).contains(progressFraction),
              let index = records.firstIndex(where: {
                  $0.id == documentID && $0.sourceKind == .youtube
              }) else { return }
        if let durationMs, durationMs >= 0 {
            records[index].youtubeDurationMs = durationMs
        }
        records[index].youtubeResumeStartMs = resumeStartMs
        records[index].youtubeProgressFraction = progressFraction
        // YouTube has its own History rail and is intentionally excluded from
        // Continue/App Intents. Frequent playback checkpoints only persist the
        // index metadata; rebuilding the unchanged projection and reloading a
        // widget timeline every five seconds wastes foreground playback work.
        save(syncSystemContinue: false)
    }

    /// Web/DOCX language is only known after DOM extraction. Persist the final
    /// nine-language result so history reopen, voice defaults and analytics do
    /// not fall back to the placeholder English value.
    func updateDetectedLanguage(documentID: String, language: String) {
        guard let language = SupportedTTSLanguage(identifier: language)?.rawValue,
              let index = records.firstIndex(where: { $0.id == documentID }),
              records[index].language != language else { return }
        records[index].language = language
        save()
    }

    /// Live web readers update their location without creating a new document.
    /// Persist that address on the existing stable book record so Library opens
    /// the latest page rather than the URL captured when the reader was created.
    func updateSourceURL(documentID: String, sourceURL: String) {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = records.firstIndex(where: { $0.id == documentID }),
              records[index].sourceURL != trimmed else { return }
        records[index].sourceURL = trimmed
        save()
    }

    /// Kindle 书本级历史：点击朗读/解读后写入顶部 Continue。这里保存的是书架 metadata，
    /// 不是某一页 OCR 临时文档，避免 MiniPlayer/锁屏/首页拿不到书封和真实书名。
    func recordKindleBook(_ book: KindleBook, language: String = Constants.TTS.defaultLanguage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let payload = try? encoder.encode(book) {
            try? payload.write(to: payloadURL(book.id))
        }

        let now = Date()
        let existing = records.first(where: { $0.id == book.id })
        var rec = HistoryRecord(
            id: book.id,
            title: book.title.isEmpty ? AppLocalized("Kindle Book") : book.title,
            sourceKindRaw: ReadingSourceKind.kindle.rawValue,
            sourceURL: book.effectiveReaderURL,
            language: language,
            createdAt: existing?.createdAt ?? now,
            lastOpenedAt: now
        )
        rec.coverPath = existing?.coverPath
        records.removeAll { $0.id == book.id }
        records.insert(rec, at: 0)
        save()

        if performsCoverWork, rec.coverPath == nil || rec.coverPath == "" {
            Task { await generateCoverFromURL(book.coverURL, id: book.id) }
        }
    }

    func kindleBook(for rec: HistoryRecord) -> KindleBook? {
        guard rec.sourceKind == .kindle,
              let data = localPayloadData(rec.id) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KindleBook.self, from: data)
    }

    func delete(_ id: String) {
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: payloadURL(id))
        try? FileManager.default.removeItem(at: coverFileURL(id))
        save()
    }

    /// Removes one library source without touching History records or payloads
    /// owned by any other reader channel.
    func deleteAll(sourceKind: ReadingSourceKind) {
        let removed = records.filter { $0.sourceKind == sourceKind }
        guard !removed.isEmpty else { return }
        for record in removed {
            try? FileManager.default.removeItem(at: payloadURL(record.id))
            try? FileManager.default.removeItem(at: coverFileURL(record.id))
        }
        records.removeAll { $0.sourceKind == sourceKind }
        save()
    }

    func clearAll() {
        for r in records {
            try? FileManager.default.removeItem(at: payloadURL(r.id))
            try? FileManager.default.removeItem(at: coverFileURL(r.id))
        }
        records.removeAll()
        save()
    }

    // MARK: - 封面 + 标题生成

    /// 启动回填：给所有还没封面的历史项补封面 + web 真实标题（best-effort、串行、不阻塞 UI）。
    /// 让升级前已有的「继续看」卡片（如微信文章链接）也自动从 demo 的 host 文字升级为封面+标题。
    func backfillCovers() async {
        for rec in records where !rec.isRemoteReference
            && rec.sourceKind != .youtube
            && rec.coverPath == nil {
            await generateCoverFromRecord(rec)
        }
    }

    /// 新打开文档时生成封面：用内存中的数据（含 epub 已解析的封面图段），最快。
    private func generateCover(for doc: ReadingDocument) async {
        guard doc.sourceKind != .youtube,
              doc.origin == nil,
              doc.persistencePolicy == .localPayload else { return }
        var imageData: Data?
        var title: String?
        if let coverURL = Self.makeURL(doc.coverURL) {
            imageData = try? await URLSession.shared.data(from: coverURL).0
            // A temporary CDN/network failure is not proof that this book has
            // no cover. Keep coverPath nil so opening it again can retry.
            guard imageData != nil else { return }
            finishCover(id: doc.id, imageData: imageData, title: nil)
            return
        }
        switch doc.sourceKind {
        case .web, .weread, .googleBooks, .kobo, .oreilly:
            (title, imageData) = await webCover(doc.sourceURL)
        case .pdf:   if let d = doc.fileData { imageData = await Task.detached { Self.pdfFirstPageJPEG(d) }.value }
        case .photo: imageData = doc.imageData
        case .kindle: imageData = doc.paragraphs.first(where: { $0.type == .image && $0.imageData != nil })?.imageData
        case .epub:  imageData = doc.paragraphs.first(where: { $0.type == .image && $0.imageData != nil })?.imageData
        case .text, .docx, .youtube: break
        }
        finishCover(id: doc.id, imageData: imageData, title: title)
    }

    /// 回填路径：从历史记录 + payload 文件生成（无内存文档）。epub/docx/text 用渐变占位（不重解析大书）。
    private func generateCoverFromRecord(_ rec: HistoryRecord) async {
        guard !rec.isRemoteReference, rec.sourceKind != .youtube else { return }
        var imageData: Data?
        var title: String?
        switch rec.sourceKind {
        case .web, .weread, .googleBooks, .kobo, .oreilly:
            (title, imageData) = await webCover(rec.sourceURL)
        case .pdf:   if let d = localPayloadData(rec.id) { imageData = await Task.detached { Self.pdfFirstPageJPEG(d) }.value }
        case .photo: imageData = localPayloadData(rec.id)
        case .epub, .docx, .kindle, .text, .youtube: break
        }
        finishCover(id: rec.id, imageData: imageData, title: title)
    }

    /// web：抓 og:title + 下载 og:image 字节。
    private func webCover(_ urlString: String?) async -> (String?, Data?) {
        guard let urlString else { return (nil, nil) }
        let meta = await LinkMetadata.fetch(urlString)
        var img: Data?
        if let s = meta.imageURL, let u = URL(string: s) { img = try? await URLSession.shared.data(from: u).0 }
        return (meta.title, img)
    }

    private func generateCoverFromURL(_ urlString: String?, id: String) async {
        guard let url = Self.makeURL(urlString) else {
            finishCover(id: id, imageData: nil, title: nil)
            return
        }
        let imageData = try? await URLSession.shared.data(from: url).0
        guard imageData != nil else { return }
        finishCover(id: id, imageData: imageData, title: nil)
    }

    private nonisolated static func makeURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let url = URL(string: raw) { return url }
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }

    /// 落地封面 + 标题：写降采样 jpeg、置 coverPath（无图时置 "" 标记已尝试，用占位、不再重复抓取）。
    private func finishCover(id: String, imageData: Data?, title: String?) {
        guard let record = records.first(where: { $0.id == id }),
              !record.isRemoteReference,
              record.sourceKind != .youtube else { return }
        if let t = title { applyTitle(t, id: id) }
        var savedName = ""
        if let data = imageData, let down = EpubImageDecoder.downsampled(data, maxPixel: 640),
           let jpeg = down.jpegData(compressionQuality: 0.72) {
            try? jpeg.write(to: coverFileURL(id))
            savedName = coverFileURL(id).lastPathComponent
        }
        applyCover(savedName, id: id)
    }

    private func applyTitle(_ title: String, id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        records[idx].title = clean
        save()
    }

    private func applyCover(_ name: String, id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].coverPath = name
        save()
    }

    /// PDF 首页渲染为 JPEG（白底、长边 640）。
    nonisolated private static func pdfFirstPageJPEG(_ data: Data) -> Data? {
        guard let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) else { return nil }
        let rect = page.bounds(for: .mediaBox)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let scale = 640 / max(rect.width, rect.height)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.white.set(); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        return img.jpegData(compressionQuality: 0.8)
    }

    /// 从历史项重建可播放文档（id 沿用 rec.id，保证重开后 record 是更新而非新增）。photo 需重新 OCR，故 async。
    func reopen(_ rec: HistoryRecord) async throws -> ReadingDocument? {
        try Task.checkCancellation()
        // Cloud records deliberately have no local payload. Returning nil is
        // an explicit contract for the caller to invoke its provider reopen
        // flow instead of treating the missing payload as file corruption.
        guard !rec.requiresRemoteReopen else { return nil }
        switch rec.sourceKind {
        case .youtube:
            guard let rawURL = rec.sourceURL,
                  let reference = YouTubeURLParser.parse(rawURL),
                  let cache = YouTubeCacheProvider.shared,
                  let key = await cache.mostRecentKey(videoId: reference.videoId),
                  let transcript = await cache.transcript(for: key) else {
                return nil
            }
            var document = YouTubeReadingDocumentBuilder.make(
                transcript: transcript,
                cacheHit: true
            )
            document = ReadingDocument(
                id: rec.id,
                title: rec.title,
                sourceKind: .youtube,
                language: document.language,
                paragraphs: document.paragraphs,
                sourceURL: rec.sourceURL ?? document.sourceURL,
                coverURL: document.coverURL,
                // The cache fingerprint is authoritative. A stale History
                // session key must not reuse a reader session for old captions.
                contentSessionKey: document.contentSessionKey,
                youtubeTranscript: transcript,
                youtubeCacheHit: document.youtubeCacheHit,
                createdAt: rec.createdAt
            )
            return document
        case .web:
            guard let url = rec.sourceURL else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .web, language: rec.language,
                                   paragraphs: [], sourceURL: url)
        case .weread:
            let latestBook = WeReadLibraryStore.shared.book(for: rec.id)
            guard let url = latestBook?.effectiveReaderURL ?? rec.sourceURL else {
                return nil
            }
            return ReadingDocument(
                id: rec.id,
                title: latestBook?.title ?? rec.title,
                sourceKind: .weread,
                language: rec.language,
                paragraphs: [],
                sourceURL: url,
                coverURL: latestBook?.coverURL
            )
        case .googleBooks:
            let store = GoogleBooksLibraryStore.shared
            let latestBook = store.book(for: rec.id)
            guard let url = latestBook?.effectiveReaderURL ?? rec.sourceURL else { return nil }
            if let latestBook {
                store.markOpened(latestBook)
            } else {
                store.clearError()
            }
            return ReadingDocument(
                id: rec.id,
                title: latestBook?.title ?? rec.title,
                sourceKind: .googleBooks,
                language: rec.language,
                paragraphs: [],
                sourceURL: url,
                coverURL: latestBook?.coverURL
            )
        case .kobo:
            let store = KoboLibraryStore.shared
            let latestBook = store.book(for: rec.id)
            guard let url = latestBook?.effectiveReaderURL ?? rec.sourceURL else {
                return nil
            }
            if let latestBook {
                store.markOpened(latestBook)
            } else {
                store.clearError()
            }
            return ReadingDocument(
                id: rec.id,
                title: latestBook?.title ?? rec.title,
                sourceKind: .kobo,
                language: rec.language,
                paragraphs: [],
                sourceURL: url,
                coverURL: latestBook?.coverURL
            )
        case .oreilly:
            let store = OReillyLibraryStore.shared
            let latestBook = store.book(for: rec.id)
            guard let url = latestBook?.effectiveReaderURL ?? rec.sourceURL else {
                return nil
            }
            if let latestBook {
                store.markOpened(latestBook)
            } else {
                store.clearError()
            }
            return ReadingDocument(
                id: rec.id,
                title: latestBook?.title ?? rec.title,
                sourceKind: .oreilly,
                language: rec.language,
                paragraphs: [],
                sourceURL: url,
                coverURL: latestBook?.coverURL
            )
        case .text:
            guard let data = localPayloadData(rec.id),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let built = DocumentBuilder.fromPlainText(text, title: rec.title)
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .text,
                                   language: built.language, paragraphs: built.paragraphs)
        case .pdf:
            guard let data = localPayloadData(rec.id) else { return nil }
            guard let built = try await DocumentBuilder.fromPDFWithOCR(
                data: data,
                title: rec.title,
                fallbackTitle: rec.title
            ) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .pdf, language: built.language,
                                   paragraphs: built.paragraphs, fileData: data)
        case .docx:
            guard let data = localPayloadData(rec.id) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .docx,
                                   language: rec.language, paragraphs: [], fileData: data)
        case .kindle:
            if kindleBook(for: rec) != nil { return nil }
            guard let data = localPayloadData(rec.id),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let built = DocumentBuilder.fromPlainText(text, title: rec.title)
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .text,
                                   language: built.language, paragraphs: built.paragraphs)
        case .epub:
            // EPUB 原生重开：从字节重新解析为段落（像 PDF），而非旧 WebView 的空 paragraphs（否则白屏）
            guard let data = localPayloadData(rec.id),
                  let built = DocumentBuilder.fromEPUB(data: data, title: rec.title) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .epub, language: built.language,
                                   paragraphs: built.paragraphs, fileData: data)
        case .photo:
            guard let data = localPayloadData(rec.id), let img = UIImage(data: data) else { return nil }
            let cap = CaptureFlowViewModel()
            await cap.process(image: img)
            guard let built = cap.document else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .photo, language: built.language,
                                   paragraphs: built.paragraphs, imageData: built.imageData, imagePixelSize: built.imagePixelSize)
        }
    }
}

// MARK: - 网页元数据抓取（og:title / og:image，给「继续看」/文库卡片做封面+真实标题）

enum LinkMetadata {
    /// 抓取网页 <head> 的标题与封面图 URL（best-effort，失败返回 nil）。
    static func fetch(_ urlString: String) async -> (title: String?, imageURL: String?) {
        guard let url = URL(string: urlString) else { return (nil, nil) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, nil) }
        let finalURL = resp.url ?? url
        // 仅取前 ~400KB（<head> 足够），兼容非 UTF-8 用 lossy 解码。
        let head = data.prefix(400_000)
        let html = String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self)
        return parse(html: html, baseURL: finalURL)
    }

    /// 从 HTML 解析标题 + 封面（与网络分离，便于单测）。
    static func parse(html: String, baseURL: URL) -> (title: String?, imageURL: String?) {
        let title = metaContent(html, keys: ["og:title", "twitter:title"]) ?? htmlTitle(html)
        var image = metaContent(html, keys: ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"])
        if let img = image, let resolved = URL(string: img, relativeTo: baseURL)?.absoluteString { image = resolved }
        return (title, image)
    }

    /// 扫描所有 <meta> 标签，命中 property/name ∈ keys 时取 content（属性顺序任意）。
    private static func metaContent(_ html: String, keys: Set<String>) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let key = (attr(tag, "property") ?? attr(tag, "name"))?.lowercased(), keys.contains(key) else { continue }
            if let content = attr(tag, "content")?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                return decodeEntities(content)
            }
        }
        return nil
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : decodeEntities(raw)
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        return r
    }
}
