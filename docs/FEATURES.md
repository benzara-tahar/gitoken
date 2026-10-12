# Gitoken features

The detailed reference for how Gitoken behaves. For install and setup, see the [README](../README.md).

## Notch and inbox


- The collapsed notch shows the number of unseen groups and, while activity arrives, the avatar of whoever caused it. Bursts on the same pull request merge into a single arrival.
- A status-lit rim makes the notch easier to find: blue for unseen activity, violet for quiet/snooze, amber for connection trouble, mint when caught up, and pale blue while starting. A short beam sweeps on launch, status changes and new arrivals; reduced motion keeps only the static rim.
- Setup and Settings use light/dark Gitoken wordmarks; Fluid keeps the dark variant. Empty, caught-up, search-empty, quiet, connection-error and initial-loading states have distinct illustrations. Populated or cached lists stay visible, and the collapsed notch keeps its compact glyph.
- Clicking the notch opens a compact inbox grouped by pull request or issue. Opening a group shows the conversation (timeline, review comments with their diff hunks, check status) in a narrow panel below the notch. Comment bodies render from GitHub's HTML: headings, lists and task lists, tables, highlighted code, collapsible details and images (dark variants on dark surfaces); long bodies fold behind "Show more". New activity arriving while a conversation or the inbox is open is scrolled to, or offered with a "new ↓" pill if you're reading elsewhere.
- Activity timestamps use elapsed time (`2min ago`, `3h ago`) and refresh every minute; conversation and file-preview timestamps retain the full date in their tooltip.
- Escape dismisses transient menus, search or file previews first, then returns to the previous view. Settings returns to its originating conversation or inbox; Escape in the main inbox closes the notch. Clicking outside also collapses it, and reopening restores the prior view, selection and search.
- `/` searches the inbox: words and `"phrases"` match titles, repositories, `#numbers`, previews and people; qualifiers `repo:`, `author:`, `reason:` (e.g. `reason:review`, `reason:mention`) and `is:unread` / `is:read` / `is:pr` / `is:issue` narrow it, `-` excludes. Esc clears the search, ↓ or Return jumps to the first result.
- Custom sections show saved GitHub searches above the notification inbox, including matching PRs and issues that have no notification. Sections are browse-only: no extra arrivals, sounds or global badge counts.
- Review comments open a floating file preview above the notch window: beside it when there is room, centered over its expanded content otherwise. The file's PR diff or whole file is highlighted, with every review thread inline under its line (reply, resolve, open on GitHub at that line). Outdated comments show the file at their original commit. Space toggles it from the inbox or a conversation and it follows the selection; J/K (or ↑/↓) jump between threads, D/F switch Diff/File, R replies, ⌘F finds, Esc dismisses it and restores the originating notch view. Clicking the preview does not collapse the notch. Pin keeps a copy open. File contents and diffs are fetched only from GitHub; Gitoken does not scan local clones, create worktrees, check out branches or map files into an editor. TypeScript, TSX, JavaScript, C#, JSON, YAML, Markdown, HTML, CSS and SCSS are highlighted with tree-sitter, other languages with a simpler keyword highlighter. Lockfiles, minified or generated files and files over 1 MB stay collapsed until loaded.
- Review mode: the preview lists the pull request's changed files beside the code (on by default for review requests, B toggles it, N/P move between files; the conversation's Files button opens it). Click a line number, or drag across several, to comment on that line or range: Return adds the comment to your pending review (kept on GitHub, like github.com), ⌘Return posts it on its own. Pending comments can be deleted; the Review button submits the pending review as Comment, Approve or Request changes with an optional summary, or discards it. ```` ```suggestion ```` blocks can be added to a batch and committed together as one commit on the head branch.
- Reviews by AI reviewers (Copilot, CodeRabbit, …) can be shown, collapsed to one line, or hidden. Unless "Notify for AI reviews" is on, AI-only activity never triggers an arrival or sound and doesn't change inbox previews.
- Seen is not done. Opening a group marks it seen (read on GitHub); marking it done removes it from the inbox (done on GitHub). Seen-but-not-done groups stay listed as pending. New activity on a done group brings it back.
- Quiet hours, manual quiet and snooze (per group or app-wide: 30 minutes, 1 hour, until tomorrow 09:00) suppress arrival animations while activity keeps collecting; a summary arrival appears when quiet ends.
- A subtle sound (Drop, Chime or Tap; or Off) plays once per new arrival. Bursts stay a single sound, and quiet mode, quiet hours, snooze and full-screen spaces keep it silent.
- Settings has three tabs: **General** for image-based Calm/Fluid presets, motion, display, keyboard, saved replies and launch at login; **Notifications** for notification types, sound, AI reviews, focus and mute rules; **Sections** for saved GitHub searches. The presets are the only appearance selector; motion remains independently configurable. Type switches cover review requests, mentions, team mentions, your threads, comments, assignments, state changes, following and CI activity. Disabled types disappear immediately from the inbox, badge, arrivals, sounds and summaries but remain tracked locally; GitHub read/done state is unchanged. Re-enabling a type restores tracked groups without replaying old arrivals.
- Monitor a pull request from its conversation to be told when it's ready to merge: once checks pass, required approvals are in and GitHub reports a clean merge state, a distinct sound and green notch glow announce it. Alerts respect quiet mode and full-screen apps. Manage monitored PRs in Settings › Notifications.
- Pushed commits and force pushes are hidden from conversations by default; turn on **Show commit notifications** in Settings › Notifications to include them.

On Macs without a notch, Gitoken shows a pill at the top of the main screen. It hides while a full-screen space is active.

## Custom sections

Open **Settings → Sections**, or the stacked-plus button in the inbox. Give a section a name and GitHub search query, preview the results, then save. Edit or delete sections in Settings, use the up/down buttons to reorder them, and click a section header to collapse it. Names, queries, order and collapse state persist.

Queries use GitHub search syntax, including qualifiers, quoted text, grouped `AND`/`OR` clauses and `sort:`. For example:

```text
repo:cli/cli is:pr archived:false sort:updated-desc (author:mislav OR author:vilmibm)
```

- A PR or issue appears in every matching section. Seen, dismissal and last-visit state are shared across those sections, separately for each GitHub account. Section definitions are global; cached results and subject state are account-scoped.
- Newly encountered subjects in a section's initial baseline start seen; adding or editing a section preserves existing local unseen state. Later new or updated subjects get a local unseen indicator, not a notch badge or arrival. Opening a result marks it seen locally. `D`/`E` dismiss it from all matching sections; `U` undoes the dismissal. New activity brings it back, and each section offers **Restore dismissed**.
- Results open a read-only native conversation with the recent timeline, review comments and checks. Use **Open on GitHub** for replies, reviews and the complete history. Search subjects have no notification-thread identity: browsing or dismissing them never marks a GitHub notification read or done.
- Sections refresh when the inbox is visible, at most once every five minutes automatically; each has a manual refresh button. Cached rows stay visible after a failed refresh. Load more fetches 100 results at a time, up to GitHub's 1,000-result search limit. Incomplete results and capped totals are shown explicitly; narrow the query to retrieve matches beyond that limit.
- The inbox's `/` search also filters loaded section rows. Search subjects have no notification `reason:`, so a positive reason filter excludes them.
