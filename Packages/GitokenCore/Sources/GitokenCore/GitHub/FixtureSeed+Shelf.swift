import Foundation

/// A fixture pull request as the PR Shelf sees it. Mutated by `FixtureGitHubService.ShelfTransition`s.
struct FixtureShelfPR {
    let ref: PullRequestRef
    let title: String
    let author: String
    let body: String
    let headRefName: String
    let allowedMergeMethods: [MergeMethod]
    var state: SubjectState = .open
    var isDraft = false
    var headSHA: String
    var checks: CheckSummary?
    var reviewDecision: ReviewDecision
    var mergeable: MergeableState
    var threads: [AgentContext.ReviewThread] = []
    var latestHumanActivity: ActivityPreview?
    var updatedAt: Date
    /// Raw job logs (with Actions timestamps) for failing checks, by check name.
    var logs: [String: String] = [:]

    var status: PullRequestStatus {
        PullRequestStatus(
            nodeID: "PR_fx_\(ref.repo.name)_\(ref.number)", ref: ref, title: title, author: FixtureSeed.person(author),
            state: state, isDraft: isDraft, headRefName: headRefName, headRefOID: headSHA, baseRefName: "main",
            isCrossRepository: false, checks: checks, reviewDecision: reviewDecision, mergeable: mergeable,
            unresolvedThreadCount: threads.filter { !$0.isResolved }.count, latestHumanActivity: latestHumanActivity,
            updatedAt: updatedAt, viewerCanMerge: true, allowedMergeMethods: allowedMergeMethods
        )
    }

    var agentContext: AgentContext {
        let failing = checks?.status == .failure ? checks?.failedChecks ?? [] : []
        return AgentContext(
            ref: ref, title: title, headRefName: headRefName, baseRefName: "main", body: body, threads: threads,
            failingChecks: failing.map { name in
                AgentContext.FailingCheck(
                    name: name, detailsURL: URL(string: "https://github.com/\(ref.repo.fullName)/actions/runs/4100\(ref.number)"),
                    summary: nil, logTail: logs[name].map { AgentContext.logTail($0) }
                )
            }
        )
    }
}

extension FixtureSeed {
    static func pending(_ sha: String, done: Int, running: Int) -> CheckSummary {
        CheckSummary(status: .pending, commitSHA: sha, failedChecks: [], passedCount: done, pendingCount: running)
    }

    static func thread(_ hunk: Hunk, line: Int, resolved: Bool = false, _ comments: [(String, String)]) -> AgentContext.ReviewThread {
        AgentContext.ReviewThread(
            path: hunk.file, line: line, isResolved: resolved, isOutdated: false, diffHunk: hunk.diffHunk(endingAt: line),
            comments: comments.map { AgentContext.Comment(author: $0.0, body: $0.1) }
        )
    }

    static let settingsHunk = Hunk(
        file: "src/pages/settings/ProfileForm.tsx",
        header: "@@ -12,10 +12,12 @@ export function ProfileForm({ user }: Props) {",
        newStart: 12,
        lines: [
            "   const form = useForm<ProfileValues>({ defaultValues: toValues(user) });",
            "-  const [saving, setSaving] = useState(false);",
            "+  const save = useMutation(updateProfile);",
            " ",
            "   return (",
            "-    <form onSubmit={onSubmit}>",
            "+    <Form form={form} onSubmit={(values) => save.mutate(values)}>",
            "       <TextField name=\"displayName\" label=\"Display name\" />",
            "+      <TextField name=\"pronouns\" label=\"Pronouns\" optional />",
            "       <EmailField name=\"email\" label=\"Email\" />",
            "-    </form>",
            "+    </Form>",
        ]
    )

    static let lintLog = """
        2026-10-02T13:12:40.1180000Z ##[group]Run pnpm lint
        2026-10-02T13:12:40.1190000Z pnpm lint
        2026-10-02T13:12:40.1200000Z ##[endgroup]
        2026-10-02T13:12:41.9020000Z > web@0.0.0 lint /home/runner/work/web/web
        2026-10-02T13:12:41.9030000Z > eslint . --max-warnings 0
        2026-10-02T13:12:49.3310000Z
        2026-10-02T13:12:49.3320000Z /home/runner/work/web/web/src/components/ResultList.tsx
        2026-10-02T13:12:49.3330000Z   23:13  error  Do not use Array index in keys  react/no-array-index-key
        2026-10-02T13:12:49.3340000Z
        2026-10-02T13:12:49.3350000Z /home/runner/work/web/web/src/components/SearchBox.tsx
        2026-10-02T13:12:49.3360000Z   37:6  warning  React Hook useEffect has a missing dependency: 'onSearch'  react-hooks/exhaustive-deps
        2026-10-02T13:12:49.3370000Z
        2026-10-02T13:12:49.3380000Z \u{1B}[31m✖ 2 problems (1 error, 1 warning)\u{1B}[39m
        2026-10-02T13:12:49.4010000Z ##[error]Process completed with exit code 1.
        """

    static let unitTestLog = """
        2026-10-02T13:13:02.5000000Z ##[group]Run pnpm test --ci
        2026-10-02T13:13:02.5010000Z ##[endgroup]
        2026-10-02T13:13:31.0040000Z PASS src/components/ResultList.test.tsx
        2026-10-02T13:13:33.7720000Z FAIL src/components/SearchBox.test.tsx
        2026-10-02T13:13:33.7730000Z   ● SearchBox › applies the ?q= deep link before the first debounce
        2026-10-02T13:13:33.7740000Z
        2026-10-02T13:13:33.7750000Z     expect(onSearch).toHaveBeenCalledWith("dashboards", expect.anything())
        2026-10-02T13:13:33.7760000Z     Number of calls: 0
        2026-10-02T13:13:33.7770000Z
        2026-10-02T13:13:33.7780000Z       at Object.<anonymous> (src/components/SearchBox.test.tsx:58:22)
        2026-10-02T13:13:35.0100000Z Tests:       1 failed, 47 passed, 48 total
        2026-10-02T13:13:35.0200000Z ##[error]Process completed with exit code 1.
        """

    static let typecheckLog = """
        2026-10-02T13:20:11.0000000Z ##[group]Run pnpm typecheck
        2026-10-02T13:20:11.0010000Z ##[endgroup]
        2026-10-02T13:20:24.4400000Z src/pages/settings/ProfileForm.tsx(19,7): error TS2322: Type '"pronouns"' is not assignable to type 'keyof ProfileValues'.
        2026-10-02T13:20:24.6000000Z ##[error]Process completed with exit code 2.
        """

    /// akim's open PRs in every shelf state, plus PRs by others that can be pinned.
    static func shelfPullRequests(relativeTo start: Date) -> [FixtureShelfPR] {
        func ago(_ minutes: Double) -> Date { start.addingTimeInterval(-minutes * 60) }
        func activity(_ login: String, _ verb: ActivityVerb, _ snippet: String?, _ minutes: Double) -> ActivityPreview {
            ActivityPreview(actor: person(login), verb: verb, snippet: snippet, at: ago(minutes))
        }
        func ref(_ repo: String, _ number: Int) -> PullRequestRef {
            PullRequestRef(repo: RepoRef(owner: "platform", name: repo), number: number)
        }
        return [
            // CI failing, review required, two unresolved threads (one resolved).
            FixtureShelfPR(
                ref: ref("web", 142), title: web142.title, author: "akim",
                body: "<!-- Describe the change and link the issue. -->\nTyping in global search fires a request per keystroke and re-renders the entire result list. This debounces the input (250ms), aborts stale requests, and memoizes `ResultRow`.\n\nCloses #131.",
                headRefName: "akim/debounce-search", allowedMergeMethods: [.squash, .merge], headSHA: "7be0d44",
                checks: ci("7be0d44", failed: ["lint", "unit-tests"]), reviewDecision: .reviewRequired, mergeable: .mergeable,
                threads: [
                    thread(searchHunk, line: 37, [
                        ("schen", "This effect re-subscribes on every keystroke because `onSearch` is recreated by the parent on each render. Could we wrap it in `useCallback` upstream, or keep the latest callback in a ref here?"),
                        ("leom", "+1 to the ref. It also avoids a stale closure in the cleanup."),
                    ]),
                    thread(resultsHunk, line: 23, [
                        ("schen", "`key={index}` will defeat the row memoization as soon as results reorder. Can we key by `result.id`?"),
                    ]),
                    thread(searchHunk, line: 30, resolved: true, [
                        ("leom", "Did you check the `?q=` deep-link flow? That path sets the value before the debounce hook mounts."),
                        ("akim", "Good catch. Added a test for the deep-link case."),
                    ]),
                ],
                latestHumanActivity: activity("leom", .reviewed, "+1 to the ref. It also avoids a stale closure in the cleanup.", 31),
                updatedAt: ago(31), logs: ["lint": lintLog, "unit-tests": unitTestLog]
            ),
            // Approved + green + mergeable: ready to merge.
            FixtureShelfPR(
                ref: ref("ui-kit", 305), title: "Button: add loading state", author: "akim",
                body: "Adds `loading` to `<Button>`: keeps the width stable, swaps the label for a spinner and blocks clicks.",
                headRefName: "akim/button-loading", allowedMergeMethods: [.merge, .squash, .rebase], headSHA: "f4b8d21",
                checks: ci("f4b8d21"), reviewDecision: .approved, mergeable: .mergeable,
                latestHumanActivity: activity("pnair", .approved, "Spinner sizing matches the spec. Nit: `aria-busy` on the button would be nice, not blocking.", 1450),
                updatedAt: ago(1440)
            ),
            // CI still running.
            FixtureShelfPR(
                ref: ref("api", 102), title: "Stream CSV exports instead of buffering", author: "akim",
                body: "Exports over 50k rows ran the worker out of memory. This streams rows through `csv.Writer` straight into the response and flushes every 1,000 rows.",
                headRefName: "akim/stream-csv-exports", allowedMergeMethods: [.squash], headSHA: "a19c3e7",
                checks: pending("a19c3e7", done: 3, running: 3), reviewDecision: .reviewRequired, mergeable: .mergeable,
                updatedAt: ago(12)
            ),
            // Changes requested, green.
            FixtureShelfPR(
                ref: ref("web", 150), title: "Move settings page to the new form primitives", author: "akim",
                body: "Ports the profile and notification settings forms to `<Form>` / `useForm`, and adds the optional pronouns field.",
                headRefName: "akim/settings-form-primitives", allowedMergeMethods: [.squash, .merge], headSHA: "3d5f0b2",
                checks: ci("3d5f0b2"), reviewDecision: .changesRequested, mergeable: .mergeable,
                threads: [
                    thread(settingsHunk, line: 20, [
                        ("schen", "`pronouns` isn't in `ProfileValues` yet, so this only type-checks because the field is untyped. Can we add it to the schema first?"),
                    ]),
                ],
                latestHumanActivity: activity("schen", .requestedChanges, "A couple of schema issues before this can land.", 95),
                updatedAt: ago(95)
            ),
            // Approved + green but conflicting with main.
            FixtureShelfPR(
                ref: ref("ui-kit", 309), title: "Popover: support nested portals", author: "akim",
                body: "Lets a `<Popover>` open inside another popover's portal without closing its parent on outside-click.",
                headRefName: "akim/nested-portals", allowedMergeMethods: [.merge, .squash, .rebase], headSHA: "b07e6c4",
                checks: ci("b07e6c4"), reviewDecision: .approved, mergeable: .conflicting,
                latestHumanActivity: activity("ilaurent", .approved, "Works with the date picker inside the filter popover. 👍", 400),
                updatedAt: ago(380)
            ),
            // Others' PRs (pinnable by URL).
            FixtureShelfPR(
                ref: ref("api", 87), title: "Add idempotency keys to payment intents", author: "dpatel",
                body: "Adds an `Idempotency-Key` header to `POST /v1/payment_intents`.", headRefName: "dpatel/idempotency-keys",
                allowedMergeMethods: [.squash], headSHA: "5e02a7b", checks: ci("5e02a7b"), reviewDecision: .reviewRequired,
                mergeable: .mergeable,
                threads: [thread(idempotencyHunk, line: 53, [("mokafor", "If two requests with the same key race, both can miss the cache and execute the handler. Should this take a `SETNX` lock before calling `next`?")])],
                latestHumanActivity: activity("dpatel", .commented, "@akim when you get a chance — you wrote the original retry middleware.", 22),
                updatedAt: ago(22)
            ),
            FixtureShelfPR(
                ref: ref("api", 91), title: "Migrate rate limiter to a sliding window", author: "jberg",
                body: "Replaces the fixed-window counter with a sliding-window log in Redis.", headRefName: "jberg/sliding-window",
                allowedMergeMethods: [.squash], headSHA: "91ac3f0", checks: ci("91ac3f0"), reviewDecision: .approved,
                mergeable: .mergeable,
                latestHumanActivity: activity("mokafor", .approved, "Load-test numbers look good. Ship it.", 360),
                updatedAt: ago(350)
            ),
            FixtureShelfPR(
                ref: ref("ui-kit", 298), title: "Tokens: rename spacing scale to t-shirt sizes", author: "pnair",
                body: "Renames `space-1…space-12` to `space-3xs…space-3xl`.", headRefName: "pnair/spacing-tshirt",
                allowedMergeMethods: [.merge, .squash, .rebase], headSHA: "0d9e6aa", checks: ci("0d9e6aa"),
                reviewDecision: .reviewRequired, mergeable: .mergeable, updatedAt: ago(1400)
            ),
            FixtureShelfPR(
                ref: ref("web", 120), title: "Upgrade to React 19", author: "leom",
                body: "Bumps React and React DOM to 19.", headRefName: "leom/react-19", allowedMergeMethods: [.squash, .merge],
                state: .merged, headSHA: "e5c1a90", checks: ci("e5c1a90"), reviewDecision: .approved, mergeable: .unknown,
                updatedAt: ago(5800)
            ),
        ]
    }
}
