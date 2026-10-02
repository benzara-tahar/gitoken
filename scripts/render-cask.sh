#!/usr/bin/env bash
# Renders packaging/homebrew/gitoken.rb.template to stdout.
#
# Usage: scripts/render-cask.sh <version> <sha256> [owner/repo]
# owner/repo defaults to $GITHUB_REPOSITORY, then benzara-tahar/gitoken. The release
# asset URL is derived from it: https://github.com/<repo>/releases/download/v<version>/Gitoken-<version>.zip
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <version> <sha256> [owner/repo]" >&2
  exit 64
fi

version="${1#v}"
sha256="$2"
repo="${3:-${GITHUB_REPOSITORY:-benzara-tahar/gitoken}}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "error: bad version '$1'" >&2; exit 64; }
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: bad sha256 '$sha256'" >&2; exit 64; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "error: bad repository '$repo'" >&2; exit 64; }

template="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packaging/homebrew/gitoken.rb.template"
rendered="$(sed \
  -e "s|@VERSION@|$version|g" \
  -e "s|@SHA256@|$sha256|g" \
  -e "s|@REPOSITORY@|$repo|g" \
  "$template")"

if grep -qE '@[A-Z0-9_]+@' <<<"$rendered"; then
  echo "error: unrendered placeholder in template" >&2
  exit 1
fi

printf '%s\n' "$rendered"
