import Foundation
import GRDB

/// SQLite storage for inbox rows, cached conversation timelines, and app-wide state.
/// Inbox and detail rows are keyed by `AccountKey`; app state is a single row.
final class GitokenDatabase: Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    /// `~/Library/Application Support/Gitoken/gitoken.sqlite`.
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "Gitoken", directoryHint: .isDirectory).appending(path: "gitoken.sqlite")
    }

    static func onDisk(at url: URL? = nil, fileManager: FileManager = .default) throws -> GitokenDatabase {
        let url = try url ?? defaultURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try GitokenDatabase(queue: DatabaseQueue(path: url.path(percentEncoded: false)))
    }

    static func inMemory() throws -> GitokenDatabase {
        try GitokenDatabase(queue: DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: ThreadRow.databaseTableName) { t in
                t.column("accountHost", .text).notNull()
                t.column("accountLogin", .text).notNull()
                t.column("id", .text).notNull()
                t.column("thread", .text).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("unread", .boolean).notNull()
                t.column("state", .text).notNull()
                t.column("preview", .text)
                t.column("actors", .text).notNull()
                t.column("unseenCount", .integer).notNull()
                t.column("seenThrough", .double)
                t.column("lastVisitAt", .double)
                t.column("doneAt", .double)
                t.column("snoozedUntil", .double)
                t.column("resurfaced", .text)
                t.column("hydratedThrough", .double)
                t.column("keptLocally", .boolean).notNull().defaults(to: false)
                t.primaryKey(["accountHost", "accountLogin", "id"])
            }
            try db.create(table: DetailRow.databaseTableName) { t in
                t.column("accountHost", .text).notNull()
                t.column("accountLogin", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("fetchedAt", .double).notNull()
                t.primaryKey(["accountHost", "accountLogin", "threadID"])
            }
            try db.create(table: AppStateRow.databaseTableName) { t in
                t.primaryKey("id", .integer).check { $0 == AppStateRow.singletonID }
                t.column("settings", .text).notNull()
                t.column("manualQuiet", .boolean).notNull()
                t.column("globalSnoozeUntil", .double)
                t.column("lastModified", .text)
                t.column("viewer", .text)
                t.column("collectedUpdates", .integer).notNull()
                t.column("collectedGroups", .text).notNull()
                t.column("collectedActors", .text).notNull()
                t.column("collectedReason", .text)
            }
        }
        return migrator
    }

    // MARK: App state

    func appState() throws -> PersistedAppState? {
        try queue.read { db in try AppStateRow.fetchOne(db, key: AppStateRow.singletonID)?.state }
    }

    func save(_ state: PersistedAppState) throws {
        try queue.write { db in try AppStateRow(state: state).upsert(db) }
    }

    // MARK: Threads

    func threads(for account: AccountKey) throws -> [TrackedThread] {
        try queue.read { db in
            try ThreadRow
                .filter(Column("accountHost") == account.host && Column("accountLogin") == account.login)
                .fetchAll(db)
                .map(\.tracked)
        }
    }

    func save(_ threads: [TrackedThread], for account: AccountKey) throws {
        guard !threads.isEmpty else { return }
        try queue.write { db in
            for tracked in threads { try ThreadRow(account: account, tracked: tracked).upsert(db) }
        }
    }

    /// Deletes the rows and their cached details.
    func deleteThreads(_ ids: [ThreadID], for account: AccountKey) throws {
        guard !ids.isEmpty else { return }
        let raw = ids.map(\.rawValue)
        try queue.write { db in
            _ = try ThreadRow
                .filter(Column("accountHost") == account.host && Column("accountLogin") == account.login)
                .filter(raw.contains(Column("id")))
                .deleteAll(db)
            _ = try DetailRow
                .filter(Column("accountHost") == account.host && Column("accountLogin") == account.login)
                .filter(raw.contains(Column("threadID")))
                .deleteAll(db)
        }
    }

    // MARK: Conversation cache

    func detail(for id: ThreadID, account: AccountKey) throws -> ThreadDetail? {
        try queue.read { db in
            try DetailRow.fetchOne(db, key: ["accountHost": account.host, "accountLogin": account.login, "threadID": id.rawValue])?
                .detail
        }
    }

    func save(_ detail: ThreadDetail, for account: AccountKey) throws {
        try queue.write { db in try DetailRow(account: account, detail: detail).upsert(db) }
    }
}

// MARK: - Persisted values

struct PersistedAppState: Equatable, Sendable {
    var settings = AppSettings()
    var manualQuiet = false
    var globalSnoozeUntil: Date?
    var lastModified: String?
    var viewer: Actor?
    var collected = CollectedActivity()
    /// The quiet reason in effect while `collected` accumulated; becomes the summary's `endedReason`.
    var collectedReason: QuietReason?
}

/// Codable mirror of `QuietReason` for the app-state row.
private enum StoredQuietReason: Codable {
    case globalSnooze(until: Date)
    case manual
    case quietHours(until: ClockTime)

    init(_ reason: QuietReason) {
        switch reason {
        case .globalSnooze(let until): self = .globalSnooze(until: until)
        case .manual: self = .manual
        case .quietHours(let until): self = .quietHours(until: until)
        }
    }

    var reason: QuietReason {
        switch self {
        case .globalSnooze(let until): .globalSnooze(until: until)
        case .manual: .manual
        case .quietHours(let until): .quietHours(until: until)
        }
    }
}

// MARK: - Records

/// JSON columns use Foundation's default date strategy (seconds since 2001 as Double), so dates round-trip exactly.
private enum StorageJSON {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    static func decodeIfPresent<T: Decodable>(_ type: T.Type, from text: String?) throws -> T? {
        try text.map { try decode(type, from: $0) }
    }
}

private extension Date {
    var storageValue: Double { timeIntervalSinceReferenceDate }
    init?(storageValue: Double?) {
        guard let storageValue else { return nil }
        self.init(timeIntervalSinceReferenceDate: storageValue)
    }
}

private struct ThreadRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "thread"

    var account: AccountKey
    var tracked: TrackedThread

    init(account: AccountKey, tracked: TrackedThread) {
        self.account = account
        self.tracked = tracked
    }

    init(row: Row) throws {
        account = AccountKey(host: row["accountHost"], login: row["accountLogin"])
        var tracked = TrackedThread(thread: try StorageJSON.decode(NotificationThread.self, from: row["thread"]))
        tracked.state = SubjectState(rawValue: row["state"]) ?? .unknown
        tracked.preview = try StorageJSON.decodeIfPresent(ActivityPreview.self, from: row["preview"])
        tracked.actors = try StorageJSON.decode([Actor].self, from: row["actors"])
        tracked.unseenCount = row["unseenCount"]
        tracked.seenThrough = Date(storageValue: row["seenThrough"])
        tracked.lastVisitAt = Date(storageValue: row["lastVisitAt"])
        tracked.doneAt = Date(storageValue: row["doneAt"])
        tracked.snoozedUntil = Date(storageValue: row["snoozedUntil"])
        tracked.resurfaced = (row["resurfaced"] as String?).flatMap(ResurfaceReason.init(rawValue:))
        tracked.hydratedThrough = Date(storageValue: row["hydratedThrough"])
        tracked.keptLocally = row["keptLocally"]
        self.tracked = tracked
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["accountHost"] = account.host
        container["accountLogin"] = account.login
        container["id"] = tracked.thread.id.rawValue
        container["thread"] = try StorageJSON.encode(tracked.thread)
        container["updatedAt"] = tracked.thread.updatedAt.storageValue
        container["unread"] = tracked.thread.unread
        container["state"] = tracked.state.rawValue
        container["preview"] = try tracked.preview.map { try StorageJSON.encode($0) }
        container["actors"] = try StorageJSON.encode(tracked.actors)
        container["unseenCount"] = tracked.unseenCount
        container["seenThrough"] = tracked.seenThrough?.storageValue
        container["lastVisitAt"] = tracked.lastVisitAt?.storageValue
        container["doneAt"] = tracked.doneAt?.storageValue
        container["snoozedUntil"] = tracked.snoozedUntil?.storageValue
        container["resurfaced"] = tracked.resurfaced?.rawValue
        container["hydratedThrough"] = tracked.hydratedThrough?.storageValue
        container["keptLocally"] = tracked.keptLocally
    }
}

private struct DetailRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "threadDetail"

    var account: AccountKey
    var detail: ThreadDetail

    init(account: AccountKey, detail: ThreadDetail) {
        self.account = account
        self.detail = detail
    }

    init(row: Row) throws {
        account = AccountKey(host: row["accountHost"], login: row["accountLogin"])
        detail = try StorageJSON.decode(ThreadDetail.self, from: row["detail"])
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["accountHost"] = account.host
        container["accountLogin"] = account.login
        container["threadID"] = detail.threadID.rawValue
        container["detail"] = try StorageJSON.encode(detail)
        container["fetchedAt"] = detail.fetchedAt.storageValue
    }
}

private struct AppStateRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "appState"
    static let singletonID = 1

    var state: PersistedAppState

    init(state: PersistedAppState) { self.state = state }

    init(row: Row) throws {
        var state = PersistedAppState()
        state.settings = try StorageJSON.decode(AppSettings.self, from: row["settings"])
        state.manualQuiet = row["manualQuiet"]
        state.globalSnoozeUntil = Date(storageValue: row["globalSnoozeUntil"])
        state.lastModified = row["lastModified"]
        state.viewer = try StorageJSON.decodeIfPresent(Actor.self, from: row["viewer"])
        state.collected = CollectedActivity(
            updates: row["collectedUpdates"],
            groupIDs: try StorageJSON.decode([ThreadID].self, from: row["collectedGroups"]),
            actors: try StorageJSON.decode([Actor].self, from: row["collectedActors"]))
        state.collectedReason = try StorageJSON.decodeIfPresent(StoredQuietReason.self, from: row["collectedReason"])?.reason
        self.state = state
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = Self.singletonID
        container["settings"] = try StorageJSON.encode(state.settings)
        container["manualQuiet"] = state.manualQuiet
        container["globalSnoozeUntil"] = state.globalSnoozeUntil?.storageValue
        container["lastModified"] = state.lastModified
        container["viewer"] = try state.viewer.map { try StorageJSON.encode($0) }
        container["collectedUpdates"] = state.collected.updates
        container["collectedGroups"] = try StorageJSON.encode(state.collected.groupIDs)
        container["collectedActors"] = try StorageJSON.encode(state.collected.actors)
        container["collectedReason"] = try state.collectedReason.map { try StorageJSON.encode(StoredQuietReason($0)) }
    }
}
