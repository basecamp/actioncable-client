#!/usr/bin/env bash
# Usage: scripts/bump-version.sh VERSION
#   VERSION: semver without the v prefix (for example, 2.1.0)
#
# Writes the one version number to every place it lives, then refreshes the
# four lockfiles that record it. scripts/release.sh reads the same places back
# and refuses to tag if any of them disagrees; change one and change both.

set -euo pipefail

cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

info()  { printf "%b==>%b %s\n" "$GREEN" "$RESET" "$*"; }
error() { printf "%bERROR:%b %s\n" "$RED" "$RESET" "$*" >&2; }
die()   { error "$@"; exit 1; }

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/bump-version.sh VERSION" >&2
  echo "       make bump VERSION=2.1.0" >&2
  exit 1
fi
if [[ "$VERSION" == v* ]]; then
  die "Leave the leading v off the version (use ${VERSION#v})"
fi
if ! version_error=$(scripts/validate-version.sh "$VERSION" 2>&1); then
  die "$version_error"
fi

# Every file this script rewrites. Checked before anything is written, so a
# path that moved fails the bump rather than half-applying it.
FILES=(
  go/version.go
  typescript/package.json
  typescript/src/version.ts
  python/pyproject.toml
  python/src/actioncable/_version.py
  ruby/lib/actioncable_client/version.rb
  kotlin/build.gradle.kts
  kotlin/client/src/commonMain/kotlin/com/basecamp/actioncable/Version.kt
  rust/Cargo.toml
  swift/Sources/ActionCable/Version.swift
)
missing=()
for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || missing+=("$file")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  die "These version files are missing: ${missing[*]}"
fi

for tool in python3 jq npm bundle uv cargo; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required to bump the version"
done

# sed -i spells its backup suffix differently on GNU and BSD, so the edit goes
# through a temp file. The rewritten file has to contain the line we asked for
# before it replaces the original: a pattern that stopped matching leaves the
# file alone and exits 0, and would otherwise announce a bump it never made.
rewrite() {
  local expression="$1" expected="$2" file="$3" temp
  temp=$(mktemp)
  sed "$expression" "$file" > "$temp"
  if ! grep -qxF "$expected" "$temp"; then
    rm -f "$temp"
    die "$file has no '$expected' line after the bump. Its version line is not where this script looks for it."
  fi
  cat "$temp" > "$file"
  rm -f "$temp"
}

info "Bumping every version to $VERSION"

rewrite "s/^const Version = \".*\"\$/const Version = \"$VERSION\"/" \
  "const Version = \"$VERSION\"" go/version.go
rewrite "s/^  \"version\": \".*\",\$/  \"version\": \"$VERSION\",/" \
  "  \"version\": \"$VERSION\"," typescript/package.json
rewrite "s/^export const VERSION = \".*\";\$/export const VERSION = \"$VERSION\";/" \
  "export const VERSION = \"$VERSION\";" typescript/src/version.ts
rewrite "s/^VERSION = \".*\"\$/VERSION = \"$VERSION\"/" \
  "VERSION = \"$VERSION\"" python/src/actioncable/_version.py
rewrite "s/^  VERSION = \".*\"\$/  VERSION = \"$VERSION\"/" \
  "  VERSION = \"$VERSION\"" ruby/lib/actioncable_client/version.rb
rewrite "s/^const val VERSION = \".*\"\$/const val VERSION = \"$VERSION\"/" \
  "const val VERSION = \"$VERSION\"" kotlin/client/src/commonMain/kotlin/com/basecamp/actioncable/Version.kt
rewrite "s/^    public static let version = \".*\"\$/    public static let version = \"$VERSION\"/" \
  "    public static let version = \"$VERSION\"" swift/Sources/ActionCable/Version.swift

# The last three files are edited inside the block that owns the version rather
# than line by line: a bare `version = ` also lives under Cargo's
# [dependencies], under pyproject's other tables, and in a Gradle module block,
# and every one of those files is free to grow one.
rewrite_toml_version() {
  local table="$1" file="$2" temp
  temp=$(mktemp)
  awk -v table="[$table]" -v want="version = \"$VERSION\"" '
    substr($0, 1, 1) == "[" { inside = ($0 == table) }
    inside && /^version = "/ { $0 = want; found = 1 }
    { print }
    END { exit !found }
  ' "$file" > "$temp" || { rm -f "$temp"; die "No version line under [$table] in $file"; }
  cat "$temp" > "$file"
  rm -f "$temp"
}

rewrite_gradle_version() {
  local file="$1" temp
  temp=$(mktemp)
  awk -v want="    version = \"$VERSION\"" '
    /^allprojects [{]/ { inside = 1 }
    /^[}]/ { inside = 0 }
    inside && /^    version = "/ { $0 = want; found = 1 }
    { print }
    END { exit !found }
  ' "$file" > "$temp" || { rm -f "$temp"; die "No version line inside allprojects in $file"; }
  cat "$temp" > "$file"
  rm -f "$temp"
}

rewrite_toml_version project python/pyproject.toml
rewrite_toml_version package rust/Cargo.toml
rewrite_gradle_version kotlin/build.gradle.kts

# Read the two manifests back through their own parsers rather than a second
# regex over the file, which is the check that would fail the same way the
# edit did.
TOML_VERSION=$(python3 -c 'import tomllib; print(tomllib.load(open("python/pyproject.toml","rb"))["project"]["version"])')
if [[ "$TOML_VERSION" != "$VERSION" ]]; then
  die "python/pyproject.toml [project].version reads $TOML_VERSION after the edit, not $VERSION"
fi
CARGO_VERSION=$(cd rust && cargo metadata --no-deps --format-version 1 \
  | jq -r '.packages[] | select(.name == "actioncable-client") | .version')
if [[ "$CARGO_VERSION" != "$VERSION" ]]; then
  die "rust/Cargo.toml [package].version reads $CARGO_VERSION after the edit, not $VERSION"
fi

info "Syncing the TypeScript lockfile"
(cd typescript && npm install --package-lock-only --ignore-scripts --silent)

info "Syncing the Ruby lockfile"
(cd ruby && bundle install --quiet)

info "Syncing the Python lockfile"
(cd python && uv lock --quiet)

info "Syncing the Rust lockfile"
(cd rust && cargo update -q -w --offline)

info "Bumped ${#FILES[@]} version files and synced 4 lockfiles to $VERSION."
