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

final class EditorViewController: NSViewController, NSTextViewDelegate, NSSplitViewDelegate, NSTextFieldDelegate {
    static let committedPaneHeightDefaultsKey = "DiffEdit.committedPaneHeight"

    var onBufferedChangesChanged: ((Set<String>) -> Void)?
    var onStageSelectionAvailabilityChanged: ((Bool) -> Void)?
    var resolveExternalFileConflict: ((ExternalFileConflict) -> ExternalFileResolution)?

    private let stack = NSStackView()
    private let editorSplitView = EditorSplitView()
    private let committedRow = NSStackView()
    private let mainRow = NSStackView()
    private let committedScroll = NSScrollView()
    private let committedTextView = LineHighlightTextView()
    private var committedGutter: LineNumberGutterView?
    private let mainScroll = NSScrollView()
    private let textView = LineHighlightTextView()
    private var mainGutter: LineNumberGutterView?
    private let changeOverview = ChangeOverviewView()
    private let stagingDiffView = StagingDiffView()
    private let searchBar = NSStackView()
    private let searchField = NSTextField()
    private let replacementField = NSTextField()
    private let replacementRow = NSStackView()
    private let searchFeedback = NSTextField(labelWithString: "")
    private var searchIsOpen = false

    private let statusBar = NSView()
    private let statusLabel = NSTextField(labelWithString: "Open a folder to begin.")
    private let fileIOQueue = DispatchQueue(label: "com.diffedit.file-io", qos: .userInitiated)
    private var openingGeneration = 0
    private var savingPaths = Set<String>()
    private var repeatSavePaths = Set<String>()
    private var queuedSaveCompletions: [String: [(Result<Void, Error>) -> Void]] = [:]
    var isSaving: Bool { !savingPaths.isEmpty }

    private var currentFileURL: URL?
    private var currentRelativePath: String?
    private var onSaved: (() -> Void)?
    private var buffersByPath: [String: EditorBuffer] = [:]
    private var stageSelectionsByPath: [String: StageSelection] = [:]
    private var lastReportedBufferedChanges = Set<String>()
    private var baseText = "" {
        didSet {
            cachedBaseLines = baseText.splitKeepingEmptyLines()
            committedContextNeedsRefresh = true
        }
    }
    private var cachedBaseLines: [String] = []
    private var committedContextNeedsRefresh = true
    private var diffGeneration = 0
    private var preparedStagingPlan: (base: String, current: String, plan: SelectiveStagingPlan)?
    private var stagingGeneration = 0
    private let typingDiffQueue = DispatchQueue(label: "com.diffedit.typing-diff", qos: .userInitiated)
    private var pendingDiffWorkItem: DispatchWorkItem?
    private var fontSize: CGFloat = 13
    private var wordWrap = true
    private var lastDiff = DiffResult.empty
    private var isApplyingHighlights = false
    private var committedVisibleBaseLines: [Int?] = []
    private var foregroundEditorState: ForegroundEditorState?
    private let editorContentMargin: CGFloat = 24
    private var mode = WorkspaceMode.editing
    private var hasRestoredDivider = false
    private var isApplyingDividerLayout = false
    private var preferredCommittedHeight: CGFloat?

    override func loadView() {
        view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        view.addSubview(stack)

        editorSplitView.translatesAutoresizingMaskIntoConstraints = false
        editorSplitView.isVertical = false
        editorSplitView.dividerStyle = .thin
        editorSplitView.delegate = self
        editorSplitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorSplitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        committedRow.orientation = .horizontal
        committedRow.spacing = 0
        committedRow.translatesAutoresizingMaskIntoConstraints = true
        committedRow.wantsLayer = true
        committedRow.layer?.masksToBounds = true
        mainRow.orientation = .horizontal
        mainRow.spacing = 0
        mainRow.translatesAutoresizingMaskIntoConstraints = true
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
        committedTextView.showsCaretMarker = false
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

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusBar.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.identifier = NSUserInterfaceItemIdentifier("editorStatus")
        statusLabel.controlSize = .small
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.backgroundColor = .windowBackgroundColor
        statusLabel.drawsBackground = true
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        stagingDiffView.isHidden = true
        stagingDiffView.onSetChangeSelection = { [weak self] id, selected in
            self?.setStageSelection(for: id, selected: selected)
        }

        editorSplitView.addSubview(committedRow)
        editorSplitView.addSubview(mainRow)
        editorSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        stack.addArrangedSubview(editorSplitView)
        configureSearchBar()
        stack.addArrangedSubview(searchBar)
        searchBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(statusBar)
        stack.addArrangedSubview(stagingDiffView)
        let committedGutterWidth = committedGutter.widthAnchor.constraint(equalToConstant: 46)
        let mainGutterWidth = mainGutter.widthAnchor.constraint(equalToConstant: 46)
        let overviewWidth = changeOverview.widthAnchor.constraint(equalToConstant: 14)
        for constraint in [committedGutterWidth, mainGutterWidth, overviewWidth] {
            constraint.priority = NSLayoutConstraint.Priority(999)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stagingDiffView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            committedGutterWidth,
            mainGutterWidth,
            overviewWidth,
            statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: mainScroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: committedScroll.contentView)
        applyWrapping()
        updateDocumentVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyWrapping()
        restoreDividerIfNeeded()
        mainScroll.contentView.scroll(to: NSPoint(x: 0, y: mainScroll.contentView.bounds.origin.y))
        mainScroll.reflectScrolledClipView(mainScroll.contentView)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === editorSplitView, dividerIndex == 0 else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, committedPaneMinimumHeight)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === editorSplitView, dividerIndex == 0 else { return proposedMaximumPosition }
        let maximum = splitView.bounds.height - splitView.dividerThickness - editablePaneMinimumHeight
        return min(proposedMaximumPosition, maximum)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === editorSplitView, dividerIndex == 0 else { return proposedPosition }
        let contentInset = committedTextView.textContainerInset.height * 2
        let lineHeight = editorLineHeight(for: committedTextView)
        let lineCount = max(2, ((proposedPosition - contentInset) / lineHeight).rounded())
        let snappedPosition = contentInset + lineCount * lineHeight
        let maximum = splitView.bounds.height - splitView.dividerThickness - editablePaneMinimumHeight
        let position = min(maximum, max(committedPaneMinimumHeight, snappedPosition))
        if hasRestoredDivider, !isApplyingDividerLayout, mode == .editing,
           position >= committedPaneMinimumHeight {
            preferredCommittedHeight = position
            UserDefaults.standard.set(Double(position), forKey: Self.committedPaneHeightDefaultsKey)
        }
        return position
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView === editorSplitView else { return }
        restoreDividerIfNeeded()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === editorSplitView else { return }
        if currentFileURL != nil {
            committedRow.layoutSubtreeIfNeeded()
            updateCommittedContext()
        }
    }

    func showPlaceholder(_ message: String) {
        diffGeneration += 1
        pendingDiffWorkItem?.cancel()
        buffersByPath.removeAll()
        stageSelectionsByPath.removeAll()
        currentFileURL = nil
        currentRelativePath = nil
        updateDocumentVisibility()
        baseText = ""
        textView.string = ""
        committedTextView.string = ""
        textView.fullLineHighlightedLines = []
        textView.activeLine = nil
        committedTextView.fullLineHighlightedLines = []
        textView.deletionMarkers = []
        committedTextView.deletionMarkers = []
        committedTextView.caretMarker = nil
        committedTextView.insertionCaretMarker = nil
        committedVisibleBaseLines = []
        statusLabel.stringValue = message
        stagingDiffView.setDocument(rows: [], selectedChanges: [])
        reportBufferedChanges()
        onStageSelectionAvailabilityChanged?(false)
    }

    @discardableResult
    func open(file url: URL, relativePath: String, repository: Repository, prepared: (disk: DiskFileSnapshot, base: String)? = nil, onSaved: @escaping () -> Void) throws -> Bool {
        persistCurrentBuffer()
        pendingDiffWorkItem?.cancel()
        self.onSaved = onSaved

        let buffer: EditorBuffer
        if var existing = buffersByPath[relativePath] {
            let observedModificationDate = try prepared.map { $0.disk.modificationDate } ?? DiskFileReader.modificationDate(at: existing.url)
            if observedModificationDate != existing.knownDiskModificationDate {
                let observedDisk = try prepared?.disk ?? DiskFileReader.snapshot(at: existing.url)
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
            existing.baseText = prepared?.base ?? repository.committedText(relativePath: relativePath) ?? ""
            buffersByPath[relativePath] = existing
            buffer = existing
        } else {
            let observedDisk = try prepared?.disk ?? DiskFileReader.snapshot(at: url)
            guard let workingText = observedDisk.text else {
                throw CocoaError(.fileNoSuchFile)
            }
            let committedText = prepared?.base ?? repository.committedText(relativePath: relativePath) ?? ""
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

        activate(buffer, deferredHighlights: prepared != nil)
        return true
    }

    func openAsync(file: URL, relativePath: String, repository: Repository,
                   onSaved: @escaping () -> Void, completion: @escaping (Result<Bool, Error>) -> Void) {
        openingGeneration += 1
        let generation = openingGeneration
        fileIOQueue.async { [weak self] in
            let prepared = Result { (disk: try DiskFileReader.snapshot(at: file), base: repository.committedText(relativePath: relativePath) ?? "") }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openingGeneration == generation else { return }
                completion(Result {
                    try self.open(file: file, relativePath: relativePath, repository: repository, prepared: prepared.get(), onSaved: onSaved)
                })
            }
        }
    }

    func saveCurrentFileAsync(completion: @escaping (Result<Void, Error>) -> Void) {
        persistCurrentBuffer()
        guard let path = currentRelativePath else { completion(.success(())); return }
        saveFileAsync(path: path, completion: completion)
    }

    private func saveFileAsync(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        if savingPaths.contains(path) {
            repeatSavePaths.insert(path)
            queuedSaveCompletions[path, default: []].append(completion)
            return
        }
        guard let captured = buffersByPath[path] else { completion(.success(())); return }
        savingPaths.insert(path)
        if currentRelativePath == path { statusLabel.stringValue = "Saving \(path)…" }
        fileIOQueue.async { [weak self] in
            let disk = Result { try DiskFileReader.snapshot(at: captured.url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                do {
                    var saving = captured
                    let shouldWrite = try self.prepareForSave(&saving, observedDisk: disk.get())
                    if !shouldWrite {
                        self.finishBackgroundSave(captured: captured, saved: saving, reloaded: true, completion: completion)
                        return
                    }
                    let snapshot = saving
                    self.fileIOQueue.async { [weak self] in
                        let result = Result { () -> EditorBuffer in
                            var saved = snapshot
                            if saved.hasUnsavedChanges || saved.requiresOverwriteConfirmation {
                                try saved.text.write(to: saved.url, atomically: true, encoding: .utf8)
                            }
                            saved.markSaved(modificationDate: try DiskFileReader.modificationDate(at: saved.url))
                            return saved
                        }
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            switch result {
                            case let .success(saved):
                                self.finishBackgroundSave(captured: captured, saved: saved, reloaded: false, completion: completion)
                            case let .failure(error):
                                self.savingPaths.remove(path)
                                if self.currentRelativePath == path { self.statusLabel.stringValue = "Save failed: \(path)" }
                                self.repeatSavePaths.remove(path)
                                completion(.failure(error))
                                self.queuedSaveCompletions.removeValue(forKey: path)?.forEach { $0(.failure(error)) }
                            }
                        }
                    }
                } catch {
                    self.savingPaths.remove(path)
                    if self.currentRelativePath == path { self.statusLabel.stringValue = "Save cancelled or failed: \(path)" }
                    self.repeatSavePaths.remove(path)
                    completion(.failure(error))
                    self.queuedSaveCompletions.removeValue(forKey: path)?.forEach { $0(.failure(error)) }
                }
            }
        }
    }

    private func finishBackgroundSave(captured: EditorBuffer, saved: EditorBuffer, reloaded: Bool,
                                      completion: @escaping (Result<Void, Error>) -> Void) {
        persistCurrentBuffer()
        let path = captured.relativePath
        if var latest = buffersByPath[path] {
            let unchangedSinceRequest = latest.text == captured.text
            latest.knownDiskText = saved.knownDiskText
            latest.knownDiskModificationDate = saved.knownDiskModificationDate
            latest.requiresOverwriteConfirmation = reloaded && !unchangedSinceRequest && latest.text != saved.knownDiskText
            if reloaded && unchangedSinceRequest { latest.text = saved.text }
            buffersByPath[path] = latest
            if currentRelativePath == path {
                if reloaded && unchangedSinceRequest { activate(latest, deferredHighlights: true) }
                statusLabel.stringValue = latest.hasUnsavedChanges ? "Saved \(path); newer edits are unsaved" : "Saved \(path)"
            }
        }
        savingPaths.remove(path)
        reportBufferedChanges()
        onSaved?()
        completion(.success(()))
        if repeatSavePaths.remove(path) != nil {
            let waiters = queuedSaveCompletions.removeValue(forKey: path) ?? []
            saveFileAsync(path: path) { result in waiters.forEach { $0(result) } }
        }
    }

    private func activate(_ buffer: EditorBuffer, deferredHighlights: Bool = false) {
        if currentRelativePath != buffer.relativePath {
            lastPastFocus = nil
            pastManualScrollOffset = 0
            pastCanonicalScrollY = nil
        }
        currentFileURL = buffer.url
        currentRelativePath = buffer.relativePath
        updateDocumentVisibility()
        view.layoutSubtreeIfNeeded()
        baseText = buffer.baseText
        textView.string = buffer.text
        textView.textStorage?.setAttributes(editorAttributes(), range: NSRange(location: 0, length: (buffer.text as NSString).length))
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
        statusLabel.stringValue = ""
        view.window?.title = "DiffEdit — \(buffer.relativePath)"
        if deferredHighlights {
            lastDiff = .empty
            textView.fullLineHighlightedLines = []
            textView.deletionMarkers = []
            updateCommittedContext()
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        } else {
            recomputeHighlights()
        }
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

    func saveAllFilesAsync(completion: @escaping (Result<Void, Error>) -> Void) {
        persistCurrentBuffer()
        let paths = bufferedChangePaths.sorted()
        func saveNext(_ index: Int) {
            guard index < paths.count else { completion(.success(())); return }
            saveFileAsync(path: paths[index]) { result in
                switch result {
                case .success: saveNext(index + 1)
                case let .failure(error): completion(.failure(error))
                }
            }
        }
        saveNext(0)
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

    func commitSnapshot() -> (buffer: EditorBuffer?, available: Set<StagingChangeID>, selected: Set<StagingChangeID>, paths: [String]) {
        persistCurrentBuffer()
        let state = currentRelativePath.flatMap { stageSelectionsByPath[$0] }
        return (currentRelativePath.flatMap { buffersByPath[$0] }, state?.available ?? [], state?.selected ?? [], Array(buffersByPath.keys))
    }

    func applyCommittedBases(_ bases: [String: String]) {
        persistCurrentBuffer()
        for (path, base) in bases {
            buffersByPath[path]?.baseText = base
        }
        stageSelectionsByPath.removeAll()
        if let path = currentRelativePath, let buffer = buffersByPath[path] {
            baseText = buffer.baseText
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
    }

    func setOperationBusy(_ busy: Bool) {
        textView.isEditable = !busy
        if busy {
            openingGeneration += 1
            view.window?.makeFirstResponder(nil)
        } else if mode == .editing, currentFileURL != nil {
            view.window?.makeFirstResponder(textView)
        }
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

    private func prepareForSave(_ buffer: inout EditorBuffer, observedDisk preparedDisk: DiskFileSnapshot? = nil) throws -> Bool {
        let observedModificationDate = try preparedDisk.map { $0.modificationDate } ?? DiskFileReader.modificationDate(at: buffer.url)
        let metadataChanged = observedModificationDate != buffer.knownDiskModificationDate
        let observedDisk = try preparedDisk ?? (metadataChanged
            ? DiskFileReader.snapshot(at: buffer.url)
            : DiskFileSnapshot(text: buffer.knownDiskText, modificationDate: buffer.knownDiskModificationDate))
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
        textView.textStorage?.setAttributes(editorAttributes(), range: NSRange(location: 0, length: (textView.string as NSString).length))
        recomputeHighlights()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingHighlights else { return }
        updateTypingAttributesForSelection()
        updateActiveLineHighlight()
        persistCurrentBuffer()
        pendingDiffWorkItem?.cancel()
        diffGeneration += 1
        let generation = diffGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.diffGeneration == generation else { return }
            let base = self.baseText
            let current = self.textView.string
            let path = self.currentRelativePath
            self.typingDiffQueue.async { [weak self] in
                let result = DiffEngine.diff(base: base, current: current)
                let plan = DiffEngine.selectiveStagingPlan(base: base, current: current)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.diffGeneration == generation,
                          self.currentRelativePath == path,
                          !self.textView.hasMarkedText() else { return }
                    self.preparedStagingPlan = (base, current, plan)
                    self.lastDiff = result
                    self.committedContextNeedsRefresh = true
                    if let path {
                        _ = self.updateStageSelection(relativePath: path, selectableChanges: plan.selectableChanges)
                    }
                    self.applyHighlights(to: current)
                    self.updateCommittedContext()
                    self.updateStagingDiff()
                }
            }
        }
        pendingDiffWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard textView === self.textView else { return true }
        lastDiff.adjustDecorations(for: affectedCharRange, replacement: replacementString ?? "", in: textView.string as NSString)
        self.textView.deletionMarkers = lastDiff.currentDeletionMarkers
        self.textView.fullLineHighlightedLines = lastDiff.currentTouchedLines
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingHighlights else { return }
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
            if !isRenderingPast, let canonical = pastCanonicalScrollY {
                pastManualScrollOffset = committedScroll.contentView.bounds.minY - canonical
            }
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

    private var committedPaneMinimumHeight: CGFloat {
        paneMinimumHeight(for: committedTextView, visibleLines: 2)
    }

    private var committedPaneDefaultHeight: CGFloat {
        paneMinimumHeight(for: committedTextView, visibleLines: 5)
    }

    private var editablePaneMinimumHeight: CGFloat {
        paneMinimumHeight(for: textView, visibleLines: 5)
    }

    private func paneMinimumHeight(for textView: NSTextView, visibleLines: Int) -> CGFloat {
        let lineHeight = editorLineHeight(for: textView)
        return ceil(textView.textContainerInset.height * 2 + lineHeight * CGFloat(visibleLines))
    }

    private func editorLineHeight(for textView: NSTextView) -> CGFloat {
        let font = textView.font ?? editorFont()
        return (textView.layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height) + 2
    }

    private func restoreDividerIfNeeded() {
        guard !isApplyingDividerLayout else { return }
        let availableHeight = editorSplitView.bounds.height
        let requiredHeight = committedPaneMinimumHeight + editorSplitView.dividerThickness + editablePaneMinimumHeight
        let canRestore = availableHeight >= requiredHeight
        if canRestore, preferredCommittedHeight == nil {
            let savedHeight = (UserDefaults.standard.object(forKey: Self.committedPaneHeightDefaultsKey) as? NSNumber)
                .map { CGFloat(truncating: $0) }
            preferredCommittedHeight = savedHeight.flatMap {
                $0.isFinite && $0 >= committedPaneMinimumHeight ? $0 : nil
            } ?? committedPaneDefaultHeight
        }
        let maximumHeight = max(0, availableHeight - editorSplitView.dividerThickness - editablePaneMinimumHeight)
        let height = min(maximumHeight, max(committedPaneMinimumHeight, preferredCommittedHeight ?? committedPaneDefaultHeight))
        isApplyingDividerLayout = true
        defer { isApplyingDividerLayout = false }
        // Own automatic resizing so startup, window resizing and mode changes
        // cannot collapse the past pane or overwrite the user's chosen height.
        let width = editorSplitView.bounds.width
        committedRow.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let mainY = min(availableHeight, height + editorSplitView.dividerThickness)
        mainRow.frame = NSRect(x: 0, y: mainY, width: width, height: availableHeight - mainY)
        if canRestore { hasRestoredDivider = true }
    }

    private func recomputeHighlights() {
        diffGeneration += 1
        pendingDiffWorkItem?.cancel()
        committedContextNeedsRefresh = true
        let workingText = textView.string
        lastDiff = DiffEngine.diff(base: baseText, current: workingText)
        if let currentRelativePath {
            let plan = DiffEngine.selectiveStagingPlan(base: baseText, current: workingText)
            preparedStagingPlan = (baseText, workingText, plan)
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
        updateDocumentVisibility()
        if !editing {
            persistCurrentBuffer()
            updateStagingDiff()
        } else if currentFileURL != nil {
            view.window?.makeFirstResponder(textView)
        }
    }

    private func updateDocumentVisibility() {
        let hasDocument = currentFileURL != nil
        editorSplitView.isHidden = !hasDocument || mode != .editing
        statusBar.isHidden = !hasDocument || mode != .editing
        stagingDiffView.isHidden = !hasDocument || mode != .staging
        searchBar.isHidden = !hasDocument || mode != .editing || !searchIsOpen
    }

    private func configureSearchBar() {
        searchBar.orientation = .vertical
        searchBar.alignment = .width
        searchBar.spacing = 6
        searchBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.setContentHuggingPriority(.required, for: .vertical)
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            return button
        }
        for (field, placeholder, identifier) in [
            (searchField, "Find", "findField"),
            (replacementField, "Replace with", "replacementField")
        ] {
            field.placeholderString = placeholder
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.setAccessibilityLabel(placeholder)
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        searchFeedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchFeedback.textColor = .secondaryLabelColor
        searchFeedback.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [searchField, searchFeedback,
            button("Previous", #selector(previousSearchMatch(_:))),
            button("Next", #selector(nextSearchMatch(_:))),
            button("Close", #selector(closeSearch(_:)))])
        row.spacing = 6
        searchBar.addArrangedSubview(row)
        replacementRow.orientation = .horizontal
        replacementRow.spacing = 6
        replacementRow.addArrangedSubview(replacementField)
        replacementRow.addArrangedSubview(button("Replace", #selector(replaceSearchMatch(_:))))
        replacementRow.addArrangedSubview(button("Replace All", #selector(replaceAllSearchMatches(_:))))
        searchBar.addArrangedSubview(replacementRow)
        replacementRow.isHidden = true
        searchBar.isHidden = true
    }

    func showSearch(replacing: Bool) {
        guard currentFileURL != nil, mode == .editing else { return }
        let selection = textView.selectedRange()
        if selection.length > 0 {
            let selected = (textView.string as NSString).substring(with: selection)
            if !selected.contains("\n"), !selected.contains("\r") { searchField.stringValue = selected }
        }
        searchIsOpen = true
        replacementRow.isHidden = !replacing
        searchFeedback.stringValue = ""
        updateDocumentVisibility()
        view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func findMatch(backwards: Bool, includingSelection: Bool = false) {
        guard currentFileURL != nil, mode == .editing else { return }
        let query = searchField.stringValue
        guard !query.isEmpty else { showSearch(replacing: false); return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let start = backwards ? selection.location : (includingSelection ? selection.location : NSMaxRange(selection))
        let first = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: text.length - start)
        let second = backwards ? NSRange(location: start, length: text.length - start) : NSRange(location: 0, length: start)
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        var match = text.range(of: query, options: options, range: first)
        let wrapped = match.location == NSNotFound
        if wrapped { match = text.range(of: query, options: options, range: second) }
        guard match.location != NSNotFound else {
            searchFeedback.stringValue = "No matches"
            return
        }
        searchFeedback.stringValue = wrapped ? "Wrapped" : ""
        textView.setSelectedRange(match)
        textView.scrollRangeToVisible(match)
        textView.showFindIndicator(for: match)
    }

    @objc private func nextSearchMatch(_ sender: Any?) { findMatch(backwards: false) }
    @objc private func previousSearchMatch(_ sender: Any?) { findMatch(backwards: true) }

    @objc private func closeSearch(_ sender: Any?) {
        searchIsOpen = false
        updateDocumentVisibility()
        view.window?.makeFirstResponder(textView)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === searchField else { return }
        searchFeedback.stringValue = ""
        if !searchField.stringValue.isEmpty { findMatch(backwards: false, includingSelection: true) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeSearch(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === replacementField { replaceSearchMatch(nil) }
            else { findMatch(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
            return true
        }
        return false
    }

    @objc private func replaceSearchMatch(_ sender: Any?) {
        guard currentFileURL != nil, mode == .editing, !searchField.stringValue.isEmpty else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        guard selected.compare(searchField.stringValue, options: [.caseInsensitive]) == .orderedSame else {
            findMatch(backwards: false, includingSelection: true)
            return
        }
        let replacement = replacementField.stringValue
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
        textView.didChangeText()
        textView.undoManager?.setActionName("Replace")
        findMatch(backwards: false)
    }

    @objc private func replaceAllSearchMatches(_ sender: Any?) {
        guard currentFileURL != nil, mode == .editing, !searchField.stringValue.isEmpty else { return }
        let original = textView.string as NSString
        let range = NSRange(location: 0, length: original.length)
        let replaced = original.replacingOccurrences(of: searchField.stringValue, with: replacementField.stringValue, options: [.caseInsensitive], range: range)
        guard replaced != textView.string else { return }
        guard textView.shouldChangeText(in: range, replacementString: replaced) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replaced)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.didChangeText()
        textView.undoManager?.setActionName("Replace All")
        searchFeedback.stringValue = "Replaced all"
    }

    private func updateStagingDiff() {
        guard !stagingDiffView.isHidden,
              let currentRelativePath,
              let buffer = buffersByPath[currentRelativePath] else {
            if !stagingDiffView.isHidden {
                stagingDiffView.setDocument(rows: [], selectedChanges: [])
            }
            return
        }
        let currentText = textView.string
        let base = buffer.baseText
        stagingGeneration += 1
        let generation = stagingGeneration
        if let prepared = preparedStagingPlan, prepared.base == base, prepared.current == currentText {
            renderStagingPlan(prepared.plan, relativePath: currentRelativePath)
            return
        }
        typingDiffQueue.async { [weak self] in
            let plan = DiffEngine.selectiveStagingPlan(base: base, current: currentText)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stagingGeneration == generation,
                      self.currentRelativePath == currentRelativePath,
                      self.baseText == base, self.textView.string == currentText,
                      self.mode == .staging else { return }
                self.preparedStagingPlan = (base, currentText, plan)
                self.renderStagingPlan(plan, relativePath: currentRelativePath)
            }
        }
    }

    private func renderStagingPlan(_ plan: SelectiveStagingPlan, relativePath: String) {
        let state = updateStageSelection(relativePath: relativePath, selectableChanges: plan.selectableChanges)
        stagingDiffView.setDocument(rows: plan.diffRows, selectedChanges: state.selected)
    }

    private func applyHighlights(to string: String) {
        isApplyingHighlights = true
        let scrollOrigin = mainScroll.contentView.bounds.origin
        guard let storage = textView.textStorage else {
            isApplyingHighlights = false
            return
        }
        textView.fullLineHighlightedLines = lastDiff.currentTouchedLines
        textView.deletionMarkers = lastDiff.currentDeletionMarkers
        // Highlighting must never replace document characters or line endings.
        // Attribute-only edits also avoid invalidating the entire glyph buffer.
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        for range in lastDiff.insertedWordRanges where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.backgroundColor, value: DiffPalette.insertedText, range: range)
        }
        storage.endEditing()
        updateTypingAttributesForSelection()
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
        if !(textView.typingAttributes as NSDictionary).isEqual(to: attributes) {
            textView.typingAttributes = attributes
        }
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

    private struct PastFocus: Equatable {
        enum Kind: Equatable { case word, deletion, insertion, none }
        let line: Int
        let column: Int
        var range: NSRange? = nil
        var kind: Kind = .none
    }

    private var lastPastFocus: PastFocus?
    private var pastManualScrollOffset: CGFloat = 0
    private var pastCanonicalScrollY: CGFloat?
    private var isRenderingPast = false

    // Resolve focus entirely in base-document coordinates. Rendering never
    // changes this decision, whether invoked by typing, selection, or refresh.
    private func resolvedPastFocus() -> PastFocus {
        let current = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = min(selection.location, current.length)
        let currentLine = current.lineIndex(containing: caret)
        let currentColumn = caret - current.lineStartOffset(forLineIndex: currentLine)
        let baseLine = min(max(0, lastDiff.currentToBaseLine[currentLine] ?? currentLine), max(0, cachedBaseLines.count - 1))
        let oldLine = (cachedBaseLines[safe: baseLine] ?? "").trimmedTrailingNewline() as NSString
        let column = min(oldLine.length, max(0, mappedBaseColumn(currentLine: currentLine, currentColumn: currentColumn, defaultColumn: currentColumn)))
        var probe = caret
        if selection.length == 0, caret > 0 {
            let previous = current.rangeOfComposedCharacterSequence(at: caret - 1)
            let beforeWhitespace = caret == current.length ||
                current.substring(with: current.rangeOfComposedCharacterSequence(at: caret)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            if beforeWhitespace, current.substring(with: previous).rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                probe = previous.location
            }
        }
        let insertion = lastDiff.insertedWordRanges.first { NSLocationInRange(probe, $0) }
        let link = lastDiff.replacementLinks.first {
            $0.current.length == 0 && selection.length == 0 && caret == $0.current.location
        } ?? lastDiff.replacementLinks.first { NSLocationInRange(probe, $0.current) }
            ?? insertion.flatMap { inserted in
                lastDiff.replacementLinks.first { NSIntersectionRange(inserted, $0.current).length > 0 }
            }
        if let link {
            let deleted = lastDiff.deletedWordRanges.first {
                $0.line == link.base.line && NSIntersectionRange($0.range, link.base.range).length > 0
            } ?? link.base
            return PastFocus(line: deleted.line, column: deleted.range.location, range: deleted.range, kind: .deletion)
        }
        if let insertion, selection.length == 0 {
            let line = current.lineIndex(containing: insertion.location)
            let startColumn = insertion.location - current.lineStartOffset(forLineIndex: line)
            let oldLineIndex = min(max(0, lastDiff.currentToBaseLine[line] ?? baseLine), max(0, cachedBaseLines.count - 1))
            let length = ((cachedBaseLines[safe: oldLineIndex] ?? "").trimmedTrailingNewline() as NSString).length
            let anchor = mappedBaseColumn(currentLine: line, currentColumn: startColumn, defaultColumn: startColumn)
            return PastFocus(line: oldLineIndex, column: min(length, max(0, anchor)), kind: .insertion)
        }
        guard insertion == nil else { return PastFocus(line: baseLine, column: column) }
        let probeColumn = probe - current.lineStartOffset(forLineIndex: currentLine)
        let oldProbe = probe == caret ? column : mappedBaseColumn(currentLine: currentLine, currentColumn: probeColumn, defaultColumn: probeColumn)
        guard oldProbe >= 0, oldProbe < oldLine.length else { return PastFocus(line: baseLine, column: column) }
        var range = oldLine.rangeOfComposedCharacterSequence(at: oldProbe)
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ range: NSRange) -> Bool {
            oldLine.substring(with: range).rangeOfCharacter(from: wordCharacters) != nil
        }
        if isWord(range) {
            while range.location > 0 {
                let previous = oldLine.rangeOfComposedCharacterSequence(at: range.location - 1)
                guard isWord(previous) else { break }
                range = NSUnionRange(previous, range)
            }
            while NSMaxRange(range) < oldLine.length {
                let next = oldLine.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
                guard isWord(next) else { break }
                range = NSUnionRange(range, next)
            }
        }
        guard !oldLine.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PastFocus(line: baseLine, column: column)
        }
        return PastFocus(line: baseLine, column: column, range: range, kind: .word)
    }

    private func updateCommittedContext() {
        guard !isRenderingPast else { return }
        isRenderingPast = true
        defer { isRenderingPast = false }
        let focus = resolvedPastFocus()
        if focus != lastPastFocus { pastManualScrollOffset = 0 }
        lastPastFocus = focus
        let radius = committedContextRadius()
        let indices = (focus.line - radius)...(focus.line + radius)
        let visibleLines: [Int?] = indices.map { cachedBaseLines.indices.contains($0) ? $0 : nil }
        let context = visibleLines.map { index in
            index.map { cachedBaseLines[$0].trimmedTrailingNewline() } ?? ""
        }.joined(separator: "\n")
        let needsRebuild = committedContextNeedsRefresh || committedVisibleBaseLines != visibleLines
        committedVisibleBaseLines = visibleLines
        let text = context as NSString
        if needsRebuild {
            committedContextNeedsRefresh = false
            let storage = committedTextView.textStorage
            storage?.beginEditing()
            if committedTextView.string != context {
                storage?.setAttributedString(NSAttributedString(string: context, attributes: editorAttributes()))
            } else {
                storage?.setAttributes(editorAttributes(), range: NSRange(location: 0, length: text.length))
            }
            for deletion in lastDiff.deletedWordRanges {
                guard let line = visibleLines.firstIndex(where: { $0 == deletion.line }) else { continue }
                let range = NSRange(location: text.lineStartOffset(forLineIndex: line) + deletion.range.location, length: deletion.range.length)
                if NSMaxRange(range) <= text.length {
                    storage?.addAttribute(.backgroundColor, value: DiffPalette.deletedText, range: range)
                }
            }
            storage?.endEditing()
            committedTextView.fullLineHighlightedLines = Set(visibleLines.enumerated().compactMap { line, base in
                base.map { lastDiff.baseTouchedLines.contains($0) ? line : nil } ?? nil
            })
            committedGutter?.needsDisplay = true
        }
        let layout = committedTextView.layoutManager
        layout?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        let marker = visibleLines.firstIndex(where: { $0 == focus.line }).map {
            CaretMarker(line: $0, column: focus.column)
        }
        committedTextView.caretMarker = marker
        committedTextView.insertionCaretMarker = focus.kind == .insertion ? marker : nil
        if let marker, let highlight = focus.range {
            let range = NSRange(location: text.lineStartOffset(forLineIndex: marker.line) + highlight.location, length: highlight.length)
            if NSMaxRange(range) <= text.length {
                layout?.addTemporaryAttribute(.backgroundColor,
                    value: focus.kind == .deletion ? DiffPalette.activeDeletedText : DiffPalette.correspondingWord,
                    forCharacterRange: range)
            }
        }
        centerCommittedCaret(marker)
    }

    private func committedContextRadius() -> Int {
        let availableHeight = max(committedPaneMinimumHeight, committedScroll.contentSize.height)
            - committedTextView.textContainerInset.height * 2
        let visibleLineCount = max(2, Int(ceil(availableHeight / editorLineHeight(for: committedTextView))))
        return max(2, Int(ceil(CGFloat(visibleLineCount) / 2)) + 2)
    }

    var canRestorePrevious: Bool {
        textView.isEditable && view.window?.firstResponder === textView &&
            restorationAction(at: textView.selectedRange().location) != nil
    }

    @objc func restorePrevious(_ sender: Any?) {
        guard canRestorePrevious, let action = restorationAction(at: textView.selectedRange().location) else { return }
        restore(action)
    }

    private func restorationAction(at characterIndex: Int) -> RevertAction? {
        guard mode == .editing, textView.isEditable,
              let inserted = lastDiff.insertedWordRanges.first(where: { NSLocationInRange(characterIndex, $0) }),
              let link = lastDiff.replacementLinks.first(where: {
                  $0.current.length > 0 && NSIntersectionRange(inserted, $0.current).length > 0
              }) else { return nil }
        let deleted = lastDiff.deletedWordRanges.first(where: {
            $0.line == link.base.line && NSIntersectionRange($0.range, link.base.range).length > 0
        }) ?? link.base
        // Restore a consecutive replacement group, never use nearby deletions
        // as a guess for text that was only inserted.
        let group = lastDiff.replacementLinks.filter {
            $0.current.length > 0 && $0.base.line == deleted.line &&
                NSIntersectionRange($0.base.range, deleted.range).length > 0 &&
                NSIntersectionRange($0.current, inserted).length > 0
        }
        guard let start = group.map({ $0.current.location }).min(),
              let end = group.map({ NSMaxRange($0.current) }).max() else { return nil }
        let range = NSRange(location: start, length: end - start)
        // A joined-line replacement can refer to several old lines. Include
        // every part of that same replacement, with its original line breaks.
        let related = group + lastDiff.replacementLinks.filter {
            $0.base.line != deleted.line && NSIntersectionRange($0.current, range).length > 0
        }
        let base = baseText as NSString
        let oldRanges = related.map { link -> NSRange in
            let segment = lastDiff.deletedWordRanges.first(where: {
                $0.line == link.base.line && NSIntersectionRange($0.range, link.base.range).length > 0
            }) ?? link.base
            return NSRange(location: base.lineStartOffset(forLineIndex: segment.line) + segment.range.location, length: segment.range.length)
        }
        guard let oldStart = oldRanges.map(\.location).min(),
              let oldEnd = oldRanges.map({ NSMaxRange($0) }).max(),
              oldEnd <= base.length else { return nil }
        return RevertAction(currentRange: range, replacement: base.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart)))

    }

    private func contextMenu(at characterIndex: Int) -> NSMenu? {
        guard let action = restorationAction(at: characterIndex) else { return nil }
        let menu = NSMenu()
        let title = "Restore '" + action.replacement + "'"
        let item = NSMenuItem(title: title, action: #selector(applyRevertAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        menu.addItem(item)
        return menu
    }

    @objc private func applyRevertAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? RevertAction else { return }
        restore(action)
    }

    private func restore(_ action: RevertAction) {
        guard textView.isEditable, NSMaxRange(action.currentRange) <= (textView.string as NSString).length else { return }
        textView.breakUndoCoalescing()
        textView.insertText(action.replacement, replacementRange: action.currentRange)
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName("Restore previous")
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
        if let exact = lastDiff.currentToBaseColumn[LineColumn(line: currentLine, column: currentColumn)] {
            return exact
        }
        if currentColumn == 0 { return 0 }
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

    private func centerCommittedCaret(_ resolvedMarker: CaretMarker?) {
        guard let marker = resolvedMarker,
              let layoutManager = committedTextView.layoutManager,
              let textContainer = committedTextView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let nsString = committedTextView.string as NSString
        let range = nsString.lineRange(forLineIndex: marker.line)
        guard range.location != NSNotFound else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        let character = min(NSMaxRange(range) - 1, range.location + max(0, marker.column))
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        rect.origin.y += committedTextView.textContainerOrigin.y
        let viewport = committedScroll.contentView.bounds
        let targetY = max(0, rect.midY - viewport.height / 2)
        pastCanonicalScrollY = targetY
        committedScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetY + pastManualScrollOffset)))
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
