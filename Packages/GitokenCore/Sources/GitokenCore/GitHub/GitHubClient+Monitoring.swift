import Foundation

extension GitHubClient: PullRequestMonitoringService {
    public func pullRequestReadiness(for ref: PullRequestRef) async throws(GitHubError) -> PullRequestReadiness {
        let query = """
        query PullRequestReadiness($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              title state isDraft headRefOid reviewDecision mergeStateStatus
              commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
            }
          }
        }
        """
        let data: GQLReadinessData = try await graphQL(query, variables: SubjectVariables(
            owner: ref.repo.owner, name: ref.repo.name, number: ref.number))
        guard let pr = data.repository?.pullRequest else { throw .http(status: 404, message: "Pull request not found") }
        // Never report checks belonging to a stale head.
        guard let commit = pr.commits.items.last?.commit, commit.oid == pr.headRefOid else {
            throw .decoding("GitHub returned checks for a different PR head. Will retry on the next poll.")
        }
        return PullRequestReadiness(title: pr.title, headOID: pr.headRefOid, state: pr.state, isDraft: pr.isDraft,
            checksState: commit.statusCheckRollup?.state, reviewDecision: pr.reviewDecision, mergeState: pr.mergeStateStatus)
    }
}

private struct GQLReadinessData: Decodable {
    struct Repository: Decodable {
        struct PR: Decodable {
            struct CommitNode: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable { let state: String }
                    let oid: String
                    let statusCheckRollup: Rollup?
                }
                let commit: Commit
            }
            let title: String
            let state: String
            let isDraft: Bool
            let headRefOid: String
            let reviewDecision: String?
            let mergeStateStatus: String
            let commits: GQLNodes<CommitNode>
        }
        let pullRequest: PR?
    }
    let repository: Repository?
}
