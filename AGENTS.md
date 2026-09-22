# actioncable-client

One Action Cable client per language, one directory each: `go/`, `typescript/`,
`python/`, `ruby/`, `kotlin/`, `rust/`, `swift/`. Every one of them is the Go
client in another language: the same public surface, the same defaults, and a
counterpart for every test in `go/*_test.go`. Read the Go client before
changing what a client does, and change every language or none. Each README
has a section on where its language made it differ, and why.

Work inside one language directory at a time. The root — this file, the
Makefile, `scripts/`, `.github/`, the READMEs that tie the languages together —
is its own job.

## Checks

Run the gate for whatever you touched before you push, and the whole thing
before you hand back:

```bash
make ruby-check    # go, typescript, python, ruby, kotlin, rust, swift
make check         # all seven, plus the release scripts
```

Each language directory has a `Makefile` with `check`, `fmt`, `lint`, `test`
and `build`; Kotlin has the equivalent Gradle tasks, and the root Makefile
calls them through `./gradlew`. `check` is exactly what CI runs for that
language — `.github/workflows/test.yml` runs `make <language>-check` and
nothing else, so the two cannot drift.

## Versions and releases

One version number covers all seven languages. It lives in ten files;
`scripts/bump-version.sh` writes all of them and `scripts/release.sh` reads
them all back. Never edit one by hand — `make bump VERSION=x.y.z`.

Before preparing, tagging, publishing or recovering a release, read
[RELEASING.md](RELEASING.md) completely and follow it. Published tags and
published packages are immutable; recovery re-runs a job or releases a new
version, never a moved tag.
