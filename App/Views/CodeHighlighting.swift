import Foundation
import GitokenCore
import SwiftUI

enum CodeHighlighting {
    /// Colors one line of a highlighted text. `spans` (sorted, non-overlapping) cover the whole text and `lineStart` is
    /// the line's UTF-16 offset in it. Tabs become `tab` for monospaced display.
    static func line(
        _ text: String, at lineStart: Int, spans: [HighlightSpan], theme: Theme, tab: String
    ) -> AttributedString {
        let ns = text as NSString
        let lineEnd = lineStart + ns.length
        var out = AttributedString()
        var cursor = 0
        func piece(_ lower: Int, _ upper: Int) -> AttributedString {
            AttributedString(ns.substring(with: NSRange(location: lower, length: upper - lower))
                .replacingOccurrences(of: "\t", with: tab))
        }
        var i = firstSpan(endingAfter: lineStart, in: spans)
        while i < spans.count, spans[i].range.location < lineEnd {
            let lower = max(spans[i].range.location, lineStart) - lineStart
            let upper = min(NSMaxRange(spans[i].range), lineEnd) - lineStart
            if lower > cursor { out += piece(cursor, lower) }
            var colored = piece(lower, upper)
            colored.foregroundColor = theme.tokenColor(spans[i].kind)
            out += colored
            cursor = upper
            i += 1
        }
        if cursor < ns.length { out += piece(cursor, ns.length) }
        return out
    }

    /// UTF-16 offset of each line when `lines` are joined with "\n".
    static func lineStarts(_ lines: [String]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        return starts
    }

    private static func firstSpan(endingAfter offset: Int, in spans: [HighlightSpan]) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(spans[mid].range) <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
