import Foundation

/// Inbox search: free words and `"quoted phrases"` (all must match, case-insensitive, against title, repository,
/// `#number`, preview snippet and actor logins/names) plus `repo:`, `author:`, `reason:` and
/// `is:unread|read|pr|issue` qualifiers. A leading `-` negates a term; unknown qualifiers are plain text and
/// qualifiers without a value are ignored (so a half-typed `repo:` doesn't empty the list).
public struct InboxQuery: Hashable, Sendable {
    enum Filter: Hashable, Sendable {
        case text(String)
        case repo(String)
        case author(String)
        case reason(String)
        case unread(Bool)
        case kind(SubjectKind)
    }

    struct Term: Hashable, Sendable {
        var filter: Filter
        var negated: Bool
    }

    let terms: [Term]

    public init(_ text: String) {
        terms = Self.tokens(in: text).compactMap(Self.term)
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// `author:` is the only term that consults conversation detail; callers can skip the lookup otherwise.
    public var needsDetail: Bool {
        terms.contains { if case .author = $0.filter { true } else { false } }
    }

    public func matches(_ group: InboxGroup, detail: ThreadDetail?) -> Bool {
        matches(group, author: detail?.author)
    }

    /// Same as `matches(_:detail:)` given only the subject author (nil when unknown).
    public func matches(_ group: InboxGroup, author: Actor?) -> Bool {
        terms.allSatisfy { $0.negated != Self.matches($0.filter, group, author) }
    }

    /// Search sections have local seen state but no GitHub notification reason.
    public func matches(_ item: SearchItem, isUnseen: Bool) -> Bool {
        terms.allSatisfy { term in
            let matches: Bool
            switch term.filter {
            case .text(let value):
                matches = Self.contains(item.title, value) || Self.contains(item.repo.fullName, value)
                    || Self.contains("#\(item.number)", value)
                    || item.author.map { Self.contains($0.login, value) || Self.contains($0.displayName, value) } == true
            case .repo(let value): matches = Self.contains(item.repo.fullName, value)
            case .author(let value): matches = item.author.map { Self.contains($0.login, value) } == true
            case .reason: matches = false
            case .unread(let unread): matches = isUnseen == unread
            case .kind(let kind): matches = item.kind == kind
            }
            return term.negated != matches
        }
    }

    // MARK: Matching

    private static func matches(_ filter: Filter, _ group: InboxGroup, _ author: Actor?) -> Bool {
        let thread = group.thread
        switch filter {
        case .text(let text):
            return searchableFields(group).contains { contains($0, text) }
        case .repo(let value):
            return contains(thread.repo.fullName, value)
        case .author(let login):
            if let author { return contains(author.login, login) }
            return (group.actors + [group.preview?.actor].compactMap { $0 }).contains { contains($0.login, login) }
        case .reason(let value):
            return reasonMatches(thread.reason, value)
        case .unread(let unread):
            return group.isUnseen == unread
        case .kind(let kind):
            return thread.kind == kind
        }
    }

    private static func searchableFields(_ group: InboxGroup) -> [String] {
        var fields = [group.thread.title, group.thread.repo.fullName]
        if let number = group.thread.number { fields.append("#\(number)") }
        if let snippet = group.preview?.snippet { fields.append(snippet) }
        for actor in group.actors + [group.preview?.actor].compactMap({ $0 }) {
            fields.append(actor.login)
            if let name = actor.name { fields.append(name) }
        }
        return fields
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Raw value (`review_requested`), any of its `_`-separated words (`review`), or a word of the inbox's short
    /// label (`mentioned`, `yours`, `participating`, …). `-` and spaces count as `_`.
    private static func reasonMatches(_ reason: NotificationReason, _ value: String) -> Bool {
        let value = value.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let raw = reason.rawValue
        if value == raw { return true }
        let words = raw.split(separator: "_").map(String.init) + labelWords(reason)
        return words.contains(value)
    }

    private static func labelWords(_ reason: NotificationReason) -> [String] {
        switch reason {
        case .reviewRequested: ["review", "requested"]
        case .mention, .teamMention: ["mentioned"]
        case .author: ["yours"]
        case .comment: ["participating"]
        case .assign: ["assigned"]
        case .stateChange: ["state", "changed"]
        case .manual: ["subscribed"]
        case .ciActivity: ["ci"]
        case .subscribed: ["watching"]
        case .securityAlert: ["security"]
        case .invitation: ["invitation"]
        case .approvalRequested: ["approval", "requested"]
        case .other: ["updated"]
        }
    }

    // MARK: Parsing

    private struct Token {
        var text: String
        /// Characters before the token's first quote: 0 for `"phrase"`, 1 for `-"phrase"`, nil without quotes.
        var quoteOffset: Int?
    }

    /// Whitespace-separated tokens; double quotes group spaces and are dropped (an unclosed quote runs to the end).
    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var current = Token(text: "")
        var inQuotes = false
        var started = false
        for char in text {
            if char == "\"" {
                if current.quoteOffset == nil { current.quoteOffset = current.text.count }
                inQuotes.toggle()
                started = true
            } else if char.isWhitespace && !inQuotes {
                if started { tokens.append(current) }
                current = Token(text: "")
                started = false
            } else {
                current.text.append(char)
                started = true
            }
        }
        if started { tokens.append(current) }
        return tokens
    }

    private static let qualifierKeys: Set<String> = ["repo", "author", "reason", "is"]

    private static func term(_ token: Token) -> Term? {
        var text = token.text
        let negated = token.quoteOffset != 0 && text.count > 1 && text.hasPrefix("-")
        if negated { text.removeFirst() }
        let phrase = token.quoteOffset == (negated ? 1 : 0)
        if !phrase, let colon = text.firstIndex(of: ":"), qualifierKeys.contains(text[..<colon].lowercased()) {
            let key = text[..<colon].lowercased()
            var value = String(text[text.index(after: colon)...])
            if key == "author", value.hasPrefix("@") { value.removeFirst() }
            if value.isEmpty { return nil }
            if let filter = qualifier(key, value) {
                return Term(filter: filter, negated: negated)
            }
        }
        return text.isEmpty ? nil : Term(filter: .text(text), negated: negated)
    }

    /// Filter for a known `key:value`; nil for an unknown `is:` value (then it's plain text).
    private static func qualifier(_ key: String, _ value: String) -> Filter? {
        switch key {
        case "repo": return .repo(value)
        case "author": return .author(value)
        case "reason": return .reason(value)
        default:
            switch value.lowercased() {
            case "unread": return .unread(true)
            case "read": return .unread(false)
            case "pr": return .kind(.pullRequest)
            case "issue": return .kind(.issue)
            default: return nil
            }
        }
    }
}
