import AppKit
import Foundation

final class LineHighlightTextView: NSTextView {
    var lineNumberProvider: ((Int) -> String?)?
    var shortcutHandler: ((EditorShortcut) -> Void)?
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var clipboardWriter: ((String) -> Void)?
    var caretMarker: CaretMarker? {
        didSet {
            needsDisplay = true
        }
    }
    var deletionMarkers: [DeletionMarker] = [] {
        didSet {
            needsDisplay = true
        }
    }
    var fullLineHighlightedLines = Set<Int>() {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawFullLineHighlights(in: dirtyRect)
        super.draw(dirtyRect)
        drawDeletionMarkers(in: dirtyRect)
        drawCaretMarker(in: dirtyRect)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option), !flags.contains(.command), !flags.contains(.control) {
            if event.keyCode == 126 {
                shortcutHandler?(.previousParagraph)
                return
            }
            if event.keyCode == 125 {
                shortcutHandler?(.nextParagraph)
                return
            }
        }
        guard flags.contains(.control),
              !flags.contains(.command),
              let characters = event.charactersIgnoringModifiers else {
            super.keyDown(with: event)
            return
        }
        let byLine = flags.contains(.shift)
        if characters == "." {
            shortcutHandler?(byLine ? .nextChangedLine : .nextChangedGroup)
            return
        }
        if characters == "," {
            shortcutHandler?(byLine ? .previousChangedLine : .previousChangedGroup)
            return
        }
        super.keyDown(with: event)
    }

    override func copy(_ sender: Any?) {
        if selectedRange().length == 0 {
            writeToClipboard(currentLineText(includeNewline: true))
        } else {
            super.copy(sender)
        }
    }

    override func cut(_ sender: Any?) {
        if selectedRange().length == 0 {
            let range = currentLineRangeIncludingNewline()
            let line = (string as NSString).substring(with: range)
            writeToClipboard(line)
            if shouldChangeText(in: range, replacementString: "") {
                textStorage?.replaceCharacters(in: range, with: "")
                didChangeText()
            }
        } else {
            super.cut(sender)
        }
    }

    private func writeToClipboard(_ string: String) {
        if let clipboardWriter {
            clipboardWriter(string)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard let layoutManager, let textContainer else { return super.menu(for: event) }
        guard layoutManager.numberOfGlyphs > 0 else { return super.menu(for: event) }
        var point = localPoint
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: max(0, min(glyphIndex, max(0, layoutManager.numberOfGlyphs - 1))))
        return contextMenuProvider?(characterIndex) ?? super.menu(for: event)
    }

    private func currentLineRangeIncludingNewline() -> NSRange {
        let nsString = string as NSString
        if nsString.length == 0 { return NSRange(location: 0, length: 0) }
        return nsString.lineRange(for: NSRange(location: min(selectedRange().location, max(0, nsString.length - 1)), length: 0))
    }

    private func currentLineText(includeNewline: Bool) -> String {
        let range = currentLineRangeIncludingNewline()
        let text = (string as NSString).substring(with: range)
        return includeNewline ? text : text.trimmingCharacters(in: .newlines)
    }

    private func drawFullLineHighlights(in dirtyRect: NSRect) {
        guard !fullLineHighlightedLines.isEmpty,
              let layoutManager,
              let textContainer else { return }
        let nsString = string as NSString
        let textOrigin = textContainerOrigin
        let visibleBounds = enclosingScrollView?.contentView.bounds ?? visibleRect
        let color = DiffPalette.changedLine
        color.setFill()

        for line in fullLineHighlightedLines {
            let characterRange = nsString.lineRange(forLineIndex: line)
            guard characterRange.location != NSNotFound else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            var lineRect: NSRect
            if glyphRange.length > 0 {
                lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            } else {
                let lineHeight = layoutManager.defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
                let y = CGFloat(line) * lineHeight
                lineRect = NSRect(x: visibleBounds.minX, y: y, width: visibleBounds.width, height: lineHeight)
            }
            lineRect.origin.x = visibleBounds.minX
            lineRect.origin.y += textOrigin.y
            lineRect.size.width = visibleBounds.width
            lineRect = lineRect.integral
            if lineRect.intersects(dirtyRect) {
                lineRect.fill()
            }
        }
    }

    private func drawDeletionMarkers(in dirtyRect: NSRect) {
        guard !deletionMarkers.isEmpty,
              let layoutManager,
              let textContainer else { return }
        let nsString = string as NSString
        let textOrigin = textContainerOrigin
        let visibleBounds = enclosingScrollView?.contentView.bounds ?? visibleRect
        DiffPalette.deletionMarker.setFill()
        for marker in deletionMarkers {
            if marker.kind != .inline {
                guard let boundaryY = deletionBoundaryY(
                    for: marker,
                    textOrigin: textOrigin,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                ) else { continue }
                let markerRect = NSRect(
                    x: visibleBounds.minX,
                    y: boundaryY - 1,
                    width: visibleBounds.width,
                    height: 2
                ).integral
                if markerRect.intersects(dirtyRect) {
                    markerRect.fill()
                }
                continue
            }
            let lineRange = nsString.lineRange(forLineIndex: marker.line)
            guard lineRange.location != NSNotFound else { continue }
            let clampedColumn = max(0, min(marker.column, lineRange.length))
            let characterLocation = min(lineRange.location + clampedColumn, nsString.length)
            guard var markerRect = markerRect(characterLocation: characterLocation, textOrigin: textOrigin, layoutManager: layoutManager, textContainer: textContainer) else { continue }
            markerRect.origin.x -= 1
            markerRect.size.width = 3
            if markerRect.intersects(dirtyRect) {
                markerRect.fill()
            }
        }
    }

    private func deletionBoundaryY(
        for marker: DeletionMarker,
        textOrigin: NSPoint,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> CGFloat? {
        guard marker.kind != .inline else { return nil }
        let nsString = string as NSString
        if nsString.length == 0 {
            return textOrigin.y
        }
        let lineRange = nsString.lineRange(forLineIndex: marker.line)
        guard lineRange.location != NSNotFound else {
            let usedRect = layoutManager.usedRect(for: textContainer)
            return textOrigin.y + usedRect.maxY
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            let usedRect = layoutManager.usedRect(for: textContainer)
            return marker.kind == .lineBoundaryBefore
                ? textOrigin.y + usedRect.minY
                : textOrigin.y + usedRect.maxY
        }
        let glyphIndex = marker.kind == .lineBoundaryBefore
            ? glyphRange.location
            : NSMaxRange(glyphRange) - 1
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return textOrigin.y + (marker.kind == .lineBoundaryBefore ? fragment.minY : fragment.maxY)
    }

    private func drawCaretMarker(in dirtyRect: NSRect) {
        guard let caretMarker,
              let layoutManager,
              let textContainer else { return }
        let nsString = string as NSString
        let lineRange = nsString.lineRange(forLineIndex: caretMarker.line)
        guard lineRange.location != NSNotFound else { return }
        let column = max(0, min(caretMarker.column, lineRange.length))
        let characterLocation = min(lineRange.location + column, nsString.length)
        let textOrigin = textContainerOrigin
        guard let rect = markerRect(characterLocation: characterLocation, textOrigin: textOrigin, layoutManager: layoutManager, textContainer: textContainer) else { return }
        let triangleWidth: CGFloat = 7
        let triangleHeight: CGFloat = 5
        let midX = rect.midX
        let y = rect.maxY - 1
        let triangleRect = NSRect(x: midX - triangleWidth / 2, y: y - triangleHeight, width: triangleWidth, height: triangleHeight)
        guard triangleRect.intersects(dirtyRect.insetBy(dx: -8, dy: -8)) else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: midX, y: y - triangleHeight))
        path.line(to: NSPoint(x: midX - triangleWidth / 2, y: y))
        path.line(to: NSPoint(x: midX + triangleWidth / 2, y: y))
        path.close()
        DiffPalette.caretMarker.setFill()
        path.fill()
    }

    private func markerRect(characterLocation: Int, textOrigin: NSPoint, layoutManager: NSLayoutManager, textContainer: NSTextContainer) -> NSRect? {
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let nsString = string as NSString
        let clampedLocation = max(0, min(characterLocation, nsString.length))
        if clampedLocation < nsString.length,
           nsString.substring(with: NSRange(location: clampedLocation, length: 1)).rangeOfCharacter(from: .newlines) != nil {
            let glyphIndex = max(0, min(layoutManager.glyphIndexForCharacter(at: clampedLocation), layoutManager.numberOfGlyphs - 1))
            var effectiveRange = NSRange(location: 0, length: 0)
            var lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
            lineRect.origin.y += textOrigin.y
            return NSRect(x: textOrigin.x + lineRect.minX, y: lineRect.minY, width: 1, height: max(1, lineRect.height))
        }
        let glyphIndex: Int
        let atLineEnd = clampedLocation >= nsString.length || nsString.substring(with: NSRange(location: max(0, min(clampedLocation, max(0, nsString.length - 1))), length: min(1, nsString.length))).rangeOfCharacter(from: .newlines) != nil
        if atLineEnd {
            glyphIndex = max(0, min(layoutManager.glyphIndexForCharacter(at: max(0, clampedLocation - 1)), layoutManager.numberOfGlyphs - 1))
        } else {
            glyphIndex = max(0, min(layoutManager.glyphIndexForCharacter(at: clampedLocation), layoutManager.numberOfGlyphs - 1))
        }
        var effectiveRange = NSRange(location: 0, length: 0)
        var lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
        lineRect.origin.y += textOrigin.y
        let x: CGFloat
        if atLineEnd {
            x = textOrigin.x + lineRect.maxX
        } else {
            x = textOrigin.x + layoutManager.location(forGlyphAt: glyphIndex).x
        }
        return NSRect(x: x, y: lineRect.minY, width: 1, height: max(1, lineRect.height))
    }
}

final class LineNumberGutterView: NSView {
    private weak var textView: LineHighlightTextView?
    private weak var scrollView: NSScrollView?
    var width: CGFloat = 46

    init(textView: LineHighlightTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: NSRect(x: 0, y: 0, width: 46, height: 100))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        postsFrameChangedNotifications = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width, height: NSView.noIntrinsicMetric)
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        (scrollView.backgroundColor).setFill()
        bounds.fill()
        layoutManager.ensureLayout(for: textContainer)
        let nsString = textView.string as NSString
        let textOrigin = textView.textContainerOrigin
        let visibleRect = scrollView.contentView.bounds
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView.font?.pointSize ?? 13) - 2), weight: .regular),
            .foregroundColor: DiffPalette.lineNumber
        ]
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y), in: textContainer)
        var drawnLogicalLines = Set<Int>()
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            guard fragmentGlyphRange.length > 0 else { return }
            let characterIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            let line = nsString.lineIndex(containing: characterIndex)
            guard !drawnLogicalLines.contains(line) else { return }
            let logicalLineRange = nsString.lineRange(forLineIndex: line)
            guard logicalLineRange.location != NSNotFound else { return }
            let firstGlyphInLogicalLine = layoutManager.glyphRange(forCharacterRange: logicalLineRange, actualCharacterRange: nil).location
            guard fragmentGlyphRange.location == firstGlyphInLogicalLine else { return }
            drawnLogicalLines.insert(line)
            let displayNumber: String
            if let provided = textView.lineNumberProvider?(line) {
                displayNumber = provided
            } else if textView.lineNumberProvider == nil {
                displayNumber = "\(line + 1)"
            } else {
                return
            }
            let label = displayNumber as NSString
            let size = label.size(withAttributes: attributes)
            let y = usedRect.minY + textOrigin.y - visibleRect.minY
            let labelRect = NSRect(
                x: self.bounds.width - size.width - 8,
                y: y + max(0, (usedRect.height - size.height) / 2),
                width: size.width,
                height: size.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
        }
        if textView.string.hasSuffix("\n") {
            let line = nsString.lineCount
            let displayNumber: String
            if let provided = textView.lineNumberProvider?(line) {
                displayNumber = provided
            } else if textView.lineNumberProvider == nil {
                displayNumber = "\(line + 1)"
            } else {
                return
            }
            let used = layoutManager.usedRect(for: textContainer)
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            let y = max(0, used.maxY - lineHeight) + textOrigin.y - visibleRect.minY
            guard y >= dirtyRect.minY - 40, y <= dirtyRect.maxY + 40 else { return }
            let label = displayNumber as NSString
            let size = label.size(withAttributes: attributes)
            let labelRect = NSRect(x: bounds.width - size.width - 8, y: y, width: size.width, height: size.height)
            label.draw(in: labelRect, withAttributes: attributes)
        } else if textView.string.isEmpty {
            let line = 0
            let displayNumber: String
            if let provided = textView.lineNumberProvider?(line) {
                displayNumber = provided
            } else if textView.lineNumberProvider == nil {
                displayNumber = "1"
            } else {
                return
            }
            let y = textOrigin.y - visibleRect.minY
            let label = displayNumber as NSString
            let size = label.size(withAttributes: attributes)
            let labelRect = NSRect(x: bounds.width - size.width - 8, y: y, width: size.width, height: size.height)
            label.draw(in: labelRect, withAttributes: attributes)
        }
    }

}

final class ChangeOverviewView: NSView {
    var editedFractions: [CGFloat] = [] { didSet { needsDisplay = true } }
    var deletionFractions: [CGFloat] = [] { didSet { needsDisplay = true } }
    weak var scrollView: NSScrollView? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        drawScrollTrack()
        let edited = Set(editedFractions.map { roundedFraction($0) })
        let deleted = Set(deletionFractions.map { roundedFraction($0) })
        for fraction in edited.union(deleted).sorted() {
            let hasEdit = edited.contains(fraction)
            let hasDeletion = deleted.contains(fraction)
            let y = min(bounds.maxY - 2, max(bounds.minY, fraction * bounds.height))
            if hasEdit && hasDeletion {
                DiffPalette.insertedText.withAlphaComponent(0.9).setFill()
                NSRect(x: 0, y: y, width: 4, height: 2).fill()
                DiffPalette.deletionMarker.setFill()
                NSRect(x: 6, y: y, width: 4, height: 2).fill()
            } else if hasDeletion {
                DiffPalette.deletionMarker.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: 2).fill()
            } else {
                DiffPalette.insertedText.withAlphaComponent(0.9).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: 2).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        scroll(to: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        scroll(to: convert(event.locationInWindow, from: nil).y)
    }

    private func drawScrollTrack() {
        let trackRect = bounds.insetBy(dx: 3, dy: 3)
        DiffPalette.divider.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 4, yRadius: 4).fill()
        guard let scrollView,
              let documentView = scrollView.documentView else { return }
        let documentHeight = max(1, documentView.bounds.height)
        let visibleHeight = max(1, scrollView.contentView.bounds.height)
        let maxScroll = max(0, documentHeight - visibleHeight)
        let thumbHeight = max(28, min(trackRect.height, trackRect.height * visibleHeight / documentHeight))
        let scrollY = min(max(0, scrollView.contentView.bounds.origin.y), maxScroll)
        let travel = max(0, trackRect.height - thumbHeight)
        let thumbY = trackRect.minY + (maxScroll == 0 ? 0 : (scrollY / maxScroll) * travel)
        DiffPalette.lineNumber.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: trackRect.minX, y: thumbY, width: trackRect.width, height: thumbHeight), xRadius: 4, yRadius: 4).fill()
    }

    private func scroll(to y: CGFloat) {
        guard let scrollView,
              let documentView = scrollView.documentView else { return }
        let trackRect = bounds.insetBy(dx: 3, dy: 3)
        let documentHeight = max(1, documentView.bounds.height)
        let visibleHeight = max(1, scrollView.contentView.bounds.height)
        let maxScroll = max(0, documentHeight - visibleHeight)
        let thumbHeight = max(28, min(trackRect.height, trackRect.height * visibleHeight / documentHeight))
        let travel = max(1, trackRect.height - thumbHeight)
        let fraction = min(1, max(0, (y - trackRect.minY - thumbHeight / 2) / travel))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: fraction * maxScroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsDisplay = true
    }

    private func roundedFraction(_ fraction: CGFloat) -> CGFloat {
        (min(1, max(0, fraction)) * 1000).rounded() / 1000
    }
}
