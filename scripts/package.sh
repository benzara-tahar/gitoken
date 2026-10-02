#!/usr/bin/env bash
# Builds a universal Release Gitoken.app, ad-hoc signs it and zips it for distribution.
#
# Usage: scripts/package.sh <version>        e.g. scripts/package.sh 1.2.0
# Env:   DERIVED_DATA  derived data path (default build/DerivedData)
#        BUILD_NUMBER  CFBundleVersion (default: numeric part of <version>)
# Output: dist/Gitoken-<version>.zip; prints its sha256. In GitHub Actions also writes
#         the `zip`, `sha256` and `version` step outputs.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 64
fi

version="${1#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: version must look like 1.2.3 or 1.2.3-beta.1, got '$1'" >&2
  exit 64
fi
# CFBundleVersion only accepts dot-separated integers.
build_number="${BUILD_NUMBER:-${version%%[-+]*}}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

derived_data="${DERIVED_DATA:-build/DerivedData}"
app="$derived_data/Build/Products/Release/Gitoken.app"
zip="dist/Gitoken-$version.zip"

echo "==> Building Gitoken $version ($build_number)"
xcodebuild \
  -project Gitoken.xcodeproj \
  -scheme Gitoken \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  build

if [[ ! -d "$app" ]]; then
  echo "error: build succeeded but $app is missing" >&2
  exit 1
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --options runtime "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --verbose=2 "$app" 2>&1 | grep -E '^(Identifier|Signature|CodeDirectory)' || true
lipo -archs "$app/Contents/MacOS/Gitoken"

echo "==> Zipping"
mkdir -p dist
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

sha256="$(shasum -a 256 "$zip" | awk '{print $1}')"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "zip=$zip"
    echo "sha256=$sha256"
    echo "version=$version"
  } >> "$GITHUB_OUTPUT"
fi

echo "$zip"
echo "sha256 $sha256"
