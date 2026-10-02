import Foundation

/// The arrival on screen plus those waiting behind it. Activity on a group that is already showing or waiting
/// merges into that arrival (same `id`, rising `updateCount`) instead of producing a new one.
struct ArrivalQueue: Equatable, Sendable {
    private(set) var current: Arrival?
    private(set) var queued: [Arrival] = []

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

    mutating func enqueue(_ arrival: Arrival) {
        if current == nil { current = arrival } else { queued.append(arrival) }
    }

    mutating func dismiss() {
        current = queued.isEmpty ? nil : queued.removeFirst()
    }

    /// The user acted on the group (opened, snoozed, done): nothing about it needs announcing anymore.
    mutating func remove(groupID: ThreadID) {
        queued.removeAll { $0.groupID == groupID }
        if current?.groupID == groupID { dismiss() }
    }

    /// Empties the queue and returns what was still waiting (the arrival on screen is dropped).
    mutating func clear() -> [Arrival] {
        defer { self = ArrivalQueue() }
        return queued
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

    var isEmpty: Bool { updates == 0 }

    mutating func add(groupID: ThreadID, count: Int, actors newActors: [Actor]) {
        updates += count
        if !groupIDs.contains(groupID) { groupIDs.append(groupID) }
        actors = actors.merging(newActors)
    }

    /// Folds an announcement that never got shown. Only activity carries collectable updates.
    mutating func add(_ arrival: Arrival) {
        guard case .activity(let groupID, _, _) = arrival.kind else { return }
        add(groupID: groupID, count: arrival.updateCount, actors: arrival.actors)
    }

    func summary(endedReason: QuietReason) -> Arrival {
        Arrival(kind: .summary(updates: updates, groups: groupIDs.count, actors: actors, endedReason: endedReason),
                updateCount: 1, actors: actors)
    }
}
