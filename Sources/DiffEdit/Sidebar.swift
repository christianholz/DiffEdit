import AppKit
import Foundation

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelection: ((FileNode) -> Void)?
    var onModeChanged: ((WorkspaceMode) -> Void)?
    var onStageSelected: (() -> Void)?
    var onCommit: ((String) -> Void)?
    private let modeControl = NSSegmentedControl(labels: ["Edit", "Stage & Commit"], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let sidebarHeader = NSTextField(labelWithString: "Files")
    private let sourceControlPanel = NSView()
    private let commitMessageField = NSTextField()
    private let commitDescriptionScroll = NSScrollView()
    private let commitDescriptionView = NSTextView()
    private let stageButton = NSButton(title: "Stage Selected Lines", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let sourceControlStatusLabel = NSTextField(labelWithString: "")
    private var root = FileNode.directory(name: "", relativePath: "", url: URL(fileURLWithPath: "/"), children: [])
    private var outlineRoot = FileNode.directory(name: "", relativePath: "", url: URL(fileURLWithPath: "/"), children: [])
    private var selectedRelativePath: String?
    private var bufferedChangePaths = Set<String>()
    private var isReloading = false
    private var stagingMode = false
    private var stageSelectionAvailable = false
    private var currentBranchName = "HEAD"
    private var sourceControlPanelHeight: NSLayoutConstraint?

    override func loadView() {
        view = NSView()
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegment = WorkspaceMode.editing.rawValue
        modeControl.segmentStyle = .texturedRounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        sidebarHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        sidebarHeader.textColor = .secondaryLabelColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsEmptySelection = true
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "Files"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        scrollView.documentView = outlineView
        view.addSubview(modeControl)
        view.addSubview(sidebarHeader)
        view.addSubview(scrollView)
        sourceControlPanel.translatesAutoresizingMaskIntoConstraints = false
        commitMessageField.translatesAutoresizingMaskIntoConstraints = false
        commitMessageField.placeholderString = "Commit summary (required)"
        commitMessageField.lineBreakMode = .byTruncatingTail
        commitDescriptionScroll.translatesAutoresizingMaskIntoConstraints = false
        commitDescriptionScroll.borderType = .bezelBorder
        commitDescriptionScroll.hasVerticalScroller = true
        commitDescriptionScroll.autohidesScrollers = true
        commitDescriptionView.isRichText = false
        commitDescriptionView.isAutomaticQuoteSubstitutionEnabled = false
        commitDescriptionView.font = .systemFont(ofSize: 12)
        commitDescriptionView.textContainerInset = NSSize(width: 5, height: 5)
        commitDescriptionView.string = ""
        commitDescriptionScroll.documentView = commitDescriptionView
        stageButton.translatesAutoresizingMaskIntoConstraints = false
        stageButton.bezelStyle = .rounded
        stageButton.controlSize = .small
        stageButton.target = self
        stageButton.action = #selector(stageSelected(_:))
        stageButton.isEnabled = false
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.target = self
        commitButton.action = #selector(commit(_:))
        sourceControlStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceControlStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sourceControlStatusLabel.textColor = .secondaryLabelColor
        sourceControlStatusLabel.lineBreakMode = .byTruncatingTail
        sourceControlPanel.addSubview(commitMessageField)
        sourceControlPanel.addSubview(commitDescriptionScroll)
        sourceControlPanel.addSubview(stageButton)
        sourceControlPanel.addSubview(commitButton)
        sourceControlPanel.addSubview(sourceControlStatusLabel)
        sourceControlPanel.isHidden = true
        view.addSubview(sourceControlPanel)
        let panelHeight = sourceControlPanel.heightAnchor.constraint(equalToConstant: 0)
        sourceControlPanelHeight = panelHeight
        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            modeControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            modeControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            modeControl.heightAnchor.constraint(equalToConstant: 25),
            sidebarHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            sidebarHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            sidebarHeader.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 5),
            sidebarHeader.heightAnchor.constraint(equalToConstant: 22),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: sourceControlPanel.topAnchor),
            sourceControlPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sourceControlPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sourceControlPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panelHeight,
            commitMessageField.leadingAnchor.constraint(equalTo: sourceControlPanel.leadingAnchor, constant: 10),
            commitMessageField.trailingAnchor.constraint(equalTo: sourceControlPanel.trailingAnchor, constant: -10),
            commitMessageField.topAnchor.constraint(equalTo: sourceControlPanel.topAnchor, constant: 10),
            commitMessageField.heightAnchor.constraint(equalToConstant: 24),
            commitDescriptionScroll.leadingAnchor.constraint(equalTo: commitMessageField.leadingAnchor),
            commitDescriptionScroll.trailingAnchor.constraint(equalTo: commitMessageField.trailingAnchor),
            commitDescriptionScroll.topAnchor.constraint(equalTo: commitMessageField.bottomAnchor, constant: 7),
            commitDescriptionScroll.heightAnchor.constraint(equalToConstant: 72),
            sourceControlStatusLabel.leadingAnchor.constraint(equalTo: commitMessageField.leadingAnchor),
            sourceControlStatusLabel.trailingAnchor.constraint(equalTo: commitMessageField.trailingAnchor),
            sourceControlStatusLabel.topAnchor.constraint(equalTo: commitDescriptionScroll.bottomAnchor, constant: 5),
            stageButton.leadingAnchor.constraint(equalTo: commitMessageField.leadingAnchor),
            stageButton.trailingAnchor.constraint(equalTo: commitMessageField.trailingAnchor),
            stageButton.topAnchor.constraint(equalTo: sourceControlStatusLabel.bottomAnchor, constant: 6),
            commitButton.leadingAnchor.constraint(equalTo: commitMessageField.leadingAnchor),
            commitButton.trailingAnchor.constraint(equalTo: commitMessageField.trailingAnchor),
            commitButton.topAnchor.constraint(equalTo: stageButton.bottomAnchor, constant: 6)
        ])
    }

    func setStageEnabled(_ enabled: Bool) {
        stageSelectionAvailable = enabled
        stageButton.isEnabled = stagingMode && enabled
    }

    func setSourceControlStatus(_ message: String) {
        sourceControlStatusLabel.stringValue = message
    }

    func setCurrentBranchName(_ branchName: String) {
        currentBranchName = branchName
        updateCommitButtonTitle()
    }

    func clearCommitMessage() {
        commitMessageField.stringValue = ""
        commitDescriptionView.string = ""
    }

    func setMode(_ mode: WorkspaceMode) {
        modeControl.selectedSegment = mode.rawValue
        stagingMode = mode == .staging
        sourceControlPanel.isHidden = !stagingMode
        sourceControlPanelHeight?.constant = stagingMode ? 210 : 0
        stageButton.isEnabled = stagingMode && stageSelectionAvailable
        load(root: root, preservingSelection: selectedRelativePath)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let mode = WorkspaceMode(rawValue: sender.selectedSegment) ?? .editing
        setMode(mode)
        onModeChanged?(mode)
    }

    func load(root: FileNode, preservingSelection selection: String? = nil, resetState: Bool = false) {
        let expandedPaths = resetState ? [] : currentExpandedPaths()
        let scrollOrigin = resetState ? .zero : scrollView.contentView.bounds.origin
        selectedRelativePath = resetState ? selection : (selection ?? selectedRelativePath)
        self.root = root
        outlineRoot = stagingMode ? root.flattenedChanges(additionalPaths: bufferedChangePaths) : root
        sidebarHeader.stringValue = stagingMode ? "Changes  \(outlineRoot.changedFileCount)" : "Files"
        updateCommitButtonTitle()
        isReloading = true
        outlineView.reloadData()
        restoreExpandedPaths(expandedPaths)
        var selectedNode: FileNode?
        if let selectedRelativePath, let node = outlineRoot.find(relativePath: selectedRelativePath), !node.isDirectory {
            selectedNode = node
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if stagingMode, let firstFile = outlineRoot.firstFile {
            selectedRelativePath = firstFile.relativePath
            selectedNode = firstFile
            let row = outlineView.row(forItem: firstFile)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollView.contentView.scroll(to: scrollOrigin)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
        isReloading = false
        if stagingMode, let selectedNode {
            DispatchQueue.main.async { [weak self] in
                self?.onSelection?(selectedNode)
            }
        }
    }

    func setBufferedChangePaths(_ paths: Set<String>) {
        bufferedChangePaths = paths
        guard isViewLoaded else { return }
        if stagingMode {
            load(root: root, preservingSelection: selectedRelativePath)
            return
        }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else {
                continue
            }
            cell.setShowsBufferedChange(paths.contains(node.relativePath) && !node.isDirectory)
        }
    }

    @discardableResult
    func selectFile(relativePath: String) -> Bool {
        guard isViewLoaded,
              let node = outlineRoot.find(relativePath: relativePath),
              !node.isDirectory else { return false }
        isReloading = true
        defer { isReloading = false }
        expandAncestors(of: relativePath, in: outlineRoot)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        selectedRelativePath = relativePath
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode ?? outlineRoot).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileNode ?? outlineRoot).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = FileCellView()
        cell.configure(
            node: node,
            showsRepositoryDot: showsDot(for: node),
            showsBufferedChange: bufferedChangePaths.contains(node.relativePath) && !node.isDirectory
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        selectedRelativePath = node.relativePath
        if !node.isDirectory {
            onSelection?(node)
        }
    }

    @objc private func outlineRowClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0,
              let node = sender.item(atRow: row) as? FileNode,
              node.isDirectory else { return }

        if let event = NSApp.currentEvent, event.type == .leftMouseUp {
            let point = sender.convert(event.locationInWindow, from: nil)
            // The disclosure triangle already toggles itself; only toggle when
            // the user clicks the rest of the folder row.
            if sender.frameOfOutlineCell(atRow: row).contains(point) || event.clickCount > 1 {
                return
            }
        }

        if sender.isItemExpanded(node) {
            sender.collapseItem(node)
        } else {
            sender.expandItem(node)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        outlineView.reloadItem(node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        outlineView.reloadItem(node)
    }

    private func showsDot(for node: FileNode) -> Bool {
        guard node.hasUnstagedChange else { return false }
        if node.isDirectory {
            return !outlineView.isItemExpanded(node)
        }
        return true
    }

    private func currentExpandedPaths() -> Set<String> {
        var paths = Set<String>()
        collectExpandedPaths(from: outlineRoot, into: &paths)
        return paths
    }

    private func collectExpandedPaths(from node: FileNode, into paths: inout Set<String>) {
        for child in node.children where child.isDirectory {
            if outlineView.isItemExpanded(child) {
                paths.insert(child.relativePath)
                collectExpandedPaths(from: child, into: &paths)
            }
        }
    }

    private func restoreExpandedPaths(_ paths: Set<String>) {
        for path in paths.sorted(by: { $0.count < $1.count }) {
            if let node = outlineRoot.find(relativePath: path), node.isDirectory {
                outlineView.expandItem(node)
            }
        }
    }

    private func expandAncestors(of relativePath: String, in node: FileNode) {
        for child in node.children where child.isDirectory {
            let containsTarget = relativePath == child.relativePath
                || relativePath.hasPrefix(child.relativePath + "/")
            guard containsTarget else { continue }
            outlineView.expandItem(child)
            expandAncestors(of: relativePath, in: child)
            return
        }
    }

    private func updateCommitButtonTitle() {
        commitButton.title = "Commit selected changes to \(currentBranchName)"
    }

    @objc private func stageSelected(_ sender: Any?) {
        onStageSelected?()
    }

    @objc private func commit(_ sender: Any?) {
        let summary = commitMessageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = commitDescriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? summary : "\(summary)\n\n\(description)"
        onCommit?(message)
    }
}

final class FileCellView: NSTableCellView {
    private let repositoryDot = NSView()
    private let bufferedChangeDot = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        repositoryDot.translatesAutoresizingMaskIntoConstraints = false
        repositoryDot.wantsLayer = true
        repositoryDot.layer?.cornerRadius = 4
        bufferedChangeDot.translatesAutoresizingMaskIntoConstraints = false
        bufferedChangeDot.wantsLayer = true
        bufferedChangeDot.layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(repositoryDot)
        addSubview(label)
        addSubview(bufferedChangeDot)
        NSLayoutConstraint.activate([
            repositoryDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            repositoryDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            repositoryDot.widthAnchor.constraint(equalToConstant: 8),
            repositoryDot.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: repositoryDot.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bufferedChangeDot.leadingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            bufferedChangeDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bufferedChangeDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            bufferedChangeDot.widthAnchor.constraint(equalToConstant: 8),
            bufferedChangeDot.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(node: FileNode, showsRepositoryDot: Bool, showsBufferedChange: Bool) {
        label.stringValue = node.name
        repositoryDot.layer?.backgroundColor = showsRepositoryDot ? NSColor.systemOrange.cgColor : NSColor.clear.cgColor
        setShowsBufferedChange(showsBufferedChange)
    }

    func setShowsBufferedChange(_ showsBufferedChange: Bool) {
        bufferedChangeDot.layer?.backgroundColor = showsBufferedChange ? NSColor.lightGray.cgColor : NSColor.clear.cgColor
    }
}
