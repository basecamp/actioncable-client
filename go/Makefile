.PHONY: help all check fmt vet build test

CYAN  := \033[1;36m
RESET := \033[0m

all: check

help:
	@printf "$(CYAN)Targets$(RESET)\n"
	@printf "  check      Everything CI runs: fmt, vet, build, test\n"
	@printf "  fmt        Check formatting\n"
	@printf "  vet        Run go vet\n"
	@printf "  build      Build the package\n"
	@printf "  test       Run the tests with the race detector\n"

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
