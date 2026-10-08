# Build and share Gitoken

## Requirements

- Xcode 26 to build the app.
- macOS 15 Sequoia or newer to run it.
- GitHub CLI installed and signed in on each developer's Mac.

Run the commands below from the repository root. Select Xcode without changing the global `xcode-select` setting:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

If Xcode is installed elsewhere, use its `Contents/Developer` path. `scripts/select-xcode.sh` prints the export command for the newest stable Xcode 26 in `/Applications`.

## Build a distributable ZIP

The packaging script builds a universal Release app, ad-hoc signs it, verifies the signature, and creates a ZIP. It packages the current source, including uncommitted changes; no commit or push is required.

Choose a version. For example:

```bash
scripts/package.sh 0.1.1-dev.1
```

The output is:

```text
dist/Gitoken-0.1.1-dev.1.zip
```

The script also prints the ZIP's SHA-256 checksum and the binary's architectures. Versions must use the form `1.2.3`, optionally with a suffix such as `-dev.1` or `-beta.1`.

Quit any existing Gitoken instance before trying the newly built app:

```bash
open build/DerivedData/Build/Products/Release/Gitoken.app
```

Share the ZIP through Slack, Teams, or a shared drive rather than sending the raw `.app` bundle. Include the SHA-256 checksum if recipients need to verify the downloaded archive:

```bash
shasum -a 256 Gitoken-0.1.1-dev.1.zip
```

## Install on another developer's Mac

1. Use macOS 15 or newer.
2. Quit any existing Gitoken instance.
3. Unzip the archive and move `Gitoken.app` into `/Applications`, replacing the previous app if necessary.
4. Install and authenticate the GitHub CLI:

   ```bash
   brew install gh
   gh auth login
   ```

5. Launch Gitoken:

   ```bash
   open /Applications/Gitoken.app
   ```

Gitoken has no Dock icon. Look for it around the hardware notch, or as a pill at the top of the screen on Macs without a notch. Launch at login can be enabled under Settings → General.

If the CLI is missing, signed out, or its token is rejected at startup, Gitoken automatically opens setup guidance with commands you can copy into Terminal. Run `brew install gh` if necessary, then `gh auth login`, and click **Retry** in Gitoken. Installation and sign-in are manual; Gitoken does not run these commands itself.

Escape closes the main inbox or setup guidance; in conversations, settings and file previews, it dismisses transient controls or returns to the previous view first.

Each developer uses their own GitHub CLI authentication. The packaged app does not include the builder's GitHub token, local settings, or inbox database.

### First launch and Gatekeeper

The packaging script uses ad-hoc signing; the app is not notarized. macOS may block its first launch after downloading it.

For a build you trust, open **System Settings → Privacy & Security → Open Anyway** after the blocked launch, then launch the app again.

Alternatively, for a trusted build only, clear the app's quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Gitoken.app
open /Applications/Gitoken.app
```

Distribution without this Gatekeeper workaround requires Developer ID signing and Apple notarization, which the current packaging script does not perform.

## Development build and tests

Build and launch a Debug app:

```bash
xcodebuild -project Gitoken.xcodeproj -scheme Gitoken -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Gitoken.app
```

Debug builds can run against fictional notifications without GitHub authentication:

```bash
open build/DerivedData/Build/Products/Debug/Gitoken.app --args --fixtures
```

Run the core logic tests:

```bash
(cd Packages/GitokenCore && swift test)
```
