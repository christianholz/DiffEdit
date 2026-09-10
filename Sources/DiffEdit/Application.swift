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

final class AppDelegate: NSObject, NSApplicationDelegate, AppCommands, NSMenuItemValidation {
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
        let controllers = windowControllersByPath.values.sorted { $0.folderURL.path < $1.folderURL.path }
        func confirmNext(_ index: Int) {
            guard index < controllers.count else {
                terminationApproved = true
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            guard let window = controllers[index].window else { confirmNext(index + 1); return }
            controllers[index].mainViewController.requestClose(window: window) { approved in
                if approved { confirmNext(index + 1) }
                else { sender.reply(toApplicationShouldTerminate: false) }
            }
        }
        DispatchQueue.main.async { confirmNext(0) }
        return .terminateLater
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

    func findText(_ sender: Any?) { activeMainController?.findText(sender) }
    func findNext(_ sender: Any?) { activeMainController?.findNext(sender) }
    func findPrevious(_ sender: Any?) { activeMainController?.findPrevious(sender) }
    func replaceText(_ sender: Any?) { activeMainController?.replaceText(sender) }

    func restorePrevious(_ sender: Any?) { activeMainController?.restorePrevious(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(AppCommands.restorePrevious(_:)) {
            return activeMainController?.canRestorePrevious == true
        }
        return true
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

    func previousChangedFile(_ sender: Any?) { activeMainController?.previousChangedFile(sender) }
    func nextChangedFile(_ sender: Any?) { activeMainController?.nextChangedFile(sender) }

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
        let application = NSApplication.shared
        application.mainMenu = mainMenu
        let appDelegate = application.delegate as AnyObject?

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
        for (title, action, key, modifiers) in [
            ("Find…", #selector(AppCommands.findText(_:)), "f", NSEvent.ModifierFlags.command),
            ("Find Next", #selector(AppCommands.findNext(_:)), "g", NSEvent.ModifierFlags.command),
            ("Find Previous", #selector(AppCommands.findPrevious(_:)), "g", NSEvent.ModifierFlags([.command, .shift])),
            ("Replace…", #selector(AppCommands.replaceText(_:)), "f", NSEvent.ModifierFlags([.command, .option]))
        ] {
            let item = editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = appDelegate
        }

        editMenu.addItem(.separator())
        let restoreItem = editMenu.addItem(withTitle: "Restore previous", action: #selector(AppCommands.restorePrevious(_:)), keyEquivalent: "d")
        restoreItem.keyEquivalentModifierMask = [.command]
        restoreItem.target = appDelegate

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
        mainMenu.insertItem(navigateItem, at: mainMenu.index(of: windowItem))
        let navigateMenu = NSMenu(title: "Go")
        navigateItem.submenu = navigateMenu
        let quickOpenItem = navigateMenu.addItem(withTitle: "Quick Open…", action: #selector(AppCommands.quickOpen(_:)), keyEquivalent: "t")
        quickOpenItem.target = appDelegate
        navigateMenu.addItem(.separator())
        let previousChange = navigateMenu.addItem(withTitle: "Previous Change", action: #selector(AppCommands.previousChange(_:)), keyEquivalent: "[")
        previousChange.keyEquivalentModifierMask = [.command]
        previousChange.target = appDelegate
        let nextChange = navigateMenu.addItem(withTitle: "Next Change", action: #selector(AppCommands.nextChange(_:)), keyEquivalent: "]")
        nextChange.keyEquivalentModifierMask = [.command]
        nextChange.target = appDelegate
        let previousFile = navigateMenu.addItem(withTitle: "Previous Changed File", action: #selector(AppCommands.previousChangedFile(_:)), keyEquivalent: "[")
        previousFile.keyEquivalentModifierMask = [.command, .option]
        previousFile.target = appDelegate
        let nextFile = navigateMenu.addItem(withTitle: "Next Changed File", action: #selector(AppCommands.nextChangedFile(_:)), keyEquivalent: "]")
        nextFile.keyEquivalentModifierMask = [.command, .option]
        nextFile.target = appDelegate
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
    func restorePrevious(_ sender: Any?)
    func findText(_ sender: Any?)
    func findNext(_ sender: Any?)
    func findPrevious(_ sender: Any?)
    func replaceText(_ sender: Any?)
    func openFolder(_ sender: Any?)
    func saveDocument(_ sender: Any?)
    func toggleWordWrap(_ sender: Any?)
    func increaseFontSize(_ sender: Any?)
    func decreaseFontSize(_ sender: Any?)
    func quickOpen(_ sender: Any?)
    func previousChangedFile(_ sender: Any?)
    func nextChangedFile(_ sender: Any?)
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
        mainViewController.refreshAfterBecomingKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        mainViewController.captureBeforeResigningKey()
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.removeWindowController(for: folderURL.path)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if (NSApp.delegate as? AppDelegate)?.terminationApproved == true {
            return true
        }
        mainViewController.requestClose(window: sender) { approved in
            if approved { sender.close() }
        }
        return false
    }
}

final class MainViewController: NSSplitViewController, AppCommands {
    private let sidebar = SidebarViewController()
    private let editor = EditorViewController()
    private let activationRefreshQueue = DispatchQueue(
        label: "com.diffedit.window-refresh",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let repositoryOperationQueue = DispatchQueue(label: "com.diffedit.repository-operations", qos: .userInitiated)
    private var commitOverlay: NSView?
    private var isCommitting = false

    private var repository: Repository?
    private var quickOpenController: QuickOpenController?
    private var activationRefreshGeneration = 0
    private var folderLoadGeneration = 0

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
        sidebar.onModeChanged = { [weak self] mode in
            guard let self else { return }
            self.editor.setMode(mode)
            self.refreshRepositoryStatus()
        }
        editor.resolveExternalFileConflict = { [weak self] conflict in
            self?.resolveExternalFileConflict(conflict) ?? .cancel
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
        guard !isCommitting else { return }
        editor.saveCurrentFileAsync { [weak self] result in
            if case let .failure(error) = result {
                if case EditorFileError.cancelled = error { return }
                self?.presentError(error, title: "Couldn’t Save File")
            }
        }
    }

    func findText(_ sender: Any?) { guard !isCommitting else { return }; editor.showSearch(replacing: false) }
    func findNext(_ sender: Any?) { guard !isCommitting else { return }; editor.findMatch(backwards: false) }
    func findPrevious(_ sender: Any?) { guard !isCommitting else { return }; editor.findMatch(backwards: true) }
    func replaceText(_ sender: Any?) { guard !isCommitting else { return }; editor.showSearch(replacing: true) }

    func toggleWordWrap(_ sender: Any?) {
        guard !isCommitting else { return }
        editor.toggleWordWrap()
    }

    func increaseFontSize(_ sender: Any?) {
        guard !isCommitting else { return }
        editor.adjustFontSize(by: 1)
    }

    func decreaseFontSize(_ sender: Any?) {
        guard !isCommitting else { return }
        editor.adjustFontSize(by: -1)
    }

    var canRestorePrevious: Bool { !isCommitting && editor.canRestorePrevious }

    func restorePrevious(_ sender: Any?) {
        guard !isCommitting else { return }
        editor.restorePrevious(sender)
    }

    func quickOpen(_ sender: Any?) {
        guard !isCommitting else { return }
        guard let repository else { return }
        if let controller = quickOpenController {
            controller.showWindow(nil)
            return
        }
        let controller = QuickOpenController(files: [], onClose: { [weak self] in
            self?.quickOpenController = nil
        }) { [weak self] file in
            guard let self else { return }
            self.openFile(relativePath: file.relativePath, url: file.url)
        }
        quickOpenController = controller
        activationRefreshQueue.async { [weak self, weak controller] in
            let files = repository.allFiles()
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller,
                      self.repository === repository,
                      self.quickOpenController === controller else { return }
                controller.setFiles(files)
            }
        }
        if let window = view.window {
            controller.show(relativeTo: window)
        } else {
            controller.showWindow(nil)
        }
    }

    func previousChangedFile(_ sender: Any?) {
        guard !isCommitting else { return }
        navigateChange(.previous, skipCurrentFile: true)
    }

    func nextChangedFile(_ sender: Any?) {
        guard !isCommitting else { return }
        navigateChange(.next, skipCurrentFile: true)
    }

    func previousParagraph(_ sender: Any?) {
        guard !isCommitting else { return }
        editor.jumpParagraph(up: true)
    }

    func nextParagraph(_ sender: Any?) {
        guard !isCommitting else { return }
        editor.jumpParagraph(up: false)
    }

    func previousChange(_ sender: Any?) {
        guard !isCommitting else { return }
        navigateChange(.previous)
    }

    func nextChange(_ sender: Any?) {
        guard !isCommitting else { return }
        navigateChange(.next)
    }

    func requestClose(window: NSWindow, completion: @escaping (Bool) -> Void) {
        guard !isCommitting, !editor.isSaving else { completion(false); return }
        guard editor.hasUnsavedChanges else { completion(true); return }
        let count = editor.unsavedFileCount
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Save changes to 1 file?" : "Save changes to \(count) files?"
        alert.informativeText = "Your buffered changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            editor.saveAllFilesAsync { [weak self] result in
                switch result {
                case .success:
                    // Edits made while saving must not disappear on close.
                    completion(self?.editor.hasUnsavedChanges == false)
                case let .failure(error):
                    if case EditorFileError.cancelled = error {} else {
                        self?.presentError(error, title: "Couldn’t Save All Files")
                    }
                    completion(false)
                }
            }
        } else {
            completion(response != .alertSecondButtonReturn)
        }
    }

    func refreshRepositoryStatus() {
        guard !isCommitting else { return }
        invalidateActivationRefresh()
        guard let repository else { return }
        let generation = activationRefreshGeneration
        activationRefreshQueue.async { [weak self] in
            let snapshot = repository.statusSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.repository === repository,
                      self.activationRefreshGeneration == generation else { return }
                repository.apply(snapshot)
                self.sidebar.setCurrentBranchName(snapshot.branchName)
                self.sidebar.load(root: snapshot.tree, preservingSelection: self.editor.currentDocumentPath)
            }
        }
    }

    func captureBeforeResigningKey() {
        invalidateActivationRefresh()
        editor.captureForegroundState()
    }

    func refreshAfterBecomingKey() {
        guard !isCommitting, let repository else { return }
        invalidateActivationRefresh()
        let generation = activationRefreshGeneration
        let fileRequest = editor.foregroundFileRefreshRequest()
        activationRefreshQueue.async { [weak self, weak repository] in
            guard let self, let repository else { return }
            let status = repository.statusSnapshot()
            let fileRefresh: Result<PreparedForegroundFileRefresh?, Error> = Result {
                guard let fileRequest else { return nil as PreparedForegroundFileRefresh? }
                return try PreparedForegroundFileRefresh.load(
                    request: fileRequest,
                    repository: repository
                )
            }
            DispatchQueue.main.async { [weak self, weak repository] in
                guard let self,
                      let repository,
                      self.repository === repository,
                      self.activationRefreshGeneration == generation,
                      self.view.window?.isKeyWindow == true else { return }
                repository.apply(status)
                self.sidebar.setCurrentBranchName(status.branchName)
                self.sidebar.load(
                    root: status.tree,
                    preservingSelection: self.editor.currentDocumentPath
                )
                switch fileRefresh {
                case let .success(prepared):
                    if let prepared {
                        _ = self.editor.apply(prepared)
                    } else {
                        self.editor.finishForegroundRefreshWithoutFileChange(fileRequest)
                    }
                case let .failure(error):
                    self.presentError(error, title: "Couldn’t Refresh File")
                }
            }
        }
    }

    func loadFolder(_ url: URL) {
        invalidateActivationRefresh()
        folderLoadGeneration += 1
        let generation = folderLoadGeneration
        repository = nil
        sidebar.setLoading(true)
        editor.showPlaceholder("Loading \(url.lastPathComponent)…")
        view.window?.title = "DiffEdit - \(url.path)"
        let started = PerformanceTiming.start()
        activationRefreshQueue.async { [weak self] in
            let repo = Repository(rootURL: url)
            let snapshot = repo.statusSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.folderLoadGeneration == generation else { return }
                self.invalidateActivationRefresh()
                self.repository = repo
                repo.apply(snapshot)
                self.sidebar.setCurrentBranchName(snapshot.branchName)
                let sidebarStarted = PerformanceTiming.start()
                self.sidebar.load(root: snapshot.tree, resetState: true)
                self.sidebar.setLoading(false)
                PerformanceTiming.finish("initial sidebar load", since: sidebarStarted)
                self.editor.showPlaceholder("Select a file from \(url.lastPathComponent).")
                PerformanceTiming.finish("folder open", since: started)
            }
        }
    }

    private func open(node: FileNode) {
        guard !node.isDirectory, repository != nil else { return }
        openFile(relativePath: node.relativePath, url: node.url)
    }

    @discardableResult
    private func openFile(relativePath: String, url: URL, completion: (() -> Void)? = nil) -> Bool {
        guard let repository, !isCommitting else { return false }
        invalidateActivationRefresh()
        editor.openAsync(file: url, relativePath: relativePath, repository: repository, onSaved: { [weak self] in
            self?.refreshRepositoryStatus()
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(true):
                self.sidebar.selectFile(relativePath: relativePath)
                completion?()
            case .success(false):
                if let path = self.editor.currentDocumentPath { self.sidebar.selectFile(relativePath: path) }
            case let .failure(error):
                self.presentError(error, title: "Couldn’t Open File")
            }
        }
        return true
    }

    private func navigateChange(_ direction: ChangeNavigationDirection, skipCurrentFile: Bool = false) {
        guard let repository else { return }
        invalidateActivationRefresh()
        if !skipCurrentFile, editor.navigateToAdjacentChange(direction, animated: true) {
            return
        }

        let generation = activationRefreshGeneration
        let previousPath = editor.currentDocumentPath
        let bufferedPaths = editor.changedDocumentPaths
        activationRefreshQueue.async { [weak self] in
            let snapshot = repository.statusSnapshot()
            let changedPaths = snapshot.unstagedPaths.union(bufferedPaths)
            let changedFiles = snapshot.tree.filesInDisplayOrder.filter { changedPaths.contains($0.relativePath) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.repository === repository,
                      self.activationRefreshGeneration == generation,
                      !self.isCommitting else { return }
                repository.apply(snapshot)
                self.sidebar.setCurrentBranchName(snapshot.branchName)
                guard let targetPath = ChangedFileNavigator.adjacentPath(
                    in: changedFiles.map(\.relativePath), from: previousPath, direction: direction
                ), let target = changedFiles.first(where: { $0.relativePath == targetPath }),
                   !skipCurrentFile || targetPath != previousPath else { return }
                _ = self.openFile(relativePath: targetPath, url: target.url) { [weak self] in
                    _ = self?.editor.navigateToEdgeChange(direction, animated: targetPath == previousPath)
                }
            }
        }
    }

    private func stageSelectedChanges() {
        guard !isCommitting, let repository else { return }
        invalidateActivationRefresh()
        do {
            try editor.stageSelectedChanges(using: repository)
            repository.refreshStatus()
            sidebar.setCurrentBranchName(repository.currentBranchName)
            sidebar.load(root: repository.makeTree())
            sidebar.setSourceControlStatus("Selected lines staged")
        } catch {
            presentError(error, title: "Couldn’t Stage Changes")
        }
    }

    private func commit(message: String) {
        guard let repository, !isCommitting else { return }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentError(RepositoryError.emptyCommitMessage, title: "Couldn’t Commit")
            return
        }
        invalidateActivationRefresh()
        let captured = editor.commitSnapshot()
        setCommitBusy(true)
        repositoryOperationQueue.async { [weak self] in
            let result = Result { () -> (String, RepositoryStatusSnapshot, [String: String]) in
                let representedPaths = Set(repository.makeTree().filesInDisplayOrder.map(\.relativePath))
                let invisible = try repository.invisibleStagedPaths(representedUIPaths: representedPaths)
                guard invisible.isEmpty else { throw RepositoryError.invisibleStagedChanges(invisible) }
                if let buffer = captured.buffer {
                    let plan = DiffEngine.selectiveStagingPlan(base: buffer.baseText, current: buffer.text)
                    if !plan.selectableChanges.isEmpty {
                        let selected = captured.selected.intersection(plan.selectableChanges)
                            .union(plan.selectableChanges.subtracting(captured.available))
                        try repository.stage(text: plan.text(selectedChanges: selected), relativePath: buffer.relativePath)
                    }
                }
                let output = try repository.commit(message: message)
                let snapshot = repository.statusSnapshot()
                var bases: [String: String] = [:]
                for path in captured.paths { bases[path] = repository.committedText(relativePath: path) ?? "" }
                return (output, snapshot, bases)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.invalidateActivationRefresh()
                self.setCommitBusy(false)
                switch result {
                case let .success((output, snapshot, bases)):
                    repository.apply(snapshot)
                    self.editor.applyCommittedBases(bases)
                    self.sidebar.setCurrentBranchName(snapshot.branchName)
                    self.sidebar.load(root: snapshot.tree, preservingSelection: self.editor.currentDocumentPath)
                    self.sidebar.clearCommitMessage()
                    self.sidebar.setSourceControlStatus(output.split(separator: "\n").first.map(String.init) ?? "Commit created")
                case let .failure(error):
                    self.refreshRepositoryStatus()
                    self.presentError(error, title: "Couldn’t Commit")
                }
            }
        }
    }

    private func setCommitBusy(_ busy: Bool) {
        isCommitting = busy
        editor.setOperationBusy(busy)
        if !busy {
            commitOverlay?.removeFromSuperview()
            commitOverlay = nil
            return
        }
        let overlay = NSVisualEffectView()
        overlay.material = .sheet
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.translatesAutoresizingMaskIntoConstraints = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Committing…")
        let content = NSStackView(views: [spinner, label])
        content.orientation = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(content)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])
        commitOverlay = overlay
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }

    private func invalidateActivationRefresh() {
        activationRefreshGeneration &+= 1
    }

    private func resolveExternalFileConflict(_ conflict: ExternalFileConflict) -> ExternalFileResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = conflict.fileWasDeleted
            ? "\(conflict.relativePath) was deleted outside DiffEdit."
            : "\(conflict.relativePath) changed outside DiffEdit."
        if conflict.operation == .saving {
            alert.informativeText = "Saving your buffered version will overwrite the external change."
            alert.addButton(withTitle: conflict.fileWasDeleted ? "Recreate File" : "Overwrite")
        } else {
            alert.informativeText = "Choose whether to keep your buffered version or reload the file from disk."
            alert.addButton(withTitle: "Keep My Changes")
        }
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .keepBuffer
        case .alertSecondButtonReturn:
            return .reloadFromDisk
        default:
            return .cancel
        }
    }
}
