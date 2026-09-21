.PHONY: help all check fmt lint build test clean

CYAN  := \033[1;36m
RESET := \033[0m

SOURCES := Sources Tests Package.swift

all: check

help:
	@printf "$(CYAN)Targets$(RESET)\n"
	@printf "  check      Everything CI runs: lint, build, test\n"
	@printf "  fmt        Reformat the sources in place\n"
	@printf "  lint       Check formatting and style without changing anything\n"
	@printf "  build      Build the package\n"
	@printf "  test       Run the tests\n"
	@printf "  clean      Remove build artifacts\n"

check: lint build test

fmt:
	@printf "\n$(CYAN)Formatting...$(RESET)\n"
	@swift format --in-place --recursive $(SOURCES)

lint:
	@printf "\n$(CYAN)Linting...$(RESET)\n"
	@swift format lint --recursive --strict $(SOURCES)

build:
	@printf "\n$(CYAN)Building...$(RESET)\n"
	@swift build

test:
	@printf "\n$(CYAN)Running tests...$(RESET)\n"
	@swift test

clean:
	@swift package clean
