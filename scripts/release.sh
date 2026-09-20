#!/usr/bin/env bash
# Usage: scripts/release.sh VERSION [--dry-run]
#   VERSION: semver without the v prefix (for example, 1.1.0 or 1.2.0-rc.1)
#
# Validates, tags, and pushes to trigger the release workflow.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "%b==>%b %b%s%b\n" "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
error() { printf "%bERROR:%b %s\n" "$RED" "$RESET" "$*" >&2; }
die()   { error "$@"; exit 1; }

usage() {
  echo "Usage: scripts/release.sh VERSION [--dry-run]"
  echo "       make release VERSION=1.1.0 [DRY_RUN=1]"
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

DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
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

if grep -q '^[[:space:]]*replace[[:space:]]' go.mod; then
  die "go.mod contains replace directives. Remove them before releasing."
fi

if git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null; then
  EXISTING_SHA=$(git rev-parse "refs/tags/$TAG^{commit}")
  if [[ "$EXISTING_SHA" == "$LOCAL" ]]; then
    die "Tag $TAG already exists at HEAD. Re-run its GitHub workflow instead of pushing the tag again."
  fi
  die "Tag $TAG already exists at ${EXISTING_SHA:0:7}. Published Go module tags must not move; choose a new version."
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

info "Creating annotated tag $TAG"
git tag -a "$TAG" -m "Release $TAG"

info "Pushing $TAG to origin"
if ! git push --atomic origin "$DEFAULT_BRANCH" "$TAG"; then
  git tag -d "$TAG" >/dev/null
  git fetch origin "$DEFAULT_BRANCH" --tags --quiet
  die "Push rejected. Nothing was published; pull the latest $DEFAULT_BRANCH and try again."
fi

echo
info "Release $TAG triggered"
echo
echo "  Actions: https://github.com/basecamp/actioncable-go/actions"
echo "  Release: https://github.com/basecamp/actioncable-go/releases/tag/$TAG"
