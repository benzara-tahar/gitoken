import Foundation
import Observation

public struct MonitoredPullRequest: Hashable, Codable, Sendable, Identifiable {
    public let accountLogin: String
    public let ref: PullRequestRef
    public var lastAnnouncedHead: String?
    public var id: String { "\(accountLogin.lowercased())/\(ref.htmlURL.absoluteString.lowercased())" }

    public init(accountLogin: String, ref: PullRequestRef, lastAnnouncedHead: String? = nil) {
        self.accountLogin = accountLogin.lowercased()
        self.ref = ref
        self.lastAnnouncedHead = lastAnnouncedHead
    }
}

public struct PullRequestReadiness: Equatable, Sendable {
    public let title: String
    public let headOID: String
    public let state: String
    public let isDraft: Bool
    public let checksState: String?
    public let reviewDecision: String?
    public let mergeState: String

    public init(title: String, headOID: String, state: String, isDraft: Bool, checksState: String?,
                reviewDecision: String?, mergeState: String) {
        self.title = title; self.headOID = headOID; self.state = state; self.isDraft = isDraft
        self.checksState = checksState; self.reviewDecision = reviewDecision; self.mergeState = mergeState
    }

    /// GitHub's merge state is authoritative for branch/ruleset requirements, including code-owner reviews.
    /// A missing rollup is allowed for repositories with no checks; unknown/blocked merge states never qualify.
    public var isReady: Bool {
        state == "OPEN" && !isDraft && !headOID.isEmpty
            && (checksState == nil || checksState == "SUCCESS")
            && (reviewDecision == nil || reviewDecision == "APPROVED")
            && ["CLEAN", "HAS_HOOKS"].contains(mergeState)
    }

    public var statusText: String {
        if state != "OPEN" { return state == "MERGED" ? "Merged" : "Closed" }
        if isDraft { return "Draft" }
        if isReady { return "Ready to merge" }
        if let checksState, checksState != "SUCCESS" { return "Waiting for green checks" }
        if reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
        if reviewDecision == "REVIEW_REQUIRED" { return "Waiting for required approvals" }
        return "Waiting for GitHub merge requirements"
    }
}

public protocol PullRequestMonitoringService: Sendable {
    func pullRequestReadiness(for ref: PullRequestRef) async throws(GitHubError) -> PullRequestReadiness
}

public struct ReadyPullRequest: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let ref: PullRequestRef
    public let title: String
}

@MainActor @Observable
public final class PullRequestMonitorStore {
    public private(set) var records: [MonitoredPullRequest] = []
    public private(set) var statuses: [String: PullRequestReadiness] = [:]
    public private(set) var errors: [String: GitHubError] = [:]
    public private(set) var notification: ReadyPullRequest?
    public private(set) var accountLogin: String?
    @ObservationIgnored var onChange: (([MonitoredPullRequest]) -> Void)?
    @ObservationIgnored private let service: (any PullRequestMonitoringService)?
    @ObservationIgnored private var pending: [ReadyPullRequest] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshing = false

    public init(service: (any PullRequestMonitoringService)?) { self.service = service }
    public var currentRecords: [MonitoredPullRequest] { records.filter { $0.accountLogin == accountLogin } }
    public func configure(_ records: [MonitoredPullRequest]) { self.records = records }
    public func setAccount(_ login: String) {
        let login = login.lowercased()
        guard accountLogin != login else { return }
        accountLogin = login; generation += 1
        statuses = [:]; errors = [:]; notification = nil; pending = []
    }
    public func isMonitoring(_ ref: PullRequestRef) -> Bool {
        currentRecords.contains { $0.ref.htmlURL.absoluteString.lowercased() == ref.htmlURL.absoluteString.lowercased() }
    }
    public func monitor(_ ref: PullRequestRef) {
        guard let accountLogin, !isMonitoring(ref) else { return }
        records.append(MonitoredPullRequest(accountLogin: accountLogin, ref: ref))
        onChange?(records)
    }
    public func stopMonitoring(_ ref: PullRequestRef) {
        let ids = Set(currentRecords.filter { $0.ref.htmlURL.absoluteString.lowercased() == ref.htmlURL.absoluteString.lowercased() }.map(\.id))
        records.removeAll { ids.contains($0.id) }
        pending.removeAll { $0.ref == ref }
        if notification?.ref == ref { dismissNotification() }
        onChange?(records)
    }
    public func dismissNotification() {
        notification = pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Runs on every successful inbox poll, including HTTP 304: checks/reviews can change without a notification.
    public func refresh(announce: Bool = true) async {
        guard !refreshing, let service, accountLogin != nil else { return }
        refreshing = true
        defer { refreshing = false }
        let snapshot = currentRecords
        let generation = generation
        for record in snapshot {
            do throws(GitHubError) {
                let status = try await service.pullRequestReadiness(for: record.ref)
                guard self.generation == generation else { return }
                guard let index = records.firstIndex(where: { $0.id == record.id }) else { continue }
                statuses[record.id] = status; errors[record.id] = nil
                guard announce, status.isReady, records[index].lastAnnouncedHead != status.headOID else { continue }
                records[index].lastAnnouncedHead = status.headOID
                onChange?(records)
                let ready = ReadyPullRequest(ref: record.ref, title: status.title)
                if notification == nil { notification = ready } else { pending.append(ready) }
            } catch {
                guard self.generation == generation else { return }
                guard records.contains(where: { $0.id == record.id }) else { continue }
                errors[record.id] = error
            }
        }
    }
}
