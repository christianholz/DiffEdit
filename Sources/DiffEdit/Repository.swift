import Foundation

final class Repository {
    let rootURL: URL
    private let gitRootURL: URL
    private let openedFolderGitPrefix: String
    private(set) var unstagedPaths = Set<String>()

    init(rootURL: URL) {
        self.rootURL = rootURL
        let discoveredRoot = Repository.gitOutput(in: rootURL, arguments: ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if discoveredRoot.isEmpty {
            gitRootURL = rootURL
            openedFolderGitPrefix = ""
        } else {
            gitRootURL = URL(fileURLWithPath: discoveredRoot)
            openedFolderGitPrefix = Repository.relativePath(from: URL(fileURLWithPath: discoveredRoot), to: rootURL) ?? ""
        }
    }

    func refreshStatus() {
        let modified = runGit(arguments: ["diff", "--name-only"]).output.splitLines()
        let untracked = runGit(arguments: ["ls-files", "--others", "--exclude-standard"]).output.splitLines()
        unstagedPaths = Set((modified + untracked).compactMap(uiRelativePath(gitRelativePath:)))
    }

    func committedText(relativePath: String) -> String? {
        let gitPath = gitRelativePath(uiRelativePath: relativePath)
        let exists = runGit(arguments: ["cat-file", "-e", "HEAD:\(gitPath)"], allowFailure: true)
        guard exists.status == 0 else { return nil }
        return runGit(arguments: ["show", "HEAD:\(gitPath)"], allowFailure: true).output
    }

    func makeTree() -> FileNode {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )
        let root = MutableNode(name: rootURL.lastPathComponent, relativePath: "", url: rootURL, isDirectory: true)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == ".git" {
                enumerator?.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), values.isHidden != true else { continue }
            let isDirectory = values.isDirectory == true
            let isRegular = values.isRegularFile == true
            guard isDirectory || isRegular else { continue }
            guard let relativePath = Repository.relativePath(from: rootURL, to: url), !relativePath.isEmpty else {
                continue
            }
            let components = relativePath.split(separator: "/").map(String.init)
            var cursor = root
            for (index, component) in components.enumerated() {
                let path = components.prefix(index + 1).joined(separator: "/")
                let childIsDirectory = index < components.count - 1 || isDirectory
                cursor = cursor.child(named: component, relativePath: path, url: rootURL.appendingPathComponent(path), isDirectory: childIsDirectory)
            }
        }
        return root.frozen(unstagedPaths: unstagedPaths)
    }

    func allFiles() -> [FileReference] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )
        var files: [FileReference] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == ".git" {
                enumerator?.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys), values.isHidden != true else { continue }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            guard let relativePath = Repository.relativePath(from: rootURL, to: url), !relativePath.isEmpty else {
                continue
            }
            files.append(FileReference(relativePath: relativePath, url: url))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func gitRelativePath(uiRelativePath: String) -> String {
        [openedFolderGitPrefix, uiRelativePath].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func uiRelativePath(gitRelativePath: String) -> String? {
        guard !openedFolderGitPrefix.isEmpty else { return gitRelativePath }
        if gitRelativePath == openedFolderGitPrefix {
            return ""
        }
        let prefix = openedFolderGitPrefix + "/"
        guard gitRelativePath.hasPrefix(prefix) else { return nil }
        return String(gitRelativePath.dropFirst(prefix.count))
    }

    private func runGit(arguments: [String], allowFailure: Bool = false) -> (status: Int32, output: String) {
        Repository.runGit(in: gitRootURL, arguments: arguments, allowFailure: allowFailure)
    }

    private static func gitOutput(in directory: URL, arguments: [String]) -> String {
        runGit(in: directory, arguments: arguments, allowFailure: true).output
    }

    private static func relativePath(from root: URL, to url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func runGit(in directory: URL, arguments: [String], allowFailure: Bool = false) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        // Drain stdout while Git is running. Waiting first can deadlock once the
        // pipe buffer fills in repositories with many files.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else { return (process.terminationStatus, "") }
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

final class MutableNode {
    let name: String
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    private var childrenByName: [String: MutableNode] = [:]

    init(name: String, relativePath: String, url: URL, isDirectory: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.isDirectory = isDirectory
    }

    func child(named name: String, relativePath: String, url: URL, isDirectory: Bool) -> MutableNode {
        if let existing = childrenByName[name] {
            return existing
        }
        let node = MutableNode(name: name, relativePath: relativePath, url: url, isDirectory: isDirectory)
        childrenByName[name] = node
        return node
    }

    func frozen(unstagedPaths: Set<String>) -> FileNode {
        let children = childrenByName.values
            .map { $0.frozen(unstagedPaths: unstagedPaths) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        let directChange = unstagedPaths.contains(relativePath)
        let descendantChange = children.contains { $0.hasUnstagedChange }
        return FileNode(
            name: name,
            relativePath: relativePath,
            url: url,
            isDirectory: isDirectory,
            hasUnstagedChange: directChange || descendantChange,
            children: children
        )
    }
}

final class FileNode: NSObject {
    let name: String
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let hasUnstagedChange: Bool
    let children: [FileNode]

    init(name: String, relativePath: String, url: URL, isDirectory: Bool, hasUnstagedChange: Bool, children: [FileNode]) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.isDirectory = isDirectory
        self.hasUnstagedChange = hasUnstagedChange
        self.children = children
    }

    static func directory(name: String, relativePath: String, url: URL, children: [FileNode]) -> FileNode {
        FileNode(name: name, relativePath: relativePath, url: url, isDirectory: true, hasUnstagedChange: children.contains { $0.hasUnstagedChange }, children: children)
    }

    func find(relativePath: String) -> FileNode? {
        if self.relativePath == relativePath { return self }
        for child in children {
            if let found = child.find(relativePath: relativePath) {
                return found
            }
        }
        return nil
    }
}
