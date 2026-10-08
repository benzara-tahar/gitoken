import Foundation

public struct CustomSection: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var query: String
    public var isCollapsed: Bool

    public init(id: UUID = UUID(), name: String, query: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.query = query
        self.isCollapsed = isCollapsed
    }
}

/// GitHub subject node ID, never a notification thread ID.
public struct SearchItemID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct SearchItem: Hashable, Codable, Sendable, Identifiable {
    public let id: SearchItemID
    public let repo: RepoRef
    public let number: Int
    public let kind: SubjectKind
    public let title: String
    public let state: SubjectState
    public let author: Actor?
    public let updatedAt: Date
    public let htmlURL: URL

    public init(id: SearchItemID, repo: RepoRef, number: Int, kind: SubjectKind, title: String,
                state: SubjectState, author: Actor?, updatedAt: Date, htmlURL: URL) {
        self.id = id
        self.repo = repo
        self.number = number
        self.kind = kind
        self.title = title
        self.state = state
        self.author = author
        self.updatedAt = updatedAt
        self.htmlURL = htmlURL
    }
}

public struct SearchPage: Hashable, Codable, Sendable {
    public var items: [SearchItem]
    public var totalCount: Int
    public var incompleteResults: Bool
    public var nextPage: Int?

    public init(items: [SearchItem], totalCount: Int, incompleteResults: Bool, nextPage: Int?) {
        self.items = items
        self.totalCount = totalCount
        self.incompleteResults = incompleteResults
        self.nextPage = nextPage
    }
}

public struct SearchSubjectDetail: Hashable, Codable, Sendable {
    public let id: SearchItemID
    public let title: String
    public let state: SubjectState
    public let author: Actor?
    public let htmlURL: URL
    public let items: [TimelineItem]
    public let checks: CheckSummary?
    public let fetchedAt: Date

    public init(id: SearchItemID, title: String, state: SubjectState, author: Actor?, htmlURL: URL,
                items: [TimelineItem], checks: CheckSummary?, fetchedAt: Date) {
        self.id = id
        self.title = title
        self.state = state
        self.author = author
        self.htmlURL = htmlURL
        self.items = items
        self.checks = checks
        self.fetchedAt = fetchedAt
    }
}

public struct CustomSectionResult: Equatable, Sendable {
    public var page: SearchPage
    public var refreshedAt: Date?
    public var isLoading: Bool
    public var error: GitHubError?

    public init(page: SearchPage = .init(items: [], totalCount: 0, incompleteResults: false, nextPage: nil),
                refreshedAt: Date? = nil, isLoading: Bool = false, error: GitHubError? = nil) {
        self.page = page
        self.refreshedAt = refreshedAt
        self.isLoading = isLoading
        self.error = error
    }
}

public struct SearchConversationState: Equatable, Sendable {
    public var detail: SearchSubjectDetail?
    public var lastVisitAt: Date?
    public var isLoading: Bool
    public var error: GitHubError?

    public init(detail: SearchSubjectDetail? = nil, lastVisitAt: Date? = nil,
                isLoading: Bool = false, error: GitHubError? = nil) {
        self.detail = detail
        self.lastVisitAt = lastVisitAt
        self.isLoading = isLoading
        self.error = error
    }
}

public protocol GitHubSearchService: Sendable {
    func searchIssues(query: String, page: Int) async throws(GitHubError) -> SearchPage
    func searchDetail(for item: SearchItem) async throws(GitHubError) -> SearchSubjectDetail
}
