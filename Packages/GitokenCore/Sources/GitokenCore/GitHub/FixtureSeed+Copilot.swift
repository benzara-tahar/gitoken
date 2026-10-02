import Foundation

extension FixtureSeed {
    private static let badgeBase = "https://github.githubassets.com/static/images/icons/copilot-code-review"

    private static func badgeMarkup(_ severity: String, _ label: String) -> String {
        """
        <picture><source media="(prefers-color-scheme: dark)" srcset="\(badgeBase)/\(severity)-v2-dark.svg">\
        <source media="(prefers-color-scheme: light)" srcset="\(badgeBase)/\(severity)-v2-light.svg">\
        <img src="\(badgeBase)/\(severity)-v2-light.png" alt="\(label)" width="62" height="18" align="texttop"></picture>
        """
    }

    private static let copilotMarkdown = """
        <!-- ccr-overview-v2 -->
        ## Copilot review overview

        ### 🟡 Changes recommended

        **Findings:** 1 \(badgeMarkup("high", "High severity")) · 2 \(badgeMarkup("medium", "Medium severity")) · 1 \(badgeMarkup("low", "Low severity"))

        This PR debounces global search input, aborts stale requests, and memoizes result rows. The approach is sound; the main risk is the effect's dependency on `onSearch`, which re-subscribes whenever the parent re-renders.

        ### Reviewed changes

        Copilot reviewed 3 out of 3 changed files in this pull request and generated 4 comments.

        | File | Description |
        | ---- | ----------- |
        | src/components/SearchBox.tsx | Debounces input with `useDebouncedValue` and aborts in-flight requests |
        | src/components/ResultList.tsx | Memoizes row rendering with `useCallback` |
        | src/hooks/useDebouncedValue.ts | New hook wrapping `setTimeout` with cleanup |

        #### Suggested fix

        ```tsx
        const onSearchRef = useRef(onSearch);
        useEffect(() => {
          onSearchRef.current = onSearch;
        }, [onSearch]);
        // The debounced effect reads the ref, so it no longer depends on onSearch
        ```

        <details>
        <summary>Comments suppressed due to low confidence (1)</summary>

        **src/components/ResultList.tsx:23**
        - Using the array index as `key` defeats memoization once results reorder; prefer `result.id`.

        </details>

        ---
        <sub>Tip: reply with `@copilot` to ask follow-up questions about this review.</sub>
        """

    private static let copilotHTML = """
        <div class="markdown-heading" dir="auto"><h2 tabindex="-1" class="heading-element" dir="auto">Copilot review overview</h2><a id="user-content-copilot-review-overview" class="anchor" aria-label="Permalink: Copilot review overview" href="#copilot-review-overview"><svg class="octicon octicon-link" viewBox="0 0 16 16" version="1.1" width="16" height="16" aria-hidden="true"><path d="m7.775 3.275 1.25-1.25a3.5 3.5 0 1 1 4.95 4.95l-2.5 2.5a3.5 3.5 0 0 1-4.95 0"></path></svg></a></div>
        <div class="markdown-heading" dir="auto"><h3 tabindex="-1" class="heading-element" dir="auto"><g-emoji class="g-emoji" alias="yellow_circle">🟡</g-emoji> Changes recommended</h3><a id="user-content--changes-recommended" class="anchor" aria-label="Permalink: 🟡 Changes recommended" href="#-changes-recommended"><svg class="octicon octicon-link" viewBox="0 0 16 16" version="1.1" width="16" height="16" aria-hidden="true"><path d="m7.775 3.275 1.25-1.25"></path></svg></a></div>
        <p dir="auto"><strong>Findings:</strong> 1 \(badgeMarkup("high", "High severity")) · 2 \(badgeMarkup("medium", "Medium severity")) · 1 \(badgeMarkup("low", "Low severity"))</p>
        <p dir="auto">This PR debounces global search input, aborts stale requests, and memoizes result rows. The approach is sound; the main risk is the effect's dependency on <code class="notranslate">onSearch</code>, which re-subscribes whenever the parent re-renders.</p>
        <div class="markdown-heading" dir="auto"><h3 tabindex="-1" class="heading-element" dir="auto">Reviewed changes</h3><a id="user-content-reviewed-changes" class="anchor" aria-label="Permalink: Reviewed changes" href="#reviewed-changes"><svg class="octicon octicon-link" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"></svg></a></div>
        <p dir="auto">Copilot reviewed 3 out of 3 changed files in this pull request and generated 4 comments.</p>
        <markdown-accessiblity-table><table>
        <thead>
        <tr>
        <th>File</th>
        <th>Description</th>
        </tr>
        </thead>
        <tbody>
        <tr>
        <td>src/components/SearchBox.tsx</td>
        <td>Debounces input with <code class="notranslate">useDebouncedValue</code> and aborts in-flight requests</td>
        </tr>
        <tr>
        <td>src/components/ResultList.tsx</td>
        <td>Memoizes row rendering with <code class="notranslate">useCallback</code></td>
        </tr>
        <tr>
        <td>src/hooks/useDebouncedValue.ts</td>
        <td>New hook wrapping <code class="notranslate">setTimeout</code> with cleanup</td>
        </tr>
        </tbody>
        </table></markdown-accessiblity-table>
        <div class="markdown-heading" dir="auto"><h4 tabindex="-1" class="heading-element" dir="auto">Suggested fix</h4><a id="user-content-suggested-fix" class="anchor" aria-label="Permalink: Suggested fix" href="#suggested-fix"><svg class="octicon octicon-link" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"></svg></a></div>
        <div class="highlight highlight-source-tsx notranslate position-relative overflow-auto" dir="auto"><pre><span class="pl-k">const</span> <span class="pl-s1">onSearchRef</span> <span class="pl-c1">=</span> <span class="pl-en">useRef</span><span class="pl-kos">(</span><span class="pl-s1">onSearch</span><span class="pl-kos">)</span><span class="pl-kos">;</span>
        <span class="pl-en">useEffect</span><span class="pl-kos">(</span><span class="pl-kos">(</span><span class="pl-kos">)</span> <span class="pl-c1">=&gt;</span> <span class="pl-kos">{</span>
          <span class="pl-s1">onSearchRef</span><span class="pl-kos">.</span><span class="pl-c1">current</span> <span class="pl-c1">=</span> <span class="pl-s1">onSearch</span><span class="pl-kos">;</span>
        <span class="pl-kos">}</span><span class="pl-kos">,</span> <span class="pl-kos">[</span><span class="pl-s1">onSearch</span><span class="pl-kos">]</span><span class="pl-kos">)</span><span class="pl-kos">;</span>
        <span class="pl-c">// The debounced effect reads the ref, so it no longer depends on onSearch</span></pre><div class="zeroclipboard-container"><clipboard-copy aria-label="Copy" class="ClipboardButton btn btn-invisible js-clipboard-copy m-2 p-0 d-flex flex-justify-center flex-items-center" data-copy-feedback="Copied!" data-tooltip-direction="w" value="const onSearchRef = useRef(onSearch);" tabindex="0" role="button"><svg aria-hidden="true" height="16" viewBox="0 0 16 16" version="1.1" width="16" class="octicon octicon-copy js-clipboard-copy-icon"><path d="M0 6.75C0 5.784.784 5 1.75 5h1.5"></path></svg></clipboard-copy></div></div>
        <details>
        <summary>Comments suppressed due to low confidence (1)</summary>
        <p dir="auto"><strong>src/components/ResultList.tsx:23</strong></p>
        <ul dir="auto">
        <li>Using the array index as <code class="notranslate">key</code> defeats memoization once results reorder; prefer <code class="notranslate">result.id</code>.</li>
        </ul>
        </details>
        <hr>
        <p dir="auto"><sub>Tip: reply with <code class="notranslate">@copilot</code> to ask follow-up questions about this review.</sub></p>
        """

    /// A Copilot-style review overview shaped like GitHub's real one: HTML comment marker, headings, emoji,
    /// inline severity badges (`<picture>` with light/dark sources), a table, highlighted code and `<details>`.
    static let copilotOverview = RichBody(markdown: copilotMarkdown, html: copilotHTML)
}
