import Foundation
import GRDB

/// PR Shelf rows, keyed by account: pins, the last-known status of every shelved PR (the baseline event detection
/// diffs against, also across relaunches), and events collected while quiet for the morning summary.
struct ShelfSnapshot: Equatable, Sendable {
    var pins: [PullRequestRef: Date] = [:]
    var statuses: [PullRequestRef: PullRequestStatus] = [:]
    var mine: Set<PullRequestRef> = []
    var overnight: [ShelfEvent] = []
}

extension GitokenDatabase {
    static func registerShelfMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-pr-shelf") { db in
            try db.create(table: ShelfPinRow.databaseTableName) { t in
                t.column("accountHost", .text).notNull()
                t.column("accountLogin", .text).notNull()
                t.column("owner", .text).notNull()
                t.column("name", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("pinnedAt", .double).notNull()
                t.primaryKey(["accountHost", "accountLogin", "owner", "name", "number"])
            }
            try db.create(table: ShelfStatusRow.databaseTableName) { t in
                t.column("accountHost", .text).notNull()
                t.column("accountLogin", .text).notNull()
                t.column("owner", .text).notNull()
                t.column("name", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("isMine", .boolean).notNull()
                t.primaryKey(["accountHost", "accountLogin", "owner", "name", "number"])
            }
            try db.create(table: ShelfEventRow.databaseTableName) { t in
                t.column("accountHost", .text).notNull()
                t.column("accountLogin", .text).notNull()
                t.column("id", .text).notNull()
                t.column("event", .text).notNull()
                t.column("at", .double).notNull()
                t.primaryKey(["accountHost", "accountLogin", "id"])
            }
        }
    }

    func shelfSnapshot(for account: AccountKey) throws -> ShelfSnapshot {
        try queue.read { db in
            var snapshot = ShelfSnapshot()
            for row in try ShelfPinRow.filter(account: account).fetchAll(db) { snapshot.pins[row.ref] = row.pinnedAt }
            for row in try ShelfStatusRow.filter(account: account).fetchAll(db) {
                snapshot.statuses[row.status.ref] = row.status
                if row.isMine { snapshot.mine.insert(row.status.ref) }
            }
            snapshot.overnight = try ShelfEventRow.filter(account: account).order(Column("at")).fetchAll(db).map(\.event)
            return snapshot
        }
    }

    func savePin(_ ref: PullRequestRef, at: Date, for account: AccountKey) throws {
        try queue.write { db in try ShelfPinRow(account: account, ref: ref, pinnedAt: at).upsert(db) }
    }

    func deletePin(_ ref: PullRequestRef, for account: AccountKey) throws {
        try queue.write { db in _ = try ShelfPinRow.deleteOne(db, key: Self.key(ref, account)) }
    }

    /// Upserts `statuses` and deletes the rows for `removed`.
    func saveShelfStatuses(
        _ statuses: [PullRequestStatus], mine: Set<PullRequestRef>, removing removed: [PullRequestRef], for account: AccountKey
    ) throws {
        guard !statuses.isEmpty || !removed.isEmpty else { return }
        try queue.write { db in
            for status in statuses {
                try ShelfStatusRow(account: account, status: status, isMine: mine.contains(status.ref)).upsert(db)
            }
            for ref in removed { _ = try ShelfStatusRow.deleteOne(db, key: Self.key(ref, account)) }
        }
    }

    func appendOvernight(_ events: [ShelfEvent], for account: AccountKey) throws {
        guard !events.isEmpty else { return }
        try queue.write { db in
            for event in events { try ShelfEventRow(account: account, event: event).upsert(db) }
        }
    }

    func clearOvernight(for account: AccountKey) throws {
        try queue.write { db in _ = try ShelfEventRow.filter(account: account).deleteAll(db) }
    }

    func clearOvernight(before cutoff: Date, for account: AccountKey) throws {
        try queue.write { db in
            _ = try ShelfEventRow.filter(account: account)
                .filter(Column("at") < cutoff.timeIntervalSinceReferenceDate)
                .deleteAll(db)
        }
    }

    private static func key(_ ref: PullRequestRef, _ account: AccountKey) -> [String: any DatabaseValueConvertible] {
        [
            "accountHost": account.host, "accountLogin": account.login, "owner": ref.repo.owner, "name": ref.repo.name,
            "number": ref.number,
        ]
    }
}

// MARK: - Records

private extension TableRecord {
    static func filter(account: AccountKey) -> QueryInterfaceRequest<Self> {
        filter(Column("accountHost") == account.host && Column("accountLogin") == account.login)
    }
}

private struct ShelfPinRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "shelfPin"

    var account: AccountKey
    var ref: PullRequestRef
    var pinnedAt: Date

    init(account: AccountKey, ref: PullRequestRef, pinnedAt: Date) {
        self.account = account
        self.ref = ref
        self.pinnedAt = pinnedAt
    }

    init(row: Row) throws {
        account = AccountKey(host: row["accountHost"], login: row["accountLogin"])
        ref = PullRequestRef(repo: RepoRef(owner: row["owner"], name: row["name"]), number: row["number"])
        pinnedAt = Date(timeIntervalSinceReferenceDate: row["pinnedAt"])
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["accountHost"] = account.host
        container["accountLogin"] = account.login
        container["owner"] = ref.repo.owner
        container["name"] = ref.repo.name
        container["number"] = ref.number
        container["pinnedAt"] = pinnedAt.timeIntervalSinceReferenceDate
    }
}

private struct ShelfStatusRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "shelfStatus"

    var account: AccountKey
    var status: PullRequestStatus
    var isMine: Bool

    init(account: AccountKey, status: PullRequestStatus, isMine: Bool) {
        self.account = account
        self.status = status
        self.isMine = isMine
    }

    init(row: Row) throws {
        account = AccountKey(host: row["accountHost"], login: row["accountLogin"])
        status = try StorageJSON.decode(PullRequestStatus.self, from: row["status"])
        isMine = row["isMine"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["accountHost"] = account.host
        container["accountLogin"] = account.login
        container["owner"] = status.ref.repo.owner
        container["name"] = status.ref.repo.name
        container["number"] = status.ref.number
        container["status"] = try StorageJSON.encode(status)
        container["isMine"] = isMine
    }
}

private struct ShelfEventRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "shelfEvent"

    var account: AccountKey
    var event: ShelfEvent

    init(account: AccountKey, event: ShelfEvent) {
        self.account = account
        self.event = event
    }

    init(row: Row) throws {
        account = AccountKey(host: row["accountHost"], login: row["accountLogin"])
        event = try StorageJSON.decode(ShelfEvent.self, from: row["event"])
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["accountHost"] = account.host
        container["accountLogin"] = account.login
        container["id"] = event.id
        container["event"] = try StorageJSON.encode(event)
        container["at"] = event.at.timeIntervalSinceReferenceDate
    }
}
