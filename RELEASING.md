# Releasing

One version number covers all seven clients, and one tag releases them. The tag
is `vX.Y.Z`; pushing it starts eight workflows, seven that publish a package and
one that writes the GitHub Release once the others are green.

Published tags and published packages are immutable. Never move or reuse a
release tag, even when its workflow fails. The Go module proxy, crates.io and
RubyGems all keep the first thing they saw, permanently.


## Releasing

From a clean, current `main` checkout:

```bash
make bump VERSION=2.1.0
# review the diff, commit it, get it on main
make release VERSION=2.1.0
```

The version has no leading `v`. `make release` creates `v2.1.0`.

`make bump` writes the version to the ten files that hold it and refreshes the
four lockfiles that record it. `make release` reads every one of them back and
refuses to tag if any disagrees, so a language left behind by the bump stops the
release instead of publishing a package whose own version constant lies.

A release candidate is the same command with a suffixed version:

```bash
make release VERSION=2.2.0-rc.1
```

It publishes as a prerelease everywhere that has the idea: npm under the `next`
tag, GitHub as a prerelease.

A dry run performs every local check without creating or pushing a tag:

```bash
make release VERSION=2.1.0 DRY_RUN=1
```


## What `scripts/release.sh` checks

1. The version is valid SemVer.
2. The checkout is on the default branch with a clean working tree.
3. Local `HEAD` equals `origin/main`, after fetching branch and tags.
4. `go/go.mod` has no replace directives.
5. Every version constant and every lockfile reads `VERSION`.
6. The tag does not already exist, and a stable version is not older than the
   latest stable release.
7. `make release-check` — which is `make check`, every language — passes.
8. The annotated tag is created at the tested commit.
9. `main` and the tag are pushed atomically, so a concurrent change rejects the
   whole push and publishes nothing.


## What each workflow publishes

Every one of them re-runs that language's `make <language>-check` against the
tagged commit, verifies the tag is an ancestor of `main`, and verifies the
language's own version constant equals the tag before it publishes anything.

| Workflow                   | Publishes                               | Where                            |
|----------------------------|-----------------------------------------|----------------------------------|
| `release-go.yml`           | the `go/vX.Y.Z` tag                     | proxy.golang.org                 |
| `release-typescript.yml`   | `@37signals/actioncable`                | npm                              |
| `release-python.yml`       | `actioncable-client`                    | PyPI                             |
| `release-ruby.yml`         | `actioncable-client`                    | RubyGems                         |
| `release-kotlin.yml`       | `com.basecamp:actioncable-client`       | GitHub Packages                  |
| `release-rust.yml`         | `actioncable-client`                    | crates.io                        |
| `release-swift.yml`        | nothing — the `vX.Y.Z` tag is the release | resolved by SwiftPM from this repository |
| `release-github.yml`       | the GitHub Release and its notes        | this repository                  |

Two of those need explaining.

**Go.** The module lives in `go/`, so the proxy serves it from a `go/vX.Y.Z`
tag, not from the global one. `scripts/release.sh` never creates it:
`release-go.yml` does, from the tag that triggered it, after the tests pass.
That is why a person pushes one tag and two exist afterwards.

**Swift.** SwiftPM resolves a package from the root of a repository and cannot
be pointed at a subdirectory, so the root `Package.swift` — not
`swift/Package.swift` — is what consumers build. Nothing is uploaded anywhere;
the tag is the release. `test.yml` and `release-swift.yml` both build the root
manifest so it cannot quietly stop naming a real source path.

`release-github.yml` polls the other seven for the tag's own push-triggered
runs and only writes the Release when all of them succeeded. A release whose
notes advertise `pip install actioncable-client==2.1.0` should not exist before
PyPI has it.


## The rehearsal

Every release workflow also takes a `workflow_dispatch`, and a manual run is
always a dry run. It builds the artifact the real run would build, validates it
the way the registry will, and reports what it would have published — without
holding any publishing credential, because the dry-run job carries no
`environment:` and no write permission.

Run one from the Actions tab against `main` before the first release, and after
any change to the pipeline. `release-github.yml`'s manual run takes a tag and
creates a *draft* release, so it can be rehearsed too.


## Verification

After the workflows are green:

```bash
gh release view v2.1.0
GOPROXY=https://proxy.golang.org go list -m github.com/basecamp/actioncable-client/go@v2.1.0
npm view @37signals/actioncable@2.1.0 version
pip index versions actioncable-client
gem list -r -a actioncable-client
cargo search actioncable-client
```

Documentation appears at `pkg.go.dev/github.com/basecamp/actioncable-client/go@v2.1.0`
and `docs.rs/actioncable-client/2.1.0`; both can take a while to index.


## Recovery

**The atomic tag push failed.** Nothing was published. Pull `main` and run the
release command again.

**A publish workflow failed before it published.** For a transient failure, re-run
the job: every publish step checks the registry first and treats an already-published
version as success, so a re-run cannot double-publish. For a defect in the source
or the pipeline, merge the fix and release a new version. Do not move the tag.

**One language published and another did not.** The versions are allowed to be
uneven for as long as it takes to re-run the failed job. If the failure needs a
source change, release the next patch everywhere rather than trying to catch one
language up: one version across seven languages is the contract, and a language
sitting a patch behind is easier to explain than two languages at the same
version built from different commits.

**The GitHub Release is missing but everything published.** Run
`release-github.yml` manually with the tag. It creates a draft; publish it by
hand.


## Before the first release

None of these exist yet. Each one is referenced by a workflow that will fail
without it, and the reference is deliberate — it is the checklist.

1. **Rename the repository to `actioncable-client`.** Every package manifest,
   workflow and README already says that name. The `github.repository` guard in
   `release-rust.yml` checks it literally.
2. **npm.** Register a trusted publisher for `@37signals/actioncable` pointing
   at `basecamp/actioncable-client` and `release-typescript.yml`, and create a
   `release-npm` environment restricted to `v*` tags. The package scope must
   allow public publishing.
3. **PyPI.** Register a trusted publisher for `actioncable-client` pointing at
   `release-python.yml`, and create a `release-pypi` environment. The project
   name has to be claimed before the publisher can be attached to it.
4. **RubyGems.** Register a trusted publisher for the `actioncable-client` gem
   pointing at `release-ruby.yml`, and create a `release-rubygems` environment.
5. **crates.io.** Trusted publishing cannot create a crate, so publish
   `actioncable-client` once by hand from a local checkout (`cargo publish`),
   then register the trusted publisher for `release-rust.yml` and create a
   `release-crates` environment restricted to `v*` tags with required reviewers.
   Until the crate exists, `release-rust.yml` fails deliberately rather than
   letting the GitHub Release advertise a version nobody can install.
6. **GitHub Packages** needs nothing: `release-kotlin.yml` publishes with the
   workflow's own `GITHUB_TOKEN` and `packages: write`.
7. **Go and Swift** need nothing. Both are served from tags on this repository.
8. **Branch protection** on `main`, because every release workflow refuses a tag
   that is not an ancestor of it.

Rehearse each workflow with `workflow_dispatch` once its credentials are in
place, and only then push the first tag.
