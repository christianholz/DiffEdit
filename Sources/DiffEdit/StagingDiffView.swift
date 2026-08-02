import AppKit
import Foundation

private enum StagingDiffLayout {
    static let codeLeadingWidth: CGFloat = 160
    static let trailingInset: CGFloat = 24
    static let textMeasurementSlack: CGFloat = 6
}

final class StagingDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSetChangeSelection: ((StagingChangeID, Bool) -> Void)?

    private let header = NSTextField(labelWithString: "No changed file selected")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let diffColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
    private let placeholder = NSTextField(labelWithString: "Select a changed file to review its diff.")
    private var rows: [StagingDiffRow] = []
    private var selectedChanges = Set<StagingChangeID>()
    private var preferredTableWidth: CGFloat = 0
    private var paintSession: PaintSession?

    private struct PaintSession {
        let targetSelected: Bool
        var visitedChanges = Set<StagingChangeID>()
        var lastRow: Int
    }

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
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        diffColumn.minWidth = 0
        diffColumn.resizingMask = []
        tableView.addTableColumn(diffColumn)
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

    override func layout() {
        super.layout()
        updateTableWidth()
    }

    func setDocument(filePath: String?, rows: [StagingDiffRow], selectedChanges: Set<StagingChangeID>) {
        paintSession = nil
        header.stringValue = filePath ?? "No changed file selected"
        self.rows = rows
        self.selectedChanges = selectedChanges
        preferredTableWidth = preferredWidth(for: rows)
        placeholder.isHidden = !rows.isEmpty
        tableView.reloadData()
        needsLayout = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
            self?.setSelection(!((self?.selectedChanges.contains(id)) ?? false), for: id, row: row)
        }
        view.onPaintBegan = { [weak self] event in
            self?.beginPaint(atRow: self?.tableRow(at: event) ?? -1) ?? false
        }
        view.onPaintContinued = { [weak self] event in
            guard let self else { return }
            self.continuePaint(toRow: self.tableRow(at: event))
        }
        view.onPaintEnded = { [weak self] in
            self?.endPaint()
        }
        return view
    }

    @discardableResult
    func beginPaint(atRow row: Int) -> Bool {
        guard let id = rows[safe: row]?.selectionID else { return false }
        let targetSelected = !selectedChanges.contains(id)
        paintSession = PaintSession(targetSelected: targetSelected, lastRow: row)
        applyPaint(toRow: row)
        return true
    }

    func continuePaint(toRow row: Int) {
        guard let session = paintSession,
              rows.indices.contains(row) else { return }
        let range = min(session.lastRow, row)...max(session.lastRow, row)
        for crossedRow in range {
            applyPaint(toRow: crossedRow)
        }
        paintSession?.lastRow = row
    }

    func endPaint() {
        paintSession = nil
    }

    private func applyPaint(toRow row: Int) {
        guard var session = paintSession,
              let id = rows[safe: row]?.selectionID,
              session.visitedChanges.insert(id).inserted else { return }
        paintSession = session
        setSelection(session.targetSelected, for: id, row: row)
    }

    private func setSelection(_ selected: Bool, for id: StagingChangeID, row: Int) {
        if selected {
            selectedChanges.insert(id)
        } else {
            selectedChanges.remove(id)
        }
        if let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? StagingDiffRowView {
            rowView.setSelected(selected)
        }
        onSetChangeSelection?(id, selected)
    }

    private func tableRow(at event: NSEvent) -> Int {
        tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
    }

    private func preferredWidth(for rows: [StagingDiffRow]) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]
        let longestCodeWidth = rows.reduce(CGFloat.zero) { width, row in
            max(width, (row.text as NSString).size(withAttributes: attributes).width)
        }
        return ceil(
            StagingDiffLayout.codeLeadingWidth
                + longestCodeWidth
                + StagingDiffLayout.trailingInset
                + StagingDiffLayout.textMeasurementSlack
        )
    }

    private func updateTableWidth() {
        let width = max(scrollView.contentSize.width, preferredTableWidth)
        guard width > 0, abs(diffColumn.width - width) > 0.5 else { return }
        diffColumn.width = width
    }
}

private final class StagingDiffRowView: NSTableCellView {
    var onToggle: (() -> Void)?
    var onPaintBegan: ((NSEvent) -> Bool)?
    var onPaintContinued: ((NSEvent) -> Void)?
    var onPaintEnded: (() -> Void)?

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let oldLine = NSTextField(labelWithString: "")
    private let newLine = NSTextField(labelWithString: "")
    private let sign = NSTextField(labelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private var rowKind = StagingDiffRowKind.context
    private var isChangeSelected: Bool?

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
            code.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -StagingDiffLayout.trailingInset),
            code.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(row: StagingDiffRow, selected: Bool?) {
        rowKind = row.kind
        isChangeSelected = selected
        checkbox.isHidden = selected == nil
        checkbox.state = selected == true ? .on : .off
        oldLine.stringValue = row.oldLineNumber.map(String.init) ?? ""
        newLine.stringValue = row.newLineNumber.map(String.init) ?? ""
        code.stringValue = row.text
        code.textColor = .labelColor
        switch row.kind {
        case .context:
            sign.stringValue = ""
        case .deletion:
            sign.stringValue = "−"
            sign.textColor = .systemRed
        case .insertion:
            sign.stringValue = "+"
            sign.textColor = .systemGreen
        case .separator:
            checkbox.isHidden = true
            oldLine.stringValue = ""
            newLine.stringValue = ""
            sign.stringValue = ""
            code.textColor = .secondaryLabelColor
        }
        updateBackground()
    }

    func setSelected(_ selected: Bool) {
        isChangeSelected = selected
        checkbox.state = selected ? .on : .off
        updateBackground()
    }

    private func updateBackground() {
        switch rowKind {
        case .context:
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        case .deletion:
            let alpha: CGFloat = isChangeSelected == true ? 0.16 : 0.07
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(alpha).cgColor
        case .insertion:
            let alpha: CGFloat = isChangeSelected == true ? 0.16 : 0.07
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(alpha).cgColor
        case .separator:
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !checkbox.isHidden, checkbox.frame.contains(point) {
            return checkbox.hitTest(convert(point, to: checkbox))
        }
        return bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard onPaintBegan?(event) == true else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onPaintContinued?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onPaintEnded?()
    }

    @objc private func toggle(_ sender: Any?) {
        onToggle?()
    }
}
