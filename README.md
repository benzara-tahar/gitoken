# Gitoken

Gitoken is a macOS menu-bar agent that shows your GitHub notifications around the MacBook notch.

- The collapsed notch shows the number of unseen groups and, while activity arrives, the avatar of whoever caused it. Bursts on the same pull request merge into a single arrival.
- Clicking the notch opens a compact inbox grouped by pull request or issue. Opening a group shows the conversation (timeline, review comments with their diff hunks, check status) in a narrow panel below the notch.
- Seen is not done. Opening a group marks it seen (read on GitHub); marking it done removes it from the inbox (done on GitHub). Seen-but-not-done groups stay listed as pending. New activity on a done group brings it back.
- Quiet hours, manual quiet and snooze (per group or app-wide: 30 minutes, 1 hour, until tomorrow 09:00) suppress arrival animations while activity keeps collecting; a summary arrival appears when quiet ends.

On Macs without a notch, Gitoken shows a pill at the top of the main screen. It hides while a full-screen space is active.

## Requirements

- macOS 15 Sequoia or later. Liquid Glass styling is used on macOS 26; macOS 15 gets the system materials.
- The GitHub CLI, installed and signed in to github.com. Gitoken reuses its token (`gh auth token`) and has no login of its own:

  ```sh
  brew install gh
  gh auth login
  ```

  If gh is missing, signed out or its token is rejected, Gitoken shows instructions and a Retry button.

## Install

```sh
brew install --cask benzara-tahar/tap/gitoken
```

Release zips are also attached to each [GitHub Release](https://github.com/benzara-tahar/gitoken/releases).

### First launch

Gitoken is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch. Either:

- open System Settings › Privacy & Security and click **Open Anyway** next to the Gitoken message, then launch it again, or
- clear the quarantine flag:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Gitoken.app
  ```

Gitoken has no Dock icon. Launch at login is off by default and can be enabled in its settings.

## Building from source

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

To produce a distributable zip (universal Release build, ad-hoc signed, zipped with `ditto`):

```sh
scripts/package.sh 1.2.3   # -> dist/Gitoken-1.2.3.zip and its sha256
```

### Debug builds

- `--fixtures` launch argument: runs against built-in fictional notifications and an in-memory database instead of GitHub. No gh login needed.

  ```sh
  open build/DerivedData/Build/Products/Debug/Gitoken.app --args --fixtures
  ```

- Hidden debug controls: open the notch, then Settings (gear). A Debug section at the bottom advances the app clock by 30 minutes, 1 hour or 1 day (to check snooze expiry and quiet hours) and, with `--fixtures`, simulates a new notification, a burst on one pull request, or activity on a done group.
- The same actions are on a right-click menu on the collapsed notch, so you can fire a burst while an arrival banner is still showing and watch it merge.

Neither exists in Release builds.

## Architecture

```
App/                      SwiftUI views hosted in an AppKit NSPanel (main-actor UI only)
Packages/GitokenCore/     All non-UI logic, tested with `swift test`
  GitHub/                 gh token lookup, REST + GraphQL client (URLSession + Codable)
  Inbox/                  @Observable InboxStore, grouping, seen/done/snooze, settings
  Model/                  Domain types
  Time/                   Injectable clock (NowProvider)
```

Data flow:

1. Token: `gh auth token`, run from the usual gh install locations because GUI apps do not inherit the shell `PATH`.
2. Poll: a single task polls `GET /notifications?all=true` with `If-Modified-Since`, honouring `X-Poll-Interval` (never faster than 60 s). Polling pauses on sleep and screen lock and runs immediately on wake.
3. Hydrate: only threads that changed, or that the user opens, are fetched through GraphQL (timeline, review comments, check rollup).
4. Persist: everything, including settings, is stored in SQLite through GRDB with explicit migrations, keyed by account (host, login).
5. Present: the `@MainActor @Observable` `InboxStore` derives groups, unseen and pending counts and arrivals; the SwiftUI views in the notch panel observe it.

Sync is two-way: seen maps to GitHub "read" (`PATCH /notifications/threads/{id}`), done maps to GitHub "done" (`DELETE /notifications/threads/{id}`). Threads missing from a full listing were marked done elsewhere and become done locally. Snooze is local only.

The UI is one borderless, non-activating panel above the menu bar, resized to its content. It becomes key only while the reply composer has focus.

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
