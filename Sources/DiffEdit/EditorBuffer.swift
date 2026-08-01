import AppKit
import Foundation

struct ForegroundFileRefreshRequest {
    let relativePath: String
    let url: URL
    let knownDiskModificationDate: Date?
}

struct PreparedForegroundFileRefresh {
    let request: ForegroundFileRefreshRequest
    let diskText: String?
    let diskModificationDate: Date?
    let committedText: String

    static func load(
        request: ForegroundFileRefreshRequest,
        repository: Repository
    ) throws -> PreparedForegroundFileRefresh? {
        let observedModificationDate = try DiskFileReader.modificationDate(at: request.url)
        guard observedModificationDate != request.knownDiskModificationDate else { return nil }
        let observedDisk = try DiskFileReader.snapshot(at: request.url)
        return PreparedForegroundFileRefresh(
            request: request,
            diskText: observedDisk.text,
            diskModificationDate: observedDisk.modificationDate,
            committedText: repository.committedText(relativePath: request.relativePath) ?? ""
        )
    }
}

struct DiskFileSnapshot {
    let text: String?
    let modificationDate: Date?
}

enum DiskFileReader {
    static func modificationDate(at url: URL) throws -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date
    }

    static func snapshot(at url: URL) throws -> DiskFileSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DiskFileSnapshot(text: nil, modificationDate: nil)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return DiskFileSnapshot(text: text, modificationDate: try modificationDate(at: url))
    }
}

struct EditorBuffer {
    let url: URL
    let relativePath: String
    var baseText: String
    var text: String
    var knownDiskText: String?
    var knownDiskModificationDate: Date?
    var requiresOverwriteConfirmation: Bool = false
    var selection: NSRange
    var selectionAffinity: NSSelectionAffinity
    var scrollOrigin: CGPoint

    var hasUnsavedChanges: Bool {
        knownDiskText.map { text != $0 } ?? !text.isEmpty
    }

    mutating func markSaved(modificationDate: Date?) {
        knownDiskText = text
        knownDiskModificationDate = modificationDate
        requiresOverwriteConfirmation = false
    }

    mutating func reloadFromDisk(_ diskText: String?, modificationDate: Date?) {
        knownDiskText = diskText
        knownDiskModificationDate = modificationDate
        text = diskText ?? ""
        requiresOverwriteConfirmation = false
    }

    mutating func keepBufferAfterExternalChange(_ diskText: String?, modificationDate: Date?) {
        knownDiskText = diskText
        knownDiskModificationDate = modificationDate
        requiresOverwriteConfirmation = text != diskText
    }

    mutating func acknowledgeUnchangedDisk(modificationDate: Date?) {
        knownDiskModificationDate = modificationDate
    }
}

enum ExternalFileOperation: Equatable {
    case activating
    case saving
}

struct ExternalFileConflict {
    let relativePath: String
    let operation: ExternalFileOperation
    let fileWasDeleted: Bool
}

enum ExternalFileResolution {
    case reloadFromDisk
    case keepBuffer
    case cancel
}

enum EditorFileError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        "The file operation was cancelled."
    }
}
