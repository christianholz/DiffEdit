import Foundation

extension String {
    func splitLines() -> [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }

    func splitKeepingEmptyLines() -> [String] {
        if isEmpty { return [] }
        var lines: [String] = []
        enumerateSubstrings(in: startIndex..<endIndex, options: [.byLines, .substringNotRequired]) { _, range, enclosingRange, _ in
            var line = String(self[range])
            if enclosingRange.upperBound > range.upperBound {
                line += String(self[range.upperBound..<enclosingRange.upperBound])
            }
            lines.append(line)
        }
        if let lastScalar = unicodeScalars.last, CharacterSet.newlines.contains(lastScalar) {
            lines.append("")
        }
        return lines
    }

    func trimmedTrailingNewline() -> String {
        if hasSuffix("\r\n") {
            return String(dropLast(2))
        }
        if hasSuffix("\n") || hasSuffix("\r") {
            return String(dropLast())
        }
        return self
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NSString {
    var lineCount: Int {
        if length == 0 { return 1 }
        var count = 0
        var index = 0
        while index < length {
            let range = lineRange(for: NSRange(location: index, length: 0))
            index = max(NSMaxRange(range), index + 1)
            count += 1
        }
        return count
    }

    func lineIndex(containing location: Int) -> Int {
        let safeLocation = max(0, min(location, length))
        var line = 0
        var index = 0
        while index < safeLocation {
            let range = lineRange(for: NSRange(location: index, length: 0))
            if safeLocation < NSMaxRange(range) {
                if safeLocation > 0,
                   substring(with: NSRange(location: safeLocation - 1, length: 1)).rangeOfCharacter(from: .newlines) != nil {
                    line += 1
                }
                break
            }
            index = NSMaxRange(range)
            line += 1
        }
        return line
    }

    func lineRange(forLineIndex target: Int) -> NSRange {
        guard target >= 0, length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        var line = 0
        var index = 0
        while index < length {
            let range = lineRange(for: NSRange(location: index, length: 0))
            if line == target { return range }
            index = NSMaxRange(range)
            line += 1
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func lineStartOffset(forLineIndex target: Int) -> Int {
        guard target > 0 else { return 0 }
        var line = 0
        var index = 0
        while index < length {
            if line == target { return index }
            let range = lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            line += 1
        }
        return length
    }
}
