import Foundation
import Testing
@testable import GitokenCore

@Suite struct RichRenderingTests {
    private func blocks(html: String) -> [RichBlock] { RichBody(markdown: "", html: html).document.blocks }
    private func blocks(markdown: String) -> [RichBlock] { RichBody(markdown: markdown).document.blocks }

    private static let badgeBase = "https://github.githubassets.com/static/images/icons/copilot-code-review"

    @Test func copilotOverviewParsesIntoHeadingsAndInlineBadges() throws {
        let document = FixtureSeed.copilotOverview.document
        let blocks = document.blocks

        guard blocks.count >= 3, case .heading(2, let title) = blocks[0], case .heading(3, let verdict) = blocks[1] else {
            Issue.record("expected h2 + h3 first, got \(blocks.prefix(3))")
            return
        }
        #expect(title == [.text("Copilot review overview", [])], "permalink anchors and their SVGs are dropped")
        #expect(verdict == [.emoji("🟡"), .text(" Changes recommended", [])])

        guard case .paragraph(let findings) = blocks[2] else {
            Issue.record("expected the findings paragraph, got \(blocks[2])")
            return
        }
        #expect(findings.count == 7)
        #expect(findings.first == .text("Findings:", .bold))
        let separators = findings.compactMap { inline -> String? in
            if case .text(let text, []) = inline { return text }
            return nil
        }
        #expect(separators == [" 1 ", " · 2 ", " · 1 "], "counts and separators stay on the same line as the badges")
        let badges = findings.compactMap { inline -> RichImage? in
            if case .image(let image) = inline { return image }
            return nil
        }
        #expect(badges.map(\.alt) == ["High severity", "Medium severity", "Low severity"])
        let high = try #require(badges.first)
        #expect(high.url.absoluteString == "\(Self.badgeBase)/high-v2-light.png")
        #expect(high.darkURL?.absoluteString == "\(Self.badgeBase)/high-v2-dark.svg")
        #expect(high.lightURL?.absoluteString == "\(Self.badgeBase)/high-v2-light.svg")
        #expect(high.width == 62 && high.height == 18)
        #expect(high.candidates(dark: true).map(\.lastPathComponent) == ["high-v2-dark.svg", "high-v2-light.png"])

        let plain = FixtureSeed.copilotOverview.plainText
        #expect(!plain.contains("ccr-overview"), "the HTML comment marker never reaches text")
        #expect(!plain.contains("<"))
        #expect(plain.hasPrefix("Copilot review overview\n🟡 Changes recommended\nFindings: 1 High severity · 2"))

        #expect(blocks.contains { if case .table = $0 { true } else { false } }, "custom table wrappers keep their table")
        #expect(blocks.contains { if case .details(let d) = $0 { !d.isOpen } else { false } })
        #expect(blocks.contains { if case .code(let c) = $0 { c.language == "tsx" && c.isHighlighted } else { false } })
    }

    @Test func markdownBodiesFlowThroughTheSameParser() {
        let body = """
            Typing fires a request per keystroke.

            - [x] Debounce input
            - [ ] Memoize rows
              - key by `result.id`
              - profile it
            1. first
            """
        let blocks = blocks(markdown: body)
        guard blocks.count == 3, case .list(let tasks) = blocks[1], case .list(let ordered) = blocks[2] else {
            Issue.record("expected paragraph + task list + ordered list, got \(blocks)")
            return
        }
        #expect(!tasks.ordered)
        #expect(tasks.items.map(\.checked) == [true, false])
        #expect(tasks.items[0].blocks == [.paragraph([.text("Debounce input", [])])])
        guard tasks.items[1].blocks.count == 2, case .list(let nested) = tasks.items[1].blocks[1] else {
            Issue.record("expected a nested list under the second item, got \(tasks.items[1].blocks)")
            return
        }
        #expect(nested.items.map(\.checked) == [nil, nil])
        #expect(nested.items[0].blocks == [.paragraph([.text("key by ", []), .text("result.id", .code)])])
        #expect(ordered.ordered && ordered.items.count == 1)
    }

    @Test func githubTaskListHTMLKeepsCheckboxState() {
        let blocks = blocks(html: """
            <ul class="contains-task-list">
            <li class="task-list-item"><input type="checkbox" id="" disabled="" class="task-list-item-checkbox" checked=""> Ship it</li>
            <li class="task-list-item"><input type="checkbox" id="" disabled="" class="task-list-item-checkbox"> Tell <a class="user-mention notranslate" data-hovercard-type="user" href="https://github.com/schen">@schen</a></li>
            </ul>
            """)
        guard case .list(let list) = blocks.first else {
            Issue.record("expected a list, got \(blocks)")
            return
        }
        #expect(list.items.map(\.checked) == [true, false])
        #expect(list.items[1].blocks == [.paragraph([
            .text("Tell ", []), .mention(login: "schen", url: URL(string: "https://github.com/schen")),
        ])])
    }

    @Test func detailsCarrySummaryBlocksAndOpenFlag() {
        let blocks = blocks(html: """
            <details open><summary>Logs <code>v2</code></summary><p>Line one</p><pre>trace</pre></details>
            <details><p>No summary</p></details>
            """)
        #expect(blocks == [
            .details(RichDetails(
                summary: [.text("Logs ", []), .text("v2", .code)],
                blocks: [.paragraph([.text("Line one", [])]), .code(RichCode(language: nil, lines: [RichCodeLine(tokens: [RichCodeToken("trace")])]))],
                isOpen: true)),
            .details(RichDetails(summary: [.text("Details", [])], blocks: [.paragraph([.text("No summary", [])])], isOpen: false)),
        ])
    }

    @Test func tablesKeepHeaderRowsAndColumnAlignment() {
        let markdown = blocks(markdown: "| File | Lines |\n| :--- | ---: |\n| a.ts | 12 |\n| b.ts |")
        #expect(markdown == [.table(RichTable(
            alignments: [.leading, .trailing],
            header: [[.text("File", [])], [.text("Lines", [])]],
            rows: [[[.text("a.ts", [])], [.text("12", [])]], [[.text("b.ts", [])], []]]))])

        let html = blocks(html: "<table><tr><td align=\"center\">x</td><td>y</td></tr></table>")
        #expect(html == [.table(RichTable(alignments: [.center, .leading], header: [], rows: [[[.text("x", [])], [.text("y", [])]]]))])
    }

    @Test func highlightedCodeMapsGitHubClassesToTokenKinds() throws {
        let blocks = blocks(html: """
            <div class="highlight highlight-source-swift notranslate"><pre><span class="pl-k">let</span> <span class="pl-s1">x</span> <span class="pl-c1">=</span> <span class="pl-s"><span class="pl-pds">"</span>hi<span class="pl-pds">"</span></span>
            <span class="pl-c">// done</span>
            </pre><div class="zeroclipboard-container"><clipboard-copy value="let x"></clipboard-copy></div></div>
            """)
        guard blocks.count == 1, case .code(let code) = blocks[0] else {
            Issue.record("expected exactly one code block (clipboard UI dropped), got \(blocks)")
            return
        }
        #expect(code.language == "swift")
        #expect(code.lines.count == 2, "the newline before </pre> is not an extra line")
        #expect(code.lines[0].tokens == [
            RichCodeToken("let", .keyword), RichCodeToken(" x "), RichCodeToken("=", .constant), RichCodeToken(" "),
            RichCodeToken("\"hi\"", .string),
        ])
        #expect(code.lines[1].tokens == [RichCodeToken("// done", .comment)])
    }

    @Test func suggestionsBecomeDiffLines() {
        let rendered = blocks(html: """
            <div class="js-suggested-changes-blob"><table><tbody>
            <tr><td class="blob-num"></td><td class="blob-code-inner blob-code-deletion">key={index}</td></tr>
            <tr><td class="blob-num"></td><td class="blob-code-inner blob-code-addition">key={result.id}</td></tr>
            </tbody></table></div>
            """)
        #expect(rendered == [.code(RichCode(language: nil, isSuggestion: true, lines: [
            RichCodeLine(change: .removed, tokens: [RichCodeToken("key={index}")]),
            RichCodeLine(change: .added, tokens: [RichCodeToken("key={result.id}")]),
        ]))])

        let fenced = blocks(markdown: "```suggestion\nkey={result.id}\n```")
        #expect(fenced == [.code(RichCode(language: nil, isSuggestion: true, lines: [
            RichCodeLine(change: .added, tokens: [RichCodeToken("key={result.id}")]),
        ]))])
    }

    @Test func relativeURLsResolveAgainstGitHubAndUnsafeLinksDrop() {
        let blocks = blocks(html: """
            <p><a href="/platform/web/pull/131" class="issue-link js-issue-link" data-hovercard-type="pull_request">#131</a> \
            <a href="docs/setup.md">setup</a> <a href="javascript:alert(1)">bad</a> <a href="#notes">notes</a> \
            <img src="/user-attachments/assets/shot.png" alt="shot"> text</p>
            """)
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("expected a paragraph, got \(blocks)")
            return
        }
        #expect(inlines.contains(.reference("#131", url: URL(string: "https://github.com/platform/web/pull/131"))))
        #expect(inlines.contains(.link("setup", url: URL(string: "https://github.com/docs/setup.md")!, [])))
        #expect(!inlines.contains { if case .link(_, let url, _) = $0 { url.scheme == "javascript" } else { false } })
        #expect(inlines.contains(.image(RichImage(url: URL(string: "https://github.com/user-attachments/assets/shot.png")!, alt: "shot"))))
    }

    @Test func standaloneImageParagraphBecomesBlockImage() {
        let blocks = blocks(html: """
            <p><a target="_blank" href="https://github.com/user-attachments/assets/a1"><img src="https://github.com/user-attachments/assets/a1" alt="Screenshot" width="480"></a></p>
            """)
        let url = URL(string: "https://github.com/user-attachments/assets/a1")!
        #expect(blocks == [.image(RichImage(url: url, alt: "Screenshot", width: 480, link: url))])
    }

    @Test func snippetsAreTextWithoutMarkupOrComments() throws {
        let body = RichBody(markdown: "<!-- template: describe your change -->\n**Fixes** the `<Tooltip>` flicker.\n\n<details><summary>Repro</summary>\n\nScroll.\n</details>")
        let snippet = try #require(ActivityAnalysis.snippet(body.plainText))
        #expect(snippet == "Fixes the <Tooltip> flicker. Repro Scroll.")
        #expect(!snippet.contains("<!--") && !snippet.contains("**") && !snippet.contains("<details"))

        let rendered = RichBody(markdown: "ignored", html: "<p>Hi <strong>there</strong></p>", plain: "Hi there")
        #expect(rendered.plainText == "Hi there", "GitHub's bodyText wins when present")
    }

    @Test func consecutiveReviewRequestsCollapseIntoOneEntry() {
        func request(_ id: String, by actor: Actor, at date: Date, _ reviewer: String) -> TimelineItem {
            TimelineItem(id: id, actor: actor, createdAt: date, payload: .event(.reviewRequested, detail: reviewer), url: nil)
        }
        let items = [
            request("r1", by: sarah, at: t0, "platform/web"),
            request("r2", by: sarah, at: t0 + 30, "platform/design"),
            request("r3", by: sarah, at: t0 + 60, "akim"),
            request("r4", by: omar, at: t0 + 70, "platform/web"),
            request("r5", by: omar, at: t0 + 700, "lea"),
            comment("c1", by: sarah, at: t0 + 800),
            request("r6", by: sarah, at: t0 + 810, "lea"),
        ]
        let entries = TimelineEntry.entries(for: items)
        #expect(entries.map(\.id) == ["r1", "r4", "r5", "c1", "r6"])
        guard case .reviewRequests(let group) = entries[0] else {
            Issue.record("expected a collapsed group, got \(entries[0])")
            return
        }
        #expect(group.reviewers == ["platform/web", "platform/design", "akim"])
        #expect(group.includes("AKIM"))
        #expect(group.createdAt == t0 + 60)
        #expect(entries[1] == .item(items[3]), "another actor starts a new run; a run of one stays a plain item")
        #expect(entries[2] == .item(items[4]), "requests minutes apart are not merged")
    }

    @Test func aiReviewsCollapseOnlyWhenAsked() {
        let copilot = Actor(login: "copilot-pull-request-reviewer", name: "Copilot", isBot: true)
        let items = [
            review("ai", by: copilot, at: t0, .commented),
            review("human", by: sarah, at: t0 + 10, .approved),
            TimelineItem(id: "ci", actor: copilot, createdAt: t0 + 20, payload: .event(.closed, detail: nil), url: nil),
        ]
        #expect(TimelineEntry.entries(for: items).map(\.id) == ["ai", "human", "ci"])
        let collapsed = TimelineEntry.entries(for: items, collapseAI: true)
        #expect(collapsed == [.aiReview(items[0]), .item(items[1]), .item(items[2])])
    }
}
