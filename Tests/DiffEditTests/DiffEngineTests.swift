import AppKit
import Foundation
import XCTest
@testable import DiffEdit

final class DiffEngineTests: XCTestCase {
    func testUnchangedTextProducesNoHighlights() {
        let result = DiffEngine.diff(base: "one\ntwo\n", current: "one\ntwo\n")

        XCTAssertTrue(result.currentTouchedLines.isEmpty)
        XCTAssertTrue(result.baseTouchedLines.isEmpty)
        XCTAssertTrue(result.insertedWordRanges.isEmpty)
        XCTAssertTrue(result.deletedWordRanges.isEmpty)
        XCTAssertTrue(result.currentDeletionMarkers.isEmpty)
        XCTAssertTrue(result.revertActions.isEmpty)
    }

    func testInlineReplacementTracksBothSidesAndCanBeReverted() {
        let current = "hello brave world\n"
        let result = DiffEngine.diff(base: "hello old world\n", current: current)

        XCTAssertEqual(result.currentTouchedLines, [0])
        XCTAssertEqual(result.baseTouchedLines, [0])
        XCTAssertEqual(highlightedStrings(result.insertedWordRanges, in: current), ["brave"])
        XCTAssertEqual(result.deletedWordRanges.count, 1)
        XCTAssertEqual(result.revertActions.count, 1)
        XCTAssertEqual(result.revertActions.first?.replacement, "old")
    }

    func testInsertedLineIsHighlightedAndDiscardable() {
        let current = "one\ninserted\ntwo\n"
        let result = DiffEngine.diff(base: "one\ntwo\n", current: current)

        XCTAssertEqual(result.currentTouchedLines, [1])
        XCTAssertEqual(highlightedStrings(result.insertedWordRanges, in: current), ["inserted"])
        XCTAssertEqual(result.revertActions.first?.replacement, "")
    }

    func testDeletedLineAddsADeletionMarker() {
        let result = DiffEngine.diff(base: "one\nremoved\ntwo\n", current: "one\ntwo\n")

        XCTAssertEqual(result.baseTouchedLines, [1])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.line), [1])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.column), [0])
    }

    func testDeletionMarkerUsesCurrentPositionAfterEarlierInsertedLines() {
        let baseLines = (1...60).map { "line \($0)\n" }
        var currentLines = baseLines
        currentLines.insert(contentsOf: (1...4).map { "inserted \($0)\n" }, at: 10)
        currentLines.removeAll { $0 == "line 52\n" }

        let result = DiffEngine.diff(base: baseLines.joined(), current: currentLines.joined())

        XCTAssertEqual(result.currentDeletionMarkers.map(\.line), [55])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.column), [0])
    }

    func testUTF16RangesMatchNSStringOffsets() {
        let current = "hello 👋🏽 friend\n"
        let result = DiffEngine.diff(base: "hello friend\n", current: current)

        XCTAssertEqual(highlightedStrings(result.insertedWordRanges, in: current), ["👋🏽 "])
        XCTAssertTrue(result.insertedWordRanges.allSatisfy { NSMaxRange($0) <= (current as NSString).length })
    }

    func testLargeMostlyUnchangedDocumentRemainsPractical() {
        let lines = (0..<5_000).map { "line \($0)\n" }
        var changedLines = lines
        changedLines[2_500] = "line 2500 changed\n"

        let result = DiffEngine.diff(base: lines.joined(), current: changedLines.joined())

        XCTAssertEqual(result.currentTouchedLines, [2_500])
        XCTAssertEqual(result.baseTouchedLines, [2_500])
    }

    private func highlightedStrings(_ ranges: [NSRange], in string: String) -> [String] {
        let nsString = string as NSString
        return ranges.map { nsString.substring(with: $0) }
    }
}

final class TypingBackgroundResolverTests: XCTestCase {
    private let insertedColor = NSColor.systemGreen

    func testCaretInsideAddedTextInheritsGreenFromPreviousCharacter() {
        let text = addedText("added")

        let color = TypingBackgroundResolver.backgroundColor(
            in: text,
            selection: NSRange(location: 3, length: 0),
            changedLines: [0],
            insertedColor: insertedColor
        )

        XCTAssertTrue(color?.isEqual(insertedColor) == true)
    }

    func testCaretAtStartOfAddedTextInheritsGreenFromNextCharacter() {
        let text = addedText("added")

        let color = TypingBackgroundResolver.backgroundColor(
            in: text,
            selection: NSRange(location: 0, length: 0),
            changedLines: [0],
            insertedColor: insertedColor
        )

        XCTAssertTrue(color?.isEqual(insertedColor) == true)
    }

    func testReplacementInAddedTextRetainsGreen() {
        let text = addedText("added")

        let color = TypingBackgroundResolver.backgroundColor(
            in: text,
            selection: NSRange(location: 1, length: 3),
            changedLines: [0],
            insertedColor: insertedColor
        )

        XCTAssertTrue(color?.isEqual(insertedColor) == true)
    }

    func testEmptyChangedLineUsesInsertedColor() {
        let color = TypingBackgroundResolver.backgroundColor(
            in: NSAttributedString(string: ""),
            selection: NSRange(location: 0, length: 0),
            changedLines: [0],
            insertedColor: insertedColor
        )

        XCTAssertTrue(color?.isEqual(insertedColor) == true)
    }

    func testUnchangedTextDoesNotGainABackground() {
        let color = TypingBackgroundResolver.backgroundColor(
            in: NSAttributedString(string: "plain"),
            selection: NSRange(location: 3, length: 0),
            changedLines: [],
            insertedColor: insertedColor
        )

        XCTAssertNil(color)
    }

    private func addedText(_ string: String) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.backgroundColor: insertedColor]
        )
    }
}

final class WholeLineClipboardTests: XCTestCase {
    func testCopyWithoutSelectionCopiesTheCurrentLine() {
        let textView = makeTextView()
        var copiedText: String?
        textView.clipboardWriter = { copiedText = $0 }

        textView.copy(nil)

        XCTAssertEqual(copiedText, "two\n")
        XCTAssertEqual(textView.string, "one\ntwo\nthree\n")
    }

    func testCutWithoutSelectionCutsTheCurrentLine() {
        let textView = makeTextView()
        var copiedText: String?
        textView.clipboardWriter = { copiedText = $0 }

        textView.cut(nil)

        XCTAssertEqual(copiedText, "two\n")
        XCTAssertEqual(textView.string, "one\nthree\n")
    }

    private func makeTextView() -> LineHighlightTextView {
        let textView = LineHighlightTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isEditable = true
        textView.string = "one\ntwo\nthree\n"
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        return textView
    }
}

final class TextEditClassifierTests: XCTestCase {
    func testOrdinaryTypingKeepsTheDebouncedPath() {
        XCTAssertFalse(
            TextEditClassifier.changesLineStructure(
                original: "one\ntwo\n",
                range: NSRange(location: 1, length: 0),
                replacement: "x"
            )
        )
    }

    func testInsertingANewlineRequiresImmediateRefresh() {
        XCTAssertTrue(
            TextEditClassifier.changesLineStructure(
                original: "one\ntwo\n",
                range: NSRange(location: 3, length: 0),
                replacement: "\n"
            )
        )
    }

    func testRemovingAWholeLineRequiresImmediateRefresh() {
        XCTAssertTrue(
            TextEditClassifier.changesLineStructure(
                original: "one\ntwo\nthree\n",
                range: NSRange(location: 4, length: 4),
                replacement: ""
            )
        )
    }

    func testPastingMultipleLinesRequiresImmediateRefresh() {
        XCTAssertTrue(
            TextEditClassifier.changesLineStructure(
                original: "one\n",
                range: NSRange(location: 0, length: 0),
                replacement: "first\nsecond\n"
            )
        )
    }
}

final class EditorBufferTests: XCTestCase {
    func testBufferBecomesDirtyAndCleanAfterSave() {
        var buffer = makeBuffer(text: "original")
        XCTAssertFalse(buffer.hasUnsavedChanges)

        buffer.text = "edited"
        XCTAssertTrue(buffer.hasUnsavedChanges)

        buffer.markSaved()
        XCTAssertFalse(buffer.hasUnsavedChanges)
        XCTAssertEqual(buffer.savedText, "edited")
    }

    func testRevertingToSavedTextClearsDirtyState() {
        var buffer = makeBuffer(text: "original")
        buffer.text = "temporary edit"
        XCTAssertTrue(buffer.hasUnsavedChanges)

        buffer.text = "original"
        XCTAssertFalse(buffer.hasUnsavedChanges)
    }

    func testBufferRetainsNavigationState() {
        var buffer = makeBuffer(text: "one\ntwo\n")
        buffer.selection = NSRange(location: 4, length: 3)
        buffer.selectionAffinity = .upstream
        buffer.scrollOrigin = CGPoint(x: 0, y: 120)

        XCTAssertEqual(buffer.selection, NSRange(location: 4, length: 3))
        XCTAssertEqual(buffer.selectionAffinity, .upstream)
        XCTAssertEqual(buffer.scrollOrigin, CGPoint(x: 0, y: 120))
    }

    private func makeBuffer(text: String) -> EditorBuffer {
        EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/example.txt"),
            relativePath: "example.txt",
            baseText: text,
            text: text,
            savedText: text,
            selection: NSRange(location: 0, length: 0),
            selectionAffinity: .downstream,
            scrollOrigin: .zero
        )
    }
}

final class TextSelectionSnapshotTests: XCTestCase {
    func testRestorePreservesDownstreamAffinityAtAmbiguousCaretPosition() {
        let textView = LineHighlightTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 200))
        textView.string = "a long line that wraps across several visual lines"
        let caretRange = NSRange(location: 12, length: 0)
        textView.setSelectedRange(caretRange, affinity: .downstream, stillSelecting: false)
        let snapshot = TextSelectionSnapshot(textView: textView)

        textView.textStorage?.setAttributedString(NSAttributedString(string: textView.string))
        snapshot.restore(to: textView)

        XCTAssertEqual(textView.selectedRange(), caretRange)
        XCTAssertEqual(textView.selectionAffinity, .downstream)
    }

    func testRestorePreservesUpstreamAffinity() {
        let textView = LineHighlightTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 200))
        textView.string = "another long line that wraps"
        let caretRange = NSRange(location: 8, length: 0)
        textView.setSelectedRange(caretRange, affinity: .upstream, stillSelecting: false)
        let snapshot = TextSelectionSnapshot(textView: textView)

        textView.textStorage?.setAttributedString(NSAttributedString(string: textView.string))
        snapshot.restore(to: textView)

        XCTAssertEqual(textView.selectedRange(), caretRange)
        XCTAssertEqual(textView.selectionAffinity, .upstream)
    }
}
