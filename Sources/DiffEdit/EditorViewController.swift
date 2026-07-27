import AppKit
import Foundation

final class EditorViewController: NSViewController, NSTextViewDelegate {
    var onBufferedChangesChanged: ((Set<String>) -> Void)?

    private let stack = NSStackView()
    private let committedRow = NSStackView()
    private let mainRow = NSStackView()
    private let committedScroll = NSScrollView()
    private let committedTextView = LineHighlightTextView()
    private var committedGutter: LineNumberGutterView?
    private let divider = NSBox()
    private let mainScroll = NSScrollView()
    private let textView = LineHighlightTextView()
    private var mainGutter: LineNumberGutterView?
    private let changeOverview = ChangeOverviewView()
    private let statusLabel = NSTextField(labelWithString: "Open a folder to begin.")
    private var currentFileURL: URL?
    private var currentRelativePath: String?
    private var onSaved: (() -> Void)?
    private var buffersByPath: [String: EditorBuffer] = [:]
    private var lastReportedBufferedChanges = Set<String>()
    private var baseText = ""
    private var pendingDiffWorkItem: DispatchWorkItem?
    private var pendingLineStructureChange = false
    private var fontSize: CGFloat = 13
    private var wordWrap = true
    private var lastDiff = DiffResult.empty
    private var isApplyingHighlights = false
    private var committedVisibleBaseLines: [Int?] = []
    private let editorContentMargin: CGFloat = 24

    override func loadView() {
        view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        view.addSubview(stack)

        committedRow.orientation = .horizontal
        committedRow.spacing = 0
        committedRow.translatesAutoresizingMaskIntoConstraints = false
        mainRow.orientation = .horizontal
        mainRow.spacing = 0
        mainRow.translatesAutoresizingMaskIntoConstraints = false

        committedScroll.hasVerticalScroller = false
        committedScroll.borderType = .noBorder
        committedScroll.drawsBackground = true
        committedScroll.backgroundColor = .windowBackgroundColor
        committedTextView.isEditable = false
        committedTextView.isSelectable = true
        committedTextView.drawsBackground = false
        committedTextView.lineNumberProvider = { [weak self] line in
            guard let value = self?.committedVisibleBaseLines[safe: line], let baseLine = value else { return nil }
            return "\(baseLine + 1)"
        }
        committedTextView.textContainerInset = NSSize(width: editorContentMargin, height: 6)
        committedTextView.textContainer?.lineFragmentPadding = 0
        committedTextView.font = editorFont()
        committedTextView.insertionPointColor = DiffPalette.insertionPoint
        committedTextView.frame = NSRect(origin: .zero, size: NSSize(width: 600, height: 106))
        committedTextView.autoresizingMask = [.width]
        committedTextView.textContainer?.widthTracksTextView = true
        committedTextView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        committedScroll.documentView = committedTextView
        let committedGutter = LineNumberGutterView(textView: committedTextView, scrollView: committedScroll)
        self.committedGutter = committedGutter
        committedRow.addArrangedSubview(committedGutter)
        committedRow.addArrangedSubview(committedScroll)

        mainScroll.hasVerticalScroller = false
        mainScroll.autohidesScrollers = false
        mainScroll.hasHorizontalScroller = false
        mainScroll.borderType = .noBorder
        mainScroll.drawsBackground = true
        mainScroll.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.drawsBackground = false
        textView.shortcutHandler = { [weak self] shortcut in
            self?.jumpToChange(shortcut)
        }
        textView.contextMenuProvider = { [weak self] index in
            self?.contextMenu(at: index)
        }
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.delegate = self
        textView.textContainerInset = NSSize(width: editorContentMargin, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = editorFont()
        textView.insertionPointColor = DiffPalette.insertionPoint
        textView.frame = NSRect(origin: .zero, size: NSSize(width: 800, height: 600))
        mainScroll.documentView = textView
        let mainGutter = LineNumberGutterView(textView: textView, scrollView: mainScroll)
        self.mainGutter = mainGutter
        mainRow.addArrangedSubview(mainGutter)
        mainRow.addArrangedSubview(mainScroll)
        changeOverview.translatesAutoresizingMaskIntoConstraints = false
        changeOverview.scrollView = mainScroll
        mainRow.addArrangedSubview(changeOverview)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.controlSize = .small
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.backgroundColor = .windowBackgroundColor
        statusLabel.drawsBackground = true
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.contentView?.wantsLayer = true
        divider.contentView?.layer?.backgroundColor = DiffPalette.divider.cgColor

        stack.addArrangedSubview(committedRow)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(mainRow)
        stack.addArrangedSubview(statusLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            committedRow.heightAnchor.constraint(equalToConstant: 106),
            committedGutter.widthAnchor.constraint(equalToConstant: 46),
            mainGutter.widthAnchor.constraint(equalToConstant: 46),
            changeOverview.widthAnchor.constraint(equalToConstant: 14),
            divider.heightAnchor.constraint(equalToConstant: 2),
            statusLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: mainScroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: committedScroll.contentView)
        applyWrapping()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyWrapping()
        mainScroll.contentView.scroll(to: NSPoint(x: 0, y: mainScroll.contentView.bounds.origin.y))
        mainScroll.reflectScrolledClipView(mainScroll.contentView)
    }

    func showPlaceholder(_ message: String) {
        pendingDiffWorkItem?.cancel()
        buffersByPath.removeAll()
        currentFileURL = nil
        currentRelativePath = nil
        baseText = ""
        textView.string = ""
        committedTextView.string = ""
        textView.fullLineHighlightedLines = []
        committedTextView.fullLineHighlightedLines = []
        textView.deletionMarkers = []
        committedTextView.deletionMarkers = []
        committedTextView.caretMarker = nil
        committedVisibleBaseLines = []
        statusLabel.stringValue = message
        reportBufferedChanges()
    }

    func open(file url: URL, relativePath: String, repository: Repository, onSaved: @escaping () -> Void) throws {
        persistCurrentBuffer()
        pendingDiffWorkItem?.cancel()
        self.onSaved = onSaved

        let buffer: EditorBuffer
        if let existing = buffersByPath[relativePath] {
            buffer = existing
        } else {
            let workingText = try String(contentsOf: url, encoding: .utf8)
            let committedText = repository.committedText(relativePath: relativePath) ?? ""
            let newBuffer = EditorBuffer(
                url: url,
                relativePath: relativePath,
                baseText: committedText,
                text: workingText,
                savedText: workingText,
                selection: NSRange(location: 0, length: 0),
                selectionAffinity: .downstream,
                scrollOrigin: .zero
            )
            buffersByPath[relativePath] = newBuffer
            buffer = newBuffer
        }

        activate(buffer)
    }

    private func activate(_ buffer: EditorBuffer) {
        currentFileURL = buffer.url
        currentRelativePath = buffer.relativePath
        baseText = buffer.baseText
        textView.string = buffer.text
        let textLength = (buffer.text as NSString).length
        let selectionLocation = min(buffer.selection.location, textLength)
        let selectionLength = min(buffer.selection.length, textLength - selectionLocation)
        textView.setSelectedRange(
            NSRange(location: selectionLocation, length: selectionLength),
            affinity: buffer.selectionAffinity,
            stillSelecting: false
        )
        mainScroll.contentView.scroll(to: buffer.scrollOrigin)
        mainScroll.reflectScrolledClipView(mainScroll.contentView)
        textView.undoManager?.removeAllActions()
        statusLabel.stringValue = buffer.relativePath
        recomputeHighlights()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.textView)
        }
    }

    func saveCurrentFile() throws {
        persistCurrentBuffer()
        guard let relativePath = currentRelativePath,
              var buffer = buffersByPath[relativePath] else { return }
        try buffer.text.write(to: buffer.url, atomically: true, encoding: .utf8)
        buffer.markSaved()
        buffersByPath[relativePath] = buffer
        statusLabel.stringValue = "Saved \(relativePath)"
        reportBufferedChanges()
        onSaved?()
        recomputeHighlights()
    }

    func saveAllFiles() throws {
        persistCurrentBuffer()
        defer { reportBufferedChanges() }
        for relativePath in bufferedChangePaths.sorted() {
            guard var buffer = buffersByPath[relativePath] else { continue }
            try buffer.text.write(to: buffer.url, atomically: true, encoding: .utf8)
            buffer.markSaved()
            buffersByPath[relativePath] = buffer
        }
        if let currentRelativePath {
            statusLabel.stringValue = "Saved all files"
            if let current = buffersByPath[currentRelativePath] {
                baseText = current.baseText
            }
            recomputeHighlights()
        }
        onSaved?()
    }

    func toggleWordWrap() {
        wordWrap.toggle()
        applyWrapping()
    }

    var hasUnsavedChanges: Bool {
        persistCurrentBuffer()
        return !bufferedChangePaths.isEmpty
    }

    var unsavedFileCount: Int {
        persistCurrentBuffer()
        return bufferedChangePaths.count
    }

    var currentFileName: String? {
        currentFileURL?.lastPathComponent
    }

    func isEditing(relativePath: String) -> Bool {
        currentRelativePath == relativePath
    }

    private var bufferedChangePaths: Set<String> {
        Set(buffersByPath.values.lazy.filter(\.hasUnsavedChanges).map(\.relativePath))
    }

    private func persistCurrentBuffer() {
        guard let currentRelativePath,
              var buffer = buffersByPath[currentRelativePath] else { return }
        buffer.text = textView.string
        buffer.selection = textView.selectedRange()
        buffer.selectionAffinity = textView.selectionAffinity
        buffer.scrollOrigin = mainScroll.contentView.bounds.origin
        buffersByPath[currentRelativePath] = buffer
        reportBufferedChanges()
    }

    private func reportBufferedChanges() {
        let paths = bufferedChangePaths
        guard paths != lastReportedBufferedChanges else { return }
        lastReportedBufferedChanges = paths
        onBufferedChangesChanged?(paths)
    }

    func adjustFontSize(by delta: CGFloat) {
        fontSize = max(9, min(30, fontSize + delta))
        textView.font = editorFont()
        committedTextView.font = editorFont()
        textView.insertionPointColor = DiffPalette.insertionPoint
        recomputeHighlights()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingHighlights else { return }
        let refreshImmediately = pendingLineStructureChange
        pendingLineStructureChange = false
        updateTypingAttributesForSelection()
        persistCurrentBuffer()
        pendingDiffWorkItem?.cancel()
        if refreshImmediately {
            pendingDiffWorkItem = nil
            recomputeHighlights()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.recomputeHighlights()
        }
        pendingDiffWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        pendingLineStructureChange = pendingLineStructureChange || TextEditClassifier.changesLineStructure(
            original: textView.string,
            range: affectedCharRange,
            replacement: replacementString ?? ""
        )
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateTypingAttributesForSelection()
        updateCommittedContext()
    }

    func jumpParagraph(up: Bool) {
        let target = paragraphBoundary(up: up)
        textView.setSelectedRange(NSRange(location: target, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        updateCommittedContext()
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        if notification.object as AnyObject? === mainScroll.contentView {
            mainGutter?.needsDisplay = true
            changeOverview.needsDisplay = true
        } else if notification.object as AnyObject? === committedScroll.contentView {
            committedGutter?.needsDisplay = true
        }
    }

    private func editorFont() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private func editorAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.lineBreakMode = .byWordWrapping
        return [
            .font: editorFont(),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func applyWrapping() {
        configureWrapping(for: committedTextView, in: committedScroll, wrap: wordWrap)
        configureWrapping(for: textView, in: mainScroll, wrap: wordWrap)
    }

    private func configureWrapping(for textView: NSTextView, in scrollView: NSScrollView, wrap: Bool) {
        guard let container = textView.textContainer else { return }
        let horizontalInset = textView.textContainerInset.width * 2
        let wrappedWidth = max(1, scrollView.contentSize.width - horizontalInset)
        if wrap {
            scrollView.hasHorizontalScroller = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: wrappedWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(textView.frame.height, scrollView.contentSize.height)))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.hasHorizontalScroller = true
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func recomputeHighlights() {
        let workingText = textView.string
        lastDiff = DiffEngine.diff(base: baseText, current: workingText)
        applyHighlights(to: workingText)
        updateCommittedContext()
    }

    private func applyHighlights(to string: String) {
        isApplyingHighlights = true
        let selection = TextSelectionSnapshot(textView: textView)
        let scrollOrigin = mainScroll.contentView.bounds.origin
        let attributed = NSMutableAttributedString(
            string: string,
            attributes: editorAttributes()
        )
        textView.fullLineHighlightedLines = lastDiff.currentTouchedLines
        textView.deletionMarkers = lastDiff.currentDeletionMarkers
        for range in lastDiff.insertedWordRanges {
            if NSMaxRange(range) <= attributed.length {
                attributed.addAttribute(.backgroundColor, value: DiffPalette.insertedText, range: range)
            }
        }
        textView.undoManager?.disableUndoRegistration()
        textView.textStorage?.setAttributedString(attributed)
        textView.font = editorFont()
        selection.restore(to: textView)
        updateTypingAttributesForSelection()
        textView.undoManager?.enableUndoRegistration()
        updateChangeOverview()
        mainGutter?.needsDisplay = true
        mainScroll.contentView.scroll(to: scrollOrigin)
        mainScroll.reflectScrolledClipView(mainScroll.contentView)
        isApplyingHighlights = false
    }

    private func updateTypingAttributesForSelection() {
        var attributes = editorAttributes()
        if let backgroundColor = inheritedTypingBackgroundColor() {
            attributes[.backgroundColor] = backgroundColor
        }
        textView.typingAttributes = attributes
    }

    private func inheritedTypingBackgroundColor() -> NSColor? {
        guard let textStorage = textView.textStorage else { return nil }
        return TypingBackgroundResolver.backgroundColor(
            in: textStorage,
            selection: textView.selectedRange(),
            changedLines: lastDiff.currentTouchedLines,
            insertedColor: DiffPalette.insertedText
        )
    }

    private func updateChangeOverview() {
        changeOverview.editedFractions = fractionsForDocumentLines(lastDiff.currentTouchedLines)
        changeOverview.deletionFractions = fractionsForDocumentLines(Set(lastDiff.currentDeletionMarkers.map(\.line)))
    }

    private func fractionsForDocumentLines(_ lines: Set<Int>) -> [CGFloat] {
        guard !lines.isEmpty,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let nsString = textView.string as NSString
        let used = layoutManager.usedRect(for: textContainer)
        let contentHeight = max(1, used.height)
        return lines.compactMap { line in
            let characterRange = nsString.lineRange(forLineIndex: line)
            guard characterRange.location != NSNotFound else { return nil }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            if glyphRange.length > 0 {
                let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                return min(1, max(0, rect.midY / contentHeight))
            }
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            return min(1, max(0, CGFloat(line) * lineHeight / contentHeight))
        }
    }

    private func updateCommittedContext() {
        let currentLine = (textView.string as NSString).lineIndex(containing: textView.selectedRange().location)
        let mappedBaseLine = lastDiff.currentToBaseLine[currentLine] ?? currentLine
        let baseLines = baseText.splitKeepingEmptyLines()
        var context = ""
        var contextBaseLines: [Int?] = []
        let visibleBaseLines = (mappedBaseLine - 2)...(mappedBaseLine + 2)
        for (offset, index) in visibleBaseLines.enumerated() {
            if index >= 0 && index < baseLines.count {
                contextBaseLines.append(index)
                context += baseLines[index].trimmedTrailingNewline()
            } else {
                contextBaseLines.append(nil)
            }
            if offset < 4 {
                context += "\n"
            }
        }
        committedVisibleBaseLines = contextBaseLines
        let currentLineStart = (textView.string as NSString).lineStartOffset(forLineIndex: currentLine)
        let currentColumn = max(0, textView.selectedRange().location - currentLineStart)
        if let visibleLine = contextBaseLines.firstIndex(where: { $0 == mappedBaseLine }) {
            let baseLineLength = baseLines[safe: mappedBaseLine].map { ($0.trimmedTrailingNewline() as NSString).length } ?? 0
            let mappedColumn = mappedBaseColumn(currentLine: currentLine, currentColumn: currentColumn, defaultColumn: currentColumn)
            committedTextView.caretMarker = CaretMarker(line: visibleLine, column: min(mappedColumn, baseLineLength))
        } else {
            committedTextView.caretMarker = nil
        }
        let attributed = NSMutableAttributedString(
            string: context,
            attributes: editorAttributes()
        )
        let nsContext = context as NSString
        committedTextView.fullLineHighlightedLines = Set(contextBaseLines.enumerated().compactMap { visibleLine, baseLine in
            guard let baseLine else { return nil }
            return lastDiff.baseTouchedLines.contains(baseLine) ? visibleLine : nil
        })
        for deletion in lastDiff.deletedWordRanges {
            guard let visibleLine = contextBaseLines.firstIndex(where: { $0 == deletion.line }) else { continue }
            let lineStart = nsContext.lineStartOffset(forLineIndex: visibleLine)
            let range = NSRange(location: lineStart + deletion.range.location, length: deletion.range.length)
            if NSMaxRange(range) <= attributed.length {
                attributed.addAttribute(.backgroundColor, value: DiffPalette.deletedText, range: range)
            }
        }
        committedTextView.textStorage?.setAttributedString(attributed)
        committedGutter?.needsDisplay = true
        if let visibleLine = contextBaseLines.firstIndex(where: { $0 == mappedBaseLine }) {
            DispatchQueue.main.async { [weak self] in
                self?.centerCommittedVisibleLine(visibleLine)
            }
        }
    }

    private func contextMenu(at characterIndex: Int) -> NSMenu? {
        guard let action = lastDiff.revertActions.first(where: { NSLocationInRange(characterIndex, $0.currentRange) }) else { return nil }
        let menu = NSMenu()
        let title = action.replacement.isEmpty ? "Discard" : "Restore Previous"
        let item = NSMenuItem(title: title, action: #selector(applyRevertAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        menu.addItem(item)
        return menu
    }

    @objc private func applyRevertAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RevertAction else { return }
        let oldString = textView.string as NSString
        guard NSMaxRange(action.currentRange) <= oldString.length else { return }
        let replacement = NSAttributedString(string: action.replacement, attributes: editorAttributes())
        textView.shouldChangeText(in: action.currentRange, replacementString: action.replacement)
        textView.textStorage?.replaceCharacters(in: action.currentRange, with: replacement)
        textView.didChangeText()
    }

    private func paragraphBoundary(up: Bool) -> Int {
        let lines = textView.string.splitKeepingEmptyLines()
        let nsString = textView.string as NSString
        let currentLine = nsString.lineIndex(containing: textView.selectedRange().location)
        if up {
            var line = currentLine
            if nsString.lineStartOffset(forLineIndex: currentLine) == textView.selectedRange().location {
                line -= 1
            }
            while line > 0 && lines[safe: line]?.trimmedTrailingNewline().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                line -= 1
            }
            while line > 0 && lines[safe: line - 1]?.trimmedTrailingNewline().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                line -= 1
            }
            return nsString.lineStartOffset(forLineIndex: max(0, line))
        } else {
            var line = currentLine
            while line < lines.count && lines[safe: line]?.trimmedTrailingNewline().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                line += 1
            }
            while line < lines.count && lines[safe: line]?.trimmedTrailingNewline().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                line += 1
            }
            return nsString.lineStartOffset(forLineIndex: min(line, max(0, lines.count - 1)))
        }
    }

    private func mappedBaseColumn(currentLine: Int, currentColumn: Int, defaultColumn: Int) -> Int {
        if currentColumn == 0 { return 0 }
        if let exact = lastDiff.currentToBaseColumn[LineColumn(line: currentLine, column: currentColumn)] {
            return exact
        }
        var best: (distance: Int, currentColumn: Int, baseColumn: Int)?
        for (key, baseColumn) in lastDiff.currentToBaseColumn where key.line == currentLine {
            let distance = abs(key.column - currentColumn)
            if best == nil || distance < best!.distance || (distance == best!.distance && key.column < currentColumn) {
                best = (distance, key.column, baseColumn)
            }
        }
        guard let best else { return defaultColumn }
        return max(0, best.baseColumn + (currentColumn - best.currentColumn))
    }

    private func centerCommittedVisibleLine(_ line: Int) {
        guard let layoutManager = committedTextView.layoutManager,
              let textContainer = committedTextView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let nsString = committedTextView.string as NSString
        let range = nsString.lineRange(forLineIndex: line)
        guard range.location != NSNotFound else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphRange.location, length: 1), in: textContainer)
        rect.origin.y += committedTextView.textContainerOrigin.y
        let viewport = committedScroll.contentView.bounds
        let targetY = max(0, rect.midY - viewport.height / 2)
        committedScroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        committedScroll.reflectScrolledClipView(committedScroll.contentView)
    }

    private func jumpToChange(_ shortcut: EditorShortcut) {
        let changedLines = lastDiff.currentTouchedLines.sorted()
        guard !changedLines.isEmpty else { return }
        let currentLine = (textView.string as NSString).lineIndex(containing: textView.selectedRange().location)
        let targetLine: Int
        switch shortcut {
        case .nextChangedLine:
            targetLine = changedLines.first(where: { $0 > currentLine }) ?? changedLines[0]
        case .previousChangedLine:
            targetLine = changedLines.reversed().first(where: { $0 < currentLine }) ?? changedLines[changedLines.count - 1]
        case .nextChangedGroup:
            let groups = changedLineGroups(changedLines)
            targetLine = groups.first(where: { $0.lowerBound > currentLine })?.lowerBound ?? groups[0].lowerBound
        case .previousChangedGroup:
            let groups = changedLineGroups(changedLines)
            targetLine = groups.reversed().first(where: { $0.upperBound < currentLine })?.lowerBound ?? groups[groups.count - 1].lowerBound
        case .previousParagraph:
            jumpParagraph(up: true)
            return
        case .nextParagraph:
            jumpParagraph(up: false)
            return
        }
        selectLine(targetLine)
    }

    private func changedLineGroups(_ lines: [Int]) -> [ClosedRange<Int>] {
        guard let first = lines.first else { return [] }
        var groups: [ClosedRange<Int>] = []
        var start = first
        var previous = first
        for line in lines.dropFirst() {
            if line == previous + 1 {
                previous = line
            } else {
                groups.append(start...previous)
                start = line
                previous = line
            }
        }
        groups.append(start...previous)
        return groups
    }

    private func selectLine(_ line: Int) {
        let nsString = textView.string as NSString
        let lineStart = nsString.lineStartOffset(forLineIndex: line)
        textView.setSelectedRange(NSRange(location: min(lineStart, nsString.length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        updateCommittedContext()
    }
}

struct TextSelectionSnapshot {
    let ranges: [NSValue]
    let affinity: NSSelectionAffinity

    init(textView: NSTextView) {
        ranges = textView.selectedRanges
        affinity = textView.selectionAffinity
    }

    func restore(to textView: NSTextView) {
        if ranges.count == 1, let range = ranges.first?.rangeValue {
            textView.setSelectedRange(range, affinity: affinity, stillSelecting: false)
        } else {
            textView.selectedRanges = ranges
        }
    }
}

enum TextEditClassifier {
    static func changesLineStructure(original: String, range: NSRange, replacement: String) -> Bool {
        if replacement.rangeOfCharacter(from: .newlines) != nil {
            return true
        }
        let nsOriginal = original as NSString
        guard range.location >= 0, NSMaxRange(range) <= nsOriginal.length else {
            return false
        }
        return nsOriginal.substring(with: range).rangeOfCharacter(from: .newlines) != nil
    }
}

enum TypingBackgroundResolver {
    static func backgroundColor(
        in attributedString: NSAttributedString,
        selection: NSRange,
        changedLines: Set<Int>,
        insertedColor: NSColor
    ) -> NSColor? {
        let location = max(0, min(selection.location, attributedString.length))

        func backgroundColor(at index: Int) -> (isText: Bool, color: NSColor?) {
            guard index >= 0, index < attributedString.length else { return (false, nil) }
            let character = (attributedString.string as NSString).substring(with: NSRange(location: index, length: 1))
            guard character.rangeOfCharacter(from: .newlines) == nil else { return (false, nil) }
            return (true, attributedString.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor)
        }

        // Replacing a selection should retain the selection's highlight. For a
        // caret, AppKit conventionally inherits from the character to its left,
        // then from the right at the beginning of a line.
        if selection.length > 0 {
            let selected = backgroundColor(at: location)
            if selected.isText {
                return selected.color
            }
        }
        let previous = backgroundColor(at: location - 1)
        if previous.isText {
            return previous.color
        }
        let next = backgroundColor(at: location)
        if next.isText {
            return next.color
        }

        // An empty newly-added line has no attributed neighbor to inherit from,
        // but text entered there is still an insertion.
        let line = (attributedString.string as NSString).lineIndex(containing: location)
        return changedLines.contains(line) ? insertedColor : nil
    }
}
