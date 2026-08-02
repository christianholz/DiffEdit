import AppKit
import Foundation

private struct StageSelection {
    var available: Set<StagingChangeID>
    var selected: Set<StagingChangeID>
}

private struct ForegroundEditorState {
    let line: Int
    let column: Int
    let selectionLength: Int
    let affinity: NSSelectionAffinity
    let scrollOrigin: CGPoint
}

enum WorkspaceMode: Int {
    case editing
    case staging
}

final class EditorViewController: NSViewController, NSTextViewDelegate {
    var onBufferedChangesChanged: ((Set<String>) -> Void)?
    var onStageSelectionAvailabilityChanged: ((Bool) -> Void)?
    var resolveExternalFileConflict: ((ExternalFileConflict) -> ExternalFileResolution)?

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
    private let stagingDiffView = StagingDiffView()
    private let statusLabel = NSTextField(labelWithString: "Open a folder to begin.")
    private var currentFileURL: URL?
    private var currentRelativePath: String?
    private var onSaved: (() -> Void)?
    private var buffersByPath: [String: EditorBuffer] = [:]
    private var stageSelectionsByPath: [String: StageSelection] = [:]
    private var lastReportedBufferedChanges = Set<String>()
    private var baseText = ""
    private var pendingDiffWorkItem: DispatchWorkItem?
    private var pendingLineStructureChange = false
    private var fontSize: CGFloat = 13
    private var wordWrap = true
    private var lastDiff = DiffResult.empty
    private var isApplyingHighlights = false
    private var committedVisibleBaseLines: [Int?] = []
    private var foregroundEditorState: ForegroundEditorState?
    private let editorContentMargin: CGFloat = 24
    private var mode = WorkspaceMode.editing

    override func loadView() {
        view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        view.addSubview(stack)

        committedRow.orientation = .horizontal
        committedRow.spacing = 0
        committedRow.translatesAutoresizingMaskIntoConstraints = false
        committedRow.wantsLayer = true
        committedRow.layer?.masksToBounds = true
        mainRow.orientation = .horizontal
        mainRow.spacing = 0
        mainRow.translatesAutoresizingMaskIntoConstraints = false
        mainRow.wantsLayer = true
        mainRow.layer?.masksToBounds = true

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
        textView.showsActiveLineHighlight = true
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
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.contentView?.wantsLayer = true
        divider.contentView?.layer?.backgroundColor = DiffPalette.divider.cgColor

        stagingDiffView.isHidden = true
        stagingDiffView.onSetChangeSelection = { [weak self] id, selected in
            self?.setStageSelection(for: id, selected: selected)
        }

        stack.addArrangedSubview(committedRow)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(mainRow)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(stagingDiffView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stagingDiffView.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        stageSelectionsByPath.removeAll()
        currentFileURL = nil
        currentRelativePath = nil
        baseText = ""
        textView.string = ""
        committedTextView.string = ""
        textView.fullLineHighlightedLines = []
        textView.activeLine = nil
        committedTextView.fullLineHighlightedLines = []
        textView.deletionMarkers = []
        committedTextView.deletionMarkers = []
        committedTextView.caretMarker = nil
        committedVisibleBaseLines = []
        statusLabel.stringValue = message
        stagingDiffView.setDocument(filePath: nil, rows: [], selectedChanges: [])
        reportBufferedChanges()
        onStageSelectionAvailabilityChanged?(false)
    }

    @discardableResult
    func open(file url: URL, relativePath: String, repository: Repository, onSaved: @escaping () -> Void) throws -> Bool {
        persistCurrentBuffer()
        pendingDiffWorkItem?.cancel()
        self.onSaved = onSaved

        let buffer: EditorBuffer
        if var existing = buffersByPath[relativePath] {
            let observedModificationDate = try DiskFileReader.modificationDate(at: existing.url)
            if observedModificationDate != existing.knownDiskModificationDate {
                let observedDisk = try DiskFileReader.snapshot(at: existing.url)
                if observedDisk.text == existing.knownDiskText {
                    existing.acknowledgeUnchangedDisk(modificationDate: observedDisk.modificationDate)
                } else if existing.text == existing.knownDiskText, !existing.requiresOverwriteConfirmation {
                    existing.reloadFromDisk(
                        observedDisk.text,
                        modificationDate: observedDisk.modificationDate
                    )
                } else {
                    let conflict = ExternalFileConflict(
                        relativePath: relativePath,
                        operation: .activating,
                        fileWasDeleted: observedDisk.text == nil
                    )
                    switch resolveExternalFileConflict?(conflict) ?? .cancel {
                    case .reloadFromDisk:
                        existing.reloadFromDisk(
                            observedDisk.text,
                            modificationDate: observedDisk.modificationDate
                        )
                    case .keepBuffer:
                        existing.keepBufferAfterExternalChange(
                            observedDisk.text,
                            modificationDate: observedDisk.modificationDate
                        )
                    case .cancel:
                        return false
                    }
                }
                buffersByPath[relativePath] = existing
                reportBufferedChanges()
            }
            existing.baseText = repository.committedText(relativePath: relativePath) ?? ""
            buffersByPath[relativePath] = existing
            buffer = existing
        } else {
            let observedDisk = try DiskFileReader.snapshot(at: url)
            guard let workingText = observedDisk.text else {
                throw CocoaError(.fileNoSuchFile)
            }
            let committedText = repository.committedText(relativePath: relativePath) ?? ""
            let newBuffer = EditorBuffer(
                url: url,
                relativePath: relativePath,
                baseText: committedText,
                text: workingText,
                knownDiskText: workingText,
                knownDiskModificationDate: observedDisk.modificationDate,
                selection: NSRange(location: 0, length: 0),
                selectionAffinity: .downstream,
                scrollOrigin: .zero
            )
            buffersByPath[relativePath] = newBuffer
            buffer = newBuffer
        }

        activate(buffer)
        return true
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
        updateActiveLineHighlight()
        statusLabel.stringValue = buffer.relativePath
        recomputeHighlights()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.stagingDiffView.isHidden else { return }
            self.view.window?.makeFirstResponder(self.textView)
        }
    }

    func saveCurrentFile() throws {
        persistCurrentBuffer()
        guard let relativePath = currentRelativePath,
              var buffer = buffersByPath[relativePath] else { return }
        guard try prepareForSave(&buffer) else {
            buffersByPath[relativePath] = buffer
            activate(buffer)
            statusLabel.stringValue = "Reloaded external changes in \(relativePath)"
            reportBufferedChanges()
            onSaved?()
            return
        }
        guard buffer.hasUnsavedChanges || buffer.requiresOverwriteConfirmation else {
            buffersByPath[relativePath] = buffer
            statusLabel.stringValue = "No changes to save in \(relativePath)"
            reportBufferedChanges()
            return
        }
        try buffer.text.write(to: buffer.url, atomically: true, encoding: .utf8)
        buffer.markSaved(modificationDate: try DiskFileReader.modificationDate(at: buffer.url))
        buffersByPath[relativePath] = buffer
        statusLabel.stringValue = "Saved \(relativePath)"
        reportBufferedChanges()
        onSaved?()
        recomputeHighlights()
    }

    func saveAllFiles() throws {
        persistCurrentBuffer()
        defer { reportBufferedChanges() }
        var reloadedCurrentBuffer = false
        for relativePath in bufferedChangePaths.sorted() {
            guard var buffer = buffersByPath[relativePath] else { continue }
            guard try prepareForSave(&buffer) else {
                buffersByPath[relativePath] = buffer
                reloadedCurrentBuffer = reloadedCurrentBuffer || relativePath == currentRelativePath
                continue
            }
            try buffer.text.write(to: buffer.url, atomically: true, encoding: .utf8)
            buffer.markSaved(modificationDate: try DiskFileReader.modificationDate(at: buffer.url))
            buffersByPath[relativePath] = buffer
        }
        if let currentRelativePath {
            statusLabel.stringValue = "Saved all files"
            if let current = buffersByPath[currentRelativePath] {
                baseText = current.baseText
                if reloadedCurrentBuffer {
                    activate(current)
                    statusLabel.stringValue = "Saved files and reloaded external changes"
                    onSaved?()
                    return
                }
            }
            recomputeHighlights()
        }
        onSaved?()
    }

    func stageSelectedChanges(using repository: Repository) throws {
        persistCurrentBuffer()
        guard let relativePath = currentRelativePath,
              let buffer = buffersByPath[relativePath] else { return }
        let plan = DiffEngine.selectiveStagingPlan(base: buffer.baseText, current: buffer.text)
        let state = updateStageSelection(relativePath: relativePath, selectableChanges: plan.selectableChanges)
        try repository.stage(text: plan.text(selectedChanges: state.selected), relativePath: relativePath)
        statusLabel.stringValue = "Staged selected changes in \(relativePath)"
    }

    var hasStageableChanges: Bool {
        persistCurrentBuffer()
        guard let relativePath = currentRelativePath,
              let buffer = buffersByPath[relativePath] else { return false }
        return !DiffEngine.selectiveStagingPlan(
            base: buffer.baseText,
            current: buffer.text
        ).selectableChanges.isEmpty
    }

    func refreshCommittedBases(using repository: Repository) {
        persistCurrentBuffer()
        for relativePath in buffersByPath.keys {
            guard var buffer = buffersByPath[relativePath] else { continue }
            buffer.baseText = repository.committedText(relativePath: relativePath) ?? ""
            buffersByPath[relativePath] = buffer
        }
        stageSelectionsByPath.removeAll()
        if let currentRelativePath, let buffer = buffersByPath[currentRelativePath] {
            baseText = buffer.baseText
            recomputeHighlights()
        } else {
            onStageSelectionAvailabilityChanged?(false)
        }
    }

    func captureForegroundState() {
        persistCurrentBuffer()
        guard currentRelativePath != nil else {
            foregroundEditorState = nil
            return
        }
        let nsString = textView.string as NSString
        let selection = textView.selectedRange()
        let line = nsString.lineIndex(containing: selection.location)
        let lineStart = nsString.lineStartOffset(forLineIndex: line)
        foregroundEditorState = ForegroundEditorState(
            line: line,
            column: max(0, selection.location - lineStart),
            selectionLength: selection.length,
            affinity: textView.selectionAffinity,
            scrollOrigin: mainScroll.contentView.bounds.origin
        )
    }

    func foregroundFileRefreshRequest() -> ForegroundFileRefreshRequest? {
        persistCurrentBuffer()
        guard let currentRelativePath,
              let buffer = buffersByPath[currentRelativePath] else { return nil }
        return ForegroundFileRefreshRequest(
            relativePath: currentRelativePath,
            url: buffer.url,
            knownDiskModificationDate: buffer.knownDiskModificationDate
        )
    }

    func finishForegroundRefreshWithoutFileChange(_ request: ForegroundFileRefreshRequest?) {
        guard request?.relativePath == currentRelativePath else { return }
        foregroundEditorState = nil
    }

    @discardableResult
    func refreshCurrentFileFromDisk(using repository: Repository) throws -> Bool {
        guard let request = foregroundFileRefreshRequest() else { return false }
        guard let prepared = try PreparedForegroundFileRefresh.load(
            request: request,
            repository: repository
        ) else {
            finishForegroundRefreshWithoutFileChange(request)
            return false
        }
        return apply(prepared)
    }

    @discardableResult
    func apply(_ prepared: PreparedForegroundFileRefresh) -> Bool {
        persistCurrentBuffer()
        let request = prepared.request
        guard request.relativePath == currentRelativePath,
              var buffer = buffersByPath[request.relativePath],
              buffer.knownDiskModificationDate == request.knownDiskModificationDate else {
            return false
        }
        var reloadedText = false
        if prepared.diskText == buffer.knownDiskText {
            buffer.acknowledgeUnchangedDisk(modificationDate: prepared.diskModificationDate)
        } else {
            if buffer.text == buffer.knownDiskText, !buffer.requiresOverwriteConfirmation {
                buffer.reloadFromDisk(
                    prepared.diskText,
                    modificationDate: prepared.diskModificationDate
                )
                reloadedText = true
            } else {
                let conflict = ExternalFileConflict(
                    relativePath: request.relativePath,
                    operation: .activating,
                    fileWasDeleted: prepared.diskText == nil
                )
                switch resolveExternalFileConflict?(conflict) ?? .cancel {
                case .reloadFromDisk:
                    buffer.reloadFromDisk(
                        prepared.diskText,
                        modificationDate: prepared.diskModificationDate
                    )
                    reloadedText = true
                case .keepBuffer:
                    buffer.keepBufferAfterExternalChange(
                        prepared.diskText,
                        modificationDate: prepared.diskModificationDate
                    )
                case .cancel:
                    foregroundEditorState = nil
                    return false
                }
            }
        }

        buffer.baseText = prepared.committedText
        if let foregroundEditorState {
            buffer.selection = restoredSelection(in: buffer.text, from: foregroundEditorState)
            buffer.selectionAffinity = foregroundEditorState.affinity
            buffer.scrollOrigin = foregroundEditorState.scrollOrigin
        }
        buffersByPath[request.relativePath] = buffer
        baseText = buffer.baseText
        if reloadedText {
            activate(buffer)
            textView.scrollRangeToVisible(textView.selectedRange())
            statusLabel.stringValue = "Reloaded external changes in \(request.relativePath)"
            reportBufferedChanges()
        } else {
            recomputeHighlights()
        }
        foregroundEditorState = nil
        return true
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

    var currentDocumentPath: String? {
        currentRelativePath
    }

    var changedDocumentPaths: Set<String> {
        persistCurrentBuffer()
        return Set(buffersByPath.values.lazy.filter { $0.baseText != $0.text }.map(\.relativePath))
    }

    func isEditing(relativePath: String) -> Bool {
        currentRelativePath == relativePath
    }

    @discardableResult
    func navigateToAdjacentChange(_ direction: ChangeNavigationDirection, animated: Bool = true) -> Bool {
        guard mode == .editing else { return false }
        refreshDiffForNavigation()
        let currentLine = (textView.string as NSString).lineIndex(containing: textView.selectedRange().location)
        guard let targetLine = ChangedLineNavigator.adjacentTarget(
            in: navigableChangedLines,
            from: currentLine,
            direction: direction
        ) else { return false }
        selectLine(targetLine, animated: animated)
        return true
    }

    @discardableResult
    func navigateToEdgeChange(_ direction: ChangeNavigationDirection, animated: Bool) -> Bool {
        guard mode == .editing else { return false }
        refreshDiffForNavigation()
        guard let targetLine = ChangedLineNavigator.edgeTarget(
            in: navigableChangedLines,
            direction: direction
        ) else { return false }
        selectLine(targetLine, animated: animated)
        return true
    }

    private var bufferedChangePaths: Set<String> {
        Set(buffersByPath.values.lazy.filter(\.hasUnsavedChanges).map(\.relativePath))
    }

    private func persistCurrentBuffer() {
        guard let currentRelativePath,
              var buffer = buffersByPath[currentRelativePath] else { return }
        buffer.text = textView.string
        if buffer.text == buffer.knownDiskText {
            buffer.requiresOverwriteConfirmation = false
        }
        buffer.selection = textView.selectedRange()
        buffer.selectionAffinity = textView.selectionAffinity
        buffer.scrollOrigin = mainScroll.contentView.bounds.origin
        buffersByPath[currentRelativePath] = buffer
        reportBufferedChanges()
    }

    private func prepareForSave(_ buffer: inout EditorBuffer) throws -> Bool {
        let observedModificationDate = try DiskFileReader.modificationDate(at: buffer.url)
        let metadataChanged = observedModificationDate != buffer.knownDiskModificationDate
        let observedDisk = metadataChanged
            ? try DiskFileReader.snapshot(at: buffer.url)
            : DiskFileSnapshot(text: buffer.knownDiskText, modificationDate: buffer.knownDiskModificationDate)
        let diskChanged = observedDisk.text != buffer.knownDiskText
        if metadataChanged, !diskChanged {
            buffer.acknowledgeUnchangedDisk(modificationDate: observedDisk.modificationDate)
        }
        if diskChanged,
           buffer.text == buffer.knownDiskText,
           !buffer.requiresOverwriteConfirmation {
            buffer.reloadFromDisk(
                observedDisk.text,
                modificationDate: observedDisk.modificationDate
            )
            return false
        }
        guard diskChanged || buffer.requiresOverwriteConfirmation else { return true }
        let conflict = ExternalFileConflict(
            relativePath: buffer.relativePath,
            operation: .saving,
            fileWasDeleted: observedDisk.text == nil
        )
        switch resolveExternalFileConflict?(conflict) ?? .cancel {
        case .reloadFromDisk:
            buffer.reloadFromDisk(
                observedDisk.text,
                modificationDate: observedDisk.modificationDate
            )
            return false
        case .keepBuffer:
            buffer.keepBufferAfterExternalChange(
                observedDisk.text,
                modificationDate: observedDisk.modificationDate
            )
            return true
        case .cancel:
            throw EditorFileError.cancelled
        }
    }

    private func restoredSelection(in text: String, from state: ForegroundEditorState) -> NSRange {
        let nsString = text as NSString
        let lines = text.splitKeepingEmptyLines()
        let line = min(max(0, state.line), max(0, lines.count - 1))
        let lineStart = nsString.lineStartOffset(forLineIndex: line)
        let lineLength = lines[safe: line].map {
            ($0.trimmedTrailingNewline() as NSString).length
        } ?? 0
        let location = min(nsString.length, lineStart + min(state.column, lineLength))
        return NSRange(
            location: location,
            length: min(state.selectionLength, nsString.length - location)
        )
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
        updateActiveLineHighlight()
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
        updateActiveLineHighlight()
        updateCommittedContext()
    }

    private func updateActiveLineHighlight() {
        let line = (textView.string as NSString).lineIndex(containing: textView.selectedRange().location)
        textView.activeLine = line
        mainGutter?.needsDisplay = true
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
        if let currentRelativePath {
            let plan = DiffEngine.selectiveStagingPlan(base: baseText, current: workingText)
            _ = updateStageSelection(relativePath: currentRelativePath, selectableChanges: plan.selectableChanges)
        }
        applyHighlights(to: workingText)
        updateCommittedContext()
        updateStagingDiff()
    }

    private func updateStageSelection(relativePath: String, selectableChanges: Set<StagingChangeID>) -> StageSelection {
        let previous = stageSelectionsByPath[relativePath]
        let newlyAvailable = selectableChanges.subtracting(previous?.available ?? [])
        let selected = (previous?.selected.intersection(selectableChanges) ?? []).union(newlyAvailable)
        let state = StageSelection(available: selectableChanges, selected: selected)
        stageSelectionsByPath[relativePath] = state
        if relativePath == currentRelativePath {
            onStageSelectionAvailabilityChanged?(!selectableChanges.isEmpty)
        }
        return state
    }

    private func setStageSelection(for id: StagingChangeID, selected: Bool) {
        guard let currentRelativePath,
              var state = stageSelectionsByPath[currentRelativePath],
              state.available.contains(id) else { return }
        if selected {
            state.selected.insert(id)
        } else {
            state.selected.remove(id)
        }
        stageSelectionsByPath[currentRelativePath] = state
    }

    func setMode(_ mode: WorkspaceMode) {
        self.mode = mode
        let editing = mode == .editing
        committedRow.isHidden = !editing
        divider.isHidden = !editing
        mainRow.isHidden = !editing
        statusLabel.isHidden = !editing
        stagingDiffView.isHidden = editing
        if !editing {
            persistCurrentBuffer()
            updateStagingDiff()
        } else {
            view.window?.makeFirstResponder(textView)
        }
    }

    private func updateStagingDiff() {
        guard !stagingDiffView.isHidden,
              let currentRelativePath,
              let buffer = buffersByPath[currentRelativePath] else {
            if !stagingDiffView.isHidden {
                stagingDiffView.setDocument(filePath: nil, rows: [], selectedChanges: [])
            }
            return
        }
        let currentText = textView.string
        let plan = DiffEngine.selectiveStagingPlan(base: buffer.baseText, current: currentText)
        let state = updateStageSelection(relativePath: currentRelativePath, selectableChanges: plan.selectableChanges)
        stagingDiffView.setDocument(
            filePath: currentRelativePath,
            rows: plan.diffRows,
            selectedChanges: state.selected
        )
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
        let changedLines = navigableChangedLines.sorted()
        guard !changedLines.isEmpty else { return }
        let currentLine = (textView.string as NSString).lineIndex(containing: textView.selectedRange().location)
        let targetLine: Int
        switch shortcut {
        case .nextChangedLine:
            targetLine = changedLines.first(where: { $0 > currentLine }) ?? changedLines[0]
        case .previousChangedLine:
            targetLine = changedLines.reversed().first(where: { $0 < currentLine }) ?? changedLines[changedLines.count - 1]
        case .nextChangedGroup:
            if navigateToAdjacentChange(.next) { return }
            targetLine = ChangedLineNavigator.edgeTarget(in: navigableChangedLines, direction: .next) ?? changedLines[0]
        case .previousChangedGroup:
            if navigateToAdjacentChange(.previous) { return }
            targetLine = ChangedLineNavigator.edgeTarget(in: navigableChangedLines, direction: .previous) ?? changedLines[changedLines.count - 1]
        case .previousParagraph:
            jumpParagraph(up: true)
            return
        case .nextParagraph:
            jumpParagraph(up: false)
            return
        }
        selectLine(targetLine, animated: true)
    }

    private var navigableChangedLines: Set<Int> {
        lastDiff.currentTouchedLines.union(lastDiff.currentDeletionMarkers.map(\.line))
    }

    private func refreshDiffForNavigation() {
        pendingDiffWorkItem?.cancel()
        pendingDiffWorkItem = nil
        persistCurrentBuffer()
        recomputeHighlights()
    }

    private func selectLine(_ line: Int, animated: Bool) {
        let nsString = textView.string as NSString
        let lineStart = nsString.lineStartOffset(forLineIndex: line)
        textView.setSelectedRange(NSRange(location: min(lineStart, nsString.length), length: 0))
        view.window?.makeFirstResponder(textView)
        updateCommittedContext()
        guard animated else {
            textView.scrollRangeToVisible(textView.selectedRange())
            return
        }
        animateScrollToLine(line)
    }

    private func animateScrollToLine(_ line: Int) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let nsString = textView.string as NSString
        let range = nsString.lineRange(forLineIndex: line)
        let lineMidY: CGFloat
        if range.location != NSNotFound {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if glyphRange.length > 0 {
                let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                lineMidY = textView.textContainerOrigin.y + rect.midY
            } else {
                lineMidY = textView.textContainerOrigin.y + layoutManager.usedRect(for: textContainer).maxY
            }
        } else {
            lineMidY = textView.textContainerOrigin.y + layoutManager.usedRect(for: textContainer).maxY
        }
        let clipView = mainScroll.contentView
        let maximumY = max(0, (mainScroll.documentView?.bounds.height ?? 0) - clipView.bounds.height)
        let targetY = min(maximumY, max(0, lineMidY - clipView.bounds.height / 2))
        let targetOrigin = NSPoint(x: clipView.bounds.origin.x, y: targetY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(targetOrigin)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.mainScroll.reflectScrolledClipView(self.mainScroll.contentView)
            self.mainGutter?.needsDisplay = true
            self.changeOverview.needsDisplay = true
        }
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
