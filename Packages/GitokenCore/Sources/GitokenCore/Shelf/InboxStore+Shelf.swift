import Foundation

extension InboxStore {
    /// The PR Shelf for this inbox's account, created once. It shares the database and clock, follows
    /// `settings.shelf`, stays silent while `quietReason` is set, and feeds the morning summary.
    public func makeShelfStore() -> ShelfStore {
        if let shelfStore { return shelfStore }
        guard let pullRequests = service as? any PullRequestService else {
            preconditionFailure("\(type(of: service)) does not implement PullRequestService")
        }
        let store = ShelfStore(
            service: pullRequests, database: database, now: now,
            account: { [weak self] in
                guard let self, case .ready(let viewer) = self.phase else { return nil }
                return AccountKey(login: viewer.login)
            },
            settings: { [weak self] in self?.settings.shelf ?? ShelfSettings() },
            quietReason: { [weak self] in self?.quietReason })
        shelfStore = store
        overnightShelfLines = { [weak store] in ShelfEvent.overnightLines(store?.takeOvernightChanges() ?? []) }
        return store
    }
}
