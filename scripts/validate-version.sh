#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:-}"

invalid() {
  echo "Invalid version '$VERSION' (expected X.Y.Z or X.Y.Z-suffix without leading zeros)" >&2
  exit 1
}

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(.*))?$ ]]; then
  invalid
fi

PRERELEASE="${BASH_REMATCH[5]:-}"
if [[ -z "$PRERELEASE" ]]; then
  [[ "$VERSION" != *- ]] || invalid
  exit 0
fi

if [[ ! "$PRERELEASE" =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]]; then
  invalid
fi

IFS=. read -r -a identifiers <<< "$PRERELEASE"
for identifier in "${identifiers[@]}"; do
  if [[ "$identifier" =~ ^[0-9]+$ && ! "$identifier" =~ ^(0|[1-9][0-9]*)$ ]]; then
    invalid
  fi
done
