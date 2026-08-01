import Foundation

enum RepositoryError: LocalizedError {
    case notGitRepository
    case emptyCommitMessage
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            return "The opened folder is not inside a Git repository."
        case .emptyCommitMessage:
            return "Enter a commit message first."
        case let .commandFailed(message):
            return message.isEmpty ? "Git could not complete the operation." : message
        }
    }
}

final class Repository {
    let rootURL: URL
    private let gitRootURL: URL
    private let openedFolderGitPrefix: String
    private let isGitRepository: Bool
    private(set) var unstagedPaths = Set<String>()

    init(rootURL: URL) {
        self.rootURL = rootURL
        let discoveredRoot = Repository.gitOutput(in: rootURL, arguments: ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if discoveredRoot.isEmpty {
            gitRootURL = rootURL
            openedFolderGitPrefix = ""
            isGitRepository = false
        } else {
            gitRootURL = URL(fileURLWithPath: discoveredRoot)
            openedFolderGitPrefix = Repository.relativePath(from: URL(fileURLWithPath: discoveredRoot), to: rootURL) ?? ""
            isGitRepository = true
        }
    }

    func refreshStatus() {
        let modified = runGit(arguments: ["diff", "--name-only"]).output.splitLines()
        let staged = runGit(arguments: ["diff", "--cached", "--name-only"]).output.splitLines()
        let untracked = runGit(arguments: ["ls-files", "--others", "--exclude-standard"]).output.splitLines()
        unstagedPaths = Set((modified + staged + untracked).compactMap(uiRelativePath(gitRelativePath:)))
    }

    func committedText(relativePath: String) -> String? {
        let gitPath = gitRelativePath(uiRelativePath: relativePath)
        let exists = runGit(arguments: ["cat-file", "-e", "HEAD:\(gitPath)"], allowFailure: true)
        guard exists.status == 0 else { return nil }
        return runGit(arguments: ["show", "HEAD:\(gitPath)"], allowFailure: true).output
    }

    var currentBranchName: String {
        let branch = runGit(arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], allowFailure: true)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "HEAD" : branch
    }

    func stage(text: String, relativePath: String) throws {
        guard isGitRepository else { throw RepositoryError.notGitRepository }
        let gitPath = gitRelativePath(uiRelativePath: relativePath)
        let hasCommittedVersion = runGit(
            arguments: ["cat-file", "-e", "HEAD:\(gitPath)"],
            allowFailure: true
        ).status == 0
        if !hasCommittedVersion, text.isEmpty {
            let removal = runGit(arguments: ["update-index", "--force-remove", "--", gitPath], allowFailure: true)
            guard removal.status == 0 else {
                throw RepositoryError.commandFailed(removal.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return
        }

        let blob = runGit(
            arguments: ["hash-object", "-w", "--stdin"],
            input: Data(text.utf8),
            allowFailure: true
        )
        guard blob.status == 0 else {
            throw RepositoryError.commandFailed(blob.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let objectID = blob.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objectID.isEmpty else {
            throw RepositoryError.commandFailed("Git did not return an object ID for the staged content.")
        }
        let mode = fileMode(gitPath: gitPath, uiRelativePath: relativePath)
        let update = runGit(
            arguments: ["update-index", "--add", "--cacheinfo", mode, objectID, gitPath],
            allowFailure: true
        )
        guard update.status == 0 else {
            throw RepositoryError.commandFailed(update.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @discardableResult
    func commit(message: String) throws -> String {
        guard isGitRepository else { throw RepositoryError.notGitRepository }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepositoryError.emptyCommitMessage }
        let result = runGit(arguments: ["commit", "-m", trimmed], allowFailure: true)
        guard result.status == 0 else {
            throw RepositoryError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func fileMode(gitPath: String, uiRelativePath: String) -> String {
        let indexed = runGit(arguments: ["ls-files", "--stage", "--", gitPath], allowFailure: true).output
        if let mode = indexed.split(whereSeparator: \.isWhitespace).first, !mode.isEmpty {
            return String(mode)
        }
        let committed = runGit(arguments: ["ls-tree", "HEAD", "--", gitPath], allowFailure: true).output
        if let mode = committed.split(whereSeparator: \.isWhitespace).first, !mode.isEmpty {
            return String(mode)
        }
        let url = rootURL.appendingPathComponent(uiRelativePath)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o111 != 0 {
            return "100755"
        }
        return "100644"
    }

    private func runGit(arguments: [String], input: Data? = nil, allowFailure: Bool = false) -> (status: Int32, output: String) {
        Repository.runGit(in: gitRootURL, arguments: arguments, input: input, allowFailure: allowFailure)
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

    private static func runGit(in directory: URL, arguments: [String], input: Data? = nil, allowFailure: Bool = false) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let inputPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        // Drain stdout while Git is running. Waiting first can deadlock once the
        // pipe buffer fills in repositories with many files.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard allowFailure || process.terminationStatus == 0 else { return (process.terminationStatus, text) }
        return (process.terminationStatus, text)
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

    var changedFileCount: Int {
        isDirectory ? children.reduce(0) { $0 + $1.changedFileCount } : (hasUnstagedChange ? 1 : 0)
    }

    var firstFile: FileNode? {
        if !isDirectory { return self }
        return children.lazy.compactMap(\.firstFile).first
    }

    var filesInDisplayOrder: [FileNode] {
        if !isDirectory { return [self] }
        return children.flatMap(\.filesInDisplayOrder)
    }

    func flattenedChanges(additionalPaths: Set<String> = []) -> FileNode {
        var files: [FileNode] = []
        collectChangedFiles(additionalPaths: additionalPaths, into: &files)
        let flattened = files
            .map { file in
                FileNode(
                    name: file.relativePath,
                    relativePath: file.relativePath,
                    url: file.url,
                    isDirectory: false,
                    hasUnstagedChange: true,
                    children: []
                )
            }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return FileNode.directory(name: name, relativePath: "", url: url, children: flattened)
    }

    private func collectChangedFiles(additionalPaths: Set<String>, into files: inout [FileNode]) {
        if !isDirectory {
            if hasUnstagedChange || additionalPaths.contains(relativePath) {
                files.append(self)
            }
            return
        }
        for child in children {
            child.collectChangedFiles(additionalPaths: additionalPaths, into: &files)
        }
    }
}
