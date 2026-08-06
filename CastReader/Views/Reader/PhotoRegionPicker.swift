//
//  PhotoRegionPicker.swift
//  CastReader
//
//  「读哪一块」：多栏页面（报纸/杂志）上一次拍摄往往包含好几篇文章，
//  用户通常只想听其中一篇。这里让用户在原图上直接框出要读的范围。
//
//  为什么是手动框选而不是自动分文章：报纸的文章会跨栏续接、共用大标题、
//  被图片打断，自动分割做不到可靠；猜错比不猜更糟。框选是所见即所得的，
//  一次拖拽就说清了意图。
//

import SwiftUI
import UIKit

/// 按选框裁剪文档 —— 纯函数，便于单测。
enum PhotoRegionCropper {

    /// 段落与选框的重叠达到段落自身面积的这个比例，才算被选中。
    /// 取一半是为了：擦到边的段落不进来，被框住大部分的段落不漏掉。
    static let minOverlapRatio: CGFloat = 0.5

    /// `selection` 为 layout 归一化矩形（原点左上，与 UI 一致）。
    /// 段落的 `bboxNorm` 是 Vision 坐标（原点左下），内部翻转比较。
    ///
    /// 选中结果为空时返回 `nil`，调用方应保持整页 —— 空文档比整页更糟。
    static func crop(_ document: ReadingDocument, to selection: CGRect) -> ReadingDocument? {
        guard selection.width > 0, selection.height > 0 else { return nil }
        let kept = document.paragraphs.filter { paragraph in
            guard let box = paragraph.bboxNorm else { return false }
            return overlapRatio(of: layoutRect(fromVision: box), with: selection) >= minOverlapRatio
        }
        guard !kept.isEmpty else { return nil }

        var renumbered: [ReadingParagraph] = []
        for paragraph in kept {
            renumbered.append(ReadingParagraph(
                id: renumbered.count,
                text: paragraph.text,
                type: paragraph.type,
                words: paragraph.words,
                bboxNorm: paragraph.bboxNorm,
                visualFragments: paragraph.visualFragments,
                pageIndex: paragraph.pageIndex
            ))
        }

        var cropped = document
        cropped.paragraphs = renumbered
        cropped.title = renumbered.first.map { String($0.text.prefix(40)) } ?? document.title
        return cropped
    }

    static func layoutRect(fromVision box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    static func overlapRatio(of rect: CGRect, with selection: CGRect) -> CGFloat {
        let intersection = rect.intersection(selection)
        guard !intersection.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return (intersection.width * intersection.height) / (rect.width * rect.height)
    }

    /// 值不值得问用户「只读一块」：多栏 + 内容够多，才有「只想听其中一篇」的可能。
    /// 单栏文档、短页面一律不打扰。
    static func shouldOfferSelection(for document: ReadingDocument) -> Bool {
        guard document.sourceKind == .photo,
              document.imageData != nil,
              let columns = document.layoutColumnCount, columns >= 2 else { return false }
        let readable = document.paragraphs.filter { $0.bboxNorm != nil && $0.type.isReadable }
        return readable.count >= 6
    }
}

/// 原图 + 可拖拽选框。不改动阅读器生命周期 —— 选择发生在进入阅读器之前。
struct PhotoRegionPicker: View {
    let document: ReadingDocument
    /// 传 `nil` 表示读整页。
    let onPick: (ReadingDocument?) -> Void

    @State private var selection: CGRect?      // layout 归一化
    @State private var dragStart: CGPoint?

    private var image: UIImage? { document.imageData.flatMap(UIImage.init) }

    var body: some View {
        VStack(spacing: 0) {
            header
            canvas
            footer
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(AppLocalized("选择要朗读的部分"))
                .font(.headline)
            Text(AppLocalized("在图片上拖动框选一篇文章，或直接读整页"))
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let fitted = ReadingGeometry.fittedImageRect(
                container: geo.size,
                imagePixel: document.imagePixelSize ?? image?.size ?? CGSize(width: 1, height: 1)
            )
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if let selection {
                    let rect = displayRect(selection, in: fitted)
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .reverseMask(rect: rect)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(AppTheme.accent, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard fitted.width > 0, fitted.height > 0 else { return }
                        if dragStart == nil { dragStart = value.startLocation }
                        selection = normalizedRect(
                            from: dragStart ?? value.startLocation,
                            to: value.location,
                            in: fitted
                        )
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                onPick(nil)
            } label: {
                Text(AppLocalized("读整页"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.bordered)

            Button {
                guard let selection,
                      let cropped = PhotoRegionCropper.crop(document, to: selection) else {
                    onPick(nil)
                    return
                }
                onPick(cropped)
            } label: {
                Text(AppLocalized("只读选中部分"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Geometry

    /// 屏幕点 → 图片内的 layout 归一化矩形（超出图片范围的部分被裁掉）。
    private func normalizedRect(from start: CGPoint, to end: CGPoint, in fitted: CGRect) -> CGRect {
        let raw = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).intersection(fitted)
        guard !raw.isNull else { return .zero }
        return CGRect(
            x: (raw.minX - fitted.minX) / fitted.width,
            y: (raw.minY - fitted.minY) / fitted.height,
            width: raw.width / fitted.width,
            height: raw.height / fitted.height
        )
    }

    private func displayRect(_ normalized: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(
            x: fitted.minX + normalized.minX * fitted.width,
            y: fitted.minY + normalized.minY * fitted.height,
            width: normalized.width * fitted.width,
            height: normalized.height * fitted.height
        )
    }
}

private extension View {
    /// 遮罩挖洞：选框之外压暗，框内保持原样。
    func reverseMask(rect: CGRect) -> some View {
        mask(
            ZStack {
                Rectangle()
                Rectangle()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}
