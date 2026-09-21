# The Rust Action Cable client — the recipes CI and a local gate both run.

CARGO := cargo

.PHONY: all
all: check

.PHONY: build
build:
	$(CARGO) build --all-features --locked

.PHONY: fmt
fmt:
	$(CARGO) fmt --all

.PHONY: fmt-check
fmt-check:
	$(CARGO) fmt --all -- --check

.PHONY: lint
lint: fmt-check
	$(CARGO) clippy --all-targets --all-features --locked -- -D warnings

.PHONY: test
test:
	$(CARGO) test --all-features --locked

# Every feature set the crate supports must build and pass its tests. Without `websocket`
# there is no transport to dial with, so what is left is the core and its unit tests.
.PHONY: test-features
test-features:
	$(CARGO) test --no-default-features --features test-support --locked
	$(CARGO) test --no-default-features --locked
	$(CARGO) test --locked

# Broken intra-doc links fail the build
.PHONY: doc
doc:
	RUSTDOCFLAGS="-D warnings" $(CARGO) doc --no-deps --all-features

.PHONY: deny
deny:
	$(CARGO) deny check

# Not part of `check`: it refuses to run over a tree with uncommitted changes, which is
# most of the time a developer runs the gate. The release pipeline calls it.
.PHONY: publish-check
publish-check:
	$(CARGO) publish --dry-run --locked

.PHONY: check
check: lint test test-features doc deny

.PHONY: clean
clean:
	$(CARGO) clean

.PHONY: help
help:
	@echo "Action Cable Rust client targets:"
	@echo ""
	@echo "  build           Build the crate with every feature"
	@echo "  fmt             Format code"
	@echo "  fmt-check       Check formatting"
	@echo "  lint            fmt-check + clippy with warnings denied"
	@echo "  test            Run all tests"
	@echo "  test-features   Run the tests under every feature set"
	@echo "  doc             Build the crate docs, warnings denied"
	@echo "  deny            cargo deny check (advisories, licenses, bans, sources)"
	@echo "  publish-check   cargo publish --dry-run, over a committed tree"
	@echo "  check           lint + test + test-features + doc + deny"
	@echo "  clean           Remove build artifacts"
