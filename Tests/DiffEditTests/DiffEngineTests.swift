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
        XCTAssertTrue(result.currentDeletionMarkers.isEmpty)
        XCTAssertEqual(result.revertActions.count, 1)
        XCTAssertEqual(result.revertActions.first?.replacement, "old")
    }

    func testInsertedLineIsHighlightedAndDiscardable() {
        let base = "one\ntwo\n"
        let current = "one\ninserted\ntwo\n"
        let result = DiffEngine.diff(base: base, current: current)

        XCTAssertEqual(result.currentTouchedLines, [1])
        XCTAssertEqual(highlightedStrings(result.insertedWordRanges, in: current), ["inserted"])
        XCTAssertEqual(result.revertActions.first?.replacement, "")
        XCTAssertEqual(applying(result.revertActions[0], to: current), base)
    }

    func testInsertedBlankLineIsDiscardableWithItsNewline() {
        let base = "one\ntwo\n"
        let current = "one\n\ntwo\n"
        let result = DiffEngine.diff(base: base, current: current)

        XCTAssertEqual(result.revertActions.count, 1)
        XCTAssertEqual(applying(result.revertActions[0], to: current), base)
    }

    func testPureMidLineDeletionAddsAnInlineMarker() {
        let result = DiffEngine.diff(
            base: "alpha removed beta\n",
            current: "alpha beta\n"
        )

        XCTAssertEqual(result.currentDeletionMarkers.map(\.line), [0])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.column), [6])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.kind), [.inline])
    }

    func testEveryMidLineDeletionGetsItsOwnMarker() {
        let result = DiffEngine.diff(
            base: "one old two removed three\n",
            current: "one new two three\n"
        )

        XCTAssertEqual(result.currentDeletionMarkers.map(\.line), [0])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.column), [12])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.kind), [.inline])
    }

    func testRewrittenSentenceKeepsOnlyItsPureDeletionMarker() {
        let base = #"Across eight downstream tasks, \name matches or outperforms the task-specific models that have dominated prior work, even when we exclude the target dataset from pretraining and train each head on a fraction of the labels."#
        let current = "The resulting frozen encoder supports eight downstream tasks spanning classification, regression, dense prediction, and 3D hand-pose estimation through lightweight task-specific heads."

        let result = DiffEngine.diff(base: base, current: current)

        XCTAssertEqual(result.currentDeletionMarkers.map(\.column), [116])
        XCTAssertTrue(result.currentDeletionMarkers.allSatisfy { $0.kind == .inline })
    }

    func testDeletedLineAddsADeletionMarker() {
        let result = DiffEngine.diff(base: "one\nremoved\ntwo\n", current: "one\ntwo\n")

        XCTAssertEqual(result.baseTouchedLines, [1])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.line), [1])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.column), [0])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.kind), [.lineBoundaryBefore])
    }

    func testMixedLineReplacementDoesNotAddAHorizontalDeletionMarker() {
        let result = DiffEngine.diff(
            base: "one\nremove a\nremove b\ntwo\n",
            current: "one\nreplacement\ntwo\n"
        )

        XCTAssertTrue(result.currentDeletionMarkers.isEmpty)
    }

    func testDeletionMarkerUsesCurrentPositionAfterEarlierInsertedLines() {
        let baseLines = (1...60).map { "line \($0)\n" }
        var currentLines = baseLines
        currentLines.insert(contentsOf: (1...4).map { "inserted \($0)\n" }, at: 10)
        currentLines.removeAll { $0 == "line 52\n" }

        let result = DiffEngine.diff(base: baseLines.joined(), current: currentLines.joined())

        XCTAssertEqual(result.currentDeletionMarkers.map(\.line), [55])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.column), [0])
        XCTAssertEqual(result.currentDeletionMarkers.map(\.kind), [.lineBoundaryBefore])
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

    private func applying(_ action: RevertAction, to string: String) -> String {
        (string as NSString).replacingCharacters(in: action.currentRange, with: action.replacement)
    }
}

final class SelectiveStagingTests: XCTestCase {
    func testChangesAreSelectedByDefaultWhenAllSelectableLinesArePassed() {
        let current = "one\ninserted\ntwo\n"
        let plan = DiffEngine.selectiveStagingPlan(base: "one\ntwo\n", current: current)

        XCTAssertEqual(plan.selectableChanges.count, 1)
        XCTAssertEqual(plan.text(selectedChanges: plan.selectableChanges), current)
    }

    func testDeselectingAnInsertedLineOmitsItFromStagedText() {
        let plan = DiffEngine.selectiveStagingPlan(
            base: "one\ntwo\n",
            current: "one\ninserted\ntwo\n"
        )

        XCTAssertEqual(plan.text(selectedChanges: []), "one\ntwo\n")
    }

    func testDeselectingAReplacementKeepsTheCommittedLine() {
        let plan = DiffEngine.selectiveStagingPlan(
            base: "one\nold\nthree\n",
            current: "one\nnew\nthree\n"
        )

        XCTAssertEqual(plan.selectableChanges.count, 2)
        XCTAssertEqual(plan.text(selectedChanges: []), "one\nold\nthree\n")
        XCTAssertEqual(plan.text(selectedChanges: plan.selectableChanges), "one\nnew\nthree\n")
    }

    func testDeletedLineCanBeExcludedFromStaging() {
        let plan = DiffEngine.selectiveStagingPlan(
            base: "one\nremoved\ntwo\n",
            current: "one\ntwo\n"
        )

        XCTAssertEqual(plan.selectableChanges.count, 1)
        XCTAssertEqual(plan.text(selectedChanges: []), "one\nremoved\ntwo\n")
        XCTAssertEqual(plan.text(selectedChanges: plan.selectableChanges), "one\ntwo\n")
    }

    func testOnlySelectedChangedLinesAreIncluded() {
        let plan = DiffEngine.selectiveStagingPlan(
            base: "one\ntwo\nthree\nfour\n",
            current: "one\nTWO\nthree\nadded\nfour\n"
        )

        XCTAssertEqual(plan.selectableChanges.count, 3)
        let replacement = Set(plan.selectableChanges.filter {
            $0.oldLineIndex == 1 || $0.newLineIndex == 1
        })
        let addition = Set(plan.selectableChanges.filter { $0.newLineIndex == 3 })
        XCTAssertEqual(plan.text(selectedChanges: replacement), "one\nTWO\nthree\nfour\n")
        XCTAssertEqual(plan.text(selectedChanges: addition), "one\ntwo\nthree\nadded\nfour\n")
    }

    func testDeletingAllContentStillHasASelectableGutterLine() {
        let plan = DiffEngine.selectiveStagingPlan(base: "one\ntwo\n", current: "")

        XCTAssertEqual(plan.selectableChanges.count, 2)
        XCTAssertEqual(plan.text(selectedChanges: []), "one\ntwo\n")
        XCTAssertEqual(plan.text(selectedChanges: plan.selectableChanges), "")
    }

    func testUnifiedRowsShowReplacementAsDeletionAndInsertion() {
        let plan = DiffEngine.selectiveStagingPlan(
            base: "one\nold\nthree\n",
            current: "one\nnew\nthree\n"
        )
        let changedRows = plan.diffRows.filter { $0.kind == .deletion || $0.kind == .insertion }

        XCTAssertEqual(changedRows.count, 2)
        XCTAssertEqual(changedRows[0].kind, .deletion)
        XCTAssertEqual(changedRows[0].oldLineNumber, 2)
        XCTAssertEqual(changedRows[0].selectionID?.kind, .deletion)
        XCTAssertEqual(changedRows[1].kind, .insertion)
        XCTAssertEqual(changedRows[1].newLineNumber, 2)
        XCTAssertEqual(changedRows[1].selectionID?.kind, .insertion)
        XCTAssertNotEqual(changedRows[0].selectionID, changedRows[1].selectionID)
    }

    func testConsecutiveDeletedLinesCanBeSelectedIndependently() {
        let plan = DiffEngine.selectiveStagingPlan(
            base: "one\nremove-a\nremove-b\ntwo\n",
            current: "one\ntwo\n"
        )
        let deletions = plan.diffRows.filter { $0.kind == .deletion }
        let firstDeletion = deletions[0].selectionID.map { Set([$0]) } ?? []
        let secondDeletion = deletions[1].selectionID.map { Set([$0]) } ?? []

        XCTAssertEqual(deletions.count, 2)
        XCTAssertNotEqual(deletions[0].selectionID, deletions[1].selectionID)
        XCTAssertEqual(plan.text(selectedChanges: firstDeletion), "one\nremove-b\ntwo\n")
        XCTAssertEqual(plan.text(selectedChanges: secondDeletion), "one\nremove-a\ntwo\n")
    }

    func testUnifiedRowsCollapseDistantUnchangedContext() {
        let base = (1...20).map { "line \($0)\n" }.joined()
        var currentLines = (1...20).map { "line \($0)\n" }
        currentLines[9] = "changed\n"
        let plan = DiffEngine.selectiveStagingPlan(base: base, current: currentLines.joined())

        XCTAssertTrue(plan.diffRows.contains { $0.kind == .separator })
        XCTAssertLessThan(plan.diffRows.count, 20)
    }

    func testSelectiveStagingPreservesCRLFLineEndings() {
        let base = "one\r\ntwo\r\n"
        let current = "one\r\nTWO\r\n"
        let plan = DiffEngine.selectiveStagingPlan(base: base, current: current)

        XCTAssertEqual(plan.text(selectedChanges: []), base)
        XCTAssertEqual(plan.text(selectedChanges: plan.selectableChanges), current)
    }

    func testSelectiveStagingPreservesMissingFinalNewline() {
        let base = "one\ntwo"
        let current = "one\nTWO"
        let plan = DiffEngine.selectiveStagingPlan(base: base, current: current)

        XCTAssertEqual(plan.text(selectedChanges: []), base)
        XCTAssertEqual(plan.text(selectedChanges: plan.selectableChanges), current)
        XCTAssertFalse(plan.text(selectedChanges: plan.selectableChanges).hasSuffix("\n"))
    }
}

final class ChangeNavigationTests: XCTestCase {
    func testAdjacentNavigationSkipsTheRestOfTheCurrentChangedBlock() {
        let lines: Set<Int> = [2, 3, 7, 8, 12]

        XCTAssertEqual(ChangedLineNavigator.adjacentTarget(in: lines, from: 2, direction: .next), 7)
        XCTAssertEqual(ChangedLineNavigator.adjacentTarget(in: lines, from: 3, direction: .next), 7)
        XCTAssertEqual(ChangedLineNavigator.adjacentTarget(in: lines, from: 8, direction: .previous), 2)
        XCTAssertEqual(ChangedLineNavigator.adjacentTarget(in: lines, from: 11, direction: .previous), 7)
    }

    func testAdjacentNavigationReturnsNilAtTheFileBoundary() {
        let lines: Set<Int> = [2, 3, 7, 8]

        XCTAssertNil(ChangedLineNavigator.adjacentTarget(in: lines, from: 8, direction: .next))
        XCTAssertNil(ChangedLineNavigator.adjacentTarget(in: lines, from: 2, direction: .previous))
        XCTAssertEqual(ChangedLineNavigator.edgeTarget(in: lines, direction: .next), 2)
        XCTAssertEqual(ChangedLineNavigator.edgeTarget(in: lines, direction: .previous), 7)
    }

    func testFileNavigationUsesSidebarOrderAndWraps() {
        let paths = ["Sources/B.swift", "README.md", "Sources/A.swift"]

        XCTAssertEqual(ChangedFileNavigator.adjacentPath(in: paths, from: "README.md", direction: .next), "Sources/A.swift")
        XCTAssertEqual(ChangedFileNavigator.adjacentPath(in: paths, from: "README.md", direction: .previous), "Sources/B.swift")
        XCTAssertEqual(ChangedFileNavigator.adjacentPath(in: paths, from: "Sources/A.swift", direction: .next), "Sources/B.swift")
        XCTAssertEqual(ChangedFileNavigator.adjacentPath(in: paths, from: nil, direction: .previous), "Sources/A.swift")
    }
}

final class FileNodeFilteringTests: XCTestCase {
    func testFlattenedChangesUseFullPathsAndIncludeBufferedOnlyFiles() {
        let rootURL = URL(fileURLWithPath: "/tmp/repository")
        let changed = FileNode(
            name: "changed.swift",
            relativePath: "Sources/changed.swift",
            url: rootURL.appendingPathComponent("Sources/changed.swift"),
            isDirectory: false,
            hasUnstagedChange: true,
            children: []
        )
        let buffered = FileNode(
            name: "buffered.swift",
            relativePath: "Sources/buffered.swift",
            url: rootURL.appendingPathComponent("Sources/buffered.swift"),
            isDirectory: false,
            hasUnstagedChange: false,
            children: []
        )
        let sources = FileNode.directory(
            name: "Sources",
            relativePath: "Sources",
            url: rootURL.appendingPathComponent("Sources"),
            children: [changed, buffered]
        )
        let root = FileNode.directory(name: "repository", relativePath: "", url: rootURL, children: [sources])

        let flattened = root.flattenedChanges(additionalPaths: ["Sources/buffered.swift"])

        XCTAssertEqual(flattened.children.map(\.name), ["Sources/buffered.swift", "Sources/changed.swift"])
        XCTAssertEqual(flattened.changedFileCount, 2)
    }
}

final class RepositoryStagingTests: XCTestCase {
    func testStagesInMemoryContentAndCommitsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditRepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try runGit(["init", "-q"], in: directory)
        _ = try runGit(["config", "user.name", "DiffEdit Tests"], in: directory)
        _ = try runGit(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let fileURL = directory.appendingPathComponent("example.txt")
        try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "example.txt"], in: directory)
        _ = try runGit(["commit", "-q", "-m", "Initial"], in: directory)

        let repository = Repository(rootURL: directory)
        try repository.stage(text: "one\nTWO\nthree\n", relativePath: "example.txt")

        XCTAssertEqual(try runGit(["show", ":example.txt"], in: directory), "one\nTWO\nthree\n")
        _ = try repository.commit(message: "Stage selected line")
        XCTAssertEqual(repository.committedText(relativePath: "example.txt"), "one\nTWO\nthree\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "one\ntwo\nthree\n")
    }

    func testStagingCommittedTextClearsAFileFromTheIndex() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditRepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try runGit(["init", "-q"], in: directory)
        _ = try runGit(["config", "user.name", "DiffEdit Tests"], in: directory)
        _ = try runGit(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let fileURL = directory.appendingPathComponent("example.txt")
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "example.txt"], in: directory)
        _ = try runGit(["commit", "-q", "-m", "Initial"], in: directory)
        let repository = Repository(rootURL: directory)

        try repository.stage(text: "changed\n", relativePath: "example.txt")
        XCTAssertEqual(try runGitStatus(["diff", "--cached", "--quiet"], in: directory), 1)
        try repository.stage(text: "base\n", relativePath: "example.txt")

        XCTAssertEqual(try runGitStatus(["diff", "--cached", "--quiet"], in: directory), 0)
    }

    func testCommitScopeDetectsStagedFilesOutsideAnOpenedSubfolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditRepositoryTests-\(UUID().uuidString)")
        let openedFolder = directory.appendingPathComponent("Opened")
        try FileManager.default.createDirectory(at: openedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try runGit(["init", "-q"], in: directory)
        _ = try runGit(["config", "user.name", "DiffEdit Tests"], in: directory)
        _ = try runGit(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        try "inside\n".write(to: openedFolder.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try "outside\n".write(to: directory.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "."], in: directory)
        _ = try runGit(["commit", "-q", "-m", "Initial"], in: directory)
        try "staged outside\n".write(to: directory.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "outside.txt"], in: directory)

        let repository = Repository(rootURL: openedFolder)

        XCTAssertEqual(
            try repository.invisibleStagedPaths(representedUIPaths: ["inside.txt"]),
            ["outside.txt"]
        )
    }

    func testStagingAppliesPathDependentCleanFilter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditRepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try runGit(["init", "-q"], in: directory)
        _ = try runGit(["config", "user.name", "DiffEdit Tests"], in: directory)
        _ = try runGit(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        _ = try runGit(["config", "filter.uppercase.clean", "tr a-z A-Z"], in: directory)
        _ = try runGit(["config", "filter.uppercase.smudge", "cat"], in: directory)
        try "*.txt filter=uppercase\n".write(
            to: directory.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        try "base\n".write(
            to: directory.appendingPathComponent("example.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try runGit(["add", "."], in: directory)
        _ = try runGit(["commit", "-q", "-m", "Initial"], in: directory)
        let repository = Repository(rootURL: directory)

        try repository.stage(text: "mixed Case\n", relativePath: "example.txt")

        XCTAssertEqual(try runGit(["show", ":example.txt"], in: directory), "MIXED CASE\n")
    }

    private func runGit(_ arguments: [String], in directory: URL, allowFailure: Bool = false) throws -> String {
        let result = try runGitResult(arguments, in: directory)
        if !allowFailure, result.status != 0 {
            throw RepositoryError.commandFailed(result.output)
        }
        return result.output
    }

    private func runGitStatus(_ arguments: [String], in directory: URL) throws -> Int32 {
        try runGitResult(arguments, in: directory).status
    }

    private func runGitResult(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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

        buffer.markSaved(modificationDate: nil)
        XCTAssertFalse(buffer.hasUnsavedChanges)
        XCTAssertEqual(buffer.knownDiskText, "edited")
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

    func testCleanBufferCanReloadAnExternalChange() {
        var buffer = makeBuffer(text: "original")

        buffer.reloadFromDisk("external", modificationDate: nil)

        XCTAssertEqual(buffer.text, "external")
        XCTAssertEqual(buffer.knownDiskText, "external")
        XCTAssertFalse(buffer.hasUnsavedChanges)
    }

    func testKeepingBufferAfterExternalChangeRequiresConfirmedOverwrite() {
        var buffer = makeBuffer(text: "original")
        buffer.text = "my edit"

        buffer.keepBufferAfterExternalChange("external", modificationDate: nil)

        XCTAssertEqual(buffer.text, "my edit")
        XCTAssertEqual(buffer.knownDiskText, "external")
        XCTAssertTrue(buffer.hasUnsavedChanges)
        XCTAssertTrue(buffer.requiresOverwriteConfirmation)
        buffer.markSaved(modificationDate: nil)
        XCTAssertFalse(buffer.requiresOverwriteConfirmation)
    }

    private func makeBuffer(text: String) -> EditorBuffer {
        EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/example.txt"),
            relativePath: "example.txt",
            baseText: text,
            text: text,
            knownDiskText: text,
            knownDiskModificationDate: nil,
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

final class WorkspaceModeUITests: XCTestCase {
    func testEditModeKeepsMatchingGutterWidthsAndStagingHasItsOwnView() throws {
        let main = MainViewController()
        _ = main.view
        main.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        main.view.layoutSubtreeIfNeeded()
        let sidebarContainer = try XCTUnwrap(main.splitViewItems.first?.viewController.view)
        let editorContainer = try XCTUnwrap(main.splitViewItems.last?.viewController.view)
        let gutters = descendants(of: editorContainer, matching: LineNumberGutterView.self)
        XCTAssertEqual(gutters.count, 2)
        XCTAssertTrue(gutters.allSatisfy { $0.width == 46 })
        XCTAssertTrue(gutters.allSatisfy { $0.layer?.masksToBounds == true })
        let editorRows = descendants(of: editorContainer, matching: NSStackView.self).filter {
            $0.orientation == .horizontal
        }
        XCTAssertEqual(editorRows.count, 2)
        XCTAssertTrue(editorRows.allSatisfy { $0.layer?.masksToBounds == true })

        let modeControl = try XCTUnwrap(descendants(of: main.view, matching: NSSegmentedControl.self).first)
        XCTAssertTrue(modeControl.isDescendant(of: sidebarContainer))
        XCTAssertFalse(modeControl.isDescendant(of: editorContainer))
        let stagingView = try XCTUnwrap(descendants(of: editorContainer, matching: StagingDiffView.self).first)
        XCTAssertTrue(stagingView.isHidden)

        modeControl.selectedSegment = WorkspaceMode.staging.rawValue
        _ = modeControl.sendAction(modeControl.action, to: modeControl.target)
        main.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(stagingView.isHidden)
        XCTAssertEqual(stagingView.frame.width, stagingView.superview?.bounds.width ?? 0, accuracy: 1)
        XCTAssertTrue(gutters.allSatisfy(\.isHiddenOrHasHiddenAncestor))
    }

    func testCommitButtonUsesCurrentBranchName() throws {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        sidebar.setCurrentBranchName("feature/sidebar-tabs")

        let commitButton = try XCTUnwrap(descendants(of: sidebar.view, matching: NSButton.self).first {
            $0.title.hasPrefix("Commit selected changes to ")
        })
        XCTAssertEqual(commitButton.title, "Commit selected changes to feature/sidebar-tabs")
    }

    func testStagingDiffColumnFillsWideViewport() throws {
        let stagingView = StagingDiffView(frame: NSRect(x: 0, y: 0, width: 1_800, height: 600))
        stagingView.setDocument(
            filePath: "example.txt",
            rows: [StagingDiffRow(
                kind: .context,
                oldLineNumber: 1,
                newLineNumber: 1,
                text: "short line",
                selectionID: nil
            )],
            selectedChanges: []
        )
        stagingView.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(descendants(of: stagingView, matching: NSScrollView.self).first)
        let tableView = try XCTUnwrap(descendants(of: stagingView, matching: NSTableView.self).first)
        let column = try XCTUnwrap(tableView.tableColumns.first)

        XCTAssertGreaterThanOrEqual(column.width, scrollView.contentSize.width - 1)
    }

    func testUncheckedStagingRowIsDimmerAndLongTextKeepsTrailingMargin() throws {
        let id = StagingChangeID(kind: .insertion, oldLineIndex: nil, newLineIndex: 0, text: "added")
        let longText = String(repeating: "wide text ", count: 60)
        let row = StagingDiffRow(
            kind: .insertion,
            oldLineNumber: nil,
            newLineNumber: 1,
            text: longText,
            selectionID: id
        )
        let stagingView = StagingDiffView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        stagingView.setDocument(filePath: "example.txt", rows: [row], selectedChanges: [id])
        stagingView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(descendants(of: stagingView, matching: NSTableView.self).first)
        let column = try XCTUnwrap(tableView.tableColumns.first)
        let rowView = try XCTUnwrap(tableView.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let selectedBackground = try XCTUnwrap(rowView.layer?.backgroundColor).alpha

        XCTAssertTrue(stagingView.beginPaint(atRow: 0))
        stagingView.endPaint()
        let unselectedBackground = try XCTUnwrap(rowView.layer?.backgroundColor).alpha

        let measuredTextWidth = (longText as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        ]).width
        XCTAssertLessThan(unselectedBackground, selectedBackground)
        XCTAssertGreaterThanOrEqual(column.width - measuredTextWidth, 188)
    }

    func testDraggingAcrossStagingRowsPaintsOneSelectionStateWithoutRetoggling() {
        let ids = [
            StagingChangeID(kind: .insertion, oldLineIndex: nil, newLineIndex: 0, text: "added one"),
            StagingChangeID(kind: .deletion, oldLineIndex: 1, newLineIndex: nil, text: "removed"),
            StagingChangeID(kind: .insertion, oldLineIndex: nil, newLineIndex: 2, text: "added two")
        ]
        let rows = [
            StagingDiffRow(kind: .insertion, oldLineNumber: nil, newLineNumber: 1, text: "added one", selectionID: ids[0]),
            StagingDiffRow(kind: .context, oldLineNumber: 2, newLineNumber: 2, text: "context", selectionID: nil),
            StagingDiffRow(kind: .deletion, oldLineNumber: 3, newLineNumber: nil, text: "removed", selectionID: ids[1]),
            StagingDiffRow(kind: .insertion, oldLineNumber: nil, newLineNumber: 3, text: "added two", selectionID: ids[2])
        ]
        let stagingView = StagingDiffView()
        var changes: [(StagingChangeID, Bool)] = []
        stagingView.onSetChangeSelection = { changes.append(($0, $1)) }
        stagingView.setDocument(filePath: "example.txt", rows: rows, selectedChanges: Set(ids))

        XCTAssertTrue(stagingView.beginPaint(atRow: 0))
        stagingView.continuePaint(toRow: 3)
        stagingView.continuePaint(toRow: 1)
        stagingView.endPaint()

        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(Set(changes.map(\.0)), Set(ids))
        XCTAssertTrue(changes.allSatisfy { !$0.1 })

        changes.removeAll()
        stagingView.setDocument(filePath: "example.txt", rows: rows, selectedChanges: [])
        XCTAssertTrue(stagingView.beginPaint(atRow: 3))
        stagingView.continuePaint(toRow: 0)
        stagingView.endPaint()

        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(Set(changes.map(\.0)), Set(ids))
        XCTAssertTrue(changes.allSatisfy(\.1))
    }

    func testChangeNavigationMenuUsesCommandShiftPeriodAndComma() throws {
        MainMenu.install()
        let navigateMenu = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first {
            $0.title == "Navigate"
        })
        let previous = try XCTUnwrap(navigateMenu.items.first { $0.title == "Previous Change" })
        let next = try XCTUnwrap(navigateMenu.items.first { $0.title == "Next Change" })

        XCTAssertEqual(previous.keyEquivalent, ",")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(next.keyEquivalent, ".")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .shift])
    }

    func testSidebarCanRevealAndSelectAFileInCollapsedFolders() {
        let rootURL = URL(fileURLWithPath: "/tmp/navigation-repository")
        let file = FileNode(
            name: "Changed.swift",
            relativePath: "Sources/Nested/Changed.swift",
            url: rootURL.appendingPathComponent("Sources/Nested/Changed.swift"),
            isDirectory: false,
            hasUnstagedChange: true,
            children: []
        )
        let nested = FileNode.directory(
            name: "Nested",
            relativePath: "Sources/Nested",
            url: rootURL.appendingPathComponent("Sources/Nested"),
            children: [file]
        )
        let sources = FileNode.directory(
            name: "Sources",
            relativePath: "Sources",
            url: rootURL.appendingPathComponent("Sources"),
            children: [nested]
        )
        let root = FileNode.directory(name: "repository", relativePath: "", url: rootURL, children: [sources])
        let sidebar = SidebarViewController()
        sidebar.loadView()
        sidebar.load(root: root)

        XCTAssertTrue(sidebar.selectFile(relativePath: file.relativePath))
    }

    func testReloadResolutionPreventsSaveFromOverwritingExternalEdit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditExternalEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("example.txt")
        try "original\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        editor.loadView()
        editor.resolveExternalFileConflict = { _ in .reloadFromDisk }
        XCTAssertTrue(try editor.open(
            file: fileURL,
            relativePath: "example.txt",
            repository: Repository(rootURL: directory),
            onSaved: {}
        ))
        let editableTextView = try XCTUnwrap(
            descendants(of: editor.view, matching: NSTextView.self).first(where: \.isEditable)
        )
        editableTextView.string = "buffer edit\n"
        try "external edit\n".write(to: fileURL, atomically: true, encoding: .utf8)

        try editor.saveCurrentFile()

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "external edit\n")
        XCTAssertEqual(editableTextView.string, "external edit\n")
    }

    func testSavingCleanBufferDoesNotRecreateExternallyDeletedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditExternalEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("example.txt")
        try "original\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        editor.loadView()
        XCTAssertTrue(try editor.open(
            file: fileURL,
            relativePath: "example.txt",
            repository: Repository(rootURL: directory),
            onSaved: {}
        ))
        try FileManager.default.removeItem(at: fileURL)

        try editor.saveCurrentFile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testWindowReactivationReloadsOnlyAfterOpenFileModificationDateChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditForegroundRefreshTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("example.txt")
        let initialText = "first\nsecond line\nthird\n"
        let externalText = "first\nSECOND externally\nthird\n"
        let initialDate = Date(timeIntervalSince1970: 1_800_000_000)
        try initialText.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: fileURL.path)

        let editor = EditorViewController()
        editor.loadView()
        XCTAssertTrue(try editor.open(
            file: fileURL,
            relativePath: "example.txt",
            repository: Repository(rootURL: directory),
            onSaved: {}
        ))
        let editableTextView = try XCTUnwrap(
            descendants(of: editor.view, matching: NSTextView.self).first(where: \.isEditable)
        )
        let originalCaret = ("first\n" as NSString).length + 3
        editableTextView.setSelectedRange(NSRange(location: originalCaret, length: 0))
        editor.captureForegroundState()

        try externalText.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: fileURL.path)
        XCTAssertFalse(try editor.refreshCurrentFileFromDisk(using: Repository(rootURL: directory)))
        XCTAssertEqual(editableTextView.string, initialText)

        editor.captureForegroundState()
        let changedDate = initialDate.addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: changedDate], ofItemAtPath: fileURL.path)
        XCTAssertTrue(try editor.refreshCurrentFileFromDisk(using: Repository(rootURL: directory)))
        XCTAssertEqual(editableTextView.string, externalText)
        XCTAssertEqual(editableTextView.selectedRange(), NSRange(location: originalCaret, length: 0))
    }

    func testOnlyEditableViewHighlightsActiveLogicalLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditActiveLineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("example.txt")
        try "first\nsecond\nthird\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        editor.loadView()
        XCTAssertTrue(try editor.open(
            file: fileURL,
            relativePath: "example.txt",
            repository: Repository(rootURL: directory),
            onSaved: {}
        ))
        let textViews = descendants(of: editor.view, matching: LineHighlightTextView.self)
        let editableTextView = try XCTUnwrap(textViews.first(where: \.isEditable))
        let committedTextView = try XCTUnwrap(textViews.first(where: { !$0.isEditable }))

        XCTAssertTrue(editableTextView.showsActiveLineHighlight)
        XCTAssertFalse(committedTextView.showsActiveLineHighlight)
        editableTextView.setSelectedRange(NSRange(location: ("first\n" as NSString).length + 2, length: 0))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: editableTextView))

        XCTAssertEqual(editableTextView.activeLine, 1)
        XCTAssertNil(committedTextView.activeLine)

        editableTextView.setSelectedRange(NSRange(location: (editableTextView.string as NSString).length, length: 0))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: editableTextView))

        let trailingLine = (editableTextView.string as NSString).lineCount
        let trailingRect = try XCTUnwrap(editableTextView.logicalLineRect(for: trailingLine))
        let layoutManager = try XCTUnwrap(editableTextView.layoutManager)
        XCTAssertEqual(editableTextView.activeLine, trailingLine)
        XCTAssertEqual(
            trailingRect.minY,
            editableTextView.textContainerOrigin.y + layoutManager.extraLineFragmentRect.minY,
            accuracy: 0.5
        )
        XCTAssertLessThan(trailingRect.minY, editableTextView.textContainerOrigin.y + layoutManager.usedRect(for: try XCTUnwrap(editableTextView.textContainer)).maxY)

        let statusLabel = try XCTUnwrap(descendants(of: editor.view, matching: NSTextField.self).first { $0.stringValue == "example.txt" })
        XCTAssertEqual(statusLabel.alignment, .left)
    }

    private func descendants<T: NSView>(of view: NSView, matching type: T.Type) -> [T] {
        var result: [T] = []
        if let match = view as? T {
            result.append(match)
        }
        for subview in view.subviews {
            result += descendants(of: subview, matching: type)
        }
        return result
    }
}
