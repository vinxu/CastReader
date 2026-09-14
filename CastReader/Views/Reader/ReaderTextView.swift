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

/// Sentence changes, word ticks and layout recovery use the same viewport
/// policy. A visible target stays put; an offscreen target goes directly into
/// the reading band instead of visiting the paragraph/selection top first.
enum ReaderViewportFollow {
    static let readingAnchor = CGFloat(0.25)
    private final class Motion {
        var destinationY: CGFloat?
        var startedAt: TimeInterval = 0
    }
    private static let motions = NSMapTable<UIScrollView, Motion>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private static func readingBand(_ visible: CGRect) -> CGRect {
        CGRect(x: visible.minX, y: visible.minY + visible.height * 0.18,
               width: visible.width, height: visible.height * 0.70)
    }

    static func reveal(_ target: CGRect, in scroll: UIScrollView, source: String) {
        let motion = motions.object(forKey: scroll) ?? Motion()
        motions.setObject(motion, forKey: scroll)
        guard !scroll.isDragging, !scroll.isDecelerating, !scroll.isTracking else {
            motion.destinationY = nil
            return
        }
        guard scroll.bounds.height > 0, !target.isNull, !target.isInfinite else { return }
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        if let destination = motion.destinationY {
            if abs(scroll.contentOffset.y - destination) <= 0.5 || Date.timeIntervalSinceReferenceDate - motion.startedAt > 0.6 {
                motion.destinationY = nil
            } else {
                // UIKit exposes intermediate offsets during its animation.
                // Check the intended destination so each new word/layout tick
                // does not restart the same movement from an intermediate frame.
                var projected = visible
                projected.origin.y += destination - scroll.contentOffset.y
                let band = readingBand(projected)
                if target.minY >= band.minY, target.maxY <= band.maxY { return }
            }
        }
        let comfortable = readingBand(visible)
        guard target.minY < comfortable.minY || target.maxY > comfortable.maxY else { return }
        let minY = -scroll.adjustedContentInset.top
        let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y = min(maxY, max(minY, target.minY - visible.height * readingAnchor - scroll.adjustedContentInset.top))
        if let destination = motion.destinationY, abs(destination - y) <= 0.5 { return }
        guard abs(scroll.contentOffset.y - y) > 0.5 else { return }
        // At the lower reading boundary, move narration to the upper quarter
        // (75% above the bottom), leaving upcoming text visible below it.
        // A distant restore/jump positions immediately instead of flying through
        // many pages. Explicit TOC navigation has its own point target.
        let animated = !UIAccessibility.isReduceMotionEnabled && abs(scroll.contentOffset.y - y) <= visible.height * 1.5
        motion.destinationY = animated ? y : nil
        motion.startedAt = Date.timeIntervalSinceReferenceDate
        #if DEBUG
        ReaderRunLog.write("VIEWPORT follow source=\(source) from=\(Int(scroll.contentOffset.y)) to=\(Int(y)) target=\(Int(target.minY)) height=\(Int(visible.height)) animated=\(animated ? "Y" : "N")")
        #endif
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: animated)
    }
}

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
    var viewportFocusRange: NSRange?
    private var focusScheduled = false

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
        if viewportFocusRange != nil, !focusScheduled {
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.focusScheduled = false
                self?.revealFocusInReader()
            }
        }
    }

    /// A paragraph can be many screens tall. Reveal its actual word in the
    /// outer SwiftUI scroll view without creating an inner scrolling surface.
    @discardableResult
    func revealFocusInReader() -> Bool {
        guard window != nil, !isScrollEnabled, let range = viewportFocusRange,
              let rect = rects(forCharRange: range).first else { return false }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                let target = convert(rect, to: scroll)
                ReaderViewportFollow.reveal(target, in: scroll, source: "text")
                return true
            }
            ancestor = view.superview
        }
        return false
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
    var lineSpacing: CGFloat = 8
    var usesSerif: Bool = true
    var highlightColor: UIColor = UIColor(red: 253/255, green: 95/255, blue: 1/255, alpha: 0.5)
    /// The normal reader owns scrolling at the paragraph level. The compact
    /// onboarding sample opts into an internal viewport so longer locales keep
    /// the active word visible without making the first screen unbounded.
    var autoScrollsHighlight: Bool = false
    var readerViewportRange: NSRange? = nil
    /// 暴露底层 textview（供解读 mark 定位）。布局完成后回调。
    var onReady: ((ReaderUITextView) -> Void)? = nil

    func makeUIView(context: Context) -> ReaderUITextView {
        ReaderUITextView.make()
    }

    func updateUIView(_ tv: ReaderUITextView, context: Context) {
        tv.isScrollEnabled = autoScrollsHighlight
        tv.viewportFocusRange = readerViewportRange
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
        para.lineSpacing = lineSpacing
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
        usesSerif
            ? (UIFont(name: "Georgia", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize))
            : UIFont.systemFont(ofSize: fontSize)
    }
}
