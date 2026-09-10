import Foundation

struct DiffResult {
    var currentTouchedLines: Set<Int>
    var baseTouchedLines: Set<Int>
    var insertedWordRanges: [NSRange]
    var deletedWordRanges: [LineRange]
    var currentDeletionMarkers: [DeletionMarker]
    var currentToBaseLine: [Int: Int]
    var currentToBaseColumn: [LineColumn: Int]
    var replacementLinks: [(current: NSRange, base: LineRange)] = []
    var revertActions: [RevertAction]

    static let empty = DiffResult(currentTouchedLines: [], baseTouchedLines: [], insertedWordRanges: [], deletedWordRanges: [], currentDeletionMarkers: [], currentToBaseLine: [:], currentToBaseColumn: [:], revertActions: [])
    mutating func adjustDecorations(for range: NSRange, replacement: String, in original: NSString) {
        let startLine = original.lineIndex(containing: range.location)
        let endLine = original.lineIndex(containing: NSMaxRange(range))
        let startColumn = range.location - original.lineStartOffset(forLineIndex: startLine)
        let endColumn = NSMaxRange(range) - original.lineStartOffset(forLineIndex: endLine)
        let inserted = replacement as NSString
        let insertedLines = inserted.lineIndex(containing: inserted.length)
        let newEndLine = startLine + insertedLines
        let newEndColumn = insertedLines == 0 ? startColumn + inserted.length
            : inserted.length - inserted.lineStartOffset(forLineIndex: insertedLines)
        let lineDelta = newEndLine - endLine
        currentDeletionMarkers = currentDeletionMarkers.compactMap { marker in
            if marker.line < startLine || (marker.line == startLine && marker.column < startColumn) { return marker }
            // An anchor inside removed text no longer has a meaningful position.
            if marker.line < endLine || (marker.line == endLine && marker.column < endColumn) { return nil }
            if marker.line == endLine {
                return DeletionMarker(line: newEndLine, column: marker.kind == .lineBoundaryBefore ? 0 : newEndColumn + marker.column - endColumn, kind: marker.kind)
            }
            return DeletionMarker(line: marker.line + lineDelta, column: marker.column, kind: marker.kind)
        }
        var touched = Set(currentTouchedLines.compactMap { line -> Int? in
            if line < startLine { return line }
            if line > endLine { return line + lineDelta }
            return nil
        })
        touched.formUnion(startLine...newEndLine)
        currentTouchedLines = touched
        if lineDelta != 0 {
            let baseLine = currentToBaseLine[startLine]
            currentToBaseLine = Dictionary(uniqueKeysWithValues: currentToBaseLine.compactMap { line, base -> (Int, Int)? in
                if line < startLine { return (line, base) }
                if line > endLine { return (line + lineDelta, base) }
                return nil
            })
            if let baseLine {
                for line in startLine...newEndLine { currentToBaseLine[line] = baseLine }
            }
        }
        // Character mappings and revert ranges belong to the old snapshot.
        currentToBaseColumn.removeAll()
        replacementLinks.removeAll()
        revertActions.removeAll()
    }

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
            if pendingDeletes.count != pendingInserts.count,
               let firstInsertion = pendingInserts.first,
               applyWhitespaceReflow(old: pendingDeletes, new: pendingInserts,
                                     currentStart: (current as NSString).lineStartOffset(forLineIndex: firstInsertion.0),
                                     result: &result) {
                pendingDeletes.removeAll()
                pendingInserts.removeAll()
                return
            }
            if !pendingDeletes.isEmpty, !pendingInserts.isEmpty,
               pendingDeletes.count != pendingInserts.count,
               pendingDeletes.count == 1 || pendingInserts.count == 1 {
                applySplitReplacement(old: pendingDeletes, new: pendingInserts,
                                      currentStart: (current as NSString).lineStartOffset(forLineIndex: pendingInserts[0].0),
                                      result: &result)
                pendingDeletes.removeAll()
                pendingInserts.removeAll()
                return
            }
            let isPureLineDeletion = !pendingDeletes.isEmpty && pendingInserts.isEmpty
            var addedBoundaryDeletionMarker = false
            let boundaryDeletionMarker: DeletionMarker? = {
                guard isPureLineDeletion else { return nil }
                // Reducing an existing blank gap is visual noise; removing the
                // last blank line still marks the lost paragraph separation.
                let deletesOnlyBlankLines = pendingDeletes.allSatisfy {
                    $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                let retainsBlankLine = [newIndex - 1, newIndex].contains { index in
                    guard currentLines.indices.contains(index) else { return false }
                    let line = currentLines[index]
                    // The empty EOF sentinel is not a surviving blank line.
                    return !line.isEmpty && line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if deletesOnlyBlankLines && retainsBlankLine { return nil }
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
            for (oldOffset, newOffset) in alignedChangedLines(
                old: pendingDeletes.map { $0.1 }, new: pendingInserts.map { $0.1 }
            ) {
                let deletion = oldOffset.map { pendingDeletes[$0] }
                let insertion = newOffset.map { pendingInserts[$0] }
                if let deletion, let insertion {
                    let wordDiff = wordDiff(old: deletion.1, new: insertion.1)
                    result.deletedWordRanges += wordDiff.deleted.map { LineRange(line: deletion.0, range: $0) }
                    let lineStart = (current as NSString).lineStartOffset(forLineIndex: insertion.0)
                    result.replacementLinks += wordDiff.replacements.map { pair in
                        (NSRange(location: lineStart + pair.new.location, length: pair.new.length), LineRange(line: deletion.0, range: pair.old))
                    }
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
                    result.currentToBaseLine[insertion.0] = min(pendingDeletes.isEmpty ? oldIndex : insertion.0, max(0, baseLines.count - 1))
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
        result.currentDeletionMarkers = coalescedDeletionMarkers(result.currentDeletionMarkers, lines: currentLines)
        return result
    }

    private static func applySplitReplacement(
        old: [(Int, String)], new: [(Int, String)], currentStart: Int, result: inout DiffResult
    ) {
        let oldText = old.map { $0.1 }.joined() as NSString
        let newText = new.map { $0.1 }.joined() as NSString
        let words = wordDiff(old: oldText as String, new: newText as String)
        func baseRanges(_ range: NSRange) -> [LineRange] {
            old.enumerated().compactMap { index, item in
                let start = oldText.lineStartOffset(forLineIndex: index)
                let overlap = NSIntersectionRange(range, NSRange(location: start, length: (item.1.trimmedTrailingNewline() as NSString).length))
                return overlap.length > 0 ? LineRange(line: item.0, range: NSRange(location: overlap.location - start, length: overlap.length)) : nil
            }
        }
        result.deletedWordRanges += words.deleted.flatMap(baseRanges)
        result.insertedWordRanges += words.inserted.map {
            NSRange(location: currentStart + $0.location, length: $0.length)
        }
        for pair in words.replacements {
            for base in baseRanges(pair.old) {
                result.replacementLinks.append((NSRange(location: currentStart + pair.new.location, length: pair.new.length), base))
            }
        }
        for column in words.deletionMarkerColumns {
            let line = newText.lineIndex(containing: column)
            result.currentDeletionMarkers.append(DeletionMarker(
                line: new[0].0 + line, column: column - newText.lineStartOffset(forLineIndex: line)
            ))
        }
        for (currentOffset, baseOffset) in words.currentToBaseColumn.sorted(by: { $0.key < $1.key }) {
            let currentLine = newText.lineIndex(containing: currentOffset)
            let baseLine = oldText.lineIndex(containing: baseOffset)
            guard currentLine < new.count, baseLine < old.count else { continue }
            let globalLine = new[currentLine].0
            if result.currentToBaseLine[globalLine] == nil {
                result.currentToBaseLine[globalLine] = old[baseLine].0
            }
            if result.currentToBaseLine[globalLine] == old[baseLine].0 {
                result.currentToBaseColumn[LineColumn(line: globalLine, column: currentOffset - newText.lineStartOffset(forLineIndex: currentLine))] = baseOffset - oldText.lineStartOffset(forLineIndex: baseLine)
            }
        }
        for line in new where result.currentToBaseLine[line.0] == nil {
            result.currentToBaseLine[line.0] = old[0].0
        }
        result.revertActions.append(RevertAction(
            currentRange: NSRange(location: currentStart, length: newText.length), replacement: oldText as String
        ))
    }

    // A sentence split is one text edit across multiple logical lines, not a
    // deleted sentence plus an inserted sentence. Preserve matching text and
    // record only the whitespace edits for reverting.
    private static func applyWhitespaceReflow(
        old: [(Int, String)], new: [(Int, String)], currentStart: Int, result: inout DiffResult
    ) -> Bool {
        guard let firstOld = old.first, let firstNew = new.first else { return false }
        let oldText = old.map { $0.1 }.joined() as NSString
        let newText = new.map { $0.1 }.joined() as NSString
        func contentTokens(_ text: NSString) -> [(text: String, range: NSRange)] {
            tokenize(text as String).filter {
                $0.text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
            }
        }
        let oldTokens = contentTokens(oldText)
        let newTokens = contentTokens(newText)
        guard !oldTokens.isEmpty, oldTokens.map(\.text) == newTokens.map(\.text) else { return false }
        var oldEnd = 0
        var newEnd = 0
        func recordGap(oldLimit: Int, newLimit: Int) {
            let oldGap = oldText.substring(with: NSRange(location: oldEnd, length: oldLimit - oldEnd))
            let newRange = NSRange(location: newEnd, length: newLimit - newEnd)
            let newGap = newText.substring(with: newRange)
            guard oldGap != newGap else { return }
            result.revertActions.append(RevertAction(
                currentRange: NSRange(location: currentStart + newEnd, length: newRange.length), replacement: oldGap
            ))
            if !oldGap.isEmpty, newGap.isEmpty {
                let line = newText.lineIndex(containing: newEnd)
                result.currentDeletionMarkers.append(DeletionMarker(
                    line: firstNew.0 + line, column: newEnd - newText.lineStartOffset(forLineIndex: line)
                ))
            }
        }
        for (oldToken, newToken) in zip(oldTokens, newTokens) {
            recordGap(oldLimit: oldToken.range.location, newLimit: newToken.range.location)
            let oldLine = oldText.lineIndex(containing: oldToken.range.location)
            let newLine = newText.lineIndex(containing: newToken.range.location)
            let globalNewLine = firstNew.0 + newLine
            let globalOldLine = firstOld.0 + oldLine
            // A joined line can span several old lines; retain its first anchor.
            if result.currentToBaseLine[globalNewLine] == nil {
                result.currentToBaseLine[globalNewLine] = globalOldLine
            }
            if result.currentToBaseLine[globalNewLine] == globalOldLine {
                let oldColumn = oldToken.range.location - oldText.lineStartOffset(forLineIndex: oldLine)
                let newColumn = newToken.range.location - newText.lineStartOffset(forLineIndex: newLine)
                for offset in 0...newToken.range.length {
                    result.currentToBaseColumn[LineColumn(line: globalNewLine, column: newColumn + offset)] = oldColumn + offset
                }
            }
            oldEnd = NSMaxRange(oldToken.range)
            newEnd = NSMaxRange(newToken.range)
        }
        recordGap(oldLimit: oldText.length, newLimit: newText.length)
        return true
    }

    private static func coalescedDeletionMarkers(_ markers: [DeletionMarker], lines: [String]) -> [DeletionMarker] {
        func boundary(_ marker: DeletionMarker) -> Int {
            marker.line + (marker.kind == .lineBoundaryAfter ? 1 : 0)
        }
        let horizontal = markers.filter { $0.kind != .inline }.sorted { boundary($0) < boundary($1) }
        var kept: [DeletionMarker] = []
        for marker in horizontal {
            if let previous = kept.last {
                let start = min(lines.count, max(0, boundary(previous)))
                let end = min(lines.count, max(start, boundary(marker)))
                if lines[start..<end].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    continue
                }
            }
            kept.append(marker)
        }
        return (kept + markers.filter { $0.kind == .inline }).sorted {
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.column < $1.column
        }
    }

    // Match similar lines monotonically before comparing words. Positional
    // pairing mistakes inserted sentences for replacements of following lines.
    private static func alignedChangedLines(old: [String], new: [String]) -> [(Int?, Int?)] {
        guard !old.isEmpty, !new.isEmpty else {
            return old.indices.map { (Optional($0), nil) } + new.indices.map { (nil, Optional($0)) }
        }
        // Bound work for wholesale rewrites; ordinary edit blocks are small.
        guard old.count <= 40_000 / new.count else {
            return (0..<max(old.count, new.count)).map {
                ($0 < old.count ? $0 : nil, $0 < new.count ? $0 : nil)
            }
        }
        func words(_ line: String) -> Set<String> {
            Set(line.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let oldWords = old.map(words)
        let newWords = new.map(words)
        let width = new.count + 1
        var scores = [Double](repeating: 0, count: (old.count + 1) * width)
        var matches = [Bool](repeating: false, count: scores.count)
        for i in (0..<old.count).reversed() {
            for j in (0..<new.count).reversed() {
                let total = oldWords[i].count + newWords[j].count
                let similarity = old[i] == new[j] ? 1 : (total == 0 ? 0 : Double(2 * oldWords[i].intersection(newWords[j]).count) / Double(total))
                let index = i * width + j
                let skip = max(scores[(i + 1) * width + j], scores[index + 1])
                let paired = similarity + scores[(i + 1) * width + j + 1]
                if similarity >= 0.5, paired >= skip {
                    scores[index] = paired
                    matches[index] = true
                } else {
                    scores[index] = skip
                }
            }
        }
        var anchors: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if matches[i * width + j] {
                anchors.append((i, j))
                i += 1
                j += 1
            } else if scores[(i + 1) * width + j] >= scores[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var result: [(Int?, Int?)] = []
        i = 0
        j = 0
        // Preserve positional word comparisons for rewritten spans between
        // strong matches, including blocks with no similar lines at all.
        for (oldEnd, newEnd) in anchors + [(old.count, new.count)] {
            while i < oldEnd || j < newEnd {
                result.append((i < oldEnd ? i : nil, j < newEnd ? j : nil))
                if i < oldEnd { i += 1 }
                if j < newEnd { j += 1 }
            }
            if oldEnd < old.count, newEnd < new.count {
                result.append((oldEnd, newEnd))
                i += 1
                j += 1
            }
        }
        return result
    }

    private static func wordDiff(old: String, new: String) -> (deleted: [NSRange], inserted: [NSRange], deletionMarkerColumns: [Int], currentToBaseColumn: [Int: Int], replacements: [(old: NSRange, new: NSRange)]) {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        let oldKeys = contextualDiffKeys(for: oldTokens)
        var newKeys = contextualDiffKeys(for: newTokens)
        // Unchanged punctuation at either edge must not become a change just
        // because the neighboring word was edited.
        var prefix = 0
        while prefix < min(oldTokens.count, newTokens.count), oldTokens[prefix].text == newTokens[prefix].text {
            newKeys[prefix] = oldKeys[prefix]
            prefix += 1
        }
        var suffix = 0
        while suffix < min(oldTokens.count, newTokens.count) - prefix,
              oldTokens[oldTokens.count - 1 - suffix].text == newTokens[newTokens.count - 1 - suffix].text {
            newKeys[newTokens.count - 1 - suffix] = oldKeys[oldTokens.count - 1 - suffix]
            suffix += 1
        }
        // Context finds stable anchors, but it is not itself evidence that a
        // character changed. Refine each intervening block using literal text
        // so identical punctuation and whitespace remain unchanged.
        let contextualOperations = sequenceDiff(old: oldKeys, new: newKeys)
        var operations: [Operation] = []
        var oldCursor = 0
        var newCursor = 0
        var oldBlock: [String] = []
        var newBlock: [String] = []
        func flushLiteralBlock() {
            operations += sequenceDiff(old: oldBlock, new: newBlock)
            oldBlock.removeAll(keepingCapacity: true)
            newBlock.removeAll(keepingCapacity: true)
        }
        for operation in contextualOperations {
            switch operation {
            case .equal:
                flushLiteralBlock()
                operations.append(.equal)
                oldCursor += 1
                newCursor += 1
            case .delete:
                oldBlock.append(oldTokens[oldCursor].text)
                oldCursor += 1
            case .insert:
                newBlock.append(newTokens[newCursor].text)
                newCursor += 1
            }
        }
        flushLiteralBlock()
        // When an equal separator precedes an insertion/deletion ending in the
        // same separator, align it with the unchanged text after the edit.
        // For example, " subjects (" -> " design (" keeps the final " (".
        var scanOld = 0
        var scanNew = 0
        for index in operations.indices {
            if case .equal = operations[index], index + 1 < operations.count,
               tokenCategory(oldTokens[scanOld].text) != .word {
                var end = index + 1
                if case .insert = operations[end] {
                    while end < operations.count, case .insert = operations[end] { end += 1 }
                    if newTokens[scanNew + end - index - 1].text == oldTokens[scanOld].text {
                        operations[index] = .insert
                        operations[end - 1] = .equal
                    }
                } else if case .delete = operations[end] {
                    while end < operations.count, case .delete = operations[end] { end += 1 }
                    if oldTokens[scanOld + end - index - 1].text == newTokens[scanNew].text {
                        operations[index] = .delete
                        operations[end - 1] = .equal
                    }
                }
            }
            switch operations[index] {
            case .equal: scanOld += 1; scanNew += 1
            case .delete: scanOld += 1
            case .insert: scanNew += 1
            }
        }
        var deleted: [NSRange] = []
        var inserted: [NSRange] = []
        var markerColumns: [Int] = []
        var columnMap: [Int: Int] = [:]
        var replacements: [(old: NSRange, new: NSRange)] = []
        var oldIndex = 0
        var newIndex = 0
        var pendingDeletedRanges: [NSRange] = []
        var pendingInsertedRanges: [NSRange] = []

        func flushInlineChangeBlock() {
            guard !pendingDeletedRanges.isEmpty || !pendingInsertedRanges.isEmpty else { return }
            deleted += pendingDeletedRanges
            inserted += pendingInsertedRanges
            if let oldFirst = pendingDeletedRanges.first, let oldLast = pendingDeletedRanges.last,
               let newFirst = pendingInsertedRanges.first, let newLast = pendingInsertedRanges.last {
                replacements.append((NSRange(location: oldFirst.location, length: NSMaxRange(oldLast) - oldFirst.location),
                                     NSRange(location: newFirst.location, length: NSMaxRange(newLast) - newFirst.location)))
            }
            if !pendingDeletedRanges.isEmpty, pendingInsertedRanges.isEmpty {
                if newIndex < newTokens.count {
                    markerColumns.append(newTokens[newIndex].range.location)
                } else if newIndex > 0 {
                    markerColumns.append(NSMaxRange(newTokens[newIndex - 1].range))
                } else {
                    markerColumns.append(0)
                }
                let first = pendingDeletedRanges[0]
                let last = pendingDeletedRanges[pendingDeletedRanges.count - 1]
                replacements.append((NSRange(location: first.location, length: NSMaxRange(last) - first.location),
                                     NSRange(location: markerColumns[markerColumns.count - 1], length: 0)))
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
        let semanticMarkerColumns = semanticDeletionMarkerColumns(old: old, new: new)
        let normalizedInsertedRanges = normalizedHighlightRanges(ranges: inserted, in: new)
        let candidateMarkerColumns = semanticMarkerColumns.isEmpty
            ? Array(Set(markerColumns)).sorted()
            : semanticMarkerColumns.map { semanticColumn in
                // Word-only alignment locates the next word, skipping its
                // leading space. Use the literal edit boundary when available,
                // so the marker doesn't occupy an unchanged word's caret slot.
                markerColumns.filter { column in
                    let gap = NSRange(location: min(column, semanticColumn), length: abs(column - semanticColumn))
                    return (new as NSString).substring(with: gap).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.min(by: { abs($0 - semanticColumn) < abs($1 - semanticColumn) }) ?? semanticColumn
            }
        let pureDeletionMarkerColumns = candidateMarkerColumns.filter { markerColumn in
            !normalizedInsertedRanges.contains { insertionRange in
                markerTouchesInsertion(
                    markerColumn,
                    insertionRange: insertionRange,
                    in: new
                )
            }
        }
        return (
            normalizedHighlightRanges(ranges: deleted, in: old),
            normalizedInsertedRanges,
            pureDeletionMarkerColumns,
            columnMap,
            replacements.compactMap { pair in
                guard pair.new.length == 0 else { return pair }
                // Semantic markers may sit after an unchanged space. Keep the
                // deleted range linked to the marker that is actually drawn.
                guard let column = pureDeletionMarkerColumns.min(by: {
                    abs($0 - pair.new.location) < abs($1 - pair.new.location)
                }) else { return nil }
                let gap = NSRange(location: min(column, pair.new.location), length: abs(column - pair.new.location))
                guard (new as NSString).substring(with: gap).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return (pair.old, NSRange(location: column, length: 0))
            }
        )
    }

    private static func markerTouchesInsertion(
        _ markerColumn: Int,
        insertionRange: NSRange,
        in string: String
    ) -> Bool {
        let insertionEnd = NSMaxRange(insertionRange)
        if markerColumn >= insertionRange.location, markerColumn <= insertionEnd {
            return true
        }
        let gap: NSRange
        if markerColumn < insertionRange.location {
            gap = NSRange(location: markerColumn, length: insertionRange.location - markerColumn)
        } else {
            gap = NSRange(location: insertionEnd, length: markerColumn - insertionEnd)
        }
        let nsString = string as NSString
        guard gap.location >= 0, NSMaxRange(gap) <= nsString.length else { return false }
        let gapText = nsString.substring(with: gap)
        return gapText.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) == nil
    }

    private static func semanticDeletionMarkerColumns(old: String, new: String) -> [Int] {
        let oldTokens = semanticTokens(old)
        let newTokens = semanticTokens(new)
        let operations = sequenceDiff(old: oldTokens.map(\.text), new: newTokens.map(\.text))
        var markerColumns: [Int] = []
        var newIndex = 0
        var pendingDeletion = false
        var firstInsertedColumn: Int?

        func flushChangeBlock() {
            guard pendingDeletion, firstInsertedColumn == nil else {
                pendingDeletion = false
                firstInsertedColumn = nil
                return
            }
            if newIndex < newTokens.count {
                markerColumns.append(newTokens[newIndex].range.location)
            } else if newIndex > 0 {
                markerColumns.append(NSMaxRange(newTokens[newIndex - 1].range))
            } else {
                markerColumns.append(0)
            }
            pendingDeletion = false
            firstInsertedColumn = nil
        }

        for operation in operations {
            switch operation {
            case .equal:
                flushChangeBlock()
                newIndex += 1
            case .delete:
                pendingDeletion = true
            case .insert:
                if firstInsertedColumn == nil {
                    firstInsertedColumn = newTokens[newIndex].range.location
                }
                newIndex += 1
            }
        }
        flushChangeBlock()
        return Array(Set(markerColumns)).sorted()
    }

    private static func semanticTokens(_ string: String) -> [(text: String, range: NSRange)] {
        let nsString = string as NSString
        var tokens: [(String, NSRange)] = []
        var index = 0
        while index < nsString.length {
            while index < nsString.length {
                let character = nsString.substring(with: NSRange(location: index, length: 1))
                guard character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { break }
                index += 1
            }
            guard index < nsString.length else { break }
            let start = index
            while index < nsString.length {
                let character = nsString.substring(with: NSRange(location: index, length: 1))
                guard character.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { break }
                index += 1
            }
            let range = NSRange(location: start, length: index - start)
            tokens.append((nsString.substring(with: range), range))
        }
        return tokens
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
            let firstRange = nsString.rangeOfComposedCharacterSequence(at: index)
            let first = nsString.substring(with: firstRange)
            let category = tokenCategory(first)
            index = NSMaxRange(firstRange)
            // Only words form multi-character tokens. Match whitespace and
            // punctuation individually, preserving complete Unicode graphemes.
            // Thus deleting a word doesn't insert its surrounding spaces, and
            // changing a semicolon doesn't replace adjacent closing brackets.
            while category == .word, index < nsString.length {
                let nextRange = nsString.rangeOfComposedCharacterSequence(at: index)
                let next = nsString.substring(with: nextRange)
                if tokenCategory(next) != category { break }
                index = NSMaxRange(nextRange)
            }
            let range = NSRange(location: start, length: index - start)
            tokens.append((nsString.substring(with: range), range))
        }
        return tokens
    }

    private static func contextualDiffKeys(for tokens: [(text: String, range: NSRange)]) -> [String] {
        var previousWords = Array(repeating: "", count: tokens.count)
        var previousWord = ""
        for index in tokens.indices {
            previousWords[index] = previousWord
            if let first = tokens[index].text.first, tokenCategory(String(first)) == .word {
                previousWord = tokens[index].text
            }
        }
        var nextWords = Array(repeating: "", count: tokens.count)
        var nextWord = ""
        for index in tokens.indices.reversed() {
            nextWords[index] = nextWord
            if let first = tokens[index].text.first, tokenCategory(String(first)) == .word {
                nextWord = tokens[index].text
            }
        }
        return tokens.indices.map { index in
            let token = tokens[index].text
            guard let first = token.first else { return "empty" }
            switch tokenCategory(String(first)) {
            case .word:
                return "word\u{0}\(token)"
            case .whitespace:
                return "whitespace\u{0}\(token)"
            case .punctuation:
                return "punctuation\u{0}\(token)\u{0}\(previousWords[index])\u{0}\(nextWords[index])"
            }
        }
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
        // Anchor identical edges before aligning the interior. Repeated words
        // such as "and" inside a rewrite must not steal matches from the
        // unchanged sentence tail and leave spurious deletions there.
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let oldInterior = Array(old[prefix..<(old.count - suffix)])
        let newInterior = Array(new[prefix..<(new.count - suffix)])
        let difference = newInterior.difference(from: oldInterior)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(prefix + offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(prefix + offset)
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
