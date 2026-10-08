import Foundation

/// The arrival on screen plus those waiting behind it. Activity on a group that is already showing or waiting
/// merges into that arrival (same `id`, rising `updateCount`) instead of producing a new one.
struct ArrivalQueue: Equatable, Sendable {
    private(set) var current: Arrival?
    private(set) var queued: [Arrival] = []
    private struct SummarySource: Equatable, Sendable {
        var collected: CollectedActivity
        let repos: [ThreadID: RepoRef]
    }
    private var summarySources: [UUID: SummarySource] = [:]

    mutating func announce(groupID: ThreadID, latest: ActivityPreview, reopened: Bool, count: Int, actors: [Actor]) {
        if var arrival = current, Self.merge(into: &arrival, groupID: groupID, latest: latest, reopened: reopened, count: count, actors: actors) {
            current = arrival
            return
        }
        for index in queued.indices {
            if Self.merge(into: &queued[index], groupID: groupID, latest: latest, reopened: reopened, count: count, actors: actors) {
                return
            }
        }
        enqueue(Arrival(
            kind: .activity(groupID: groupID, latest: latest, reopened: reopened), updateCount: count,
            actors: [Actor]().merging(actors)))
    }

    mutating func enqueue(_ arrival: Arrival, collected: CollectedActivity? = nil, repos: [ThreadID: RepoRef] = [:]) {
        if arrival.groupID == nil, let collected {
            summarySources[arrival.id] = SummarySource(collected: collected, repos: repos)
        }
        if current == nil { current = arrival } else { queued.append(arrival) }
    }

    mutating func dismiss() {
        if let current { summarySources[current.id] = nil }
        current = queued.isEmpty ? nil : queued.removeFirst()
    }

    /// The user acted on the group (opened, snoozed, done): nothing about it needs announcing anymore.
    mutating func remove(groupID: ThreadID) {
        queued.removeAll { $0.groupID == groupID }
        if current?.groupID == groupID { dismiss() }
    }

    /// Filtered groups must not leak through already queued aggregate announcements.
    mutating func remove(_ ids: Set<ThreadID>) {
        guard !ids.isEmpty else { return }
        for index in queued.indices.reversed() {
            if let retained = filtered(queued[index], excluding: ids) {
                queued[index] = retained
            } else {
                queued.remove(at: index)
            }
        }
        if let current {
            if let retained = filtered(current, excluding: ids) { self.current = retained } else { dismiss() }
        }
    }

    /// Empties the queue and returns what was still waiting (the arrival on screen is dropped).
    mutating func clear() -> [Arrival] {
        defer { self = ArrivalQueue() }
        return queued
    }

    private mutating func filtered(_ arrival: Arrival, excluding ids: Set<ThreadID>) -> Arrival? {
        if let groupID = arrival.groupID { return ids.contains(groupID) ? nil : arrival }
        guard var source = summarySources[arrival.id] else { return nil }
        guard source.collected.groupIDs.contains(where: { ids.contains($0) }) else { return arrival }
        source.collected.remove(ids)
        guard !source.collected.isEmpty else {
            summarySources[arrival.id] = nil
            return nil
        }
        var retained = arrival
        switch arrival.kind {
        case .summary(_, _, _, let endedReason):
            retained.kind = .summary(
                updates: source.collected.updates, groups: source.collected.groupIDs.count,
                actors: source.collected.actors, endedReason: endedReason)
            retained.actors = source.collected.actors
        case .morningSummary:
            let summary = source.collected.morningSummary(repo: { source.repos[$0] })
            guard !summary.isEmpty else {
                summarySources[arrival.id] = nil
                return nil
            }
            retained.kind = .morningSummary(summary)
            retained.actors = summary.actors
        case .activity, .snoozeEnded:
            return arrival
        }
        summarySources[arrival.id] = source
        return retained
    }

    private static func merge(
        into arrival: inout Arrival, groupID: ThreadID, latest: ActivityPreview, reopened: Bool, count: Int, actors: [Actor]
    ) -> Bool {
        guard case .activity(groupID, _, let wasReopened) = arrival.kind else { return false }
        arrival.kind = .activity(groupID: groupID, latest: latest, reopened: wasReopened || reopened)
        arrival.updateCount += count
        arrival.actors = arrival.actors.merging(actors)
        return true
    }
}

/// Activity that arrived while quiet; becomes a `.summary` arrival when quiet ends.
struct CollectedActivity: Equatable, Sendable {
    var updates = 0
    /// Distinct groups, first-seen order.
    var groupIDs: [ThreadID] = []
    /// Newest last, at most 3.
    var actors: [Actor] = []
    /// Updates per group; groups collected before this was tracked count once.
    var groupUpdates: [ThreadID: Int] = [:]
    /// Actor attribution per group, so filtering a group also filters its summary avatars.
    var groupActors: [ThreadID: [Actor]] = [:]

    var isEmpty: Bool { updates == 0 }

    mutating func add(groupID: ThreadID, count: Int, actors newActors: [Actor]) {
        updates += count
        if !groupIDs.contains(groupID) { groupIDs.append(groupID) }
        groupUpdates[groupID, default: 0] += count
        groupActors[groupID] = (groupActors[groupID] ?? []).merging(newActors)
        actors = actors.merging(newActors)
    }

    /// Folds an announcement that never got shown. Only activity carries collectable updates.
    mutating func add(_ arrival: Arrival) {
        guard case .activity(let groupID, _, _) = arrival.kind else { return }
        add(groupID: groupID, count: arrival.updateCount, actors: arrival.actors)
    }

    /// Drops groups that were muted after their activity was collected.
    mutating func remove(_ ids: Set<ThreadID>) {
        guard groupIDs.contains(where: { ids.contains($0) }) else { return }
        let retained = groupIDs.filter { !ids.contains($0) }
        actors = actors(for: retained)
        for id in groupIDs where ids.contains(id) { updates -= groupUpdates[id] ?? 1 }
        updates = max(0, updates)
        groupIDs.removeAll { ids.contains($0) }
        for id in ids { groupUpdates[id] = nil }
        for id in ids { groupActors[id] = nil }
    }

    func summary(endedReason: QuietReason) -> Arrival {
        Arrival(kind: .summary(updates: updates, groups: groupIDs.count, actors: actors, endedReason: endedReason),
                updateCount: 1, actors: actors)
    }

    /// Groups `repo` can't place (forgotten, or muted since) are left out of every count.
    func morningSummary(repo: (ThreadID) -> RepoRef?) -> MorningSummary {
        var byRepo: [RepoRef: Int] = [:]
        var updates = 0
        var conversations = 0
        var included: [ThreadID] = []
        for id in groupIDs {
            guard let repo = repo(id) else { continue }
            included.append(id)
            let count = groupUpdates[id] ?? 1
            byRepo[repo, default: 0] += count
            updates += count
            conversations += 1
        }
        let topRepos = byRepo
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.fullName < $1.key.fullName }
            .prefix(MorningSummary.maxRepos)
            .map { MorningSummary.RepoUpdates(repo: $0.key, updates: $0.value) }
        return MorningSummary(
            updates: updates, conversations: conversations, topRepos: topRepos, actors: actors(for: included))
    }

    private func actors(for ids: [ThreadID]) -> [Actor] {
        if ids.count == groupIDs.count { return actors }
        // Legacy rows only stored aggregate actors; none can be attributed safely after an exclusion.
        guard ids.allSatisfy({ groupActors[$0] != nil }) else { return [] }
        let logins = Set(ids.flatMap { groupActors[$0] ?? [] }.map(\.login))
        return actors.filter { logins.contains($0.login) }
    }
}
