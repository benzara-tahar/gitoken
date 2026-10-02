import Foundation

/// Fictional people, code, and scripted activity mirroring the design prototype (`opus-5.5/index.html`).
enum FixtureSeed {
    static let viewerLogin = "akim"

    static let people: [String: Actor] = [
        "akim": Actor(login: "akim", name: "Alex Kim"),
        "schen": Actor(login: "schen", name: "Sarah Chen"),
        "leom": Actor(login: "leom", name: "Leo Martins"),
        "mokafor": Actor(login: "mokafor", name: "Maya Okafor"),
        "dpatel": Actor(login: "dpatel", name: "Dev Patel"),
        "ilaurent": Actor(login: "ilaurent", name: "Inès Laurent"),
        "trivera": Actor(login: "trivera", name: "Tomás Rivera"),
        "pnair": Actor(login: "pnair", name: "Priya Nair"),
        "jberg": Actor(login: "jberg", name: "Jonas Berg"),
        "github-actions": Actor(login: "github-actions", name: "GitHub Actions", isBot: true),
        "copilot-pull-request-reviewer": Actor(login: "copilot-pull-request-reviewer", name: "Copilot", isBot: true),
    ]

    static func person(_ login: String) -> Actor { people[login] ?? Actor(login: login) }

    // MARK: Code

    struct Hunk: Sendable {
        let file: String
        let header: String
        let newStart: Int
        let lines: [String]

        /// GitHub's `diffHunk`: the hunk header plus every line up to and including new-file line `line`.
        func diffHunk(endingAt line: Int) -> String {
            var current = newStart - 1
            var kept = [header]
            for text in lines {
                kept.append(text)
                if !text.hasPrefix("-") { current += 1 }
                if current >= line, !text.hasPrefix("-") { break }
            }
            return kept.joined(separator: "\n")
        }
    }

    static let searchHunk = Hunk(
        file: "src/components/SearchBox.tsx",
        header: "@@ -28,13 +28,18 @@ export function SearchBox({ onSearch, initialQuery }: Props) {",
        newStart: 28,
        lines: [
            "   const [value, setValue] = useState(initialQuery ?? \"\");",
            "   const inputRef = useRef<HTMLInputElement>(null);",
            "-  useEffect(() => {",
            "-    onSearch(value);",
            "-  }, [value]);",
            "+  const debounced = useDebouncedValue(value, 250);",
            "+",
            "+  useEffect(() => {",
            "+    if (!debounced) return;",
            "+    const controller = new AbortController();",
            "+    onSearch(debounced, { signal: controller.signal });",
            "+    return () => controller.abort();",
            "+  }, [debounced, onSearch]);",
            " ",
            "   return (",
            "     <div className={styles.root}>",
            "       <SearchIcon aria-hidden />",
            "       <input",
            "         ref={inputRef}",
            "         value={value}",
            "         onChange={(e) => setValue(e.target.value)}",
        ]
    )

    static let resultsHunk = Hunk(
        file: "src/components/ResultList.tsx",
        header: "@@ -14,9 +14,14 @@ type Props = { results: SearchResult[]; query: string };",
        newStart: 14,
        lines: [
            " export function ResultList({ results, query }: Props) {",
            "+  const renderRow = useCallback(",
            "+    (result: SearchResult) => <ResultRow result={result} query={query} />,",
            "+    [query]",
            "+  );",
            "+",
            "   return (",
            "     <ul className={styles.list} role=\"listbox\">",
            "-      {results.map((result) => (",
            "-        <ResultRow result={result} query={query} />",
            "-      ))}",
            "+      {results.map((result, index) => (",
            "+        <li key={index}>{renderRow(result)}</li>",
            "+      ))}",
            "     </ul>",
            "   );",
            " }",
        ]
    )

    static let idempotencyHunk = Hunk(
        file: "internal/payments/idempotency.go",
        header: "@@ -41,9 +41,16 @@ func (m *Idempotency) Wrap(next http.Handler) http.Handler {",
        newStart: 41,
        lines: [
            " \treturn http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {",
            " \t\tkey := r.Header.Get(\"Idempotency-Key\")",
            " \t\tif key == \"\" {",
            " \t\t\tnext.ServeHTTP(w, r)",
            " \t\t\treturn",
            " \t\t}",
            "-\t\tnext.ServeHTTP(w, r)",
            "+\t\tif cached, ok := m.store.Get(r.Context(), key); ok {",
            "+\t\t\tcached.WriteTo(w)",
            "+\t\t\treturn",
            "+\t\t}",
            "+",
            "+\t\trec := newRecorder(w)",
            "+\t\tnext.ServeHTTP(rec, r)",
            "+\t\tm.store.Put(r.Context(), key, rec.Result(), 24*time.Hour)",
            " \t})",
            " }",
        ]
    )

    static let ciNames = ["lint", "typecheck", "unit-tests", "build", "e2e", "preview"]

    static func ci(_ sha: String, failed: [String] = [], names: [String] = ciNames) -> CheckSummary {
        CheckSummary(
            status: failed.isEmpty ? .success : .failure, commitSHA: sha, failedChecks: failed,
            passedCount: names.count - failed.count, pendingCount: 0
        )
    }

    // MARK: Events

    enum Event: Sendable {
        case opened(RichBody)
        case comment(RichBody)
        /// `key` names the comment so scripted replies can thread under it.
        case reviewComment(key: String?, hunk: Hunk, line: Int, body: RichBody)
        case reply(toKey: String, body: RichBody)
        case review(ReviewState, RichBody)
        case checks(CheckSummary)
        case push([String])
        /// A login, or an `org/team` slug for a team.
        case reviewRequested(from: String)
        case merged
        case closed(String?)
        case reopened(String?)
    }

    struct Step: Sendable {
        let minutesAgo: Double
        let actor: String
        let event: Event
        init(_ minutesAgo: Double, _ actor: String, _ event: Event) {
            self.minutesAgo = minutesAgo
            self.actor = actor
            self.event = event
        }
    }

    enum Seen: Sendable {
        case none
        case through(Int)
        case all
    }

    struct Subject: Sendable {
        let repo: String
        let number: Int
        let kind: SubjectKind
        let title: String
        let reason: NotificationReason
        let author: String
        var key: String { "platform/\(repo)#\(number)" }
    }

    struct Thread: Sendable {
        let subject: Subject
        let steps: [Step]
        var seen: Seen = .none
        var doneMinutesAgo: Double?
    }

    static let web142 = Subject(
        repo: "web", number: 142, kind: .pullRequest, title: "Debounce search input and memoize result rows",
        reason: .author, author: "akim"
    )

    static let threads: [Thread] = [
        Thread(subject: web142, steps: [
            Step(1560, "akim", .opened("Typing in global search fires a request per keystroke and re-renders the entire result list. This debounces the input (250ms), aborts stale requests, and memoizes `ResultRow`.\n\nCloses #131.\n\n### Checklist\n\n- [x] Debounce input and abort stale requests\n- [x] Handle the `?q=` deep link\n- [ ] Memoize result rows\n  - key rows by `result.id`\n  - profile with the 2k-row fixture")),
            Step(1552, "github-actions", .checks(ci("c81d0e4"))),
            Step(1500, "leom", .comment("Nice — this cuts request volume a lot. Did you check the `?q=` deep-link flow? That path sets the value before the debounce hook mounts.")),
            Step(1440, "akim", .comment("Good catch. Added a test for the deep-link case in `SearchBox.test.tsx`.")),
            Step(300, "akim", .push(["Handle initial query from URL", "Memoize row renderer"])),
            Step(299, "akim", .reviewRequested(from: "schen")),
            Step(298.5, "akim", .reviewRequested(from: "platform/web-core")),
            Step(298, "akim", .reviewRequested(from: "platform/design-systems")),
            Step(52, "copilot-pull-request-reviewer", .review(.commented, copilotOverview)),
            Step(48, "schen", .reviewComment(key: "w142-rc1", hunk: searchHunk, line: 37, body: "This effect re-subscribes on every keystroke because `onSearch` is recreated by the parent on each render. Could we wrap it in `useCallback` upstream, or keep the latest callback in a ref here?")),
            Step(45, "schen", .reviewComment(key: "w142-rc2", hunk: resultsHunk, line: 23, body: "`key={index}` will defeat the row memoization as soon as results reorder. Can we key by `result.id`?")),
            Step(40, "github-actions", .checks(ci("7be0d44", failed: ["lint", "unit-tests"]))),
            Step(31, "leom", .reply(toKey: "w142-rc1", body: "+1 to the ref. It also avoids a stale closure in the cleanup.")),
        ], seen: .through(5)),

        Thread(subject: Subject(repo: "api", number: 87, kind: .pullRequest, title: "Add idempotency keys to payment intents", reason: .reviewRequested, author: "dpatel"), steps: [
            Step(190, "dpatel", .opened("Adds an `Idempotency-Key` header to `POST /v1/payment_intents`. Keys live in Redis for 24h alongside the serialized response, so retries from the mobile client return the original result instead of charging twice.\n\nOpen question: should reusing a key with a *different* body return 409 or 422?")),
            Step(189, "dpatel", .reviewRequested(from: viewerLogin)),
            Step(189, "dpatel", .reviewRequested(from: "platform/payments")),
            Step(176, "github-actions", .checks(ci("5e02a7b"))),
            Step(70, "mokafor", .reviewComment(key: "a87-rc1", hunk: idempotencyHunk, line: 53, body: "If two requests with the same key race, both can miss the cache and execute the handler. Should this take a `SETNX` lock before calling `next`?")),
            Step(22, "dpatel", .comment("@akim when you get a chance — you wrote the original retry middleware, so I'd love your eyes on the lock semantics.")),
        ]),

        Thread(subject: Subject(repo: "ui-kit", number: 311, kind: .issue, title: "Tooltip flickers when its trigger is inside a scroll container", reason: .mention, author: "ilaurent"), steps: [
            Step(1380, "ilaurent", .opened("Repro: put a `<Tooltip>` trigger inside an element with `overflow: auto` and scroll while hovering. The tooltip unmounts and remounts on every scroll event.\n\nSeen in Safari 18 and Chrome 129.")),
            Step(1210, "pnair", .comment("I can reproduce. `useFloating` recomputes the reference rect on scroll and `open` toggles whenever the pointer briefly leaves it.")),
            Step(14, "ilaurent", .comment("@akim you touched the hover-intent logic in #276 — is the 120ms grace period supposed to cover this? I think the scroll listener resets it.")),
        ]),

        Thread(subject: Subject(repo: "web", number: 128, kind: .issue, title: "Dark mode: chart tooltips are unreadable", reason: .comment, author: "trivera"), steps: [
            Step(4300, "trivera", .opened("Chart tooltips use `--gray-900` text on a `--gray-800` surface in dark mode. Contrast is roughly 1.4:1.")),
            Step(2900, "akim", .comment("The chart theme isn't reading semantic tokens at all. Happy to pair on it this week.")),
            Step(180, "trivera", .comment("Pushed a fix to `theme/charts.ts` that maps tooltips to `surface.raised` / `text.primary`. Could you sanity-check contrast on the analytics page?")),
        ], seen: .all),

        Thread(subject: Subject(repo: "api", number: 91, kind: .pullRequest, title: "Migrate rate limiter to a sliding window", reason: .comment, author: "jberg"), steps: [
            Step(2950, "jberg", .opened("Replaces the fixed-window counter with a sliding-window log in Redis. Bursts at window boundaries no longer double the effective limit.")),
            Step(1500, "akim", .comment("Approach LGTM. Could we keep the fixed-window limiter behind a flag for one release?")),
            Step(1200, "jberg", .comment("Done — `RATE_LIMIT_STRATEGY=fixed` restores the old behavior.")),
            Step(360, "mokafor", .review(.approved, "Load-test numbers look good. Ship it.")),
            Step(350, "github-actions", .checks(ci("91ac3f0"))),
        ], seen: .all),

        Thread(subject: Subject(repo: "ui-kit", number: 305, kind: .pullRequest, title: "Button: add loading state", reason: .author, author: "akim"), steps: [
            Step(2880, "akim", .opened("Adds `loading` to `<Button>`: keeps the width stable, swaps the label for a spinner and blocks clicks.")),
            Step(1450, "pnair", .review(.approved, "Spinner sizing matches the spec. Nit: `aria-busy` on the button would be nice, not blocking.")),
            Step(1440, "github-actions", .checks(ci("f4b8d21"))),
        ], seen: .all),

        Thread(subject: Subject(repo: "ui-kit", number: 298, kind: .pullRequest, title: "Tokens: rename spacing scale to t-shirt sizes", reason: .reviewRequested, author: "pnair"), steps: [
            Step(1420, "pnair", .opened("Renames `space-1…space-12` to `space-3xs…space-3xl`. A codemod lives in `scripts/codemods/spacing.ts`.")),
            Step(1419, "pnair", .reviewRequested(from: viewerLogin)),
            Step(1400, "github-actions", .checks(ci("0d9e6aa"))),
        ], seen: .all),

        Thread(subject: Subject(repo: "web", number: 120, kind: .pullRequest, title: "Upgrade to React 19", reason: .comment, author: "leom"), steps: [
            Step(8600, "leom", .opened("Bumps React and React DOM to 19, replaces `forwardRef` in leaf components, and removes the legacy context shim.")),
            Step(7300, "akim", .review(.approved, "Tested the editor and dashboards locally. 🚀")),
            Step(5800, "leom", .merged),
        ], doneMinutesAgo: 5700),

        Thread(subject: Subject(repo: "api", number: 80, kind: .issue, title: "Webhook retries ignore the Retry-After header", reason: .comment, author: "mokafor"), steps: [
            Step(11500, "mokafor", .opened("When partners respond with 429 + `Retry-After`, we retry on our fixed backoff schedule anyway.")),
            Step(10100, "akim", .comment("The delivery worker never reads the header. Should be a small change in `retry.go`.")),
            Step(7200, "mokafor", .closed("Fixed in #84.")),
        ], doneMinutesAgo: 7100),
    ]

    // MARK: Scripted arrivals

    struct Arrival: Sendable {
        let key: String
        /// Creates the thread (with these opening steps) when it doesn't exist yet.
        let create: Thread?
        let actor: String
        let event: Event
    }

    static let notifications: [Arrival] = [
        Arrival(
            key: "platform/web#147",
            create: Thread(subject: Subject(repo: "web", number: 147, kind: .pullRequest, title: "Prefetch dashboard routes on hover", reason: .reviewRequested, author: "trivera"), steps: [
                Step(3, "trivera", .opened("Calls `router.prefetch` on pointerenter for dashboard nav links. Adds ~6 KB to the nav chunk but drops cold route transitions from ~420ms to ~90ms.")),
            ]),
            actor: "trivera", event: .reviewRequested(from: viewerLogin)
        ),
        Arrival(key: "platform/ui-kit#311", create: nil, actor: "pnair", event: .comment("Opened #314 with a fix that keeps the grace timer alive across scroll events. @akim does that match what you intended in #276?")),
        Arrival(key: "platform/api#87", create: nil, actor: "dpatel", event: .reply(toKey: "a87-rc1", body: "Good call — switched to `SET NX PX` with the request hash as the value. Reusing a key with a different body now returns 409.")),
        Arrival(key: "platform/web#142", create: nil, actor: "leom", event: .review(.approved, "Approving once Sarah's comments are addressed. The deep-link test is a nice touch.")),
        Arrival(key: "platform/ui-kit#305", create: nil, actor: "github-actions", event: .checks(ci("2c7e9b1", failed: ["visual-regression"], names: ["lint", "unit-tests", "visual-regression", "build"]))),
        Arrival(
            key: "platform/api#95",
            create: Thread(subject: Subject(repo: "api", number: 95, kind: .issue, title: "429 responses are missing RateLimit-* headers", reason: .mention, author: "ilaurent"), steps: [
                Step(4, "ilaurent", .opened("Clients can't back off correctly: 429s from the sliding-window limiter omit `RateLimit-Remaining` and `RateLimit-Reset`.")),
            ]),
            actor: "ilaurent", event: .comment("cc @akim — this started after #91 landed. I think the headers are only set on the success path.")
        ),
        Arrival(key: "platform/web#128", create: nil, actor: "trivera", event: .comment("Contrast is 7.2:1 on both themes now. Mind giving it a final look before I close this?")),
        Arrival(key: "platform/api#91", create: nil, actor: "jberg", event: .comment("Rolling this out to 10% of traffic tomorrow morning. @akim you're on the release checklist for the limiter flag.")),
        Arrival(key: "platform/ui-kit#298", create: nil, actor: "pnair", event: .comment("Rebased on main — the codemod now also rewrites `gap-*` utilities.")),
        Arrival(key: "platform/web#142", create: nil, actor: "github-actions", event: .checks(ci("e41b7c9"))),
    ]

    /// Same-PR burst on platform/web#142, oldest first.
    static let burst: [(actor: String, event: Event)] = [
        ("leom", .comment("Pulled this locally — the 2k-row fixture scrolls at a steady 60fps now.")),
        ("schen", .reviewComment(key: nil, hunk: searchHunk, line: 45, body: "Same thing applies to this inline handler once `SearchBox` moves to a reducer. Fine as a follow-up.")),
        ("schen", .review(.changesRequested, "Requesting changes until the `onSearch` subscription is stable — the rest looks great.")),
        ("github-actions", .checks(ci("9d03f6e", failed: ["unit-tests"]))),
    ]

    static let reopenPullRequest: [Event] = [
        .comment("Seeing a regression on staging that bisects to this PR. @akim could you take a look before tomorrow's release?"),
        .comment("Follow-up: do we need to backport this to `release/2.14`? Two customers are pinned to it."),
    ]

    static let reopenIssue: [Event] = [
        .reopened("Still reproducible on v2.14.1 — reopening."),
        .comment("One more data point: this only happens when the partner sends `Retry-After` as an HTTP date. @akim does the parser handle that?"),
    ]
}
