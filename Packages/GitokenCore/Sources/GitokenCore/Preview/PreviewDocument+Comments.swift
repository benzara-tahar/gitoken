import Foundation

extension PreviewDocument {
    /// Position for a gutter selection from line index `a` to `b` (any order), or nil when not commentable:
    /// diff mode — all selected lines must be in ONE hunk and on one side (removed → .left/oldLine; context/added →
    /// .right/newLine; a range mixing removed with added/context uses .right and must contain at least one right line);
    /// file mode — `.right`, every selected line must fall inside one hunk of `patch` (new-side ranges). Hunk headers
    /// never.
    public func commentPosition(from a: Int, to b: Int, path: String, patch: String?) -> CommentPosition? {
        let range = min(a, b)...max(a, b)
        guard range.lowerBound >= 0, range.upperBound < lines.count else { return nil }
        let selected = lines[range]
        func position(_ side: DiffSide, _ first: Int, _ last: Int) -> CommentPosition {
            CommentPosition(path: path, side: side, line: last, startLine: first == last ? nil : first)
        }
        switch mode {
        case .diff:
            guard !selected.contains(where: { $0.kind == .hunkHeader }) else { return nil }
            if selected.allSatisfy({ $0.kind == .removed }) {
                guard let first = selected.first?.oldNumber, let last = selected.last?.oldNumber else { return nil }
                return position(.left, first, last)
            }
            let right = selected.compactMap { $0.kind == .removed ? nil : $0.newNumber }
            guard let first = right.first, let last = right.last else { return nil }
            return position(.right, first, last)
        case .file:
            guard let patch else { return nil }
            let numbers = selected.compactMap(\.newNumber)
            guard numbers.count == selected.count, let first = numbers.first, let last = numbers.last,
                  Self.newSideRanges(patch).contains(where: { $0.contains(first) && $0.contains(last) })
            else { return nil }
            return position(.right, first, last)
        }
    }

    /// New-side line range of each hunk (context + added lines); pure deletions have none.
    private static func newSideRanges(_ patch: String) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var current: ClosedRange<Int>?
        for line in UnifiedDiff.parse(patch) {
            switch line.kind {
            case .hunkHeader:
                if let current { ranges.append(current) }
                current = nil
            case .context, .added:
                guard let number = line.newLine else { continue }
                current = current.map { $0.lowerBound...max($0.upperBound, number) } ?? number...number
            case .removed:
                continue
            }
        }
        if let current { ranges.append(current) }
        return ranges
    }
}
