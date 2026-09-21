# frozen_string_literal: true

require "test_helper"

class ProtocolV1JSONTest < Minitest::Test
  Command = ActionCableClient::Protocol::Command

  # What a decoded frame carries when the frame said nothing about it.
  NOTHING = { kind: nil, identifier: nil, message: "", reason: nil, reconnect: false }.freeze

  def setup
    @protocol = ActionCableClient::Protocol::V1JSON.new
  end

  def test_v1_json_subprotocol
    assert_equal "actioncable-v1-json", @protocol.subprotocol
  end

  def test_v1_json_encode
    {
      Command.new(name: :subscribe, identifier: %({"channel":"RoomChannel"})) =>
        %({"command":"subscribe","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}),
      Command.new(name: :unsubscribe, identifier: %({"channel":"RoomChannel"})) =>
        %({"command":"unsubscribe","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}),
      Command.new(name: :message, identifier: %({"channel":"RoomChannel"}), data: %({"action":"speak"})) =>
        %({"command":"message","identifier":"{\\"channel\\":\\"RoomChannel\\"}","data":"{\\"action\\":\\"speak\\"}"})
    }.each do |command, encoded|
      assert_equal encoded, @protocol.encode(command)
    end
  end

  def test_v1_json_decode
    [
      [ %({"type":"welcome"}), { kind: :welcome } ],
      [ %({"type":"ping","message":1755400000}), { kind: :ping, message: "1755400000" } ],
      [ %({"type":"disconnect","reason":"server_restart","reconnect":true}),
        { kind: :disconnect, reason: "server_restart", reconnect: true } ],
      [ %({"type":"confirm_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}),
        { kind: :confirmation, identifier: %({"channel":"RoomChannel"}) } ],
      [ %({"type":"reject_subscription","identifier":"{\\"channel\\":\\"RoomChannel\\"}"}),
        { kind: :rejection, identifier: %({"channel":"RoomChannel"}) } ],
      [ %({"identifier":"{\\"channel\\":\\"RoomChannel\\"}","message":{"body":"Hello!"}}),
        { kind: :message, identifier: %({"channel":"RoomChannel"}), message: %({"body":"Hello!"}) } ],
      [ %({"type":"something_new","identifier":"x","message":"anything"}),
        { kind: :message, identifier: "x", message: %("anything") } ]
    ].each do |payload, expected|
      incoming = @protocol.decode(payload)
      decoded = { kind: incoming.kind, identifier: incoming.identifier, message: incoming.message.to_s,
                  reason: incoming.reason, reconnect: incoming.reconnect? }

      assert_equal NOTHING.merge(expected), decoded, payload
    end
  end

  def test_v1_json_decode_garbage
    assert_raises(ActionCableClient::Error) { @protocol.decode("not json") }
  end
end
