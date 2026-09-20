#!/usr/bin/env bash

set -euo pipefail

valid=(
  0.0.0
  1.1.0
  1.2.3-alpha
  1.2.3-alpha.1
  1.2.3-0.3.7
  1.2.3-x.7.z.92
  1.2.3-alpha-1
)

invalid=(
  ""
  v1.2.3
  1.2
  1.2.3.4
  01.2.3
  1.02.3
  1.2.03
  1.2.3-
  1.2.3-.alpha
  1.2.3-alpha.
  1.2.3-alpha..1
  1.2.3-01
  1.2.3-alpha_1
  1.2.3+build
)

for version in "${valid[@]}"; do
  if ! scripts/validate-version.sh "$version"; then
    echo "expected valid version: $version" >&2
    exit 1
  fi
done

for version in "${invalid[@]}"; do
  if scripts/validate-version.sh "$version" >/dev/null 2>&1; then
    echo "expected invalid version: $version" >&2
    exit 1
  fi
done
