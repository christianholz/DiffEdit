import AppKit
import Foundation

final class StagingDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onToggleChange: ((StagingChangeID) -> Void)?

    private let header = NSTextField(labelWithString: "No changed file selected")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let placeholder = NSTextField(labelWithString: "Select a changed file to review its diff.")
    private var rows: [StagingDiffRow] = []
    private var selectedChanges = Set<StagingChangeID>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        header.translatesAutoresizingMaskIntoConstraints = false
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingMiddle

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.intercellSpacing = .zero
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.width = 1400
        column.minWidth = 700
        column.resizingMask = []
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        addSubview(header)
        addSubview(scrollView)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 20),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDocument(filePath: String?, rows: [StagingDiffRow], selectedChanges: Set<StagingChangeID>) {
        header.stringValue = filePath ?? "No changed file selected"
        self.rows = rows
        self.selectedChanges = selectedChanges
        placeholder.isHidden = !rows.isEmpty
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].kind == .separator ? 30 : 22
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("StagingDiffRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? StagingDiffRowView
            ?? StagingDiffRowView()
        view.identifier = identifier
        let item = rows[row]
        view.configure(row: item, selected: item.selectionID.map(selectedChanges.contains))
        view.onToggle = { [weak self] in
            guard let id = item.selectionID else { return }
            self?.onToggleChange?(id)
        }
        return view
    }
}

private final class StagingDiffRowView: NSTableCellView {
    var onToggle: (() -> Void)?

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let oldLine = NSTextField(labelWithString: "")
    private let newLine = NSTextField(labelWithString: "")
    private let sign = NSTextField(labelWithString: "")
    private let code = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        checkbox.controlSize = .small
        oldLine.translatesAutoresizingMaskIntoConstraints = false
        newLine.translatesAutoresizingMaskIntoConstraints = false
        sign.translatesAutoresizingMaskIntoConstraints = false
        code.translatesAutoresizingMaskIntoConstraints = false
        for label in [oldLine, newLine, sign, code] {
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
        }
        oldLine.alignment = .right
        newLine.alignment = .right
        oldLine.textColor = .secondaryLabelColor
        newLine.textColor = .secondaryLabelColor
        sign.alignment = .center
        addSubview(checkbox)
        addSubview(oldLine)
        addSubview(newLine)
        addSubview(sign)
        addSubview(code)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 16),
            oldLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            oldLine.widthAnchor.constraint(equalToConstant: 48),
            oldLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            newLine.leadingAnchor.constraint(equalTo: oldLine.trailingAnchor, constant: 4),
            newLine.widthAnchor.constraint(equalToConstant: 48),
            newLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            sign.leadingAnchor.constraint(equalTo: newLine.trailingAnchor, constant: 4),
            sign.widthAnchor.constraint(equalToConstant: 18),
            sign.centerYAnchor.constraint(equalTo: centerYAnchor),
            code.leadingAnchor.constraint(equalTo: sign.trailingAnchor, constant: 8),
            code.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            code.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(row: StagingDiffRow, selected: Bool?) {
        checkbox.isHidden = selected == nil
        checkbox.state = selected == true ? .on : .off
        oldLine.stringValue = row.oldLineNumber.map(String.init) ?? ""
        newLine.stringValue = row.newLineNumber.map(String.init) ?? ""
        code.stringValue = row.text
        code.textColor = .labelColor
        switch row.kind {
        case .context:
            sign.stringValue = ""
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        case .deletion:
            sign.stringValue = "−"
            sign.textColor = .systemRed
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.16).cgColor
        case .insertion:
            sign.stringValue = "+"
            sign.textColor = .systemGreen
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
        case .separator:
            checkbox.isHidden = true
            oldLine.stringValue = ""
            newLine.stringValue = ""
            sign.stringValue = ""
            code.textColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    @objc private func toggle(_ sender: Any?) {
        onToggle?()
    }
}
