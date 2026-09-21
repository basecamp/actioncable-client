.PHONY: help all check install fmt fmt-check lint typecheck test build clean

CYAN  := \033[1;36m
RESET := \033[0m

NODE_STAMP := node_modules/.install-stamp

all: check

help:
	@printf "$(CYAN)Targets$(RESET)\n"
	@printf "  check                      Everything CI runs: fmt, lint, typecheck, test, build\n"
	@printf "  fmt                        Format the source\n"
	@printf "  lint                       Lint the source\n"
	@printf "  test                       Run the tests\n"
	@printf "  build                      Compile to dist/\n"
	@printf "  clean                      Remove dist/ and node_modules/\n"

check: fmt-check lint typecheck test build

$(NODE_STAMP): package.json package-lock.json
	@printf "\n$(CYAN)Installing dependencies...$(RESET)\n"
	@npm ci
	@touch $(NODE_STAMP)

install: $(NODE_STAMP)

fmt: install
	@printf "\n$(CYAN)Formatting...$(RESET)\n"
	@npm run --silent format

fmt-check: install
	@printf "\n$(CYAN)Checking formatting...$(RESET)\n"
	@npm run --silent format:check

lint: install
	@printf "\n$(CYAN)Linting...$(RESET)\n"
	@npm run --silent lint

typecheck: install
	@printf "\n$(CYAN)Type checking...$(RESET)\n"
	@npm run --silent typecheck

test: install
	@printf "\n$(CYAN)Running tests...$(RESET)\n"
	@npm run --silent test

build: install
	@printf "\n$(CYAN)Building...$(RESET)\n"
	@npm run --silent build

clean:
	@rm -rf dist node_modules
