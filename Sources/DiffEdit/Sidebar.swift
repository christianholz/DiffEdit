import AppKit
import Foundation

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelection: ((FileNode) -> Void)?
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var root = FileNode.directory(name: "", relativePath: "", url: URL(fileURLWithPath: "/"), children: [])
    private var selectedRelativePath: String?
    private var bufferedChangePaths = Set<String>()
    private var isReloading = false

    override func loadView() {
        view = NSView()
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
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func load(root: FileNode, preservingSelection selection: String? = nil, resetState: Bool = false) {
        let expandedPaths = resetState ? [] : currentExpandedPaths()
        let scrollOrigin = resetState ? .zero : scrollView.contentView.bounds.origin
        selectedRelativePath = resetState ? selection : (selection ?? selectedRelativePath)
        self.root = root
        isReloading = true
        outlineView.reloadData()
        restoreExpandedPaths(expandedPaths)
        if let selectedRelativePath, let node = root.find(relativePath: selectedRelativePath) {
            let row = outlineView.row(forItem: node)
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
    }

    func setBufferedChangePaths(_ paths: Set<String>) {
        bufferedChangePaths = paths
        guard isViewLoaded else { return }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? FileNode,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else {
                continue
            }
            cell.setShowsBufferedChange(paths.contains(node.relativePath) && !node.isDirectory)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileNode ?? root).children[index]
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
        collectExpandedPaths(from: root, into: &paths)
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
            if let node = root.find(relativePath: path), node.isDirectory {
                outlineView.expandItem(node)
            }
        }
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
