import Foundation

struct DiffResult {
    var currentTouchedLines: Set<Int>
    var baseTouchedLines: Set<Int>
    var insertedWordRanges: [NSRange]
    var deletedWordRanges: [LineRange]
    var currentDeletionMarkers: [DeletionMarker]
    var currentToBaseLine: [Int: Int]
    var currentToBaseColumn: [LineColumn: Int]
    var revertActions: [RevertAction]

    static let empty = DiffResult(currentTouchedLines: [], baseTouchedLines: [], insertedWordRanges: [], deletedWordRanges: [], currentDeletionMarkers: [], currentToBaseLine: [:], currentToBaseColumn: [:], revertActions: [])
}

final class RevertAction: NSObject {
    let currentRange: NSRange
    let replacement: String

    init(currentRange: NSRange, replacement: String) {
        self.currentRange = currentRange
        self.replacement = replacement
    }
}

struct LineRange {
    let line: Int
    let range: NSRange
}

struct DeletionMarker {
    let line: Int
    let column: Int
    let kind: Kind

    enum Kind: Equatable {
        case inline
        case lineBoundaryBefore
        case lineBoundaryAfter
    }

    init(line: Int, column: Int, kind: Kind = .inline) {
        self.line = line
        self.column = column
        self.kind = kind
    }
}

struct LineColumn: Hashable {
    let line: Int
    let column: Int
}

struct CaretMarker {
    let line: Int
    let column: Int
}

struct SelectiveStagingPlan {
    let selectableChanges: Set<StagingChangeID>
    let diffRows: [StagingDiffRow]
    private let chunks: [Chunk]

    fileprivate init(selectableChanges: Set<StagingChangeID>, diffRows: [StagingDiffRow], chunks: [Chunk]) {
        self.selectableChanges = selectableChanges
        self.diffRows = diffRows
        self.chunks = chunks
    }

    func text(selectedChanges: Set<StagingChangeID>) -> String {
        chunks.map { chunk in
            switch chunk {
            case let .unchanged(text):
                return text
            case let .changed(id, selected, unselected):
                return selectedChanges.contains(id) ? selected : unselected
            }
        }.joined()
    }

    fileprivate enum Chunk {
        case unchanged(String)
        case changed(id: StagingChangeID, selected: String, unselected: String)
    }
}

enum StagingDiffRowKind: Hashable {
    case context
    case deletion
    case insertion
    case separator
}

struct StagingChangeID: Hashable {
    let kind: StagingDiffRowKind
    let oldLineIndex: Int?
    let newLineIndex: Int?
    let text: String
}

struct StagingDiffRow {
    let kind: StagingDiffRowKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String
    let selectionID: StagingChangeID?
}

enum EditorShortcut {
    case nextChangedGroup
    case previousChangedGroup
    case nextChangedLine
    case previousChangedLine
    case previousParagraph
    case nextParagraph
}

enum ChangeNavigationDirection {
    case previous
    case next
}

enum ChangedLineNavigator {
    static func groups(for lines: Set<Int>) -> [ClosedRange<Int>] {
        let sortedLines = lines.sorted()
        guard let first = sortedLines.first else { return [] }
        var result: [ClosedRange<Int>] = []
        var start = first
        var previous = first
        for line in sortedLines.dropFirst() {
            if line == previous + 1 {
                previous = line
            } else {
                result.append(start...previous)
                start = line
                previous = line
            }
        }
        result.append(start...previous)
        return result
    }

    static func adjacentTarget(
        in lines: Set<Int>,
        from currentLine: Int,
        direction: ChangeNavigationDirection
    ) -> Int? {
        let groups = groups(for: lines)
        switch direction {
        case .next:
            return groups.first(where: { $0.lowerBound > currentLine })?.lowerBound
        case .previous:
            return groups.reversed().first(where: { $0.upperBound < currentLine })?.lowerBound
        }
    }

    static func edgeTarget(in lines: Set<Int>, direction: ChangeNavigationDirection) -> Int? {
        let groups = groups(for: lines)
        switch direction {
        case .next:
            return groups.first?.lowerBound
        case .previous:
            return groups.last?.lowerBound
        }
    }
}

enum ChangedFileNavigator {
    static func adjacentPath(
        in paths: [String],
        from currentPath: String?,
        direction: ChangeNavigationDirection
    ) -> String? {
        var seen = Set<String>()
        let orderedPaths = paths.filter {
            seen.insert($0).inserted
        }
        guard !orderedPaths.isEmpty else { return nil }
        guard let currentPath else {
            return direction == .next ? orderedPaths.first : orderedPaths.last
        }
        if let index = orderedPaths.firstIndex(of: currentPath) {
            switch direction {
            case .next:
                return orderedPaths[(index + 1) % orderedPaths.count]
            case .previous:
                return orderedPaths[(index - 1 + orderedPaths.count) % orderedPaths.count]
            }
        }
        return direction == .next ? orderedPaths.first : orderedPaths.last
    }
}

enum DiffEngine {
    static func selectiveStagingPlan(base: String, current: String) -> SelectiveStagingPlan {
        let baseLines = base.splitKeepingEmptyLines()
        let currentLines = current.splitKeepingEmptyLines()
        let operations = sequenceDiff(old: baseLines, new: currentLines)
        var chunks: [SelectiveStagingPlan.Chunk] = []
        var rawRows: [StagingDiffRow] = []
        var selectableChanges = Set<StagingChangeID>()
        var oldIndex = 0
        var newIndex = 0
        var pendingDeletes: [(line: Int, text: String)] = []
        var pendingInserts: [(line: Int, text: String)] = []

        func flushChangedBlock() {
            guard !pendingDeletes.isEmpty || !pendingInserts.isEmpty else { return }
            for deletion in pendingDeletes where !deletion.text.isEmpty {
                let id = StagingChangeID(
                    kind: .deletion,
                    oldLineIndex: deletion.line,
                    newLineIndex: nil,
                    text: deletion.text
                )
                selectableChanges.insert(id)
                chunks.append(.changed(
                    id: id,
                    selected: "",
                    unselected: deletion.text
                ))
                rawRows.append(StagingDiffRow(
                    kind: .deletion,
                    oldLineNumber: deletion.line + 1,
                    newLineNumber: nil,
                    text: deletion.text.trimmedTrailingNewline(),
                    selectionID: id
                ))
            }
            for insertion in pendingInserts where !insertion.text.isEmpty {
                let id = StagingChangeID(
                    kind: .insertion,
                    oldLineIndex: nil,
                    newLineIndex: insertion.line,
                    text: insertion.text
                )
                selectableChanges.insert(id)
                chunks.append(.changed(id: id, selected: insertion.text, unselected: ""))
                rawRows.append(StagingDiffRow(
                    kind: .insertion,
                    oldLineNumber: nil,
                    newLineNumber: insertion.line + 1,
                    text: insertion.text.trimmedTrailingNewline(),
                    selectionID: id
                ))
            }
            pendingDeletes.removeAll()
            pendingInserts.removeAll()
        }

        for operation in operations {
            switch operation {
            case .equal:
                flushChangedBlock()
                chunks.append(.unchanged(baseLines[oldIndex]))
                rawRows.append(StagingDiffRow(
                    kind: .context,
                    oldLineNumber: oldIndex + 1,
                    newLineNumber: newIndex + 1,
                    text: baseLines[oldIndex].trimmedTrailingNewline(),
                    selectionID: nil
                ))
                oldIndex += 1
                newIndex += 1
            case .delete:
                pendingDeletes.append((oldIndex, baseLines[oldIndex]))
                oldIndex += 1
            case .insert:
                pendingInserts.append((newIndex, currentLines[newIndex]))
                newIndex += 1
            }
        }
        flushChangedBlock()
        return SelectiveStagingPlan(
            selectableChanges: selectableChanges,
            diffRows: collapsedStagingRows(rawRows),
            chunks: chunks
        )
    }

    private static func collapsedStagingRows(_ rows: [StagingDiffRow], contextLineCount: Int = 3) -> [StagingDiffRow] {
        let changedIndexes = rows.indices.filter { rows[$0].kind == .deletion || rows[$0].kind == .insertion }
        guard !changedIndexes.isEmpty else { return [] }
        var visibleIndexes = Set<Int>()
        for index in changedIndexes {
            let lower = max(rows.startIndex, index - contextLineCount)
            let upper = min(rows.index(before: rows.endIndex), index + contextLineCount)
            visibleIndexes.formUnion(lower...upper)
        }

        var result: [StagingDiffRow] = []
        var index = rows.startIndex
        while index < rows.endIndex {
            if visibleIndexes.contains(index) {
                result.append(rows[index])
                index += 1
                continue
            }
            let hiddenStart = index
            while index < rows.endIndex, !visibleIndexes.contains(index) {
                index += 1
            }
            let firstHidden = rows[hiddenStart]
            result.append(StagingDiffRow(
                kind: .separator,
                oldLineNumber: firstHidden.oldLineNumber,
                newLineNumber: firstHidden.newLineNumber,
                text: "@@ -\(firstHidden.oldLineNumber ?? 0),… +\(firstHidden.newLineNumber ?? 0),… @@",
                selectionID: nil
            ))
        }
        return result
    }

    static func diff(base: String, current: String) -> DiffResult {
        let baseLines = base.splitKeepingEmptyLines()
        let currentLines = current.splitKeepingEmptyLines()
        let operations = sequenceDiff(old: baseLines, new: currentLines)
        var result = DiffResult.empty
        var oldIndex = 0
        var newIndex = 0
        var pendingDeletes: [(Int, String)] = []
        var pendingInserts: [(Int, String)] = []

        func flushChangedBlock() {
            guard !pendingDeletes.isEmpty || !pendingInserts.isEmpty else { return }
            for item in pendingDeletes {
                result.baseTouchedLines.insert(item.0)
            }
            for item in pendingInserts {
                result.currentTouchedLines.insert(item.0)
            }
            var addedBoundaryDeletionMarker = false
            let boundaryDeletionMarker: DeletionMarker? = {
                guard !currentLines.isEmpty else {
                    return DeletionMarker(line: 0, column: 0, kind: .lineBoundaryBefore)
                }
                let line = min(newIndex, currentLines.count - 1)
                if newIndex < currentLines.count {
                    return DeletionMarker(line: line, column: 0, kind: .lineBoundaryBefore)
                }
                let lineText = currentLines[line].trimmedTrailingNewline()
                return DeletionMarker(
                    line: line,
                    column: (lineText as NSString).length,
                    kind: .lineBoundaryAfter
                )
            }()
            let count = max(pendingDeletes.count, pendingInserts.count)
            for offset in 0..<count {
                let deletion = offset < pendingDeletes.count ? pendingDeletes[offset] : nil
                let insertion = offset < pendingInserts.count ? pendingInserts[offset] : nil
                if let deletion, let insertion {
                    let wordDiff = wordDiff(old: deletion.1, new: insertion.1)
                    result.deletedWordRanges += wordDiff.deleted.map { LineRange(line: deletion.0, range: $0) }
                    let lineStart = (current as NSString).lineStartOffset(forLineIndex: insertion.0)
                    let insertedRanges = wordDiff.inserted.map { NSRange(location: lineStart + $0.location, length: $0.length) }
                    result.insertedWordRanges += insertedRanges
                    for insertedRange in insertedRanges {
                        let localRange = NSRange(location: insertedRange.location - lineStart, length: insertedRange.length)
                        let replacement = replacementText(for: localRange, deletedRanges: wordDiff.deleted, oldLine: deletion.1)
                        result.revertActions.append(RevertAction(currentRange: insertedRange, replacement: replacement))
                    }
                    for markerColumn in wordDiff.deletionMarkerColumns {
                        result.currentDeletionMarkers.append(DeletionMarker(line: insertion.0, column: markerColumn))
                    }
                    for (currentColumn, baseColumn) in wordDiff.currentToBaseColumn {
                        result.currentToBaseColumn[LineColumn(line: insertion.0, column: currentColumn)] = baseColumn
                    }
                    result.currentToBaseLine[insertion.0] = deletion.0
                } else if let deletion {
                    let whole = NSRange(location: 0, length: (deletion.1 as NSString).length)
                    if let trimmed = trimmedTrailingNewline(range: whole, in: deletion.1 as NSString) {
                        result.deletedWordRanges.append(LineRange(line: deletion.0, range: trimmed))
                    }
                    if !addedBoundaryDeletionMarker, let boundaryDeletionMarker {
                        result.currentDeletionMarkers.append(boundaryDeletionMarker)
                        addedBoundaryDeletionMarker = true
                    }
                } else if let insertion {
                    let lineStart = (current as NSString).lineStartOffset(forLineIndex: insertion.0)
                    let whole = NSRange(location: lineStart, length: (insertion.1 as NSString).length)
                    if let trimmed = trimmedTrailingNewline(range: whole, in: current as NSString) {
                        result.insertedWordRanges.append(trimmed)
                    }
                    if whole.length > 0 {
                        result.revertActions.append(RevertAction(currentRange: whole, replacement: ""))
                    }
                    result.currentToBaseLine[insertion.0] = min(insertion.0, max(0, baseLines.count - 1))
                }
            }
            pendingDeletes.removeAll()
            pendingInserts.removeAll()
        }

        for operation in operations {
            switch operation {
            case .equal:
                flushChangedBlock()
                result.currentToBaseLine[newIndex] = oldIndex
                oldIndex += 1
                newIndex += 1
            case .delete:
                pendingDeletes.append((oldIndex, baseLines[oldIndex]))
                oldIndex += 1
            case .insert:
                pendingInserts.append((newIndex, currentLines[newIndex]))
                newIndex += 1
            }
        }
        flushChangedBlock()
        return result
    }

    private static func wordDiff(old: String, new: String) -> (deleted: [NSRange], inserted: [NSRange], deletionMarkerColumns: [Int], currentToBaseColumn: [Int: Int]) {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        let operations = sequenceDiff(old: oldTokens.map(\.text), new: newTokens.map(\.text))
        var deleted: [NSRange] = []
        var inserted: [NSRange] = []
        var markerColumns: [Int] = []
        var columnMap: [Int: Int] = [:]
        var oldIndex = 0
        var newIndex = 0
        var pendingDeletedRanges: [NSRange] = []
        var pendingInsertedRanges: [NSRange] = []

        func flushInlineChangeBlock() {
            guard !pendingDeletedRanges.isEmpty || !pendingInsertedRanges.isEmpty else { return }
            deleted += pendingDeletedRanges
            inserted += pendingInsertedRanges
            if !pendingDeletedRanges.isEmpty {
                if let firstInserted = pendingInsertedRanges.first {
                    markerColumns.append(firstInserted.location)
                } else if newIndex < newTokens.count {
                    markerColumns.append(newTokens[newIndex].range.location)
                } else if newIndex > 0 {
                    markerColumns.append(NSMaxRange(newTokens[newIndex - 1].range))
                } else {
                    markerColumns.append(0)
                }
            }
            pendingDeletedRanges.removeAll()
            pendingInsertedRanges.removeAll()
        }

        for operation in operations {
            switch operation {
            case .equal:
                flushInlineChangeBlock()
                let oldToken = oldTokens[oldIndex]
                let newToken = newTokens[newIndex]
                let count = min(oldToken.range.length, newToken.range.length)
                for offset in 0...count {
                    columnMap[newToken.range.location + offset] = oldToken.range.location + min(offset, oldToken.range.length)
                }
                oldIndex += 1
                newIndex += 1
            case .delete:
                pendingDeletedRanges.append(oldTokens[oldIndex].range)
                oldIndex += 1
            case .insert:
                pendingInsertedRanges.append(newTokens[newIndex].range)
                newIndex += 1
            }
        }
        flushInlineChangeBlock()
        return (
            normalizedHighlightRanges(ranges: deleted, in: old),
            normalizedHighlightRanges(ranges: inserted, in: new),
            Array(Set(markerColumns)).sorted(),
            columnMap
        )
    }

    private static func replacementText(for insertedRange: NSRange, deletedRanges: [NSRange], oldLine: String) -> String {
        let oldNSString = oldLine as NSString
        let overlapping = deletedRanges.filter { range in
            abs(range.location - insertedRange.location) < max(range.length, insertedRange.length) + 8
        }
        let ranges = overlapping.isEmpty ? deletedRanges : overlapping
        guard !ranges.isEmpty else { return "" }
        let start = ranges.map(\.location).min() ?? 0
        let end = ranges.map { NSMaxRange($0) }.max() ?? start
        guard start >= 0, end <= oldNSString.length, end >= start else { return "" }
        return oldNSString.substring(with: NSRange(location: start, length: end - start))
    }

    private static func tokenize(_ string: String) -> [(text: String, range: NSRange)] {
        let nsString = string as NSString
        var tokens: [(String, NSRange)] = []
        var index = 0
        while index < nsString.length {
            let start = index
            let first = nsString.substring(with: NSRange(location: index, length: 1))
            let category = tokenCategory(first)
            index += 1
            while index < nsString.length {
                let next = nsString.substring(with: NSRange(location: index, length: 1))
                if tokenCategory(next) != category { break }
                index += 1
            }
            let range = NSRange(location: start, length: index - start)
            tokens.append((nsString.substring(with: range), range))
        }
        return tokens
    }

    private enum TokenCategory {
        case word
        case whitespace
        case punctuation
    }

    private static func tokenCategory(_ character: String) -> TokenCategory {
        if character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return .whitespace
        }
        if character.rangeOfCharacter(from: .alphanumerics) != nil || character == "_" {
            return .word
        }
        return .punctuation
    }

    private static func merged(ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged.removeLast()
            if range.location <= NSMaxRange(last) {
                merged.append(NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location))
            } else {
                merged.append(last)
                merged.append(range)
            }
        }
        return merged
    }

    private static func normalizedHighlightRanges(ranges: [NSRange], in string: String) -> [NSRange] {
        let compacted = merged(ranges: ranges)
        guard !compacted.isEmpty else { return [] }
        let nsString = string as NSString
        var result = [compacted[0]]
        for range in compacted.dropFirst() {
            let previous = result.removeLast()
            let gapStart = NSMaxRange(previous)
            let gapLength = max(0, range.location - gapStart)
            if gapLength > 0 && gapStart + gapLength <= nsString.length {
                let gap = nsString.substring(with: NSRange(location: gapStart, length: gapLength))
                if gap.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) == nil {
                    result.append(NSRange(location: previous.location, length: NSMaxRange(range) - previous.location))
                    continue
                }
            }
            result.append(previous)
            result.append(range)
        }
        return result.compactMap { trimmedTrailingNewline(range: $0, in: nsString) }
    }

    private static func trimmedTrailingNewline(range: NSRange, in string: NSString) -> NSRange? {
        var length = range.length
        while length > 0 {
            let character = string.substring(with: NSRange(location: range.location + length - 1, length: 1))
            if character.rangeOfCharacter(from: .newlines) == nil { break }
            length -= 1
        }
        return length > 0 ? NSRange(location: range.location, length: length) : nil
    }

    private enum Operation {
        case equal
        case delete
        case insert
    }

    private static func sequenceDiff<T: Equatable>(old: [T], new: [T]) -> [Operation] {
        if old.isEmpty { return Array(repeating: .insert, count: new.count) }
        if new.isEmpty { return Array(repeating: .delete, count: old.count) }

        // Swift's CollectionDifference avoids the quadratic m×n table that
        // previously made ordinary large source files consume hundreds of MB.
        let difference = new.difference(from: old)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        var operations: [Operation] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removedOffsets.contains(i) {
                operations.append(.delete)
                i += 1
            } else if j < new.count, insertedOffsets.contains(j) {
                operations.append(.insert)
                j += 1
            } else if i < old.count, j < new.count, old[i] == new[j] {
                operations.append(.equal)
                i += 1
                j += 1
            } else if i < old.count {
                // A defensive fallback for an inconsistent difference. It
                // preserves progress and will surface the element as changed.
                operations.append(.delete)
                i += 1
            } else {
                operations.append(.insert)
                j += 1
            }
        }
        return operations
    }
}
