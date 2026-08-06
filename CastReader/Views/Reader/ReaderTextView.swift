//
//  ReaderTextView.swift
//  CastReader
//
//  精简的单段落文本视图（UITextView 包装）：纯文本 + 词级圆角高亮 + 对外暴露字符范围矩形。
//  源无关：朗读用 highlightRange 高亮当前词；解读用 rects(forCharRange:) 给 MarkOverlay 定位手写标注。
//  （从 DialogueTextView 抽取 ReaderRoundedBackgroundLayoutManager / 自适应高度逻辑，去除头像/徽章/emoji/对话。）
//

import SwiftUI
import UIKit

// MARK: - ReaderRoundedBackgroundLayoutManager

/// 自定义 NSLayoutManager：把 .backgroundColor 属性绘制为 4px 圆角背景（词级高亮）。
final class ReaderRoundedBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let textStorage = textStorage else { return }
        textStorage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: textStorage.length), options: []) { value, range, _ in
            guard let backgroundColor = value as? UIColor else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let intersection = NSIntersectionRange(glyphRange, glyphsToShow)
            guard intersection.length > 0 else { return }
            guard let textContainer = textContainers.first else { return }
            var font = UIFont.systemFont(ofSize: 18)
            if let f = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont { font = f }
            enumerateLineFragments(forGlyphRange: intersection) { _, usedRect, _, lineGlyphRange, _ in
                let hl = NSIntersectionRange(lineGlyphRange, intersection)
                guard hl.length > 0 else { return }
                let glyphRect = self.boundingRect(forGlyphRange: hl, in: textContainer)
                var rect = CGRect(x: glyphRect.minX, y: usedRect.minY, width: glyphRect.width, height: font.lineHeight)
                rect = rect.insetBy(dx: -2, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
                backgroundColor.setFill()
                path.fill()
            }
        }
    }
}

// MARK: - ReaderUITextView（自适应高度 + 字符范围矩形）

final class ReaderUITextView: UITextView {

    static func make() -> ReaderUITextView {
        let storage = NSTextStorage()
        let layout = ReaderRoundedBackgroundLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let tv = ReaderUITextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        return tv
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 40
        let size = sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }

    /// 计算某字符范围（按行）的矩形，坐标系为本 textview（已含 textContainerInset 偏移）。
    /// 解读 MarkOverlay 用它把手写标注锚定到文字上。
    func rects(forCharRange range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound, range.length > 0,
              let lm = layoutManager as NSLayoutManager?,
              range.location + range.length <= (textStorage.length) else { return [] }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            let inter = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard inter.length > 0 else { return }
            let r = lm.boundingRect(forGlyphRange: inter, in: self.textContainer)
            rects.append(CGRect(x: r.minX + self.textContainerInset.left,
                                y: usedRect.minY + self.textContainerInset.top,
                                width: r.width,
                                height: r.height))
        }
        return rects
    }
}

// MARK: - SwiftUI 包装

struct ReaderTextView: UIViewRepresentable {
    let text: String
    /// 朗读：当前词在本段文字中的字符范围（nil = 不高亮）。
    var highlightRange: NSRange? = nil
    /// 是否当前段落（非当前段落整体淡化）。
    var isCurrent: Bool = true
    var fontSize: CGFloat = 18
    var highlightColor: UIColor = UIColor(red: 253/255, green: 95/255, blue: 1/255, alpha: 0.5)
    /// The normal reader owns scrolling at the paragraph level. The compact
    /// onboarding sample opts into an internal viewport so longer locales keep
    /// the active word visible without making the first screen unbounded.
    var autoScrollsHighlight: Bool = false
    /// 暴露底层 textview（供解读 mark 定位）。布局完成后回调。
    var onReady: ((ReaderUITextView) -> Void)? = nil

    func makeUIView(context: Context) -> ReaderUITextView {
        ReaderUITextView.make()
    }

    func updateUIView(_ tv: ReaderUITextView, context: Context) {
        tv.isScrollEnabled = autoScrollsHighlight
        tv.attributedText = buildAttributedString()
        tv.invalidateIntrinsicContentSize()
        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        if autoScrollsHighlight,
           let highlightRange,
           highlightRange.location != NSNotFound,
           highlightRange.length > 0 {
            DispatchQueue.main.async {
                tv.scrollRangeToVisible(highlightRange)
            }
        }
        onReady?(tv)
    }

    private func buildAttributedString() -> NSAttributedString {
        let base = UIColor(AppTheme.foreground)
        let color = isCurrent ? base : base.withAlphaComponent(0.55)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 8
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(),
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let result = NSMutableAttributedString(string: text, attributes: attrs)
        if let r = highlightRange, r.location != NSNotFound, r.length > 0,
           r.location + r.length <= result.length {
            result.addAttribute(.backgroundColor, value: highlightColor, range: r)
        }
        return result
    }

    private func font() -> UIFont {
        UIFont(name: "Georgia", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
    }
}
