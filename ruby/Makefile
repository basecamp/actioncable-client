.PHONY: help all check bundle fmt lint test build doc clean

CYAN  := \033[1;36m
RESET := \033[0m

all: check

help:
	@printf "$(CYAN)Targets$(RESET)\n"
	@printf "  check                      Everything CI runs: lint, test, build\n"
	@printf "  fmt                        Fix what RuboCop can fix\n"
	@printf "  lint                       Run RuboCop\n"
	@printf "  test                       Run the tests\n"
	@printf "  build                      Build the gem\n"
	@printf "  doc                        Generate the API documentation\n"

check: lint test build

bundle:
	@printf "\n$(CYAN)Installing dependencies...$(RESET)\n"
	@bundle install --quiet

fmt: bundle
	@printf "\n$(CYAN)Formatting...$(RESET)\n"
	@bundle exec rubocop --autocorrect

lint: bundle
	@printf "\n$(CYAN)Linting...$(RESET)\n"
	@bundle exec rubocop

test: bundle
	@printf "\n$(CYAN)Running tests...$(RESET)\n"
	@bundle exec rake test

build: bundle
	@printf "\n$(CYAN)Building the gem...$(RESET)\n"
	@bundle exec rake build

doc: bundle
	@printf "\n$(CYAN)Generating documentation...$(RESET)\n"
	@bundle exec rake doc

clean:
	@rm -rf .bundle doc pkg vendor
