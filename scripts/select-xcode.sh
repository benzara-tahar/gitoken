#!/usr/bin/env bash
# Picks the newest stable Xcode with the requested major version (default 26) and
# exports it through DEVELOPER_DIR, without touching xcode-select.
#
# Usage: scripts/select-xcode.sh [major]
# In GitHub Actions it appends DEVELOPER_DIR to $GITHUB_ENV and writes the
# `developer-dir` and `version` step outputs; elsewhere it prints an export line.
set -euo pipefail

major="${1:-26}"

candidates=()
for app in /Applications/Xcode_"${major}"*.app /Applications/Xcode.app; do
  [[ -d "$app/Contents/Developer" ]] || continue
  # Skip betas and release candidates (Xcode_26.1_beta.app, Xcode_26.1_Release_Candidate.app).
  name="$(basename "$app")"
  [[ "$name" == "Xcode.app" || "$name" =~ ^Xcode_[0-9]+(\.[0-9]+)*\.app$ ]] || continue
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "${version%%.*}" == "$major" ]] || continue
  candidates+=("$version $app")
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "error: no stable Xcode ${major}.x found in /Applications" >&2
  ls -d /Applications/Xcode*.app >&2 2>/dev/null || true
  exit 1
fi

selected="$(printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1)"
version="${selected%% *}"
developer_dir="${selected#* }/Contents/Developer"

echo "Selected Xcode $version at $developer_dir" >&2
DEVELOPER_DIR="$developer_dir" xcodebuild -version >&2

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=$developer_dir" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "developer-dir=$developer_dir"
    echo "version=$version"
  } >> "$GITHUB_OUTPUT"
fi
if [[ -z "${GITHUB_ENV:-}" ]]; then
  echo "export DEVELOPER_DIR='$developer_dir'"
fi
