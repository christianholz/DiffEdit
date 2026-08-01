import AppKit
import Foundation

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
