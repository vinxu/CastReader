//
//  PhotoOCRCache.swift
//  CastReader
//
//  照片 OCR 结果的本地快照：一张历史照片只识别一次。
//
//  历史里的 `.photo` 记录过去只存原图 JPEG，重开时整条采集管线要重跑
//  （方向探测 + 多语言 probe + 选定语言后的全图复跑），真机实测一张菜单照
//  点开要等 6.7 秒，而且每次点都重来。识别产物本身是纯几何 + 文本，
//  完全可以随 payload 一起落盘，所以这里把它快照下来。
//
//  快照只保存朗读/解读定位真正需要的字段（段落文本、词级归一化 bbox、
//  段落包络、语言、原图像素尺寸、栏数）。原图仍由 payload 持有，
//  快照不复制图片字节。
//

import CoreGraphics
import Foundation

/// 一张照片的 OCR 产物快照。`version` 用于让识别管线升级后旧快照自然失效。
struct PhotoOCRSnapshot: Codable, Equatable {
    /// 识别管线的产物契约版本。改动 OCR 的分段/几何/语言判定后必须 +1，
    /// 否则旧快照会把过期的版面结果一直带下去。
    static let currentVersion = 1

    struct Word: Codable, Equatable {
        let id: Int
        let text: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Paragraph: Codable, Equatable {
        let id: Int
        let text: String
        let words: [Word]
        let boxX: Double?
        let boxY: Double?
        let boxWidth: Double?
        let boxHeight: Double?
    }

    let version: Int
    let language: String
    /// 原图字节数：payload 换了图（同 id 重新导入）时让快照失效。
    let payloadByteCount: Int
    let pixelWidth: Double?
    let pixelHeight: Double?
    let layoutColumnCount: Int?
    let paragraphs: [Paragraph]

    var imagePixelSize: CGSize? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
}

extension PhotoOCRSnapshot {
    /// 从识别完成的文档抽快照。没有词级 bbox 的结果不值得缓存——
    /// 它无法支撑照片上的词级高亮，留着只会把一次坏识别固化下来。
    init?(document: ReadingDocument, payloadByteCount: Int) {
        guard document.sourceKind == .photo else { return nil }
        let readable = document.paragraphs.filter { !$0.text.isEmpty }
        guard !readable.isEmpty,
              readable.contains(where: { !$0.words.isEmpty }) else { return nil }

        self.version = Self.currentVersion
        self.language = document.language
        self.payloadByteCount = payloadByteCount
        self.pixelWidth = document.imagePixelSize.map { Double($0.width) }
        self.pixelHeight = document.imagePixelSize.map { Double($0.height) }
        self.layoutColumnCount = document.layoutColumnCount
        self.paragraphs = document.paragraphs.map { paragraph in
            Paragraph(
                id: paragraph.id,
                text: paragraph.text,
                words: paragraph.words.map {
                    Word(
                        id: $0.id,
                        text: $0.text,
                        x: Double($0.bboxNorm.origin.x),
                        y: Double($0.bboxNorm.origin.y),
                        width: Double($0.bboxNorm.width),
                        height: Double($0.bboxNorm.height)
                    )
                },
                boxX: paragraph.bboxNorm.map { Double($0.origin.x) },
                boxY: paragraph.bboxNorm.map { Double($0.origin.y) },
                boxWidth: paragraph.bboxNorm.map { Double($0.width) },
                boxHeight: paragraph.bboxNorm.map { Double($0.height) }
            )
        }
    }

    /// 快照是否还能代表这份 payload。
    func matches(payloadByteCount: Int) -> Bool {
        version == Self.currentVersion && self.payloadByteCount == payloadByteCount
    }

    /// 还原成可播放的段落（几何按 Vision 归一化原样带回，原点左下）。
    var readingParagraphs: [ReadingParagraph] {
        paragraphs.map { paragraph in
            ReadingParagraph(
                id: paragraph.id,
                text: paragraph.text,
                words: paragraph.words.map {
                    OCRWord(
                        id: $0.id,
                        text: $0.text,
                        bboxNorm: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    )
                },
                bboxNorm: {
                    guard let x = paragraph.boxX, let y = paragraph.boxY,
                          let width = paragraph.boxWidth, let height = paragraph.boxHeight else {
                        return nil
                    }
                    return CGRect(x: x, y: y, width: width, height: height)
                }()
            )
        }
    }

    /// 用快照 + 原图字节重建一份可直接打开的文档。
    func document(id: String, title: String, imageData: Data) -> ReadingDocument {
        ReadingDocument(
            id: id,
            title: title,
            sourceKind: .photo,
            language: language,
            paragraphs: readingParagraphs,
            imageData: imageData,
            imagePixelSize: imagePixelSize,
            layoutColumnCount: layoutColumnCount
        )
    }
}
