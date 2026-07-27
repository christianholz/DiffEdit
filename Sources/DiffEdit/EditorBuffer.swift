import AppKit
import Foundation

struct EditorBuffer {
    let url: URL
    let relativePath: String
    let baseText: String
    var text: String
    var savedText: String
    var selection: NSRange
    var selectionAffinity: NSSelectionAffinity
    var scrollOrigin: CGPoint

    var hasUnsavedChanges: Bool {
        text != savedText
    }

    mutating func markSaved() {
        savedText = text
    }
}
