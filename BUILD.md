# Building Gitoken

Everything needed to build, test, package and release Gitoken from source. Run commands from the repository root.

## Build and test

Requires Xcode 26. Commands below use `DEVELOPER_DIR` to pick Xcode without changing the global `xcode-select` setting:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Core logic tests (Swift Testing)
(cd Packages/GitokenCore && swift test)

# App
xcodebuild -project Gitoken.xcodeproj -scheme Gitoken -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Gitoken.app
```

`scripts/select-xcode.sh` prints the `export DEVELOPER_DIR=…` line for the newest Xcode 26 in `/Applications`.


## Package a release zip

`scripts/package.sh` builds a universal Release app, ad-hoc signs it, verifies the signature and zips it with `ditto`. It packages the current working tree, including uncommitted changes.

```sh
scripts/package.sh 1.2.3   # -> dist/Gitoken-1.2.3.zip and its sha256
```

Versions use the form `1.2.3`, optionally with a suffix such as `-dev.1` or `-beta.1`. The zip contains no GitHub token, settings or inbox database; each user signs in with their own GitHub CLI.

Distribution without the Gatekeeper workaround described in the README needs Developer ID signing and notarization, which the script does not do.

## Artwork

The nine original PNGs remain in `assets/`. Native resources are in `App/Resources/Assets.xcassets`: `GitokenLogo` selects its light/dark wordmark by luminosity appearance, and the six `Inbox…` imagesets supply decorative state artwork. Wordmarks have 160/320-pixel widths; illustrations have 96/192-pixel canvases for 1×/2× rendering, preserving original colors, transparency and shadows.

`AppIcon` supplies all ten macOS icon slots, from 16 points at 1× through 512 points at 2×. Xcode builds the application icon from the catalog in Debug and Release; the app remains a menu-bar agent rather than adding a Dock presence.

## Sounds

The arrival sounds in `App/Resources/Sounds/` are synthesized by `scripts/generate-sounds.swift` (no third-party audio). The script is deterministic, so rerunning it reproduces the committed files byte for byte; it prints each file's duration, peak and RMS level:

```sh
swift scripts/generate-sounds.swift
afinfo App/Resources/Sounds/Drop.caf
```

## Debug builds

- `--fixtures` launch argument: runs against built-in fictional notifications and an in-memory database instead of GitHub. No gh login needed.

  ```sh
  open build/DerivedData/Build/Products/Debug/Gitoken.app --args --fixtures
  ```

  Fixture search includes notification subjects and a permanently search-only draft, `platform/web#151`. It supports text, grouped Boolean clauses and `repo:`, `org:`, `user:`, `author:`, `is:`, `state:`, `draft:` and `archived:` predicates, with created/updated/comments sorting. Unsupported fixture predicates or sorts return an explicit error; live searches are evaluated by GitHub.

- Hidden debug controls: open the notch, then Settings › General. A Debug section at the bottom advances the app clock by 30 minutes, 1 hour or 1 day (to check snooze expiry and quiet hours) and, with `--fixtures`, simulates a new notification, a burst on one pull request, or activity on a done group.
- The same actions are on a right-click menu on the collapsed notch, so you can fire a burst while an arrival banner is still showing and watch it merge.
- `--scene <inbox|conversation|preview|review|settings> [owner/repo#number]`, together with `--fixtures`, opens that view on launch, over a full-screen gradient backdrop so the panels' glass can't pick up other apps. `scripts/screenshots.sh` uses it to regenerate `docs/assets/screenshots/`: it quits any running Gitoken, captures only Gitoken's own windows and composites them onto the same gradient. The terminal needs Screen Recording permission.

None of these exist in Release builds.

## Architecture

```
App/                      SwiftUI views hosted in AppKit NSPanels (main-actor UI only)
  Preview/                File preview window: TextKit 2 code view, inline thread cards, file list, review tools
Packages/GitokenCore/     All non-UI logic, tested with `swift test`
  GitHub/                 gh token lookup, REST + GraphQL client (URLSession + Codable)
  Inbox/                  @Observable InboxStore + CustomSectionStore, grouping, local subject state, settings
  Model/                  Domain types
  Preview/                Review threads, GitHub file/diff loading, diff parsing, tree-sitter highlighting
  Time/                   Injectable clock (NowProvider)
```

Data flow:

1. Token: `gh auth token`, run from the usual gh install locations because GUI apps do not inherit the shell `PATH`.
2. Poll: a single task polls `GET /notifications?all=true` with `If-Modified-Since`, honouring `X-Poll-Interval` (never faster than 60 s). Polling pauses on sleep and screen lock and runs immediately on wake.
3. Hydrate: only threads that changed, or that the user opens, are fetched through GraphQL (timeline, review comments, check rollup).
4. Persist: notification/search state and caches are stored in SQLite through GRDB with explicit migrations, keyed by account (host, login). Settings, including saved section definitions, are global.
5. Present: the `@MainActor @Observable` `InboxStore` derives groups, unseen and pending counts and arrivals; the SwiftUI views in the notch panel observe it.
6. Search: visible-inbox refreshes query `GET /search/issues` sequentially; opening a search subject hydrates GraphQL by repository and subject number without a notification thread ID.

Notification sync is two-way: seen maps to GitHub "read" (`PATCH /notifications/threads/{id}`), done maps to GitHub "done" (`DELETE /notifications/threads/{id}`). Threads missing from a full listing were marked done elsewhere and become done locally. Snooze and custom-section seen/dismissed state are local only.

The notch UI is a borderless, non-activating panel above the menu bar, resized to its content. It takes keyboard focus while open, unless a file-preview panel is key. Preview panels sit one window level above it and return focus and navigation to the originating notch view when dismissed.

The inbox renders notification and custom-section rows through the outer `LazyVStack`; custom sections use `Section`, not an eager stack around all their rows. `Buckets` is an immutable reference snapshot so SwiftUI does not recursively compare full group payloads captured by view closures. Content-height tracking is capped at the available viewport height, avoiding whole-list updates when lazy off-screen height estimates change.

## Releasing

Push a tag `v<version>`:

```sh
git tag v1.2.3
git push origin v1.2.3
```

`.github/workflows/release.yml` then runs the tests, builds and signs `Gitoken-1.2.3.zip` with `scripts/package.sh`, creates the GitHub Release with the zip attached, and updates `Casks/gitoken.rb` in `benzara-tahar/homebrew-tap` from `packaging/homebrew/gitoken.rb.template`. The tap update needs a `TAP_GITHUB_TOKEN` repository secret with write access to the tap; without it the step is skipped with a notice. Tags with a prerelease suffix (`v1.2.3-beta.1`) create a GitHub prerelease and leave the tap alone.

CI (`.github/workflows/ci.yml`) runs the core tests and a Release build of the app on every push and pull request to `main`.

## Prototypes

`index.html` at the repository root links the interactive HTML prototypes that preceded the app (`opus-5.5/`, `fable-5/`, `fable-5.1/`). `opus-5.5/` is the design reference for the native app.
