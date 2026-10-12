#!/usr/bin/env bash
# Regenerates the README screenshots from the built-in fictional fixture data (Debug build, --fixtures).
# Quits any running Gitoken first so live notifications can never appear. Needs Screen Recording permission.
#
#   scripts/screenshots.sh [path/to/Debug/Gitoken.app]
set -euo pipefail

cd "$(dirname "$0")/.."
app="${1:-build/DerivedData/Build/Products/Debug/Gitoken.app}"
out="docs/assets/screenshots"
[[ -d "$app" ]] || { echo "Debug build not found at $app" >&2; exit 1; }

shoot() {
  local scene=$1 name=$2
  pkill -x Gitoken 2>/dev/null || true
  while pgrep -x Gitoken >/dev/null; do sleep 0.2; done
  open -n "$app" --args --fixtures --scene "$scene" ${3:-}
  sleep "${DELAY:-4}"
  # Refuse to capture unless every running Gitoken is this Debug build launched with --fixtures.
  local pids; pids=$(pgrep -x Gitoken) || { echo "Gitoken did not launch" >&2; exit 1; }
  for pid in $pids; do
    local cmd; cmd=$(ps -o command= -p "$pid")
    [[ $cmd == *"$app"* && $cmd == *--fixtures* ]] || { echo "refusing to capture: unexpected Gitoken process: $cmd" >&2; exit 1; }
  done
  swift scripts/compose-screenshot.swift "$out/$name.png"
}

shoot inbox inbox
shoot conversation conversation
shoot preview file-preview
shoot settings settings
pkill -x Gitoken 2>/dev/null || true
