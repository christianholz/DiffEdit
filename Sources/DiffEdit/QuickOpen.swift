import AppKit
import Foundation

struct FileReference {
    let relativePath: String
    let url: URL
}

final class QuickOpenController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let allFiles: [FileReference]
    private var filteredFiles: [FileReference]
    private let onClose: () -> Void
    private let onOpen: (FileReference) -> Void
    private let searchField = QuickOpenSearchField()
    private let tableView = NSTableView()

    init(files: [FileReference], onClose: @escaping () -> Void, onOpen: @escaping (FileReference) -> Void) {
        self.allFiles = files
        self.filteredFiles = files
        self.onClose = onClose
        self.onOpen = onOpen
        let panel = QuickOpenPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Open"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = true
        panel.minSize = NSSize(width: 560, height: 320)
        panel.setContentSize(NSSize(width: 720, height: 460))
        super.init(window: panel)
        panel.delegate = self
        panel.quickOpenController = self
        panel.contentViewController = QuickOpenContentController(searchField: searchField, tableView: tableView)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(searchField)
    }

    func show(relativeTo parent: NSWindow) {
        guard let window else { return }
        let parentFrame = parent.frame
        let size = window.frame.size
        let origin = NSPoint(
            x: parentFrame.midX - size.width / 2,
            y: parentFrame.maxY - size.height - 80
        )
        window.setFrameOrigin(origin)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < filteredFiles.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("QuickOpenCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.lineBreakMode = .byTruncatingMiddle
        cell.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.stringValue = filteredFiles[row].relativePath
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if tableView.selectedRow < 0, !filteredFiles.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func moveSelection(delta: Int) {
        guard !filteredFiles.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = max(0, min(filteredFiles.count - 1, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func acceptSelection() {
        guard !filteredFiles.isEmpty else { return }
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let file = filteredFiles[row]
        closeSheet()
        onOpen(file)
    }

    func closeSheet() {
        close()
    }

    private func configure() {
        searchField.delegate = self
        searchField.quickOpenController = self
        searchField.placeholderString = "Open file"
        window?.initialFirstResponder = searchField
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 24
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        column.width = 700
        tableView.addTableColumn(column)
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickOpen)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    @objc private func doubleClickOpen() {
        acceptSelection()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredFiles = allFiles
        } else {
            let parts = query.split(separator: " ").map(String.init)
            filteredFiles = allFiles.filter { file in
                let path = file.relativePath.lowercased()
                return parts.allSatisfy { path.contains($0) }
            }
        }
        tableView.reloadData()
        if !filteredFiles.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }
}

final class QuickOpenPanel: NSPanel {
    weak var quickOpenController: QuickOpenController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 125:
                quickOpenController?.moveSelection(delta: 1)
                return
            case 126:
                quickOpenController?.moveSelection(delta: -1)
                return
            case 36, 76:
                quickOpenController?.acceptSelection()
                return
            case 53:
                quickOpenController?.closeSheet()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

final class QuickOpenSearchField: NSSearchField {
    weak var quickOpenController: QuickOpenController?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            quickOpenController?.moveSelection(delta: 1)
        case 126:
            quickOpenController?.moveSelection(delta: -1)
        case 36:
            quickOpenController?.acceptSelection()
        case 53:
            quickOpenController?.closeSheet()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        quickOpenController?.closeSheet()
    }
}

final class QuickOpenContentController: NSViewController {
    private let searchField: QuickOpenSearchField
    private let tableView: NSTableView

    init(searchField: QuickOpenSearchField, tableView: NSTableView) {
        self.searchField = searchField
        self.tableView = tableView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        let scrollView = NSScrollView()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        view.addSubview(searchField)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
    }
}
