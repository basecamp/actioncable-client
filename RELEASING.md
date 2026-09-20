# Releasing actioncable-go

A Git tag publishes this source-only Go module. The tag is the release artifact. The
GitHub Release supplies human-readable notes, and the public Go module proxy caches
the tagged source.

Published tags are immutable. Never move or reuse a release tag, even when its
workflow fails. The Go module proxy and checksum database can keep the first version
of a tag permanently.

## Quick release

Run this from a clean, current `main` checkout:

```bash
make release VERSION=1.1.0
```

The version has no leading `v`. The release command creates `v1.1.0`.

## Release candidate

```bash
make release VERSION=1.2.0-rc.1
```

## Dry run

```bash
make release VERSION=1.1.0 DRY_RUN=1
```

The dry run performs every local check without creating or pushing a tag.

## Local release process

`scripts/release.sh`:

1. Validates the semantic version.
2. Requires the repository's default branch and a clean working tree.
3. Fetches the default branch and tags from `origin`.
4. Requires local `HEAD` to equal `origin/main`.
5. Refuses `go.mod` replacement directives.
6. Refuses an existing tag and a stable version older than the latest stable release.
7. Runs `make release-check`.
8. Creates an annotated tag at the tested commit.
9. Atomically pushes `main` and the tag, so a concurrent change rejects the complete push.

The tag push starts the [release workflow](.github/workflows/release.yml).

## GitHub release workflow

The workflow runs against the exact tag commit. It:

1. Validates the tag and requires an annotated semantic-version tag.
2. Verifies that the tag commit is on `main`.
3. Runs `make release-check` again.
4. Creates the GitHub Release with generated notes, marking a suffixed version as a prerelease.
5. Requests the version from `proxy.golang.org` and fails if the proxy cannot resolve it.

There are no binary archives, package-manager updates, signing keys, or release assets.
Consumers download the source through Go tooling:

```bash
go get github.com/basecamp/actioncable-go@v1.1.0
```

## Verification

After the workflow is green, verify:

```bash
gh release view v1.1.0
GOPROXY=https://proxy.golang.org go list -m github.com/basecamp/actioncable-go@v1.1.0
```

The documentation will appear at:

```text
https://pkg.go.dev/github.com/basecamp/actioncable-go@v1.1.0
```

`pkg.go.dev` can take additional time to index a new version.

## Recovery

If the atomic tag push fails, no release was published. Pull the current `main` and
run the release command again.

If the tag workflow fails before it creates the GitHub Release:

- For a temporary infrastructure failure, rerun the existing workflow for that tag.
- For a source or release-process defect, merge the fix and use a new version. Do not
  move or reuse the published tag.

If the GitHub Release exists but the proxy check failed, rerun the failed release job.
The job detects the existing GitHub Release and continues with the proxy check.
