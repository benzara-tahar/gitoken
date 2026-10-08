import Foundation

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case hunkHeader, context, added, removed }
    public let kind: Kind
    /// Marker stripped; a hunk header keeps the full "@@ … @@ …" line.
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public enum UnifiedDiff {
    private static let headerPattern = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)"#)

    /// Parses one or more hunks. Drops "\ No newline at end of file". Tolerates CRLF and a trailing newline.
    /// Lines before the first header are numbered from 1 (a bare hunk body).
    public static func parse(_ patch: String) -> [DiffLine] {
        // "\r\n" is a single Character, so normalize before splitting.
        var rows = patch.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        if rows.last?.isEmpty == true { rows.removeLast() }
        var oldNo = 1
        var newNo = 1
        var out: [DiffLine] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            switch row.first {
            case "@" where row.hasPrefix("@@"):
                let header = String(row)
                let ns = header as NSString
                if let m = headerPattern.firstMatch(in: header, range: NSRange(location: 0, length: ns.length)) {
                    oldNo = Int(ns.substring(with: m.range(at: 1))) ?? 1
                    newNo = Int(ns.substring(with: m.range(at: 2))) ?? 1
                }
                out.append(DiffLine(kind: .hunkHeader, text: header, oldLine: nil, newLine: nil))
            case "+":
                out.append(DiffLine(kind: .added, text: String(row.dropFirst()), oldLine: nil, newLine: newNo))
                newNo += 1
            case "-":
                out.append(DiffLine(kind: .removed, text: String(row.dropFirst()), oldLine: oldNo, newLine: nil))
                oldNo += 1
            case "\\":
                continue
            default:
                out.append(DiffLine(kind: .context, text: String(row.dropFirst()), oldLine: oldNo, newLine: newNo))
                oldNo += 1
                newNo += 1
            }
        }
        return out
    }
}
