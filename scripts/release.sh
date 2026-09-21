#!/usr/bin/env bash
# Usage: scripts/release.sh VERSION [--dry-run]
#   VERSION: semver without the v prefix (for example, 2.1.0 or 2.2.0-rc.1)
#
# Validates, tags, and pushes to trigger the release workflows. One tag, vX.Y.Z,
# releases all seven languages. The Go module's own go/vX.Y.Z tag is created by
# .github/workflows/release-go.yml from this one; nothing here creates it.

set -euo pipefail

cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "%b==>%b %b%s%b\n" "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
error() { printf "%bERROR:%b %s\n" "$RED" "$RESET" "$*" >&2; }
die()   { error "$@"; exit 1; }

usage() {
  echo "Usage: scripts/release.sh VERSION [--dry-run]"
  echo "       make release VERSION=2.1.0 [DRY_RUN=1]"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi
if [[ $# -gt 2 ]]; then
  die "Unexpected arguments (expected VERSION [--dry-run])"
fi

VERSION="$1"
release_dry_run_input="${DRY_RUN:-}"
case "${2:-}" in
  "") ;;
  --dry-run) release_dry_run_input=1 ;;
  *) die "Unknown argument: '$2' (expected --dry-run)" ;;
esac
case "$release_dry_run_input" in
  ""|0|false) RELEASE_DRY_RUN=0 ;;
  1|true) RELEASE_DRY_RUN=1 ;;
  *) die "Invalid DRY_RUN value: '$release_dry_run_input' (expected 0, 1, false, or true)" ;;
esac
readonly RELEASE_DRY_RUN

if [[ "$VERSION" == v* ]]; then
  die "Leave the leading v off the version (use ${VERSION#v})"
fi
if ! version_error=$(scripts/validate-version.sh "$VERSION" 2>&1); then
  die "$version_error"
fi

TAG="v$VERSION"
PRERELEASE=0
if [[ "$VERSION" == *-* ]]; then
  PRERELEASE=1
fi

if [[ "$RELEASE_DRY_RUN" -eq 1 ]]; then
  info "Dry run - no tag will be created or pushed"
  echo
fi

# From the local ref rather than `git remote show origin`: that one goes over
# the network, and under `pipefail` a clone whose credentials are not loaded
# kills the script here with git's exit code instead of reaching the fallback.
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||') || true
if [[ -z "$DEFAULT_BRANCH" || "$DEFAULT_BRANCH" == "(unknown)" ]]; then
  DEFAULT_BRANCH=main
fi
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "$DEFAULT_BRANCH" ]]; then
  die "Not on $DEFAULT_BRANCH (currently on $BRANCH)"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  die "Working tree is not clean. Commit or stash changes first."
fi

git fetch origin "$DEFAULT_BRANCH" --tags --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$DEFAULT_BRANCH")
if [[ "$LOCAL" != "$REMOTE" ]]; then
  die "Local $DEFAULT_BRANCH (${LOCAL:0:7}) is not synced with origin/$DEFAULT_BRANCH (${REMOTE:0:7}). Pull or push first."
fi

if grep -q '^[[:space:]]*replace[[:space:]]' go/go.mod; then
  die "go/go.mod contains replace directives. Remove them before releasing."
fi

# Every place scripts/bump-version.sh writes the version, read back. A release
# is one number across seven languages, and a language left behind publishes a
# package whose own constant lies about which release it is.
for tool in python3 jq uv cargo; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required to verify the versions"
done

info "Verifying every version constant reads $VERSION"

expect_line() {
  local expected="$1" file="$2"
  if ! grep -qxF "$expected" "$file"; then
    die "$file does not read $VERSION. Run 'make bump VERSION=$VERSION' first."
  fi
}

expect_line "const Version = \"$VERSION\"" go/version.go
expect_line "  \"version\": \"$VERSION\"," typescript/package.json
expect_line "export const VERSION = \"$VERSION\";" typescript/src/version.ts
expect_line "VERSION = \"$VERSION\"" python/src/actioncable/_version.py
expect_line "  VERSION = \"$VERSION\"" ruby/lib/actioncable_client/version.rb
expect_line "    version = \"$VERSION\"" kotlin/build.gradle.kts
expect_line "const val VERSION = \"$VERSION\"" kotlin/client/src/commonMain/kotlin/com/basecamp/actioncable/Version.kt
expect_line "    public static let version = \"$VERSION\"" swift/Sources/ActionCable/Version.swift

# The two manifests read through their own parsers instead: a bare
# `version = ` line also lives under [dependencies] and under pyproject's
# other tables, so the line being present proves nothing about which one it is.
TOML_VERSION=$(python3 -c 'import tomllib; print(tomllib.load(open("python/pyproject.toml","rb"))["project"]["version"])')
if [[ "$TOML_VERSION" != "$VERSION" ]]; then
  die "python/pyproject.toml [project].version reads $TOML_VERSION, not $VERSION. Run 'make bump VERSION=$VERSION' first."
fi
CARGO_VERSION=$(cd rust && cargo metadata --no-deps --locked --format-version 1 \
  | jq -r '.packages[] | select(.name == "actioncable-client") | .version')
if [[ "$CARGO_VERSION" != "$VERSION" ]]; then
  die "rust/Cargo.toml [package].version reads $CARGO_VERSION, not $VERSION. Run 'make bump VERSION=$VERSION' first."
fi

# The four lockfiles record the version too, and every install in CI is frozen
# against them, so a stale one fails the publish rather than the release.
if [[ "$(jq -r '.version, .packages[""].version' typescript/package-lock.json | sort -u)" != "$VERSION" ]]; then
  die "typescript/package-lock.json records a stale version. Run 'make bump VERSION=$VERSION' first."
fi
expect_line "    actioncable-client ($VERSION)" ruby/Gemfile.lock
(cd python && uv lock --check >/dev/null 2>&1) \
  || die "python/uv.lock is stale. Run 'make bump VERSION=$VERSION' first."
(cd rust && cargo metadata --locked --format-version 1 >/dev/null 2>&1) \
  || die "rust/Cargo.lock is stale. Run 'make bump VERSION=$VERSION' first."

TAG_EXISTS=0
if git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null; then
  EXISTING_SHA=$(git rev-parse "refs/tags/$TAG^{commit}")
  if [[ "$EXISTING_SHA" != "$LOCAL" ]]; then
    die "Tag $TAG already exists at ${EXISTING_SHA:0:7}. Published tags must not move; choose a new version."
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "Tag $TAG is already published. Re-run its GitHub workflows instead of pushing the tag again."
  fi
  if [[ "$(git cat-file -t "$TAG")" != "tag" ]]; then
    die "Local tag $TAG is not annotated. Delete it and run the release command again."
  fi
  TAG_EXISTS=1
  info "Reusing unpublished annotated tag $TAG at HEAD"
fi

version_lt() {
  local -a a b
  local i
  IFS=. read -r -a a <<< "${1#v}"
  IFS=. read -r -a b <<< "${2#v}"
  for i in 0 1 2; do
    if (( 10#${a[i]:-0} < 10#${b[i]:-0} )); then return 0; fi
    if (( 10#${a[i]:-0} > 10#${b[i]:-0} )); then return 1; fi
  done
  return 1
}

if [[ "$PRERELEASE" -eq 0 ]]; then
  LATEST_STABLE=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | awk '!/-/ { print; exit }')
  if [[ -n "$LATEST_STABLE" && "$LATEST_STABLE" != "$TAG" ]] && version_lt "$TAG" "$LATEST_STABLE"; then
    die "Version $VERSION is older than the latest stable release ${LATEST_STABLE#v}."
  fi
fi

info "Running release checks"
echo "  Branch: $BRANCH"
echo "  Commit: ${LOCAL:0:7}"
echo "  Tag:    $TAG"
echo
make release-check

if [[ -n "$(git status --porcelain)" ]]; then
  die "Release checks changed the working tree. Restore or commit those changes first."
fi

if [[ "$RELEASE_DRY_RUN" -eq 1 ]]; then
  echo
  info "Dry run complete. No tag created."
  exit 0
fi

if [[ "$TAG_EXISTS" -eq 0 ]]; then
  info "Creating annotated tag $TAG"
  git tag -a "$TAG" -m "Release $TAG"
fi

info "Pushing $TAG to origin"
if ! git push --atomic origin "$DEFAULT_BRANCH" "$TAG"; then
  git tag -d "$TAG" >/dev/null
  git fetch origin "$DEFAULT_BRANCH" --tags --quiet
  die "Push rejected. Nothing was published; pull the latest $DEFAULT_BRANCH and try again."
fi

echo
info "Release $TAG triggered"
echo
echo "  Actions: https://github.com/basecamp/actioncable-client/actions"
echo "  Release: https://github.com/basecamp/actioncable-client/releases/tag/$TAG"
