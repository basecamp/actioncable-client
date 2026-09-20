.PHONY: help all check fmt vet build test release-check release

CYAN  := \033[1;36m
RESET := \033[0m

all: check

help:
	@printf "$(CYAN)Targets$(RESET)\n"
	@printf "  check                      Everything CI runs: fmt, vet, build, test\n"
	@printf "  test                       Run the tests with the race detector\n"
	@printf "  release-check              Run the release quality gate\n"
	@printf "  release VERSION=1.1.0      Validate and push a release tag\n"
	@printf "  release VERSION=1.1.0 DRY_RUN=1\n"
	@printf "                             Validate without creating a tag\n"

check: fmt vet build test

fmt:
	@printf "\n$(CYAN)Checking formatting...$(RESET)\n"
	@test -z "$$(gofmt -l .)" || { gofmt -d .; exit 1; }

vet:
	@printf "\n$(CYAN)Vetting...$(RESET)\n"
	@go vet ./...

build:
	@printf "\n$(CYAN)Building...$(RESET)\n"
	@go build ./...

test:
	@printf "\n$(CYAN)Running tests...$(RESET)\n"
	@go test -race ./...

release-check: check

release:
	@DRY_RUN=$(DRY_RUN) scripts/release.sh $(VERSION)
