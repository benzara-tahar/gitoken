import Foundation

enum GitHubJSON {
    /// REST payloads are snake_case; GraphQL payloads are camelCase and pass through unchanged.
    static func restDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = dateStrategy
        return decoder
    }

    static func graphQLDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateStrategy
        return decoder
    }

    private static let dateStrategy = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = parseDate(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
        }
        return date
    }

    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder) throws(GitHubError) -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw .decoding(describe(error))
        } catch {
            throw .decoding(error.localizedDescription)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(key.stringValue) at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default: return error.localizedDescription
        }
    }
}

struct RESTUser: Decodable {
    let login: String
    let name: String?
    let avatarUrl: String?
    let type: String?

    var actor: Actor {
        Actor(login: login, name: name, avatarURL: avatarUrl.flatMap(URL.init(string:)), isBot: type == "Bot")
    }
}

extension Actor {
    /// Stand-in for deleted accounts, which GitHub returns as a null author.
    static let ghost = Actor(login: "ghost", name: "Ghost")
}

struct RESTNotification: Decodable {
    struct Subject: Decodable {
        let title: String
        let url: String?
        let latestCommentUrl: String?
        let type: String
    }

    struct Repository: Decodable {
        struct Owner: Decodable {
            let login: String
            let avatarUrl: String?
        }
        let name: String
        let owner: Owner
    }

    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: Date
    let lastReadAt: Date?
    let subject: Subject
    let repository: Repository

    var thread: NotificationThread {
        NotificationThread(
            id: ThreadID(id),
            repo: RepoRef(owner: repository.owner.login, name: repository.name),
            kind: SubjectKind(apiValue: subject.type),
            number: Self.subjectNumber(from: subject.url),
            title: subject.title,
            reason: NotificationReason(apiValue: reason),
            unread: unread,
            updatedAt: updatedAt,
            lastReadAt: lastReadAt,
            subjectAPIURL: subject.url.flatMap(URL.init(string:)),
            latestCommentAPIURL: subject.latestCommentUrl.flatMap(URL.init(string:)),
            repoOwnerAvatarURL: repository.owner.avatarUrl.flatMap(URL.init(string:))
        )
    }

    /// `…/pulls/12`, `…/issues/12`, `…/discussions/12` → 12.
    static func subjectNumber(from url: String?) -> Int? {
        guard let url, let components = URL(string: url)?.pathComponents, components.count >= 2 else { return nil }
        guard ["pulls", "issues", "discussions"].contains(components[components.count - 2]) else { return nil }
        return Int(components[components.count - 1])
    }
}

struct RESTIssueComment: Decodable {
    let nodeId: String
    let user: RESTUser?
    let body: String?
    let createdAt: Date
    let htmlUrl: String?

    var timelineItem: TimelineItem {
        TimelineItem(
            id: nodeId, actor: user?.actor ?? .ghost, createdAt: createdAt, payload: .comment(body: body ?? ""),
            url: htmlUrl.flatMap(URL.init(string:))
        )
    }
}

struct RESTReviewComment: Decodable {
    let id: Int
    let nodeId: String
    let user: RESTUser?
    let body: String?
    let createdAt: Date
    let path: String
    let diffHunk: String
    let line: Int?
    let originalLine: Int?
    let inReplyToId: Int?
    let htmlUrl: String?

    func reviewComment(replyToID: String?) -> ReviewComment {
        ReviewComment(
            id: nodeId, databaseID: id, author: user?.actor ?? .ghost, body: body ?? "", createdAt: createdAt,
            path: path, diffHunk: diffHunk, line: line ?? originalLine, replyToID: replyToID,
            url: htmlUrl.flatMap(URL.init(string:))
        )
    }
}

struct RESTNodeID: Decodable {
    let nodeId: String
}

struct RESTErrorBody: Decodable {
    let message: String?
}
