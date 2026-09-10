import AppKit
import Foundation
import XCTest
@testable import DiffEdit

final class DiffEngineTests: XCTestCase {
    func testBlankGapReductionOnlyMarksRemovalOfTheEntireGap() {
        for newline in ["\n", "\r\n"] {
            let base = "one" + String(repeating: newline, count: 5) + "two"
            let reduced = DiffEngine.diff(base: base, current: "one" + String(repeating: newline, count: 3) + "two")
            XCTAssertTrue(reduced.currentDeletionMarkers.isEmpty)
            let removed = DiffEngine.diff(base: base, current: "one" + newline + "two")
            XCTAssertEqual(removed.currentDeletionMarkers.map(\.kind), [.lineBoundaryBefore])
        }
        XCTAssertTrue(DiffEngine.diff(base: "one\n\n\n\n", current: "one\n\n").currentDeletionMarkers.isEmpty)
        XCTAssertFalse(DiffEngine.diff(base: "one\n\n\n", current: "one\n").currentDeletionMarkers.isEmpty)
        XCTAssertFalse(DiffEngine.diff(base: "one\nremoved\n\ntwo", current: "one\n\ntwo").currentDeletionMarkers.isEmpty)
    }

    func testInsertedSentenceDoesNotMisalignFollowingWordEdit() {
        let original = "For example, CowPilot allows users to pause the agent, reject proposed actions, or take over part of a web task.\n"
        let edited = original.replacingOccurrences(of: "CowPilot", with: "CoPilot")
        let base = "One common approach is to let users directly intervene.\n" + original + "Unchanged ending.\n"
        let prefix = "Conversational refinement lets users provide follow-up instructions.\nBeyond conversation, one common approach is to let users directly intervene.\n"
        let current = prefix + edited + "Unchanged ending.\n"
        let result = DiffEngine.diff(base: base, current: current)
        let sentenceRange = NSRange(location: (prefix as NSString).length, length: (edited as NSString).length)
        let sentenceHighlights = result.insertedWordRanges.filter { NSIntersectionRange($0, sentenceRange).length > 0 }
        XCTAssertEqual(highlightedStrings(sentenceHighlights, in: current), ["CoPilot"])
        XCTAssertEqual(result.currentToBaseLine[2], 1)
    }

    func testDeletionBarsSeparatedOnlyByBlankSpaceAreCoalesced() {
        let merged = DiffEngine.diff(base: "start\nremoved one\n\nremoved two\nend\n", current: "start\n\nend\n")
        XCTAssertEqual(merged.currentDeletionMarkers.map(\.line), [1])
        let separate = DiffEngine.diff(base: "start\nremoved one\nkept\nremoved two\nend\n", current: "start\nkept\nend\n")
        XCTAssertEqual(separate.currentDeletionMarkers.map(\.line), [1, 2])
    }

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

    func testRepeatedConjunctionDoesNotMoveDeletionIntoUnchangedSuffix() {
        let original = #"  \item \textbf{Immersive, and made only of the visitor's material.} Walking into a reconstruction of one's own record heightens the sense of being back~\cite{danry2025}, so the space is entered rather than scrolled. Everything in it is generated from the visitor's frames and words, and no text panel or transcript stands between the visitor and their memory (Sections~\ref{sec:capture} and~\ref{sec:experience})."#
        let revised = #"  \item \textbf{Immersive and grounded in the visit record.} Walking into a reconstruction of one's own record heightens the sense of being back~\cite{danry2025}, so the space is entered rather than scrolled. Everything in it derives from the recorded visit and the visitor's review, and no text panel or transcript stands between the visitor and their memory (Sections~\ref{sec:capture} and~\ref{sec:experience})."#
        for (base, current) in [(original, revised), (revised, original)] {
            let result = DiffEngine.diff(base: base, current: current)
            let suffix = (current as NSString).range(of: ", and no text panel")
            XCTAssertFalse(result.currentDeletionMarkers.contains { $0.column > suffix.location },
                           "Markers: \(result.currentDeletionMarkers)")
            XCTAssertFalse(result.insertedWordRanges.contains { NSIntersectionRange($0, NSRange(location: suffix.location, length: (current as NSString).length - suffix.location)).length > 0 })
        }
    }

    func testSentenceLineBreakDoesNotHighlightUnchangedWords() {
        let base = "A short sentence. The following sentence is considerably longer and should remain unchanged.\n"
        for separator in ["\n", "\n ", "\r\n"] {
            let current = base.replacingOccurrences(of: ". The", with: "." + separator + "The")
            let result = DiffEngine.diff(base: base, current: current)
            XCTAssertTrue(result.deletedWordRanges.isEmpty)
            XCTAssertTrue(result.insertedWordRanges.isEmpty)
            XCTAssertTrue(result.currentDeletionMarkers.isEmpty)
            XCTAssertEqual(result.currentToBaseLine[1], 0)
            XCTAssertEqual(result.currentToBaseColumn[LineColumn(line: 1, column: separator.hasSuffix(" ") ? 1 : 0)], 18)
            var restored = current
            for action in result.revertActions.sorted(by: { $0.currentRange.location > $1.currentRange.location }) {
                restored = applying(action, to: restored)
            }
            XCTAssertEqual(restored, base)
        }
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

    func testRewrittenSentenceKeepsReplacementPunctuationAndHasNoDeletionMarker() {
        let base = #"Across eight downstream tasks, \name matches or outperforms the task-specific models that have dominated prior work, even when we exclude the target dataset from pretraining and train each head on a fraction of the labels."#
        let current = "The resulting frozen encoder supports eight downstream tasks spanning classification, regression, dense prediction, and 3D hand-pose estimation through lightweight task-specific heads."

        let result = DiffEngine.diff(base: base, current: current)
        let nsCurrent = current as NSString
        let comma = nsCurrent.range(of: ", and")
        let conjunction = nsCurrent.range(of: "and", options: [], range: comma)

        XCTAssertTrue(result.insertedWordRanges.contains { NSLocationInRange(comma.location, $0) })
        XCTAssertFalse(result.insertedWordRanges.contains { NSIntersectionRange($0, conjunction).length > 0 })
        XCTAssertTrue(result.currentDeletionMarkers.isEmpty)
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

    func testInlineDeletionMarkersNeverTouchInsertedText() {
        let cases = [
            ("alpha old beta\n", "alpha new beta\n"),
            ("one old two removed three\n", "one new two three\n"),
            ("alpha beta alpha gamma\n", "alpha new alpha\n"),
            (
                #"Across eight downstream tasks, \name matches or outperforms the task-specific models that have dominated prior work, even when we exclude the target dataset from pretraining and train each head on a fraction of the labels."#,
                "The resulting frozen encoder supports eight downstream tasks spanning classification, regression, dense prediction, and 3D hand-pose estimation through lightweight task-specific heads."
            )
        ]

        for (base, current) in cases {
            let result = DiffEngine.diff(base: base, current: current)
            let nsCurrent = current as NSString
            for marker in result.currentDeletionMarkers where marker.kind == .inline {
                for insertion in result.insertedWordRanges {
                    let insertionEnd = NSMaxRange(insertion)
                    XCTAssertFalse(marker.column >= insertion.location && marker.column <= insertionEnd)
                    let gap: NSRange
                    if marker.column < insertion.location {
                        gap = NSRange(location: marker.column, length: insertion.location - marker.column)
                    } else {
                        gap = NSRange(location: insertionEnd, length: marker.column - insertionEnd)
                    }
                    guard NSMaxRange(gap) <= nsCurrent.length else { continue }
                    let gapText = nsCurrent.substring(with: gap)
                    XCTAssertNotNil(gapText.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted))
                }
            }
        }
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
    func testFolderScanPrunesHiddenDescendantsAndPreservesVisibleChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try runGit(["init", "-q"], in: directory)
        for path in [".build/cache/leaked.txt", "visible/file.txt"] {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "content".write(to: url, atomically: true, encoding: .utf8)
        }
        let repository = Repository(rootURL: directory)
        let snapshot = repository.statusSnapshot()
        XCTAssertEqual(snapshot.tree.filesInDisplayOrder.map(\.relativePath), ["visible/file.txt"])
        XCTAssertTrue(try XCTUnwrap(snapshot.tree.find(relativePath: "visible/file.txt")).hasUnstagedChange)
        XCTAssertEqual(repository.allFiles().map(\.relativePath), ["visible/file.txt"])
        repository.refreshStatus()
        XCTAssertEqual(repository.unstagedPaths, snapshot.unstagedPaths)
    }

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
    func testPastPaneEmphasizesReplacementAsAStableUnit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGitForUITest(["init", "-q"], in: directory)
        try runGitForUITest(["config", "user.name", "DiffEdit Tests"], in: directory)
        try runGitForUITest(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let file = directory.appendingPathComponent("replacement.txt")
        try "alpha old tired words omega\n".write(to: file, atomically: true, encoding: .utf8)
        try runGitForUITest(["add", "."], in: directory)
        try runGitForUITest(["commit", "-qm", "initial"], in: directory)
        try "alpha extraordinary fresh phrase omega\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 600, height: 700))
        XCTAssertTrue(try editor.open(file: file, relativePath: "replacement.txt", repository: Repository(rootURL: directory), onSaved: {}))
        let texts = descendants(of: editor.view, matching: LineHighlightTextView.self)
        let current = try XCTUnwrap(texts.first(where: \.isEditable))
        let past = try XCTUnwrap(texts.first(where: { !$0.isEditable }))
        let layout = try XCTUnwrap(past.layoutManager)
        XCTAssertFalse(past.showsCaretMarker)
        let oldRange = (past.string as NSString).range(of: "old tired words")
        for offset in 6...32 {
            current.setSelectedRange(NSRange(location: offset, length: 0))
            editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: current))
            var effective = NSRange()
            let color = layout.temporaryAttribute(.backgroundColor, atCharacterIndex: oldRange.location, effectiveRange: &effective) as? NSColor
            XCTAssertEqual(color, DiffPalette.activeDeletedText)
            XCTAssertEqual(effective, oldRange)
            XCTAssertEqual(past.caretMarker?.column, 6)
        }
        for offset in [2, 5] {
            current.setSelectedRange(NSRange(location: offset, length: 0))
            editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: current))
            XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: oldRange.location, effectiveRange: nil))
            let unchanged = (past.string as NSString).range(of: "alpha")
            var effective = NSRange()
            XCTAssertEqual(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: unchanged.location, effectiveRange: &effective) as? NSColor, DiffPalette.correspondingWord)
            XCTAssertEqual(effective, unchanged)
        }
    }

    func testSplitEditedParagraphKeepsPastPaneAtCorrespondingSentence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGitForUITest(["init", "-q"], in: directory)
        try runGitForUITest(["config", "user.name", "DiffEdit Tests"], in: directory)
        try runGitForUITest(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let prefix = String(repeating: "Context line.\n", count: 48)
        let oldParagraph = #"Everything Keepsake builds is made from what the visitor looked at and said, so the visit is recorded without the companion setting the agenda. The visitor tours the museum with the Gemini app on a phone, under a venue-specific instruction that casts the companion as a knowledgeable friend who explains what the visitor has already chosen to look at and is told not to redirect them, rank works or attribute feelings to them (supplementary material). The instruction constrains the companion but does not make the recording a clean trace of attention (Section~\ref{sec:f-omissions}). Visitors also photograph moments they want to keep, as screenshots of the companion's camera view so that they need not leave the conversation; the study uses these photographs unchanged as the photo album."#
        let firstSentence = #"Everything Keepsake builds derives from what the visitor looked at and said, so the visit is recorded without the companion setting the agenda."#
        let secondSentence = #"The visitor tours the museum with the Gemini app on a phone. A venue-specific instruction casts the companion as a knowledgeable friend who explains what the visitor has already chosen to view. It also tells the companion not to redirect the visitor, rank works or attribute feelings to them (supplementary material). The instruction constrains the companion but does not make the recording a clean trace of attention (Section~\ref{sec:f-omissions}). Visitors also capture moments they want to keep as screenshots of the companion's camera view, which lets them remain in the conversation. The study uses these screenshots unchanged as the photo album."#
        let base = prefix + oldParagraph + "\n"
        let revised = prefix + firstSentence + "\n" + secondSentence + "\n"
        let file = directory.appendingPathComponent("split.txt")
        try base.write(to: file, atomically: true, encoding: .utf8)
        try runGitForUITest(["add", "."], in: directory)
        try runGitForUITest(["commit", "-qm", "initial"], in: directory)
        try revised.write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 600, height: 700))
        XCTAssertTrue(try editor.open(file: file, relativePath: "split.txt", repository: Repository(rootURL: directory), onSaved: {}))
        editor.view.layoutSubtreeIfNeeded()
        let texts = descendants(of: editor.view, matching: LineHighlightTextView.self)
        let current = try XCTUnwrap(texts.first(where: \.isEditable))
        let past = try XCTUnwrap(texts.first(where: { !$0.isEditable }))
        let viewport = try XCTUnwrap(past.enclosingScrollView?.contentView)
        let layout = try XCTUnwrap(past.layoutManager)
        let container = try XCTUnwrap(past.textContainer)
        // Visit the continuation first, then return to column zero of line 49.
        for (sentence, expectedColumn) in [(secondSentence, (oldParagraph as NSString).range(of: "The visitor tours").location), (firstSentence, 0)] {
            current.setSelectedRange(NSRange(location: (revised as NSString).range(of: sentence).location, length: 0))
            editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: current))
            let marker = try XCTUnwrap(past.caretMarker)
            XCTAssertEqual(marker.column, expectedColumn)
            let start = (past.string as NSString).lineStartOffset(forLineIndex: marker.line)
            XCTAssertTrue((past.string as NSString).substring(from: start).hasPrefix("Everything Keepsake builds"))
            let glyph = layout.glyphIndexForCharacter(at: start + expectedColumn)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            XCTAssertEqual(rect.midY + past.textContainerOrigin.y, viewport.bounds.midY, accuracy: 1)
        }
    }

    func testPastPaneFollowsCaretWithinAWrappedParagraph() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGitForUITest(["init", "-q"], in: directory)
        try runGitForUITest(["config", "user.name", "DiffEdit Tests"], in: directory)
        try runGitForUITest(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let file = directory.appendingPathComponent("wrapped.txt")
        let paragraph = String(repeating: "A long paragraph with several words to wrap. ", count: 100)
        try (paragraph + "\n").write(to: file, atomically: true, encoding: .utf8)
        try runGitForUITest(["add", "."], in: directory)
        try runGitForUITest(["commit", "-qm", "initial"], in: directory)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 600, height: 700))
        XCTAssertTrue(try editor.open(file: file, relativePath: "wrapped.txt", repository: Repository(rootURL: directory), onSaved: {}))
        editor.view.layoutSubtreeIfNeeded()
        let texts = descendants(of: editor.view, matching: LineHighlightTextView.self)
        let current = try XCTUnwrap(texts.first(where: \.isEditable))
        let past = try XCTUnwrap(texts.first(where: { !$0.isEditable }))
        let viewport = try XCTUnwrap(past.enclosingScrollView?.contentView)
        let initialY = viewport.bounds.minY
        current.setSelectedRange(NSRange(location: (paragraph as NSString).length / 2, length: 0))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: current))
        XCTAssertGreaterThan(viewport.bounds.minY, initialY + 100)
        let marker = try XCTUnwrap(past.caretMarker)
        let location = (past.string as NSString).lineStartOffset(forLineIndex: marker.line) + marker.column
        let layout = try XCTUnwrap(past.layoutManager)
        let container = try XCTUnwrap(past.textContainer)
        let glyph = layout.glyphIndexForCharacter(at: location)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        XCTAssertEqual(rect.midY + past.textContainerOrigin.y, viewport.bounds.midY, accuracy: 1)
        current.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: current))
        XCTAssertEqual(viewport.bounds.minY, initialY, accuracy: 1)
    }

    func testTypingMovesDeletionAnchorsImmediatelyAndEnterKeepsLineShading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGitForUITest(["init", "-q"], in: directory)
        try runGitForUITest(["config", "user.name", "DiffEdit Tests"], in: directory)
        try runGitForUITest(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let file = directory.appendingPathComponent("markers.txt")
        try "alpha removed beta\nnext\n".write(to: file, atomically: true, encoding: .utf8)
        try runGitForUITest(["add", "."], in: directory)
        try runGitForUITest(["commit", "-qm", "initial"], in: directory)
        try "alpha beta\nnext\n".write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 900, height: 700))
        XCTAssertTrue(try editor.open(file: file, relativePath: "markers.txt", repository: Repository(rootURL: directory), onSaved: {}))
        let text = try XCTUnwrap(descendants(of: editor.view, matching: LineHighlightTextView.self).first(where: \.isEditable))
        XCTAssertEqual(text.deletionMarkers.first?.column, 6)
        text.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(text.deletionMarkers.first?.column, 7)
        text.insertText("Y", replacementRange: NSRange(location: 11, length: 0))
        XCTAssertEqual(text.deletionMarkers.first?.column, 7)
        text.insertText("\n", replacementRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(text.deletionMarkers.first?.line, 1)
        XCTAssertEqual(text.deletionMarkers.first?.column, 4)
        XCTAssertTrue(text.fullLineHighlightedLines.isSuperset(of: [0, 1]))
    }

    func testTypingUndoGroupsWordsAndBreaksAtCursorMovement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("undo.txt")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 900, height: 700))
        XCTAssertTrue(try editor.open(file: file, relativePath: "undo.txt", repository: Repository(rootURL: directory), onSaved: {}))
        let text = try XCTUnwrap(descendants(of: editor.view, matching: LineHighlightTextView.self).first(where: \.isEditable))
        let undo = try XCTUnwrap(text.undoManager)
        window.makeFirstResponder(text)
        func type(_ string: String) {
            for character in string {
                text.insertText(String(character), replacementRange: text.selectedRange())
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        type("hel")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        type("lo world")
        undo.undo()
        XCTAssertEqual(text.string, "hello ")
        undo.undo()
        XCTAssertEqual(text.string, "")
        undo.redo()
        undo.redo()
        XCTAssertEqual(text.string, "hello world")
        let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
        text.keyDown(with: arrow)
        type("xy")
        undo.undo()
        XCTAssertEqual(text.string, "hello world")
        type("ab")
        let beforeFocusChange = text.string
        window.makeFirstResponder(nil)
        window.makeFirstResponder(text)
        type("cd")
        undo.undo()
        XCTAssertEqual(text.string, beforeFocusChange)
    }

    func testAsyncSavePreservesNewerEditsAndOpenDiscardsStaleResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("first.txt")
        let other = directory.appendingPathComponent("second.txt")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        try "second\n".write(to: other, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 900, height: 700))
        let repository = Repository(rootURL: directory)
        XCTAssertTrue(try editor.open(file: file, relativePath: "first.txt", repository: repository, onSaved: {}))
        let text = try XCTUnwrap(descendants(of: editor.view, matching: LineHighlightTextView.self).first(where: \.isEditable))
        text.insertText("saved\n", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        let saved = expectation(description: "background save")
        editor.saveCurrentFileAsync { result in
            if case let .failure(error) = result { XCTFail(error.localizedDescription) }
            saved.fulfill()
        }
        XCTAssertTrue(editor.isSaving)
        text.insertText("newer\n", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved\n")
        XCTAssertEqual(text.string, "saved\nnewer\n")
        XCTAssertTrue(editor.hasUnsavedChanges)
        let queued = expectation(description: "repeated saves")
        queued.expectedFulfillmentCount = 2
        editor.saveCurrentFileAsync { _ in queued.fulfill() }
        text.insertText("latest\n", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        editor.saveCurrentFileAsync { _ in queued.fulfill() }
        wait(for: [queued], timeout: 5)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved\nnewer\nlatest\n")
        XCTAssertFalse(editor.hasUnsavedChanges)
        let opened = expectation(description: "latest open")
        editor.openAsync(file: file, relativePath: "first.txt", repository: repository, onSaved: {}) { _ in XCTFail("Stale open applied") }
        editor.openAsync(file: other, relativePath: "second.txt", repository: repository, onSaved: {}) { result in
            if case let .failure(error) = result { XCTFail(error.localizedDescription) }
            opened.fulfill()
        }
        wait(for: [opened], timeout: 5)
        XCTAssertEqual(editor.currentDocumentPath, "second.txt")
        XCTAssertEqual(text.string, "second\n")
        text.insertText("local\n", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        try "external\n".write(to: other, atomically: true, encoding: .utf8)
        editor.resolveExternalFileConflict = { _ in
            XCTAssertTrue(Thread.isMainThread)
            return .cancel
        }
        let cancelled = expectation(description: "external conflict stays on main thread")
        editor.saveCurrentFileAsync { result in
            if case .success = result { XCTFail("Conflicting save should be cancelled") }
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 5)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "external\n")
        XCTAssertEqual(text.string, "local\n")
    }

    func testCommitRunsBehindOverlayAndCommitsCapturedBuffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGitForUITest(["init", "-q"], in: directory)
        try runGitForUITest(["config", "user.name", "DiffEdit Tests"], in: directory)
        try runGitForUITest(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let file = directory.appendingPathComponent("example.txt")
        try "old\n".write(to: file, atomically: true, encoding: .utf8)
        try runGitForUITest(["add", "."], in: directory)
        try runGitForUITest(["commit", "-qm", "initial"], in: directory)
        let main = MainViewController()
        let window = NSWindow(contentViewController: main)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 900, height: 700))
        main.loadFolder(directory)
        let outline = try XCTUnwrap(descendants(of: main.view, matching: NSOutlineView.self).first)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in outline.numberOfRows > 0 }, object: nil)], timeout: 5)
        let editor = try XCTUnwrap(main.splitViewItems.last?.viewController as? EditorViewController)
        let sidebar = try XCTUnwrap(main.splitViewItems.first?.viewController as? SidebarViewController)
        XCTAssertTrue(try editor.open(file: file, relativePath: "example.txt", repository: Repository(rootURL: directory), onSaved: {}))
        let text = try XCTUnwrap(descendants(of: editor.view, matching: LineHighlightTextView.self).first(where: \.isEditable))
        text.insertText("committed buffer\n", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        sidebar.onCommit?("background commit")
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(descendants(of: main.view, matching: NSTextField.self).contains { $0.stringValue == "Committing…" })
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in text.isEditable }, object: nil)], timeout: 10)
        XCTAssertFalse(descendants(of: main.view, matching: NSTextField.self).contains { $0.stringValue == "Committing…" })
        XCTAssertEqual(Repository(rootURL: directory).committedText(relativePath: "example.txt"), "committed buffer\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old\n")
    }

    func testQuickOpenOnlyAppliesLatestBackgroundFilter() throws {
        var opened: String?
        let controller = QuickOpenController(files: [], onClose: {}) { opened = $0.relativePath }
        let view = try XCTUnwrap(controller.window?.contentView)
        let field = try XCTUnwrap(descendants(of: view, matching: NSSearchField.self).first)
        let table = try XCTUnwrap(descendants(of: view, matching: NSTableView.self).first)
        controller.setFiles(["alpha.txt", "beta.txt", "beta.swift"].map {
            FileReference(relativePath: $0, url: URL(fileURLWithPath: "/tmp/" + $0))
        })
        field.stringValue = "alpha"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.stringValue = "beta swift"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        controller.acceptSelection()
        XCTAssertNil(opened)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            table.numberOfRows == 1 && table.selectedRow == 0
        }, object: nil)
        wait(for: [ready], timeout: 3)
        controller.acceptSelection()
        XCTAssertEqual(opened, "beta.swift")
    }

    func testTypingAndHighlightRefreshPreserveMultilineText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("multiline.txt")
        let original = "first line\n\nsecond line\nthird line\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 900, height: 700))
        XCTAssertTrue(try editor.open(file: file, relativePath: "multiline.txt", repository: Repository(rootURL: directory), onSaved: {}))
        let text = try XCTUnwrap(descendants(of: editor.view, matching: LineHighlightTextView.self).first(where: \.isEditable))
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 6, length: 0))
        text.insertText("changed ", replacementRange: text.selectedRange())
        editor.adjustFontSize(by: 0)
        XCTAssertEqual(text.string, "first changed line\n\nsecond line\nthird line\n")
        XCTAssertFalse(text.isFieldEditor)
        let first = try XCTUnwrap(text.logicalLineRect(for: 0))
        let third = try XCTUnwrap(text.logicalLineRect(for: 2))
        XCTAssertGreaterThan(third.minY, first.maxY)
        text.insertNewline(nil)
        editor.adjustFontSize(by: 0)
        XCTAssertEqual(text.string, "first changed \nline\n\nsecond line\nthird line\n")
        try editor.saveCurrentFile()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text.string)
    }

    func testSearchWrapsAndReplaceIsUndoableWithoutResizingPastPane() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("search.txt")
        try "alpha beta ALPHA".write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 900, height: 700))
        XCTAssertTrue(try editor.open(file: file, relativePath: "search.txt", repository: Repository(rootURL: directory), onSaved: {}))
        editor.view.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(descendants(of: editor.view, matching: EditorSplitView.self).first)
        let text = try XCTUnwrap(descendants(of: editor.view, matching: LineHighlightTextView.self).first(where: \.isEditable))
        let pastHeight = split.subviews[0].frame.height
        let initialHeight = split.subviews[1].frame.height
        editor.showSearch(replacing: false)
        let fields = descendants(of: editor.view, matching: NSTextField.self)
        let find = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "findField" })
        let replace = try XCTUnwrap(fields.first { $0.identifier?.rawValue == "replacementField" })
        XCTAssertFalse(find.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(replace.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(split.subviews[0].frame.height, pastHeight, accuracy: 1)
        XCTAssertLessThan(split.subviews[1].frame.height, initialHeight)
        find.stringValue = "alpha"
        editor.findMatch(backwards: false)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
        editor.findMatch(backwards: false)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 11, length: 5))
        editor.findMatch(backwards: false)
        XCTAssertEqual(text.selectedRange().location, 0)
        editor.findMatch(backwards: true)
        XCTAssertEqual(text.selectedRange().location, 11)
        let searchHeight = split.subviews[1].frame.height
        editor.showSearch(replacing: true)
        XCTAssertFalse(replace.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(split.subviews[0].frame.height, pastHeight, accuracy: 1)
        XCTAssertLessThan(split.subviews[1].frame.height, searchHeight)
        replace.stringValue = "omega"
        let button = try XCTUnwrap(descendants(of: editor.view, matching: NSButton.self).first { $0.title == "Replace All" })
        let undo = try XCTUnwrap(text.undoManager)
        undo.beginUndoGrouping()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        undo.endUndoGrouping()
        XCTAssertEqual(text.string, "omega beta omega")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(text.string, "alpha beta ALPHA")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha beta ALPHA")
    }

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
        XCTAssertTrue(gutters.allSatisfy(\.isHiddenOrHasHiddenAncestor))

        modeControl.selectedSegment = WorkspaceMode.staging.rawValue
        _ = modeControl.sendAction(modeControl.action, to: modeControl.target)
        main.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(stagingView.isHidden)
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

    func testEditorDividerResizesContextEnforcesMinimumsAndRestoresHeight() throws {
        let defaults = UserDefaults.standard
        let defaultsKey = EditorViewController.committedPaneHeightDefaultsKey
        let previousValue = defaults.object(forKey: defaultsKey)
        defaults.removeObject(forKey: defaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffEditDividerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runGitForUITest(["init", "-q"], in: directory)
        try runGitForUITest(["config", "user.name", "DiffEdit Tests"], in: directory)
        try runGitForUITest(["config", "user.email", "diffedit-tests@example.invalid"], in: directory)
        let fileURL = directory.appendingPathComponent("example.txt")
        let contents = (1...40).map { "line \($0)\n" }.joined()
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try runGitForUITest(["add", "example.txt"], in: directory)
        try runGitForUITest(["commit", "-q", "-m", "Initial"], in: directory)

        let editor = EditorViewController()
        editor.loadView()
        editor.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        editor.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(try editor.open(
            file: fileURL,
            relativePath: "example.txt",
            repository: Repository(rootURL: directory),
            onSaved: {}
        ))
        let splitView = try XCTUnwrap(descendants(of: editor.view, matching: EditorSplitView.self).first)
        let textViews = descendants(of: editor.view, matching: LineHighlightTextView.self)
        let editableTextView = try XCTUnwrap(textViews.first(where: \.isEditable))
        let committedTextView = try XCTUnwrap(textViews.first(where: { !$0.isEditable }))
        let committedRow = splitView.subviews[0]
        let mainRow = splitView.subviews[1]
        let editableLineHeight = try XCTUnwrap(editableTextView.layoutManager).defaultLineHeight(for: try XCTUnwrap(editableTextView.font)) + 2
        let committedLineHeight = try XCTUnwrap(committedTextView.layoutManager).defaultLineHeight(for: try XCTUnwrap(committedTextView.font)) + 2
        XCTAssertTrue(committedTextView.isDescendant(of: committedRow))
        XCTAssertTrue(editableTextView.isDescendant(of: mainRow))
        XCTAssertLessThan(committedRow.frame.minY, mainRow.frame.minY)
        XCTAssertEqual(
            committedRow.frame.height,
            ceil(committedTextView.textContainerInset.height * 2 + committedLineHeight * 5),
            accuracy: 1
        )

        splitView.setPosition(0, ofDividerAt: 0)
        XCTAssertGreaterThanOrEqual(
            committedRow.frame.height,
            committedTextView.textContainerInset.height * 2 + committedLineHeight * 2 - 1
        )
        splitView.setPosition(splitView.bounds.height, ofDividerAt: 0)
        XCTAssertGreaterThanOrEqual(
            mainRow.frame.height,
            editableTextView.textContainerInset.height * 2 + editableLineHeight * 5 - 1
        )

        let caretLocation = (contents as NSString).lineStartOffset(forLineIndex: 20)
        editableTextView.setSelectedRange(NSRange(location: caretLocation, length: 0))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: editableTextView))
        splitView.setPosition(70, ofDividerAt: 0)
        let compactContextLineCount = (committedTextView.string as NSString).lineCount
        splitView.setPosition(220, ofDividerAt: 0)
        let expandedContextLineCount = (committedTextView.string as NSString).lineCount

        XCTAssertGreaterThan(expandedContextLineCount, compactContextLineCount)
        XCTAssertEqual(committedTextView.caretMarker?.line, expandedContextLineCount / 2)
        let committedViewport = try XCTUnwrap(committedTextView.enclosingScrollView?.contentView.bounds)
        let centeredLineRect = try XCTUnwrap(
            committedTextView.logicalLineRect(for: try XCTUnwrap(committedTextView.caretMarker?.line))
        )
        XCTAssertEqual(
            centeredLineRect.midY - committedViewport.minY,
            committedViewport.height / 2,
            accuracy: 1
        )

        let persistedHeight: CGFloat = 180
        splitView.setPosition(persistedHeight, ofDividerAt: 0)
        let snappedPersistedHeight = committedRow.frame.height
        XCTAssertEqual(defaults.double(forKey: defaultsKey), snappedPersistedHeight, accuracy: 1)
        let snappedContentHeight = snappedPersistedHeight - committedTextView.textContainerInset.height * 2
        XCTAssertEqual(
            snappedContentHeight / committedLineHeight,
            (snappedContentHeight / committedLineHeight).rounded(),
            accuracy: 0.01
        )

        editor.view.frame.size.height += 250
        editor.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(committedRow.frame.height, snappedPersistedHeight, accuracy: 1)
        XCTAssertEqual(defaults.double(forKey: defaultsKey), snappedPersistedHeight, accuracy: 1)

        let restoredEditor = EditorViewController()
        restoredEditor.loadView()
        restoredEditor.view.frame = editor.view.frame
        restoredEditor.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(try restoredEditor.open(
            file: fileURL,
            relativePath: "example.txt",
            repository: Repository(rootURL: directory),
            onSaved: {}
        ))
        let restoredSplit = try XCTUnwrap(descendants(of: restoredEditor.view, matching: EditorSplitView.self).first)
        XCTAssertEqual(restoredSplit.subviews[0].frame.height, snappedPersistedHeight, accuracy: 1)

        let window = NSWindow(contentViewController: restoredEditor)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1_180, height: 820))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(restoredSplit.subviews[0].frame.height, snappedPersistedHeight, accuracy: 1)
        restoredEditor.setMode(.staging)
        window.contentView?.layoutSubtreeIfNeeded()
        restoredEditor.setMode(.editing)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(restoredSplit.subviews[0].frame.height, snappedPersistedHeight, accuracy: 1)
        XCTAssertEqual(defaults.double(forKey: defaultsKey), snappedPersistedHeight, accuracy: 1)
    }

    func testStagingDiffColumnFillsWideViewport() throws {
        let stagingView = StagingDiffView(frame: NSRect(x: 0, y: 0, width: 1_800, height: 600))
        stagingView.setDocument(
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
        let rowView = try XCTUnwrap(tableView.view(atColumn: 0, row: 0, makeIfNecessary: true))

        XCTAssertGreaterThanOrEqual(column.width, scrollView.contentSize.width - 1)
        XCTAssertEqual(tableView.style, .plain)
        XCTAssertEqual(scrollView.frame.minX, stagingView.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(scrollView.frame.maxX, stagingView.bounds.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(rowView.frame.minX, tableView.bounds.minX, accuracy: 0.5)
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
        stagingView.setDocument(rows: [row], selectedChanges: [id])
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
        stagingView.setDocument(rows: rows, selectedChanges: Set(ids))

        XCTAssertTrue(stagingView.beginPaint(atRow: 0))
        stagingView.continuePaint(toRow: 3)
        stagingView.continuePaint(toRow: 1)
        stagingView.endPaint()

        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(Set(changes.map(\.0)), Set(ids))
        XCTAssertTrue(changes.allSatisfy { !$0.1 })

        changes.removeAll()
        stagingView.setDocument(rows: rows, selectedChanges: [])
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

        let statusLabel = try XCTUnwrap(descendants(of: editor.view, matching: NSTextField.self).first { $0.identifier?.rawValue == "editorStatus" })
        XCTAssertEqual(statusLabel.alignment, .left)
        XCTAssertEqual(statusLabel.stringValue, "")
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

    private func runGitForUITest(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RepositoryError.commandFailed(String(data: output, encoding: .utf8) ?? "")
        }
    }
}
