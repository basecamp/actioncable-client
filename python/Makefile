.PHONY: help all check fmt lint typecheck test build clean

CYAN  := \033[1;36m
RESET := \033[0m

all: check

help:
	@printf "$(CYAN)Targets$(RESET)\n"
	@printf "  check      Everything CI runs: lint, typecheck, test\n"
	@printf "  fmt        Format the source\n"
	@printf "  lint       Check formatting and lints\n"
	@printf "  typecheck  Run mypy over the package\n"
	@printf "  test       Run the tests\n"
	@printf "  build      Build the wheel and sdist\n"

check: lint typecheck test

fmt:
	@printf "\n$(CYAN)Formatting...$(RESET)\n"
	@uv run ruff format src/ tests/
	@uv run ruff check --fix src/ tests/

lint:
	@printf "\n$(CYAN)Linting...$(RESET)\n"
	@uv run ruff check src/ tests/
	@uv run ruff format --check src/ tests/

typecheck:
	@printf "\n$(CYAN)Type checking...$(RESET)\n"
	@uv run mypy src/actioncable/

test:
	@printf "\n$(CYAN)Running tests...$(RESET)\n"
	@uv run pytest

build:
	@printf "\n$(CYAN)Building...$(RESET)\n"
	@uv build

clean:
	rm -rf dist .pytest_cache .mypy_cache .ruff_cache src/*.egg-info .venv
