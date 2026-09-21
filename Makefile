# The Action Cable clients. Every language directory owns its own gate; this
# file runs them, and owns the one version number they share.

CYAN  := \033[1;36m
RESET := \033[0m

# The order a reader expects, and the order `make check` runs them in.
LANGUAGES      := go typescript python ruby kotlin rust swift
# Kotlin has no Makefile: the root Makefile calls its Gradle tasks directly.
MAKE_LANGUAGES := go typescript python ruby rust swift

.PHONY: help all check $(addsuffix -check,$(LANGUAGES)) script-test release-check bump release

all: check

help:
	@printf "$(CYAN)Targets$(RESET)\n"
	@printf "  check                      Every language's check, then the release scripts\n"
	@printf "  <language>-check           One language: $(LANGUAGES)\n"
	@printf "  script-test                Syntax-check and test the release scripts\n"
	@printf "  bump VERSION=2.1.0         Write the version everywhere it lives\n"
	@printf "  release VERSION=2.1.0      Validate and push the release tag\n"
	@printf "  release VERSION=2.1.0 DRY_RUN=1\n"
	@printf "                             Validate without creating a tag\n"

check: $(addsuffix -check,$(LANGUAGES)) script-test

$(addsuffix -check,$(MAKE_LANGUAGES)): %-check:
	@printf "\n$(CYAN)=== $* ===$(RESET)\n"
	@$(MAKE) --no-print-directory -C $* check

kotlin-check:
	@printf "\n$(CYAN)=== kotlin ===$(RESET)\n"
	@cd kotlin && ./gradlew check

script-test:
	@printf "\n$(CYAN)=== release scripts ===$(RESET)\n"
	@bash -n scripts/bump-version.sh scripts/release.sh scripts/validate-version.sh scripts/validate-version_test.sh
	@scripts/validate-version_test.sh

# What scripts/release.sh runs before it tags, and what the release workflows
# run again against the tagged commit.
release-check: check

bump:
ifndef VERSION
	$(error VERSION is required. Usage: make bump VERSION=x.y.z)
endif
	@scripts/bump-version.sh $(VERSION)

release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=x.y.z)
endif
	@DRY_RUN=$(DRY_RUN) scripts/release.sh $(VERSION)
