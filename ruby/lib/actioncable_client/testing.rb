# frozen_string_literal: true

require_relative "../actioncable_client"
require_relative "testing/channel"
require_relative "testing/fake_transport"

module ActionCableClient
  # What a test needs to drive a client without a server: an in-memory
  # transport the test plays the server on. It ships with the gem because
  # anything built on this client needs the same thing.
  #
  #   require "actioncable_client/testing"
  module Testing
  end
end
