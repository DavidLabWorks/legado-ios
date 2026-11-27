import SwiftUI
import UIKit

extension UIView {
    func handleReaderTap(at point: CGPoint, menu: () -> Void, turn: (Int) -> Void) {
        let x = point.x - bounds.minX
        let third = bounds.width / 3
        if x < third { turn(-1) }
        else if x >= 2 * third { turn(1) }
        else { menu() }
    }
}

extension UIScrollView {
    @discardableResult
    func turnReaderScreen(_ direction: Int) -> Bool {
        let top = -adjustedContentInset.top
        let bottom = max(top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let y = min(bottom, max(top, contentOffset.y + CGFloat(direction) * bounds.height))
        guard abs(y - contentOffset.y) > 0.5 else { return false }
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: !UIAccessibility.isReduceMotionEnabled)
        return true
    }
}

struct ReaderTextPage {
    let offset: CGFloat
    let height: CGFloat
    let characterRange: NSRange

    @MainActor func visibleRect(in view: UITextView) -> CGRect {
        let inset = view.textContainerInset
        let available = max(1, view.bounds.height - inset.top - inset.bottom)
        return CGRect(x: view.bounds.minX, y: view.bounds.minY + inset.top,
                      width: view.bounds.width, height: min(height, available))
    }

    /// TextKit line fragments include line/paragraph spacing and mixed fonts.
    /// A page break must fall between these fragments, never through a glyph.
    @MainActor static func layout(in view: UITextView, height: CGFloat) -> [ReaderTextPage] {
        let manager = view.layoutManager
        manager.ensureLayout(for: view.textContainer)
        var pages: [ReaderTextPage] = []
        var startY: CGFloat = 0
        var endY: CGFloat = 0
        var startGlyph = 0
        var endGlyph = 0
        func appendPage() {
            guard endGlyph > startGlyph else { return }
            let glyphs = NSRange(location: startGlyph, length: endGlyph - startGlyph)
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            pages.append(.init(offset: startY, height: endY - startY, characterRange: characters))
        }
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            rect, _, _, glyphs, _ in
            if endGlyph > startGlyph, rect.maxY - startY > height + 0.01 {
                appendPage()
                startY = rect.minY
                startGlyph = glyphs.location
            }
            endY = rect.maxY
            endGlyph = NSMaxRange(glyphs)
        }
        appendPage()
        return pages
    }
}

// The live TextKit document stays at the committed page while the two visible
// page images move. Dragging never publishes a speculative reading position.
private final class ReaderPageDragView: UIView {
    let current = UIImageView()
    let adjacent = UIImageView()
    var direction = 0

    init(frame: CGRect, image: UIImage) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        current.image = image
        // Right-align the full bitmap when the cover effect reveals a clipped strip.
        for page in [current, adjacent] {
            page.contentMode = .right
            page.clipsToBounds = true
        }
        current.frame = bounds
        addSubview(current)
        addSubview(adjacent)
    }

    required init?(coder: NSCoder) { nil }

    func move(to offset: CGFloat, covering: Bool = false) {
        var outgoing = bounds.offsetBy(dx: offset, dy: 0)
        var incoming = outgoing.offsetBy(dx: CGFloat(direction) * bounds.width, dy: 0)
        if covering {
            if direction > 0 { incoming.size.width = -offset }
            else { outgoing.size.width = bounds.width - offset }
        }
        current.frame = outgoing
        adjacent.frame = incoming
    }

    func animateTurn(commit: Bool, animation: Int, releaseSpeed: CGFloat = 0,
                     completion: @escaping (Bool) -> Void) {
        let destination = commit ? -CGFloat(direction) * bounds.width : 0
        let distance = abs(destination - current.frame.minX)
        let remaining = distance / bounds.width
        let normalDuration = commit ? 0.18 + 0.12 * Double(remaining) : 0.12 + 0.10 * Double(remaining)
        let duration = commit && releaseSpeed > 0
            ? min(normalDuration, max(0.12, Double(distance / releaseSpeed))) : normalDuration
        if animation == 2, commit {
            UIView.transition(with: current, duration: 0.38,
                              options: direction > 0 ? .transitionCurlUp : .transitionCurlDown,
                              animations: { self.current.image = self.adjacent.image }, completion: completion)
        } else {
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                self.move(to: destination, covering: animation == 0)
            } completion: { completion($0) }
        }
    }
}

private class ReaderLayoutTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        onLayout?(self)
    }
}

/// A chapter snapshot keeps selection independent of page turns and recycled scroll cells.
@MainActor
struct ReaderTextSelection {
    let rendered: NSAttributedString
    let body: String
    let bodyStart: Int
    let character: Int
    let insets: UIEdgeInsets
    let viewportOffset: CGFloat
    let page: ReaderTextPage?
    let lineFragmentPadding: CGFloat

    init?(manager: NSLayoutManager, container: NSTextContainer, at point: CGPoint, body: String,
          bodyStart: Int, insets: UIEdgeInsets, viewportOffset: CGFloat, page: ReaderTextPage? = nil) {
        guard let storage = manager.textStorage, manager.numberOfGlyphs > 0 else { return nil }
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let character = manager.characterIndexForGlyph(at: glyph)
        if let page, !NSLocationInRange(character, page.characterRange) { return nil }
        guard rect.contains(point), NSLocationInRange(character, NSRange(location: bodyStart, length: body.utf16.count)) else { return nil }
        self.rendered = NSAttributedString(attributedString: storage)
        self.body = body
        self.bodyStart = bodyStart
        self.character = character
        self.insets = insets
        self.viewportOffset = viewportOffset
        self.page = page
        self.lineFragmentPadding = container.lineFragmentPadding
    }

    func containsBodyText(in range: NSRange) -> Bool {
        range.length > 0 && range.location >= bodyStart && NSMaxRange(range) <= bodyStart + body.utf16.count
    }

    func originalText(in range: NSRange) -> String? {
        guard containsBodyText(in: range) else { return nil }
        return (body as NSString).substring(with: NSRange(location: range.location - bodyStart, length: range.length))
    }
}

struct ReaderDictionary: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}

private final class ReaderSelectionRect: UITextSelectionRect {
    private let segment: UITextSelectionRect
    override var rect: CGRect { bounds }
    override var writingDirection: NSWritingDirection { segment.writingDirection }
    override var containsStart: Bool { startsRange }
    override var containsEnd: Bool { endsRange }
    override var isVertical: Bool { segment.isVertical }

    private let bounds: CGRect
    private let startsRange: Bool
    private let endsRange: Bool

    init(_ segment: UITextSelectionRect, rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        self.segment = segment
        bounds = rect
        startsRange = containsStart
        endsRange = containsEnd
        super.init()
    }
}

private final class ReaderSelectionTextView: ReaderLayoutTextView {
    static let handleDiameter: CGFloat = 9
    var onDismiss: (() -> Void)?
    var onSelectionLayout: ((CGRect) -> Void)?
    var showsSystemTranslation = false
    var page: ReaderTextPage?
    private let markers = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private let decoration = UIView()

    func configureSelection(in container: UIView) {
        // UIKit keeps its drag targets while these layers draw the smaller handles.
        tintColor = .clear
        let green = UIColor(red: 0.15, green: 0.55, blue: 0.34, alpha: 1)
        highlight.fillColor = green.withAlphaComponent(0.18).cgColor
        markers.fillColor = green.cgColor
        decoration.isUserInteractionEnabled = false
        decoration.accessibilityElementsHidden = true
        decoration.clipsToBounds = true
        decoration.frame = container.bounds
        decoration.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(decoration)
        decoration.layer.addSublayer(highlight)
        decoration.layer.addSublayer(markers)
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissSelection))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        if #unavailable(iOS 17.4) {
            NotificationCenter.default.addObserver(self, selector: #selector(legacyTranslationMenuClosed),
                name: UIMenuController.didHideMenuNotification, object: nil)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let page, let mask = layer.mask as? CAShapeLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.path = UIBezierPath(rect: page.visibleRect(in: self)).cgPath
            CATransaction.commit()
        }
        updateSelection()
    }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let characters = NSRange(location: offset(from: beginningOfDocument, to: range.start),
                                 length: offset(from: range.start, to: range.end))
        guard characters.length > 0 else { return super.selectionRects(for: range) }

        var result: [UITextSelectionRect] = []
        let manager = layoutManager
        let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let line = NSIntersectionRange(characters, manager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil))
            guard line.length > 0,
                  let start = self.position(from: range.start, offset: line.location - characters.location),
                  let end = self.position(from: start, offset: line.length),
                  let part = self.textRange(from: start, to: end) else { return }

            let band = manager.selectionBand(for: lineGlyphs)
                .offsetBy(dx: self.textContainerInset.left, dy: self.textContainerInset.top)
            let intersecting = super.selectionRects(for: part).filter { !$0.rect.intersection(band).isNull }
            let visible = intersecting.filter { $0.rect.intersection(band).width > 0 }
            let segments = visible.isEmpty ? intersecting : visible
            // At a wrap UIKit can put the endpoint on a zero-width rect on the adjacent line.
            let first = segments.first(where: { $0.containsStart }) ?? segments.first
            let last = segments.last(where: { $0.containsEnd }) ?? segments.last
            for segment in segments {
                let overlap = segment.rect.intersection(band)
                let rect = CGRect(x: overlap.minX, y: band.minY, width: overlap.width, height: band.height)
                result.append(ReaderSelectionRect(segment, rect: rect,
                    containsStart: line.location == characters.location && segment === first,
                    containsEnd: NSMaxRange(line) == NSMaxRange(characters) && segment === last))
            }
        }
        return result
    }

    func updateSelection() {
        let handles = UIBezierPath()
        let background = UIBezierPath()
        if let selection = selectedTextRange, !selection.isEmpty {
            for segment in selectionRects(for: selection) {
                let rect = convert(segment.rect, to: decoration)
                background.append(UIBezierPath(rect: rect))
                let rtl = segment.writingDirection == .rightToLeft
                if segment.containsStart { appendHandle(to: handles, rect: rect, x: rtl ? rect.maxX : rect.minX, atStart: true) }
                if segment.containsEnd { appendHandle(to: handles, rect: rect, x: rtl ? rect.minX : rect.maxX, atStart: false) }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = decoration.bounds
        markers.frame = highlight.frame
        highlight.path = background.cgPath
        markers.path = handles.cgPath
        CATransaction.commit()
        onSelectionLayout?(background.isEmpty || showsSystemTranslation ? .null : background.bounds.intersection(decoration.bounds))
    }

    private func appendHandle(to path: UIBezierPath, rect: CGRect, x: CGFloat, atStart: Bool) {
        path.append(UIBezierPath(rect: CGRect(x: x - 0.75, y: rect.minY, width: 1.5, height: rect.height)))
        let diameter = Self.handleDiameter
        guard rect.intersects(decoration.bounds) else { return }
        let desiredY = atStart ? rect.minY - diameter : rect.maxY
        let y = min(max(desiredY, 0), decoration.bounds.height - diameter)
        path.append(UIBezierPath(ovalIn: CGRect(x: x - diameter / 2, y: y, width: diameter, height: diameter)))
    }

    @objc private func dismissSelection() { onDismiss?() }

    override func accessibilityPerformEscape() -> Bool {
        dismissSelection()
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if showsSystemTranslation {
            return NSStringFromSelector(action).localizedCaseInsensitiveContains("translate")
                && super.canPerformAction(action, withSender: sender)
        }
        return action == #selector(copy(_:)) && sender is UIKeyCommand
    }

    @objc private func legacyTranslationMenuClosed() {
        guard showsSystemTranslation else { return }
        showsSystemTranslation = false
        updateSelection()
    }

    // iOS 15–17.3 expose system translation through the text editing menu.
    func showLegacyTranslation() {
        guard let range = selectedTextRange else { return }
        showsSystemTranslation = true
        updateSelection()
        UIMenuController.shared.showMenu(from: self, rect: firstRect(for: range))
    }
}

struct ReaderSelectionView: UIViewRepresentable {
    let selection: ReaderTextSelection
    let onDismiss: () -> Void
    let onFilter: (String) -> Void
    let onLookup: (String) -> Void
    let onTranslate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let view = ReaderSelectionTextView(frame: .zero, textContainer: nil)
        // Match the TextKit 1 layout used to create the chapter snapshot.
        _ = view.layoutManager
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Give native drags room past the visible edge so UIKit does not draw an overflow knob.
        let handleMargin = ReaderSelectionTextView.handleDiameter * 2
        view.frame = container.bounds.insetBy(dx: 0, dy: -handleMargin)
        container.clipsToBounds = true
        container.addSubview(view)
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.accessibilityIdentifier = "reader.selection"
        view.contentInsetAdjustmentBehavior = .never
        view.textContainer.lineFragmentPadding = selection.lineFragmentPadding
        if let page = selection.page {
            view.page = page
            // Keep the full TextKit layout for paragraphs that wrap across a page break.
            view.panGestureRecognizer.isEnabled = false
            view.showsVerticalScrollIndicator = false
            view.layer.mask = CAShapeLayer()
        }
        var insets = selection.insets
        insets.top += handleMargin
        insets.bottom += handleMargin
        view.textContainerInset = insets
        view.attributedText = selection.rendered
        view.delegate = context.coordinator
        view.configureSelection(in: container)
        view.onDismiss = onDismiss

        let toolbar = UIStackView()
        toolbar.accessibilityIdentifier = "reader.selectionMenu"
        toolbar.distribution = .fillEqually
        toolbar.backgroundColor = UIColor(white: 0.18, alpha: 0.98)
        toolbar.layer.cornerRadius = 9
        toolbar.layer.cornerCurve = .continuous
        toolbar.isHidden = true
        container.addSubview(toolbar)
        @discardableResult func addAction(_ title: String, icon: String, perform: @escaping (ReaderSelectionTextView, String) -> Void) -> UIButton {
            var config = UIButton.Configuration.plain()
            config.title = title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var styled = attributes
                styled.font = UIFont.preferredFont(forTextStyle: .caption1)
                return styled
            }
            config.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            config.imagePlacement = .top
            config.imagePadding = 4
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak view] _ in
                guard let view, let range = view.selectedTextRange, let text = view.text(in: range), !text.isEmpty else { return }
                perform(view, text)
            })
            button.accessibilityLabel = title
            toolbar.addArrangedSubview(button)
            return button
        }
        addAction("复制", icon: "doc.on.doc") { _, text in
            UIPasteboard.general.string = text
            onDismiss()
        }
        let filter = addAction("过滤", icon: "line.3.horizontal.decrease.circle") { view, _ in
            if let text = selection.originalText(in: view.selectedRange) { onFilter(text) }
        }
        addAction("查找", icon: "book") { _, text in onLookup(text) }
        addAction("翻译", icon: "character.bubble") { view, text in
            if #available(iOS 17.4, *) { onTranslate(text) } else { view.showLegacyTranslation() }
        }
        view.onSelectionLayout = { [weak view, weak toolbar, weak filter] visibleRect in
            guard let view, let toolbar, let viewport = toolbar.superview?.bounds else { return }
            toolbar.isHidden = visibleRect.isNull
            guard !visibleRect.isNull else { return }
            filter?.isEnabled = selection.containsBodyText(in: view.selectedRange)
            let anchor = visibleRect
            let size = toolbar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let width = min(max(208, size.width), viewport.width - 12)
            let height = max(46, size.height)
            let x = min(max(6, anchor.midX - width / 2), viewport.width - width - 6)
            let clearance = ReaderSelectionTextView.handleDiameter + 4
            let above = anchor.minY - height - clearance
            let y = above >= 4 ? above : min(anchor.maxY + clearance, viewport.height - height - 4)
            toolbar.frame = CGRect(x: x, y: max(4, y), width: width, height: height).integral
        }
        view.onLayout = { [selection, weak view] _ in
            guard let view else { return }
            view.onLayout = nil
            guard let position = view.position(from: view.beginningOfDocument, offset: selection.character) else { return }
            let word = view.tokenizer.rangeEnclosingPosition(position, with: .word,
                inDirection: UITextDirection.storage(.forward))
            let fallback = (selection.rendered.string as NSString).rangeOfComposedCharacterSequence(at: selection.character)
            view.becomeFirstResponder()
            if let word { view.selectedTextRange = word } else { view.selectedRange = fallback }
            // A short chapter can begin halfway down the continuous viewport.
            let selectionBottom = view.selectedTextRange.map { view.firstRect(for: $0).maxY } ?? 0
            let offset = selection.page?.offset ?? max(selection.viewportOffset, selectionBottom + handleMargin - view.bounds.height)
            view.contentInset.top = max(0, -offset)
            view.contentInset.bottom = max(0, offset + view.bounds.height - view.contentSize.height)
            view.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil else { return }
            view.becomeFirstResponder()
            view.updateSelection()
        }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {}

    final class Coordinator: NSObject, UITextViewDelegate {
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? ReaderSelectionTextView, let page = view.page,
                  abs(view.contentOffset.y - page.offset) > 0.5 else { return }
            view.contentOffset.y = page.offset
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let view = textView as? ReaderSelectionTextView else { return }
            if let range = view.page?.characterRange, view.selectedRange.length > 0 {
                let allowed = NSIntersectionRange(view.selectedRange, range)
                if allowed != view.selectedRange {
                    view.selectedRange = allowed
                }
            }
            view.updateSelection()
        }

        @available(iOS 16.0, *)
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = textView as? ReaderSelectionTextView, view.showsSystemTranslation else {
                return UIMenu(children: [])
            }
            return nil
        }
    }
}

private extension NSLayoutManager {
    func selectionBand(for line: NSRange) -> CGRect {
        func fontBand(at glyph: Int) -> CGRect {
            var glyphs = NSRange()
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            let first = glyphs.location
            let character = characterIndexForGlyph(at: first)
            guard let font = textStorage?.attribute(.font, at: character, effectiveRange: nil) as? UIFont else { return used }
            let baseline = lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY + location(forGlyphAt: first).y
            return CGRect(x: used.minX, y: baseline - font.ascender, width: used.width, height: font.ascender - font.descender)
        }

        let band = fontBand(at: line.location)
        var top = band.minY - 2
        var bottom = band.maxY + 2
        // Leave two points between adjacent selections, even with tight leading.
        if line.location > 0 {
            top = max(top, (fontBand(at: line.location - 1).maxY + band.minY) / 2 + 1)
        }
        if NSMaxRange(line) < numberOfGlyphs {
            bottom = min(bottom, (band.maxY + fontBand(at: NSMaxRange(line)).minY) / 2 - 1)
        }
        return CGRect(x: band.minX, y: top, width: band.width, height: max(0, bottom - top))
    }
}

final class ReaderLayoutManager: NSLayoutManager {
    private var speechRange: NSRange?
    private var speechColor = UIColor.clear

    func highlight(_ target: ReaderSpokenText?, sectionStart: Int, bodyStart: Int, bodyEnd: Int, tint: UIColor) -> Bool {
        let next: NSRange?
        switch target {
        case .chapterTitle where bodyStart > sectionStart + 1:
            // The rendered heading ends with a newline before the body.
            next = NSRange(location: sectionStart, length: bodyStart - sectionStart - 1)
        case .body(let range) where range.length > 0 && range.location >= 0 && NSMaxRange(range) <= bodyEnd - bodyStart:
            next = NSRange(location: bodyStart + range.location, length: range.length)
        default:
            next = nil
        }
        guard next != speechRange || (next != nil && tint != speechColor) else { return false }
        let previous = speechRange
        speechRange = next
        speechColor = tint
        for range in [previous, next].compactMap({ $0 }) {
            let valid = NSIntersectionRange(range, NSRange(location: 0, length: textStorage?.length ?? 0))
            if valid.length > 0 { invalidateDisplay(forCharacterRange: valid) }
        }
        return true
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let speechRange, NSMaxRange(speechRange) <= (textStorage?.length ?? 0),
              let context = UIGraphicsGetCurrentContext() else { return }
        let selected = glyphRange(forCharacterRange: speechRange, actualCharacterRange: nil)
        let visible = NSIntersectionRange(selected, glyphsToShow)
        guard visible.length > 0 else { return }
        context.saveGState()
        context.setFillColor(speechColor.cgColor)
        enumerateLineFragments(forGlyphRange: visible) { _, _, container, line, _ in
            let band = self.selectionBand(for: line)
            let part = NSIntersectionRange(visible, line)
            self.enumerateEnclosingRects(forGlyphRange: part, withinSelectedGlyphRange: selected, in: container) { rect, _ in
                let overlap = rect.intersection(band)
                guard overlap.width > 0 else { return }
                context.fill(CGRect(x: overlap.minX + origin.x, y: band.minY + origin.y,
                                    width: overlap.width, height: band.height))
            }
        }
        context.restoreGState()
    }
}

struct ReaderTextView: UIViewRepresentable {
    var simplifiedChinese = false
    let adjacentPagePreview: (Int) -> (title: String, text: String?)?
    let text: String
    let title: String
    let previousTitle: String?
    let previousText: String
    let isPreviousReady: Bool
    let continuationTitle: String?
    let continuationText: String
    let isContinuationReady: Bool
    let isVolume: Bool
    let fontSize: Double
    let fontPath: String
    var fontRevision = 0
    let letterSpacing: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let paragraphIndent: String
    let paddingLeft: Double
    let paddingRight: Double
    let paddingTop: Double
    let paddingBottom: Double
    let headerInset: Double
    let footerInset: Double
    let fontWeight: Int
    let titleMode: Int
    let titleSize: Double
    let titleTopSpacing: Double
    let titleBottomSpacing: Double
    let underlineMode: Int
    var onSelectText: ((ReaderTextSelection) -> Void)?
    let fullJustify: Bool
    let pageAnimation: Int
    let isEInkMode: Bool
    let backgroundColor: UIColor
    let foregroundColor: UIColor
    var spokenText: ReaderSpokenText?
    var spokenPosition: Int?
    var speechColor: UIColor = .clear
    let requestedPosition: Int
    let jumpPosition: Int?
    var jumpRevision = 0
    let renderRevision: Int
    @Binding var readerPosition: Int
    @Binding var pageRanges: [NSRange]
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    let isAutoReading: Bool
    let isAutoReadPaused: Bool
    let isLoadingNextChapter: Bool
    let secondsPerScreen: Double
    let onReachedEnd: (Int) -> Void
    let onReachedStart: (Int) -> Void
    let onEnteredPrevious: (Int) -> Void
    let onEnteredContinuation: (Int) -> Void
    let onDeferredRender: () -> Void
    let onCancelNextLoading: () -> Void
    let onPageChanged: () -> Void
    let onMenuTap: () -> Void
    var holdsDisplayedPage = false
    var chapterGeneration = 0

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let manager = ReaderLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = ReaderLayoutTextView(frame: .zero, textContainer: container)
        view.onLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator, !coordinator.parent.holdsDisplayedPage, !coordinator.isApplyingContent else { return }
            coordinator.restorePendingPage(in: view)
            coordinator.reportPage(in: view)
            coordinator.reportPageRanges(in: view)
        }
        view.accessibilityIdentifier = "reader.text"
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.textContainer.lineFragmentPadding = 4
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.isPagingEnabled = false
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let wasHoldingPage = context.coordinator.parent.holdsDisplayedPage
        let chapterChanged = context.coordinator.parent.chapterGeneration != chapterGeneration
        context.coordinator.parent = self
        if holdsDisplayedPage {
            if !wasHoldingPage { context.coordinator.holdDisplayedPage() }
            return
        }
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.lastViewportSize = view.bounds.size
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = false
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.resignFirstResponder()
        view.textContainerInset = .init(
            top: CGFloat(paddingTop + headerInset),
            left: CGFloat(paddingLeft),
            bottom: CGFloat(paddingBottom + footerInset),
            right: CGFloat(paddingRight)
        )
        let contentKey = text.hashValue
        var primaryHasher = Hasher()
        primaryHasher.combine(title)
        primaryHasher.combine(contentKey)
        let primaryContentKey = primaryHasher.finalize()
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        let adjacentContentKey = "\(showsPrevious)|\(previousTitle ?? "")|\(previousText)|\(showsContinuation)|\(continuationTitle ?? "")|\(continuationText)".hashValue
        let displaysTitle = titleMode != 2 || isVolume
        let styleKey = "\(simplifiedChinese)|\(contentKey)|\(adjacentContentKey)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(fontRevision)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)"
        if chapterChanged || context.coordinator.styleKey != styleKey {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let primaryContentChanged = chapterChanged || context.coordinator.primaryContentKey != primaryContentKey
            let position = primaryContentChanged ? requestedPosition : context.coordinator.pendingPagePosition
                ?? context.coordinator.contentCharacter(at: view.contentOffset, in: view)
            context.coordinator.resetAutoReadForPageChange()
            context.coordinator.resetPageRangeRetry()
            context.coordinator.contentKey = contentKey
            context.coordinator.primaryContentKey = primaryContentKey
            context.coordinator.styleKey = styleKey
            let typography = ReaderTypography(configuration: self)
            let bodyAttributes = typography.bodyAttributes
            let rendered = NSMutableAttributedString(string: "")
            context.coordinator.previousBodyStart = nil
            context.coordinator.previousBodyEnd = nil
            context.coordinator.continuationSectionStart = nil
            context.coordinator.continuationBodyStart = nil
            if showsPrevious {
                let previousHeading = displaysTitle ? (previousTitle ?? "").readerText(simplified: simplifiedChinese) + "\n" : ""
                rendered.append(NSAttributedString(string: previousHeading, attributes: typography.headingAttributes))
                context.coordinator.previousBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: previousText.isEmpty ? String(repeating: "\n", count: 80) : previousText.readerText(simplified: simplifiedChinese),
                    attributes: bodyAttributes
                ))
                context.coordinator.previousBodyEnd = rendered.length
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            context.coordinator.currentSectionStart = rendered.length
            let titlePrefix = displaysTitle && !title.isEmpty ? title.readerText(simplified: simplifiedChinese) + "\n" : ""
            if !titlePrefix.isEmpty {
                rendered.append(NSAttributedString(string: titlePrefix, attributes: typography.headingAttributes))
            }
            context.coordinator.renderedPrefixLength = rendered.length
            rendered.append(NSAttributedString(string: text.readerText(simplified: simplifiedChinese), attributes: bodyAttributes))
            context.coordinator.currentBodyEnd = rendered.length
            if showsContinuation {
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                context.coordinator.continuationSectionStart = rendered.length
                let continuationHeading = displaysTitle ? (continuationTitle ?? "").readerText(simplified: simplifiedChinese) + "\n" : ""
                rendered.append(NSAttributedString(string: continuationHeading, attributes: typography.headingAttributes))
                context.coordinator.continuationBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: continuationText.isEmpty ? String(repeating: "\n", count: 80) : continuationText.readerText(simplified: simplifiedChinese),
                    attributes: bodyAttributes
                ))
            }
            context.coordinator.isApplyingContent = true
            view.textStorage.setAttributedString(rendered)
            context.coordinator.isApplyingContent = false
            context.coordinator.scroll(to: position, in: view)
            if chapterChanged { context.coordinator.animateLoadedChapter(in: view) }
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged {
            context.coordinator.scroll(to: context.coordinator.pendingPagePosition ?? readerPosition, in: view)
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        }
        context.coordinator.highlightSpeech(in: view)
        if let jumpPosition, context.coordinator.lastJumpPosition != jumpPosition || context.coordinator.lastJumpRevision != jumpRevision {
            context.coordinator.lastJumpRevision = jumpRevision
            context.coordinator.lastJumpPosition = jumpPosition
            context.coordinator.scroll(to: jumpPosition, in: view)
        } else if jumpPosition == nil {
            context.coordinator.lastJumpPosition = nil
        }
        context.coordinator.updateLoadingFooter(in: view, visible: isLoadingNextChapter)
        context.coordinator.updateAutoRead(
            isRunning: isAutoReading,
            isPaused: isAutoReadPaused,
            secondsPerScreen: secondsPerScreen
        )
        // SwiftUI can reset the bindings after the chapter's TextKit layout has
        // already completed. Reconcile them even when the text/style is unchanged.
        if view.bounds.width > 0, view.bounds.height > 0 {
            context.coordinator.reportPage(in: view)
            if pageRanges.isEmpty { context.coordinator.reportPageRanges(in: view) }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var contentKey = 0
        var primaryContentKey = 0
        var styleKey = ""
        func highlightSpeech(in view: UITextView) {
            let manager = view.layoutManager as! ReaderLayoutManager
            if manager.highlight(parent.spokenText, sectionStart: currentSectionStart, bodyStart: renderedPrefixLength,
                                 bodyEnd: currentBodyEnd, tint: parent.speechColor) {
                dragImages.removeAll()
            }
        }

        var renderedPrefixLength = 0
        var currentSectionStart = 0
        var currentBodyEnd = 0
        var previousBodyStart: Int?
        var previousBodyEnd: Int?
        var continuationSectionStart: Int?
        var continuationBodyStart: Int?
        var lastJumpPosition: Int?
        var lastJumpRevision = 0
        private(set) var pendingPagePosition: Int?
        private(set) var layoutGeneration = 0
        var lastViewportSize = CGSize.zero
        private var isAutoReading = false
        private var isAutoReadPaused = false
        private var secondsPerScreen = 10.0
        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isUserDragging = false
        private var lastDragOffsetY: CGFloat = 0
        private var dragDirection = 0
        private var didReachEnd = false
        private var didReachStart = false
        private var didEnterPrevious = false
        private var didEnterContinuation = false
        private var pendingPreviousPosition: Int?
        private var pendingContinuationPosition: Int?
        var needsDeferredRender = false
        var isApplyingContent = false
        private var isRenderingAutoPage = false
        private var lastReportedPage: Int?
        private var autoPageProgress: CGFloat = 0
        private var eInkElapsed: CFTimeInterval = 0
        private var eInkPageInterval: CFTimeInterval = 10
        private var autoPageTarget: CGFloat?
        private weak var autoPageOverlay: UIImageView?
        private var pageRangeRetryCount = 0
        private weak var pagePan: UIPanGestureRecognizer?
        private var trackingPagePan = false
        private var panLayoutGeneration: Int?
        private var finishSettlingPage: (() -> Void)?
        private var pendingChapterTurn: (generation: Int, direction: Int, image: UIImage, animation: Int)?
        private var pageDragView: ReaderPageDragView?
        private weak var readerTap: UITapGestureRecognizer?
        private weak var loadingFooter: UIView?
        private var didRequestLoadingCancellation = false
        private var cachedPages: [ReaderTextPage] = []
        private var paginationKey = ""
        private let pageMask = CAShapeLayer()
        private var previewCenter: Int?
        private var dragImages: [Int: (image: UIImage, title: String?, text: String?)] = [:]

        private var showsDragPreview: Bool {
            !parent.isEInkMode && parent.pageAnimation != 3 && parent.pageAnimation != 4
                && !UIAccessibility.isReduceMotionEnabled
        }

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func installGestures(on view: UITextView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delaysTouchesBegan = false
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            readerTap = tap
            let press = UILongPressGestureRecognizer(target: self, action: #selector(selectText(_:)))
            view.addGestureRecognizer(press)
            tap.require(toFail: press)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
            tap.require(toFail: pan)
            pagePan = pan
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === pagePan else { return true }
            return (pageDragView == nil || finishSettlingPage != nil) && !parent.holdsDisplayedPage
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === readerTap || otherGestureRecognizer === readerTap
        }

        func updateInteractionMode(on view: UITextView, isScrollMode: Bool) {
            // The scroll reader owns the vertical pan gesture. Horizontal
            // swipe recognizers must be disabled there or UIKit can cancel the
            // pan before the user reaches the end of a long chapter.
            pagePan?.isEnabled = !isScrollMode
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            view.isPagingEnabled = false
            view.showsVerticalScrollIndicator = false
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
            if parent.pageAnimation != 3 {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                return
            }
            if !visible {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                view.contentInset.bottom = 0
                didRequestLoadingCancellation = false
                return
            }
            let footer: UIView
            if let loadingFooter {
                footer = loadingFooter
            } else {
                let container = UIView()
                container.isUserInteractionEnabled = false
                let indicator = RagdollImageView(width: 36)
                let label = UILabel()
                label.text = "正在加载下一章…"
                label.textColor = parent.foregroundColor.withAlphaComponent(0.65)
                label.font = .systemFont(ofSize: 13)
                let stack = UIStackView(arrangedSubviews: [indicator, label])
                stack.axis = .horizontal
                stack.spacing = 8
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                view.addSubview(container)
                loadingFooter = container
                footer = container
            }
            view.contentInset.bottom = 64
            footer.frame = CGRect(x: 0, y: view.contentSize.height, width: view.bounds.width, height: 52)
        }

        func shouldDeferRender(in view: UITextView) -> Bool {
            parent.pageAnimation == 3 && (isUserDragging || view.isDragging || view.isDecelerating)
        }

        func holdDisplayedPage() {
            cancelPageDrag()
            layoutGeneration &+= 1
            isAutoReadPaused = true
        }

        func invalidate() {
            cancelPageDrag()
            previewCenter = nil
            dragImages.removeAll()
            layoutGeneration &+= 1
            resetAutoPage()
            displayLink?.invalidate()
            displayLink = nil
        }

        func updateAutoRead(isRunning: Bool, isPaused: Bool, secondsPerScreen: Double) {
            let wasRunning = isAutoReading
            let wasPaused = isAutoReadPaused
            self.isAutoReading = isRunning
            isAutoReadPaused = isPaused
            self.secondsPerScreen = max(1, secondsPerScreen)
            if wasRunning && !isRunning {
                resetAutoPage()
            } else if !wasRunning && isRunning {
                didReachEnd = false
                lastTimestamp = 0
                eInkPageInterval = self.secondsPerScreen
            } else if isPaused || wasPaused != isPaused {
                lastTimestamp = 0
            }
        }

        func resetAutoReadForPageChange() {
            didReachEnd = false
            didReachStart = false
            lastReportedPage = nil
            didEnterPrevious = false
            didEnterContinuation = false
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            resetAutoPage()
        }

        func scroll(to characterPosition: Int, in view: UITextView) {
            cancelPageDrag()
            guard !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            if parent.pageAnimation != 3 {
                // Another layout pass may already be reading the visible page when
                // this update returns. Apply the chapter position before that pass.
                pendingPagePosition = characterPosition
                restorePendingPage(in: view)
                return
            }
            let generation = layoutGeneration
            let prefix = characterPosition == 0 ? currentSectionStart : renderedPrefixLength
            let location = ReaderPositionResolver.renderedLocation(
                position: characterPosition,
                prefixLength: prefix,
                renderedLength: view.text.utf16.count
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
                var point = view.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: view.textContainer
                ).origin
                point.y += view.textContainerInset.top
                let limits = self.scrollLimits(for: view)
                let target = min(
                    max(point.y - view.adjustedContentInset.top, limits.minimum),
                    limits.maximum
                )
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }

        func restorePendingPage(in view: UITextView) {
            guard let position = pendingPagePosition, !isApplyingContent,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            isApplyingContent = true
            defer {
                isApplyingContent = false
                if pendingPagePosition == nil { scrollViewDidScroll(view) }
            }
            // Install the new document's scroll extent before restoring a chapter-end anchor.
            view.layoutIfNeeded()
            let pages = pages(in: view)
            guard let first = pages.first, let last = pages.last else { return }
            let location = ReaderPositionResolver.renderedLocation(
                position: position, prefixLength: renderedPrefixLength, renderedLength: view.textStorage.length
            )
            // Chapter start includes the heading, even when it fills a page of its own.
            let page = position == 0 ? first : pages.first { NSLocationInRange(location, $0.characterRange) } ?? last
            lastViewportSize = view.bounds.size
            view.setContentOffset(CGPoint(x: 0, y: page.offset), animated: false)
            pendingPagePosition = nil
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            if parent.pageAnimation != 3 {
                return max(view.bounds.height - view.textContainerInset.top - view.textContainerInset.bottom, 1)
            }
            return max(
                view.bounds.height
                    - view.adjustedContentInset.top
                    - view.adjustedContentInset.bottom
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }

        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            if parent.pageAnimation != 3 {
                return (0, pages(in: view).last?.offset ?? 0)
            }
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            if parent.pageAnimation != 3 {
                let pages = pages(in: view)
                return (pageIndex(in: view, pages: pages) + 1, max(pages.count, 1))
            }
            let pageHeight = readingViewportHeight(for: view)
            if parent.pageAnimation == 3, currentBodyEnd > currentSectionStart {
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyphCount = view.layoutManager.numberOfGlyphs
                if glyphCount > 0 {
                    let first = min(view.layoutManager.glyphIndexForCharacter(at: currentSectionStart), glyphCount - 1)
                    let last = min(view.layoutManager.glyphIndexForCharacter(at: currentBodyEnd - 1), glyphCount - 1)
                    let start = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: first, length: 1), in: view.textContainer
                    ).minY + view.textContainerInset.top - view.adjustedContentInset.top
                    let end = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: last, length: 1), in: view.textContainer
                    ).maxY + view.textContainerInset.top - view.adjustedContentInset.top
                    let total = max(Int(ceil((end - start) / pageHeight)), 1)
                    let position = max(view.contentOffset.y - start, 0)
                    return (min(Int(floor(position / pageHeight)) + 1, total), total)
                }
            }
            let limits = scrollLimits(for: view)
            let scrollRange = max(limits.maximum - limits.minimum, 0)
            let total = max(Int(ceil(scrollRange / pageHeight)) + 1, 1)
            guard total > 1 else { return (1, 1) }
            let position = min(max(view.contentOffset.y - limits.minimum, 0), scrollRange)
            let current = position >= scrollRange - 0.5
                ? total
                : min(Int(floor(position / pageHeight)) + 1, total)
            return (current, total)
        }

        private func pages(in view: UITextView) -> [ReaderTextPage] {
            let key = "\(styleKey)|\(view.bounds.size)|\(view.textContainerInset)|\(view.textContainer.size.width)"
            if paginationKey != key || cachedPages.isEmpty {
                cachedPages = ReaderTextPage.layout(in: view, height: readingViewportHeight(for: view))
                paginationKey = key
                previewCenter = nil
                dragImages.removeAll()
            }
            // The last page also starts at a complete line, even when it
            // contains less than a screen of text. Keep this after relayouts.
            let bottom = max(0, (cachedPages.last?.offset ?? 0) + view.bounds.height - view.contentSize.height)
            if abs(view.contentInset.bottom - bottom) > 0.01 { view.contentInset.bottom = bottom }
            return cachedPages
        }

        private func pageIndex(in view: UITextView, pages: [ReaderTextPage]) -> Int {
            pages.lastIndex { $0.offset <= view.contentOffset.y + 0.5 } ?? 0
        }

        private func nextPageOffset(in view: UITextView, direction: Int = 1) -> CGFloat {
            let pages = pages(in: view)
            guard !pages.isEmpty else { return 0 }
            return pages[min(max(pageIndex(in: view, pages: pages) + direction, 0), pages.count - 1)].offset
        }

        private func updatePageMask(in view: UITextView) {
            guard pageDragView == nil else { return }
            guard parent.pageAnimation != 3 else {
                view.layer.mask = nil
                return
            }
            let pages = pages(in: view)
            guard !pages.isEmpty else { return }
            let page = pages[pageIndex(in: view, pages: pages)]
            // UITextView lays out one continuous document. Hide neighboring
            // lines in the per-page margins instead of showing partial lines.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pageMask.path = UIBezierPath(rect: page.visibleRect(in: view)).cgPath
            view.layer.mask = pageMask
            CATransaction.commit()
        }

        private func renderedCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            guard !view.text.isEmpty else { return 0 }
            if parent.pageAnimation != 3 {
                let pages = pages(in: view)
                return pages.isEmpty ? 0 : pages[pageIndex(in: view, pages: pages)].characterRange.location
            }
            let point = CGPoint(
                x: view.textContainerInset.left + 1,
                y: offset.y + view.textContainerInset.top + 1
            )
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return 0 }
            let glyph = min(view.layoutManager.glyphIndex(for: point, in: view.textContainer), glyphCount - 1)
            let character = view.layoutManager.characterIndexForGlyph(at: glyph)
            return min(max(character, 0), view.text.utf16.count)
        }

        func contentCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            let character = renderedCharacter(at: offset, in: view)
            return min(max(character - renderedPrefixLength, 0), parent.text.utf16.count)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !parent.holdsDisplayedPage, !isRenderingAutoPage, !isApplyingContent, pendingPagePosition == nil else { return }
            guard let view = scrollView as? UITextView, !view.text.isEmpty else { return }
            if parent.isLoadingNextChapter, !didRequestLoadingCancellation {
                let textBottom = max(
                    view.contentSize.height - view.bounds.height
                        + view.adjustedContentInset.bottom - view.contentInset.bottom,
                    -view.adjustedContentInset.top
                )
                if view.contentOffset.y < textBottom - 44 {
                    didRequestLoadingCancellation = true
                    DispatchQueue.main.async { [weak self] in self?.parent.onCancelNextLoading() }
                }
            }
            if isUserDragging {
                let delta = scrollView.contentOffset.y - lastDragOffsetY
                if abs(delta) > 0.5 { dragDirection = delta > 0 ? 1 : -1 }
                lastDragOffsetY = scrollView.contentOffset.y
            }
            let metrics = pageMetrics(for: view)
            reportPage(in: view)
            if let lastReportedPage, lastReportedPage != metrics.current {
                self.lastReportedPage = metrics.current
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onPageChanged()
                }
            } else if lastReportedPage == nil {
                lastReportedPage = metrics.current
            }
            let contentCharacter = contentCharacter(at: scrollView.contentOffset, in: view)
            let renderedCharacter = renderedCharacter(at: scrollView.contentOffset, in: view)
            if let previousBodyStart,
               let previousBodyEnd,
               renderedCharacter < currentSectionStart {
                pendingContinuationPosition = nil
                let position = min(max(renderedCharacter - previousBodyStart, 0), max(previousBodyEnd - previousBodyStart - 1, 0))
                if isUserDragging || view.isDecelerating {
                    pendingPreviousPosition = position
                    return
                }
                guard !didEnterPrevious else { return }
                didEnterPrevious = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(position)
                }
                return
            }
            if let continuationSectionStart,
               let continuationBodyStart,
               renderedCharacter >= continuationSectionStart {
                pendingPreviousPosition = nil
                let position = max(renderedCharacter - continuationBodyStart, 0)
                if isUserDragging || view.isDecelerating {
                    pendingContinuationPosition = position
                    return
                }
                guard !didEnterContinuation else { return }
                didEnterContinuation = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(position)
                }
                return
            }
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            guard contentCharacter != parent.readerPosition else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.readerPosition = contentCharacter
            }
        }

        func reportPage(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            updatePageMask(in: view)
            let metrics = pageMetrics(for: view)
            if showsDragPreview && !parent.holdsDisplayedPage {
                prepareDragImages(around: metrics.current - 1, in: view)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) frame=\(view.convert(view.bounds, to: nil)) offset=\(view.contentOffset) clip=\(view.clipsToBounds) mask=\(pageMask.path?.boundingBoxOfPath ?? .zero) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total)"
            }
            #endif
            guard metrics.current != parent.currentPage || metrics.total != parent.totalPages else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.currentPage = metrics.current
                self.parent.totalPages = metrics.total
            }
        }

        func reportPageRanges(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            if parent.pageAnimation == 3 {
                let ranges = parent.text.isEmpty
                    ? []
                    : [NSRange(location: 0, length: parent.text.utf16.count)]
                guard ranges != parent.pageRanges else { return }
                DispatchQueue.main.async { [weak self] in self?.parent.pageRanges = ranges }
                return
            }
            guard !view.text.isEmpty else { return }
            var ranges: [NSRange] = []
            for page in pages(in: view) {
                let characterRange = page.characterRange
                let start = max(characterRange.location - renderedPrefixLength, 0)
                let end = min(
                    characterRange.location + characterRange.length - renderedPrefixLength,
                    parent.text.utf16.count
                )
                ranges.append(NSRange(location: start, length: max(end - start, 0)))
            }
            if ranges.isEmpty {
                guard pageRangeRetryCount < 10 else { return }
                pageRangeRetryCount += 1
                let generation = layoutGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.reportPageRanges(in: view)
                }
                return
            }
            pageRangeRetryCount = 0
            guard ranges != parent.pageRanges else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.pageRanges = ranges
            }
        }

        func resetPageRangeRetry() {
            pageRangeRetryCount = 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserDragging = true
            lastDragOffsetY = scrollView.contentOffset.y
            dragDirection = 0
            didReachEnd = false
            didReachStart = false
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            if !decelerate {
                isUserDragging = false
                flushPendingChapterTransition()
                requestDeferredRenderIfNeeded()
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            isUserDragging = false
            flushPendingChapterTransition()
            requestDeferredRenderIfNeeded()
        }

        private func requestDeferredRenderIfNeeded() {
            guard needsDeferredRender else { return }
            needsDeferredRender = false
            DispatchQueue.main.async { [weak self] in self?.parent.onDeferredRender() }
        }

        private func flushPendingChapterTransition() {
            let previous = pendingPreviousPosition
            let continuation = pendingContinuationPosition
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            let generation = layoutGeneration
            if let previous, !didEnterPrevious {
                didEnterPrevious = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(previous)
                }
            } else if let continuation, !didEnterContinuation {
                didEnterContinuation = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(continuation)
                }
            }
        }

        private func triggerChapterBoundaryIfNeeded(in view: UITextView) {
            let (minimum, maximum) = scrollLimits(for: view)
            let atEnd = view.contentOffset.y >= maximum - 0.5
            let atStart = view.contentOffset.y <= minimum + 0.5
            if atEnd, dragDirection > 0, continuationSectionStart == nil, !didReachEnd {
                didReachEnd = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else if atStart, dragDirection < 0, previousBodyStart == nil, !didReachStart {
                didReachStart = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
            }
        }

        @objc private func selectText(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = textView, let onSelect = parent.onSelectText else { return }
            let inset = view.textContainerInset
            let point = gesture.location(in: view)
            var page: ReaderTextPage?
            if parent.pageAnimation != 3 {
                let pages = pages(in: view)
                guard !pages.isEmpty else { return }
                let current = pages[pageIndex(in: view, pages: pages)]
                guard current.visibleRect(in: view).contains(point) else { return }
                page = current
            }
            let selection = ReaderTextSelection(manager: view.layoutManager, container: view.textContainer,
                at: CGPoint(x: point.x - inset.left, y: point.y - inset.top), body: parent.text,
                bodyStart: renderedPrefixLength, insets: inset, viewportOffset: view.contentOffset.y, page: page)
            if let selection { onSelect(selection) }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = textView, gesture.state == .ended else { return }
            view.handleReaderTap(at: gesture.location(in: view), menu: parent.onMenuTap) { turnPage($0) }
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            guard let view = textView, let host = view.superview, view.bounds.width > 0 else { return }
            if pan.state == .began { panLayoutGeneration = layoutGeneration }
            guard panLayoutGeneration == layoutGeneration else { return }
            let width = view.bounds.width
            let travel = pan.translation(in: host)
            let offset = min(width, max(-width, travel.x))
            let direction = offset < 0 ? 1 : -1
            let horizontalIntent = abs(travel.x) >= 8 && abs(travel.x) * 1.8 >= abs(travel.y)
            switch pan.state {
            case .began, .changed:
                guard !parent.holdsDisplayedPage else { return }
                if !trackingPagePan {
                    // Wait for horizontal intent across several samples. A curved start can
                    // still become a page turn, while a vertical stroke leaves the page alone.
                    guard horizontalIntent else { return }
                    finishSettlingPage?()
                    guard pageDragView == nil else { return }
                    trackingPagePan = true
                    resetAutoPage()
                    if showsDragPreview, beginPagePreview(in: view) == nil { cancelPageDrag(); return }
                }
                if let overlay = pageDragView { position(overlay, in: view, direction: direction, offset: offset) }
            case .ended, .cancelled, .failed:
                panLayoutGeneration = nil
                let speed = max(0, pan.velocity(in: host).x * CGFloat(-direction))
                let projectedDistance = abs(offset) + 0.12 * speed
                let commit = pan.state == .ended && abs(offset) >= 16 && projectedDistance >= min(width * 0.24, 96)
                guard trackingPagePan else {
                    // A short flick can finish before UIKit delivers another changed sample.
                    if commit && horizontalIntent { turnPage(direction, swipe: true) }
                    return
                }
                trackingPagePan = false
                guard let overlay = pageDragView else {
                    if commit { commitPageTurn(direction, in: view) }
                    return
                }
                position(overlay, in: view, direction: direction, offset: offset)
                settle(overlay, in: view, direction: direction, commit: commit, animation: 1, releaseSpeed: speed)
            default: break
            }
        }

        private func beginPagePreview(in view: UITextView) -> ReaderPageDragView? {
            let pages = pages(in: view)
            guard !pages.isEmpty,
                  let image = dragImage(at: pageIndex(in: view, pages: pages), pages: pages, in: view) else { return nil }
            return showPagePreview(image, in: view)
        }

        private func showPagePreview(_ image: UIImage, in view: UITextView) -> ReaderPageDragView? {
            guard let host = view.superview else { return nil }
            let overlay = ReaderPageDragView(frame: view.convert(view.bounds, to: host), image: image)
            overlay.backgroundColor = view.backgroundColor
            host.insertSubview(overlay, aboveSubview: view)
            pageDragView = overlay
            view.layer.mask = CAShapeLayer()
            return overlay
        }

        private func settle(_ overlay: ReaderPageDragView, in view: UITextView, direction: Int,
                            commit: Bool, animation: Int, releaseSpeed: CGFloat = 0) {
            guard overlay.adjacent.image != nil else {
                // Until the neighbor has text, a cross-chapter swipe keeps the current page visible.
                if commit, parent.adjacentPagePreview(direction) != nil { commitPageTurn(direction, in: view) }
                cancelPageDrag()
                return
            }
            let pages = pages(in: view)
            let completion: (Bool) -> Void = { [weak self] finished in
                guard let self, self.pageDragView === overlay else { return }
                if finished && commit { self.commitPageTurn(direction, in: view) }
                self.cancelPageDrag()
            }
            // A new input can take over a turn within this chapter immediately. Chapter
            // transitions still own their preview until the new text is ready.
            if !commit || pages.indices.contains(pageIndex(in: view, pages: pages) + direction) {
                finishSettlingPage = { completion(true) }
            }
            overlay.animateTurn(commit: commit, animation: animation, releaseSpeed: releaseSpeed, completion: completion)
        }

        private func position(_ overlay: ReaderPageDragView, in view: UITextView, direction: Int, offset: CGFloat) {
            if overlay.direction != direction {
                overlay.direction = direction
                let pages = pages(in: view)
                let index = pageIndex(in: view, pages: pages) + direction
                overlay.adjacent.image = dragImage(at: index, pages: pages, in: view)
            }
            overlay.move(to: overlay.adjacent.image == nil ? 0 : offset)
        }

        private func cancelPageDrag() {
            finishSettlingPage = nil
            trackingPagePan = false
            guard let overlay = pageDragView else { return }
            pageDragView = nil
            overlay.removeFromSuperview()
            if let view = textView { updatePageMask(in: view) }
        }

        // Warm only the visible page and its two neighbors between gestures.
        private func prepareDragImages(around index: Int, in view: UITextView) {
            guard previewCenter != index, !cachedPages.isEmpty else { return }
            previewCenter = index
            dragImages = dragImages.filter { abs($0.key - index) <= 1 }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.previewCenter == index, self.showsDragPreview,
                      !self.parent.holdsDisplayedPage, !self.trackingPagePan else { return }
                for target in [index, index + 1, index - 1] {
                    _ = self.dragImage(at: target, pages: self.cachedPages, in: view)
                }
            }
        }

        private func dragImage(at index: Int, pages: [ReaderTextPage], in view: UITextView) -> UIImage? {
            if pages.indices.contains(index) {
                if let cached = dragImages[index] { return cached.image }
                let image = pageImage(pages[index], in: view)
                dragImages[index] = (image, nil, nil)
                return image
            }
            guard let chapter = parent.adjacentPagePreview(index < 0 ? -1 : 1),
                  let body = chapter.text, !body.isEmpty else { return nil }
            if let cached = dragImages[index], cached.title == chapter.title, cached.text == body {
                return cached.image
            }
            guard let image = adjacentChapterImage(title: chapter.title, body: body, lastPage: index < 0, matching: view) else { return nil }
            dragImages[index] = (image, chapter.title, body)
            return image
        }

        private func pageImage(_ page: ReaderTextPage, in view: UITextView) -> UIImage {
            let manager = view.layoutManager
            let glyphs = manager.glyphRange(forCharacterRange: page.characterRange, actualCharacterRange: nil)
            let origin = CGPoint(x: view.textContainerInset.left, y: view.textContainerInset.top - page.offset)
            return UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
                manager.drawBackground(forGlyphRange: glyphs, at: origin)
                manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
        }

        private func adjacentChapterImage(title: String, body: String, lastPage: Bool, matching view: UITextView) -> UIImage? {
            let typography = ReaderTypography(configuration: parent)
            let text = NSMutableAttributedString(string: "")
            if parent.titleMode != 2 {
                text.append(NSAttributedString(string: title.readerText(simplified: parent.simplifiedChinese) + "\n",
                                               attributes: typography.headingAttributes))
            }
            text.append(NSAttributedString(string: body.readerText(simplified: parent.simplifiedChinese),
                                           attributes: typography.bodyAttributes))
            let preview = UITextView(frame: CGRect(origin: .zero, size: view.bounds.size))
            preview.textContainerInset = view.textContainerInset
            preview.textContainer.lineFragmentPadding = view.textContainer.lineFragmentPadding
            preview.attributedText = text
            preview.layoutIfNeeded()
            let pages = ReaderTextPage.layout(in: preview, height: readingViewportHeight(for: view))
            guard let page = lastPage ? pages.last : pages.first else { return nil }
            return pageImage(page, in: preview)
        }

        func turnPage(_ direction: Int, swipe: Bool = false) {
            guard !parent.holdsDisplayedPage, pendingChapterTurn == nil, !trackingPagePan, let view = textView else { return }
            finishSettlingPage?()
            guard pageDragView == nil else { return }
            let pages = pages(in: view)
            let current = pageIndex(in: view, pages: pages)
            let index = current + direction
            let animation = swipe ? 1 : parent.pageAnimation
            guard showsDragPreview, pages.indices.contains(current),
                  let outgoing = dragImage(at: current, pages: pages, in: view) else {
                commitPageTurn(direction, in: view)
                return
            }
            guard pages.indices.contains(index) || animation == 1,
                  let incoming = dragImage(at: index, pages: pages, in: view) else {
                // Keep the outgoing page until the destination chapter has loaded and laid out.
                if parent.adjacentPagePreview(direction) != nil {
                    pendingChapterTurn = (parent.chapterGeneration &+ 1, direction, outgoing, animation)
                }
                commitPageTurn(direction, in: view)
                return
            }
            guard let overlay = showPagePreview(outgoing, in: view) else {
                commitPageTurn(direction, in: view)
                return
            }
            overlay.direction = direction
            overlay.adjacent.image = incoming
            overlay.move(to: 0, covering: animation == 0)
            settle(overlay, in: view, direction: direction, commit: true, animation: animation)
        }

        func animateLoadedChapter(in view: UITextView) {
            guard let turn = pendingChapterTurn else { return }
            pendingChapterTurn = nil
            guard turn.generation == parent.chapterGeneration, showsDragPreview,
                  turn.image.size == view.bounds.size else { return }
            let pages = pages(in: view)
            guard !pages.isEmpty,
                  let incoming = dragImage(at: pageIndex(in: view, pages: pages), pages: pages, in: view),
                  let overlay = showPagePreview(turn.image, in: view) else { return }
            overlay.direction = turn.direction
            overlay.adjacent.image = incoming
            overlay.move(to: 0, covering: turn.animation == 0)
            finishSettlingPage = { [weak self] in self?.cancelPageDrag() }
            overlay.animateTurn(commit: true, animation: turn.animation) { [weak self] _ in
                guard let self, self.pageDragView === overlay else { return }
                self.cancelPageDrag()
            }
        }

        private func commitPageTurn(_ direction: Int, in view: UITextView) {
            if isAutoReading { resetAutoReadForPageChange() }
            let (minimum, maximum) = scrollLimits(for: view)
            if direction < 0, view.contentOffset.y <= minimum + 0.5 {
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
            } else if direction > 0, view.contentOffset.y >= maximum - 0.5 {
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else {
                view.setContentOffset(CGPoint(x: 0, y: nextPageOffset(in: view, direction: direction)), animated: false)
                view.layoutIfNeeded()
            }
        }

        private func resetAutoPage() {
            autoPageProgress = 0
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            autoPageTarget = nil
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            lastTimestamp = 0
        }

        private func prepareAutoPage(in view: UITextView) -> Bool {
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else { return false }
            let target = nextPageOffset(in: view)
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            updatePageMask(in: view)
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in view.layer.render(in: context.cgContext) }
            view.setContentOffset(originalOffset, animated: false)
            updatePageMask(in: view)
            isRenderingAutoPage = false

            let overlay = UIImageView(image: image)
            overlay.isUserInteractionEnabled = false
            overlay.contentMode = .top
            overlay.clipsToBounds = true
            overlay.layer.borderColor = view.tintColor.cgColor
            overlay.layer.borderWidth = 0
            overlay.frame = CGRect(x: 0, y: originalOffset.y, width: view.bounds.width, height: 0)
            view.addSubview(overlay)
            autoPageOverlay = overlay
            autoPageTarget = target
            return true
        }

        private func advancePagedAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            if autoPageOverlay == nil, !prepareAutoPage(in: view) {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let pageHeight = readingViewportHeight(for: view)
            autoPageProgress += pageHeight / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            let revealedHeight = min(autoPageProgress, pageHeight)
            if let overlay = autoPageOverlay {
                overlay.frame = CGRect(
                    x: 0,
                    y: view.contentOffset.y,
                    width: view.bounds.width,
                    height: revealedHeight
                )
                overlay.layer.borderWidth = revealedHeight > 0 ? 0.5 : 0
            }
            guard autoPageProgress >= pageHeight, let target = autoPageTarget else { return }
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            autoPageTarget = nil
            autoPageProgress = 0
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func advanceEInkAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            eInkElapsed += elapsed
            guard eInkElapsed >= eInkPageInterval else { return }
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let target = nextPageOffset(in: view)
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard isAutoReading, !isAutoReadPaused, !isUserDragging, !trackingPagePan, pageDragView == nil, let view = textView else {
                lastTimestamp = link.timestamp
                return
            }
            guard lastTimestamp > 0 else {
                lastTimestamp = link.timestamp
                return
            }
            let elapsed = link.timestamp - lastTimestamp
            lastTimestamp = link.timestamp
            if parent.isEInkMode {
                advanceEInkAutoRead(in: view, elapsed: elapsed)
                return
            }
            if parent.pageAnimation != 3 {
                advancePagedAutoRead(in: view, elapsed: elapsed)
                return
            }
            let maximum = scrollLimits(for: view).maximum
            let next = view.contentOffset.y
                + readingViewportHeight(for: view) / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            if next >= maximum - 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else {
                didReachEnd = false
                view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
        }
    }
}
