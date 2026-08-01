import AppKit
import Foundation

@main
enum DiffEditApplication {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AppCommands {
    private var windowControllersByPath: [String: WindowController] = [:]
    private let recentFoldersKey = "RecentFolders"
    private(set) var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests launch the application executable. Avoid presenting
        // the modal folder picker before XCTest has a chance to run.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSApp.setActivationPolicy(.regular)
        MainMenu.install()
        MainMenu.updateRecentFolders(recentFolderPaths)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.openFolder(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in windowControllersByPath.values.sorted(by: { $0.folderURL.path < $1.folderURL.path }) {
            guard let window = controller.window,
                  controller.mainViewController.confirmClose(window: window) else {
                return .terminateCancel
            }
        }
        terminationApproved = true
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        activeMainController?.refreshRepositoryStatus()
    }

    func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return
        }
        openFolderWindow(url)
    }

    @objc func openRecentFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFolderWindow(URL(fileURLWithPath: path))
    }

    func saveDocument(_ sender: Any?) {
        activeMainController?.saveDocument(sender)
    }

    func toggleWordWrap(_ sender: Any?) {
        activeMainController?.toggleWordWrap(sender)
    }

    func increaseFontSize(_ sender: Any?) {
        activeMainController?.increaseFontSize(sender)
    }

    func decreaseFontSize(_ sender: Any?) {
        activeMainController?.decreaseFontSize(sender)
    }

    func quickOpen(_ sender: Any?) {
        activeMainController?.quickOpen(sender)
    }

    func previousParagraph(_ sender: Any?) {
        activeMainController?.previousParagraph(sender)
    }

    func nextParagraph(_ sender: Any?) {
        activeMainController?.nextParagraph(sender)
    }

    func previousChange(_ sender: Any?) {
        activeMainController?.previousChange(sender)
    }

    func nextChange(_ sender: Any?) {
        activeMainController?.nextChange(sender)
    }

    func removeWindowController(for path: String) {
        windowControllersByPath.removeValue(forKey: path)
    }

    private func openFolderWindow(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        if let existing = windowControllersByPath[path] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = WindowController(folderURL: standardizedURL)
        windowControllersByPath[path] = controller
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.mainViewController.loadFolder(standardizedURL)
        addRecentFolder(path)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var activeMainController: MainViewController? {
        if let keyController = NSApp.keyWindow?.windowController as? WindowController {
            return keyController.mainViewController
        }
        if let mainController = NSApp.mainWindow?.windowController as? WindowController {
            return mainController.mainViewController
        }
        return windowControllersByPath.values.first?.mainViewController
    }

    private var recentFolderPaths: [String] {
        UserDefaults.standard.stringArray(forKey: recentFoldersKey) ?? []
    }

    private func addRecentFolder(_ path: String) {
        var paths = recentFolderPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(10))
        UserDefaults.standard.set(paths, forKey: recentFoldersKey)
        MainMenu.updateRecentFolders(paths)
    }
}

enum MainMenu {
    private static let recentMenu = NSMenu(title: "Open Recent")

    static func install() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu
        let appDelegate = NSApp.delegate as AnyObject?

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About DiffEdit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DiffEdit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let openItem = fileMenu.addItem(withTitle: "Open Folder...", action: #selector(AppCommands.openFolder(_:)), keyEquivalent: "o")
        openItem.target = appDelegate
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(AppCommands.saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = appDelegate

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let quickOpenItem = editMenu.addItem(withTitle: "Quick Open...", action: #selector(AppCommands.quickOpen(_:)), keyEquivalent: "t")
        quickOpenItem.target = appDelegate

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let wrapItem = viewMenu.addItem(withTitle: "Toggle Word Wrap", action: #selector(AppCommands.toggleWordWrap(_:)), keyEquivalent: "w")
        wrapItem.keyEquivalentModifierMask = [.command, .option]
        wrapItem.target = appDelegate
        viewMenu.addItem(.separator())
        let biggerItem = viewMenu.addItem(withTitle: "Bigger", action: #selector(AppCommands.increaseFontSize(_:)), keyEquivalent: "+")
        biggerItem.target = appDelegate
        let smallerItem = viewMenu.addItem(withTitle: "Smaller", action: #selector(AppCommands.decreaseFontSize(_:)), keyEquivalent: "-")
        smallerItem.target = appDelegate

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        let navigateItem = NSMenuItem()
        mainMenu.addItem(navigateItem)
        let navigateMenu = NSMenu(title: "Navigate")
        navigateItem.submenu = navigateMenu
        let previousChange = navigateMenu.addItem(withTitle: "Previous Change", action: #selector(AppCommands.previousChange(_:)), keyEquivalent: ",")
        previousChange.keyEquivalentModifierMask = [.command, .shift]
        previousChange.target = appDelegate
        let nextChange = navigateMenu.addItem(withTitle: "Next Change", action: #selector(AppCommands.nextChange(_:)), keyEquivalent: ".")
        nextChange.keyEquivalentModifierMask = [.command, .shift]
        nextChange.target = appDelegate
        navigateMenu.addItem(.separator())
        let previousParagraph = navigateMenu.addItem(withTitle: "Previous Paragraph", action: #selector(AppCommands.previousParagraph(_:)), keyEquivalent: "\u{F700}")
        previousParagraph.keyEquivalentModifierMask = [.option]
        previousParagraph.target = appDelegate
        let nextParagraph = navigateMenu.addItem(withTitle: "Next Paragraph", action: #selector(AppCommands.nextParagraph(_:)), keyEquivalent: "\u{F701}")
        nextParagraph.keyEquivalentModifierMask = [.option]
        nextParagraph.target = appDelegate
    }

    static func updateRecentFolders(_ paths: [String]) {
        recentMenu.removeAllItems()
        let appDelegate = NSApp.delegate as AnyObject?
        if paths.isEmpty {
            let item = NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentMenu.addItem(item)
            return
        }
        for path in paths {
            let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent, action: #selector(AppDelegate.openRecentFolder(_:)), keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            item.target = appDelegate
            recentMenu.addItem(item)
        }
    }
}

@objc protocol AppCommands {
    func openFolder(_ sender: Any?)
    func saveDocument(_ sender: Any?)
    func toggleWordWrap(_ sender: Any?)
    func increaseFontSize(_ sender: Any?)
    func decreaseFontSize(_ sender: Any?)
    func quickOpen(_ sender: Any?)
    func previousParagraph(_ sender: Any?)
    func nextParagraph(_ sender: Any?)
    func previousChange(_ sender: Any?)
    func nextChange(_ sender: Any?)
}

final class WindowController: NSWindowController, NSWindowDelegate {
    let folderURL: URL
    let mainViewController: MainViewController

    init(folderURL: URL) {
        self.folderURL = folderURL
        self.mainViewController = MainViewController()
        let window = NSWindow(contentViewController: mainViewController)
        window.title = "DiffEdit - \(folderURL.path)"
        window.setContentSize(NSSize(width: 1180, height: 820))
        window.minSize = NSSize(width: 760, height: 520)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        mainViewController.refreshRepositoryStatus()
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.removeWindowController(for: folderURL.path)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if (NSApp.delegate as? AppDelegate)?.terminationApproved == true {
            return true
        }
        return mainViewController.confirmClose(window: sender)
    }
}

final class MainViewController: NSSplitViewController, AppCommands {
    private let sidebar = SidebarViewController()
    private let editor = EditorViewController()
    private var repository: Repository?
    private var quickOpenController: QuickOpenController?

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebar))
        addSplitViewItem(NSSplitViewItem(viewController: editor))
        splitViewItems[0].minimumThickness = 220
        splitViewItems[0].maximumThickness = 420
        sidebar.onSelection = { [weak self] node in
            self?.open(node: node)
        }
        editor.onBufferedChangesChanged = { [weak self] paths in
            self?.sidebar.setBufferedChangePaths(paths)
        }
        editor.onStageSelectionAvailabilityChanged = { [weak self] available in
            self?.sidebar.setStageEnabled(available)
        }
        editor.onModeChanged = { [weak self] mode in
            guard let self else { return }
            self.sidebar.setMode(mode)
            self.refreshRepositoryStatus()
        }
        sidebar.onStageSelected = { [weak self] in
            self?.stageSelectedChanges()
        }
        sidebar.onCommit = { [weak self] message in
            self?.commit(message: message)
        }
    }

    func openFolder(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openFolder(sender)
    }

    func saveDocument(_ sender: Any?) {
        do {
            try editor.saveCurrentFile()
        } catch {
            presentError(error, title: "Couldn’t Save File")
        }
    }

    func toggleWordWrap(_ sender: Any?) {
        editor.toggleWordWrap()
    }

    func increaseFontSize(_ sender: Any?) {
        editor.adjustFontSize(by: 1)
    }

    func decreaseFontSize(_ sender: Any?) {
        editor.adjustFontSize(by: -1)
    }

    func quickOpen(_ sender: Any?) {
        guard let repository else { return }
        let files = repository.allFiles()
        guard !files.isEmpty else { return }
        let controller = QuickOpenController(files: files, onClose: { [weak self] in
            self?.quickOpenController = nil
        }) { [weak self] file in
            guard let self else { return }
            self.openFile(relativePath: file.relativePath, url: file.url)
        }
        quickOpenController = controller
        if let window = view.window {
            controller.show(relativeTo: window)
        } else {
            controller.showWindow(nil)
        }
    }

    func previousParagraph(_ sender: Any?) {
        editor.jumpParagraph(up: true)
    }

    func nextParagraph(_ sender: Any?) {
        editor.jumpParagraph(up: false)
    }

    func previousChange(_ sender: Any?) {
        navigateChange(.previous)
    }

    func nextChange(_ sender: Any?) {
        navigateChange(.next)
    }

    func confirmClose(window: NSWindow) -> Bool {
        guard editor.hasUnsavedChanges else { return true }
        let count = editor.unsavedFileCount
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Save changes to 1 file?" : "Save changes to \(count) files?"
        alert.informativeText = "Your buffered changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try editor.saveAllFiles()
                return true
            } catch {
                presentError(error, title: "Couldn’t Save All Files")
                return false
            }
        }
        if response == .alertSecondButtonReturn {
            return false
        }
        return true
    }

    func refreshRepositoryStatus() {
        repository?.refreshStatus()
        if let repository {
            sidebar.setCurrentBranchName(repository.currentBranchName)
            sidebar.load(root: repository.makeTree())
        }
    }

    func loadFolder(_ url: URL) {
        let repo = Repository(rootURL: url)
        repository = repo
        repo.refreshStatus()
        sidebar.setCurrentBranchName(repo.currentBranchName)
        sidebar.load(root: repo.makeTree(), resetState: true)
        editor.showPlaceholder("Select a file from \(url.lastPathComponent).")
        view.window?.title = "DiffEdit - \(url.path)"
    }

    private func open(node: FileNode) {
        guard !node.isDirectory, repository != nil else { return }
        openFile(relativePath: node.relativePath, url: node.url)
    }

    @discardableResult
    private func openFile(relativePath: String, url: URL) -> Bool {
        guard let repository else { return false }
        if editor.isEditing(relativePath: relativePath) {
            sidebar.selectFile(relativePath: relativePath)
            return true
        }
        do {
            try editor.open(file: url, relativePath: relativePath, repository: repository) { [weak self] in
                self?.repository?.refreshStatus()
                if let repository = self?.repository {
                    self?.sidebar.load(root: repository.makeTree(), preservingSelection: relativePath)
                }
            }
            sidebar.selectFile(relativePath: relativePath)
            return true
        } catch {
            presentError(error, title: "Couldn’t Open File")
            return false
        }
    }

    private func navigateChange(_ direction: ChangeNavigationDirection) {
        guard let repository else { return }
        if editor.navigateToAdjacentChange(direction, animated: true) {
            return
        }

        repository.refreshStatus()
        let changedPaths = repository.unstagedPaths
            .union(editor.changedDocumentPaths)
        let changedFiles = repository.makeTree().filesInDisplayOrder.filter {
            changedPaths.contains($0.relativePath)
        }
        let previousPath = editor.currentDocumentPath
        guard let targetPath = ChangedFileNavigator.adjacentPath(
            in: changedFiles.map(\.relativePath),
            from: previousPath,
            direction: direction
        ), let targetFile = changedFiles.first(where: { $0.relativePath == targetPath }) else { return }

        guard openFile(relativePath: targetPath, url: targetFile.url) else { return }
        _ = editor.navigateToEdgeChange(direction, animated: targetPath == previousPath)
    }

    private func stageSelectedChanges() {
        guard let repository else { return }
        do {
            try editor.stageSelectedChanges(using: repository)
            repository.refreshStatus()
            sidebar.load(root: repository.makeTree())
            sidebar.setSourceControlStatus("Selected lines staged")
        } catch {
            presentError(error, title: "Couldn’t Stage Changes")
        }
    }

    private func commit(message: String) {
        guard let repository else { return }
        do {
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RepositoryError.emptyCommitMessage
            }
            if editor.hasStageableChanges {
                try editor.stageSelectedChanges(using: repository)
            }
            let output = try repository.commit(message: message)
            repository.refreshStatus()
            editor.refreshCommittedBases(using: repository)
            sidebar.load(root: repository.makeTree())
            sidebar.clearCommitMessage()
            let summary = output.split(separator: "\n").first.map(String.init) ?? "Commit created"
            sidebar.setSourceControlStatus(summary)
        } catch {
            presentError(error, title: "Couldn’t Commit")
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }
}
