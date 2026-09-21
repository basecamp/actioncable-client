# frozen_string_literal: true

require_relative "lib/actioncable_client/version"

Gem::Specification.new do |spec|
  spec.name = "actioncable-client"
  spec.version = ActionCableClient::VERSION
  spec.authors = [ "Basecamp" ]
  spec.email = [ "support@basecamp.com" ]

  spec.summary = "Ruby client for Rails' Action Cable"
  spec.description = "A Ruby client for Rails' Action Cable with automatic reconnection, " \
                     "subscriptions that survive it, a pluggable transport and protocol, " \
                     "and an RFC 6455 WebSocket of its own so it carries no dependencies."
  spec.homepage = "https://github.com/basecamp/actioncable-client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/releases"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Globbed rather than taken from `git ls-files`: the gem is built from the
  # working tree, and a file that is there but not yet committed belongs in it.
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "README.md"] }
  spec.require_paths = [ "lib" ]

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop-37signals"
  spec.add_development_dependency "yard", "~> 0.9"
end
