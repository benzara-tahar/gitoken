import Foundation
import Testing
@testable import GitokenCore

private let cli = RepoRef(owner: "tools", name: "cli")

private func group(
    _ id: String, title: String = "Fix login redirect", repo r: RepoRef = repo, kind: SubjectKind = .pullRequest,
    reason: NotificationReason = .reviewRequested, unseen: Bool = true, actors: [Actor] = [sarah],
    preview: ActivityPreview? = ActivityPreview(actor: sarah, verb: .commented, snippet: "Can we cache this?", at: t0)
) -> InboxGroup {
    let thread = NotificationThread(
        id: ThreadID(id), repo: r, kind: kind, number: Int(id), title: title, reason: reason, unread: unseen,
        updatedAt: t0, lastReadAt: nil, subjectAPIURL: nil, latestCommentAPIURL: nil, repoOwnerAvatarURL: nil)
    return InboxGroup(
        thread: thread, state: .open, preview: preview, actors: actors, isUnseen: unseen, unseenCount: 0,
        lastVisitAt: nil, doneAt: nil, snoozedUntil: nil, resurfaced: nil)
}

private func detail(_ id: String, author: Actor?) -> ThreadDetail {
    ThreadDetail(
        threadID: ThreadID(id), title: "", state: .open, author: author, htmlURL: URL(string: "https://github.com")!,
        items: [], checks: nil, fetchedAt: t0)
}

private func matches(_ query: String, _ g: InboxGroup, detail d: ThreadDetail? = nil) -> Bool {
    InboxQuery(query).matches(g, detail: d)
}

@Suite struct InboxQueryTests {
    @Test func emptyQueryMatchesEverything() {
        for text in ["", "   ", "repo:", "-is:", "\"\"", "author:@", "-author:@"] {
            #expect(InboxQuery(text).isEmpty, "\(text)")
            #expect(matches(text, group("1")))
        }
        #expect(!InboxQuery("-").isEmpty, "a lone dash is text")
    }

    @Test func freeWordsAllMatchCaseInsensitivelyAcrossFields() {
        let g = group("142", actors: [Actor(login: "omar", name: "Omar Haddad")])
        #expect(matches("LOGIN", g), "title")
        #expect(matches("acme/web", g), "repo full name")
        #expect(matches("#142", g), "number")
        #expect(matches("cache", g), "preview snippet")
        #expect(matches("haddad", g), "actor name")
        #expect(matches("sarah", g), "preview actor login")
        #expect(matches("login cache", g))
        #expect(!matches("login deploy", g), "every word must match")
        #expect(!matches("#7", g))
    }

    @Test func quotedPhraseMatchesAsOneTerm() {
        let g = group("1")
        #expect(matches("\"login redirect\"", g))
        #expect(!matches("\"redirect login\"", g))
        #expect(matches("redirect login", g), "unquoted words match in any order")
        #expect(matches("\"fix login", g), "an unclosed quote runs to the end")
        #expect(!matches("\"repo:acme\"", g), "a quoted qualifier is plain text")
    }

    @Test func repoQualifierMatchesSubstringOfFullName() {
        let web = group("1")
        let tools = group("2", repo: cli)
        #expect(matches("repo:acme/web", web))
        #expect(matches("repo:web", web))
        #expect(matches("Repo:ACME", web), "keys and values are case-insensitive")
        #expect(!matches("repo:cli", web))
        #expect(matches("repo:cli", tools))
    }

    @Test func authorPrefersSubjectAuthorFromDetail() {
        let g = group("1", actors: [omar], preview: ActivityPreview(actor: lea, verb: .commented, snippet: nil, at: t0))
        #expect(matches("author:nina", g, detail: detail("1", author: nina)))
        #expect(!matches("author:omar", g, detail: detail("1", author: nina)), "detail author wins over actors")
        #expect(matches("author:@nina", g, detail: detail("1", author: nina)))
    }

    @Test func authorFallsBackToActorsWithoutDetail() {
        let g = group("1", actors: [omar], preview: ActivityPreview(actor: lea, verb: .commented, snippet: nil, at: t0))
        #expect(matches("author:omar", g))
        #expect(matches("author:lea", g), "preview actor")
        #expect(!matches("author:nina", g))
        #expect(matches("author:omar", g, detail: detail("1", author: nil)), "detail without an author")
        #expect(InboxQuery("author:omar").needsDetail)
        #expect(!InboxQuery("repo:web omar").needsDetail)
    }

    @Test func reasonMatchesRawValuesAndShortLabelWords() {
        let review = group("1", reason: .reviewRequested)
        let team = group("2", reason: .teamMention)
        let mine = group("3", reason: .author)
        let ci = group("4", reason: .ciActivity)
        #expect(matches("reason:review_requested", review))
        #expect(matches("reason:review", review))
        #expect(matches("reason:review-requested", review))
        #expect(!matches("reason:review", mine))
        #expect(matches("reason:team_mention", team))
        #expect(matches("reason:mention", team))
        #expect(matches("reason:mentioned", team))
        #expect(matches("reason:author", mine))
        #expect(matches("reason:yours", mine))
        #expect(matches("reason:ci", ci))
        #expect(matches("reason:ci_activity", ci))
        #expect(!matches("reason:assign", ci))
    }

    @Test func isQualifiers() {
        let unreadPR = group("1", kind: .pullRequest, unseen: true)
        let readIssue = group("2", kind: .issue, unseen: false)
        #expect(matches("is:unread", unreadPR))
        #expect(!matches("is:unread", readIssue))
        #expect(matches("is:read", readIssue))
        #expect(matches("is:pr", unreadPR))
        #expect(!matches("is:pr", readIssue))
        #expect(matches("is:issue", readIssue))
        #expect(matches("IS:Unread is:pr", unreadPR))
    }

    @Test func dashNegatesQualifiersWordsAndPhrases() {
        let web = group("1")
        let tools = group("2", repo: cli, unseen: false)
        #expect(!matches("-repo:web", web))
        #expect(matches("-repo:web", tools))
        #expect(!matches("-is:unread", web))
        #expect(matches("-is:unread", tools))
        #expect(!matches("-login", web))
        #expect(!matches("-\"login redirect\"", web))
        #expect(matches("-\"redirect login\"", web))
        #expect(matches("\"-login\"", group("3", title: "Handle -login flag")), "a dash inside quotes is literal")
        #expect(matches("-author:omar", web))
    }

    @Test func unknownQualifiersAreText() {
        let g = group("1", title: "Support label:bug in filters")
        #expect(matches("label:bug", g))
        #expect(!matches("label:bug", group("2")))
        #expect(matches("is:open", group("3", title: "Ship when is:open works")), "unknown is: value")
        #expect(!matches("is:open", group("4")))
        #expect(matches("repo:\"acme/web\"", group("5")), "quoted qualifier value")
    }

    @Test func searchSubjectsUseLocalSeenStateAndHaveNoNotificationReason() {
        let item = SearchItem(id: .init("PR_node"), repo: cli, number: 42, kind: .pullRequest,
                              title: "Fix quoted sort:updated-desc parsing", state: .open, author: sarah,
                              updatedAt: t0, htmlURL: URL(string: "https://github.com/tools/cli/pull/42")!)
        #expect(InboxQuery("repo:tools author:\(sarah.login) is:pr #42 \"quoted sort:updated-desc\"")
            .matches(item, isUnseen: true))
        #expect(InboxQuery("is:unread").matches(item, isUnseen: true))
        #expect(!InboxQuery("is:unread").matches(item, isUnseen: false))
        #expect(InboxQuery("is:read").matches(item, isUnseen: false))
        #expect(!InboxQuery("reason:review").matches(item, isUnseen: true))
        #expect(InboxQuery("-reason:review -is:issue").matches(item, isUnseen: true))
        #expect(!InboxQuery("author:not-the-author").matches(item, isUnseen: true))
    }
}
