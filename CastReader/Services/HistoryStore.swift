//
//  HistoryStore.swift
//  CastReader
//
//  文库 = 本地历史记录：处理/朗读/解读/粘贴过的所有文档都在此留存。
//  **纯本地、不上云**。元数据存 index.json；原始数据（图片/PDF/DOCX/EPUB/文本）存 <id>.payload，
//  重新打开时按 sourceKind 重建 ReadingDocument（web 用 URL、photo 重新 OCR、pdf 重新解析）。
//

import SwiftUI
import UIKit

/// 一条历史记录（元数据）。原始数据另存 payload 文件。
struct HistoryRecord: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var sourceKindRaw: String
    var sourceURL: String?
    var language: String
    var createdAt: Date
    var lastOpenedAt: Date

    var sourceKind: ReadingSourceKind { ReadingSourceKind(rawValue: sourceKindRaw) ?? .text }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [HistoryRecord] = []

    private let dir: URL
    private let indexURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("History", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func payloadURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).payload") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let recs = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        records = recs.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: indexURL) }
    }

    /// 记录一次打开：新文档新增、已存在则更新时间并置顶。原始数据存 payload 供重开（web 仅记 URL）。
    func record(_ doc: ReadingDocument) {
        let payload: Data? = {
            switch doc.sourceKind {
            case .web: return nil
            case .text: return doc.fullText.data(using: .utf8)
            case .photo: return doc.imageData
            case .pdf, .docx, .epub: return doc.fileData
            }
        }()
        if let payload { try? payload.write(to: payloadURL(doc.id)) }

        let now = Date()
        let createdAt = records.first(where: { $0.id == doc.id })?.createdAt ?? now
        let rec = HistoryRecord(id: doc.id, title: doc.title.isEmpty ? String(localized: "未命名") : doc.title,
                                sourceKindRaw: doc.sourceKind.rawValue, sourceURL: doc.sourceURL,
                                language: doc.language, createdAt: createdAt, lastOpenedAt: now)
        records.removeAll { $0.id == doc.id }
        records.insert(rec, at: 0)
        save()
    }

    func delete(_ id: String) {
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: payloadURL(id))
        save()
    }

    func clearAll() {
        for r in records { try? FileManager.default.removeItem(at: payloadURL(r.id)) }
        records.removeAll()
        save()
    }

    /// 从历史项重建可播放文档（id 沿用 rec.id，保证重开后 record 是更新而非新增）。photo 需重新 OCR，故 async。
    func reopen(_ rec: HistoryRecord) async -> ReadingDocument? {
        switch rec.sourceKind {
        case .web:
            guard let url = rec.sourceURL else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .web, language: rec.language,
                                   paragraphs: [], sourceURL: url)
        case .text:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let built = DocumentBuilder.fromPlainText(text, title: rec.title)
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .text,
                                   language: built.language, paragraphs: built.paragraphs)
        case .pdf:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)) else { return nil }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(rec.id).pdf")
            try? data.write(to: tmp)
            guard let built = DocumentBuilder.fromPDFNative(url: tmp, title: rec.title) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .pdf, language: built.language,
                                   paragraphs: built.paragraphs, fileData: data)
        case .docx, .epub:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)) else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: rec.sourceKind,
                                   language: rec.language, paragraphs: [], fileData: data)
        case .photo:
            guard let data = try? Data(contentsOf: payloadURL(rec.id)), let img = UIImage(data: data) else { return nil }
            let cap = CaptureFlowViewModel()
            await cap.process(image: img)
            guard let built = cap.document else { return nil }
            return ReadingDocument(id: rec.id, title: rec.title, sourceKind: .photo, language: built.language,
                                   paragraphs: built.paragraphs, imageData: built.imageData, imagePixelSize: built.imagePixelSize)
        }
    }
}
