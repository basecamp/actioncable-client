# frozen_string_literal: true

require "test_helper"

class IdentifierTest < Minitest::Test
  Identifier = ActionCableClient::Identifier

  def test_identifier_key
    {
      Identifier.new("RoomChannel") => %({"channel":"RoomChannel"}),
      Identifier.new("RoomChannel", id: 42) => %({"channel":"RoomChannel","id":42}),
      Identifier.new("RoomChannel", id: 42, since: "yesterday") =>
        %({"channel":"RoomChannel","id":42,"since":"yesterday"})
    }.each do |identifier, key|
      assert_equal key, identifier.key
      assert_equal key, identifier.to_s, "to_s should be the key"
    end
  end

  def test_identifier_key_refuses_params_it_cannot_encode
    identifier = Identifier.new("RoomChannel", id: Float::NAN)

    assert_raises(ActionCableClient::Error) { identifier.key }
  end
end
