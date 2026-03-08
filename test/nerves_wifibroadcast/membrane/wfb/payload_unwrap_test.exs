defmodule NervesWifibroadcast.Membrane.WFB.PayloadUnwrapTest do
  use ExUnit.Case, async: true

  alias Membrane.RemoteStream
  alias NervesWifibroadcast.Membrane.WFB.PayloadUnwrap
  alias NervesWifibroadcast.Radiotap
  alias NervesWifibroadcast.TestSupport.WFBFixtures

  @max_payload_size 3993

  test "emits packetized remote stream format" do
    state = payload_unwrap_state()
    stream_format = WFBFixtures.ordered_shard_stream_format()

    assert {[stream_format: {:output, %RemoteStream{} = output_stream_format}], _state} =
             PayloadUnwrap.handle_stream_format(:input, stream_format, %{}, state)

    assert output_stream_format.type == :packetized
    assert output_stream_format.content_format == nil
  end

  test "unwraps payload and preserves metadata" do
    radiotap = %Radiotap{channel_freq: 5_805}
    state = payload_unwrap_state()
    stream_format = WFBFixtures.ordered_shard_stream_format(fec_k: 8, fec_n: 12)

    {[_stream_format], state} =
      PayloadUnwrap.handle_stream_format(:input, stream_format, %{}, state)

    buffer =
      WFBFixtures.ordered_shard_buffer(<<0x00, 0x00, 0x03, "abc", 0x00, 0x00>>, 22, 4,
        fec_k: 8,
        fec_n: 12,
        ordered_seq: 180,
        radiotap: radiotap
      )

    assert {[buffer: {:output, output_buffer}], state} =
             PayloadUnwrap.handle_buffer(:input, buffer, %{}, state)

    assert output_buffer.payload == "abc"
    assert output_buffer.metadata.radio.radiotap == radiotap
    assert output_buffer.metadata.wfb.block_idx == 22
    assert output_buffer.metadata.wfb.fragment_idx == 4
    assert output_buffer.metadata.wfb.ordered_seq == 180
    assert output_buffer.metadata.wfb.flags == 0
    assert output_buffer.metadata.wfb.packet_size == 3
    assert state.counters.passed_packets == 1
  end

  test "drops fec-only shards" do
    state = payload_unwrap_state()

    assert {[], state} =
             PayloadUnwrap.handle_buffer(
               :input,
               WFBFixtures.ordered_shard_buffer(<<0x01, 0x00, 0x03, "abc">>, 10, 1),
               %{},
               state
             )

    assert state.counters.fec_only_drops == 1
  end

  test "drops too-short shard payloads" do
    state = payload_unwrap_state()

    assert {[], state} =
             PayloadUnwrap.handle_buffer(
               :input,
               WFBFixtures.ordered_shard_buffer(<<0x00, 0x01>>, 10, 1),
               %{},
               state
             )

    assert state.counters.short_header_drops == 1
  end

  test "drops shards with truncated payloads" do
    state = payload_unwrap_state()

    assert {[], state} =
             PayloadUnwrap.handle_buffer(
               :input,
               WFBFixtures.ordered_shard_buffer(<<0x00, 0x00, 0x04, "abc">>, 10, 1),
               %{},
               state
             )

    assert state.counters.truncated_payload_drops == 1
  end

  test "drops shards whose payload exceeds the native max packet size" do
    payload = :binary.copy(<<0x00>>, @max_payload_size + 1)
    state = payload_unwrap_state()

    assert {[], state} =
             PayloadUnwrap.handle_buffer(
               :input,
               WFBFixtures.ordered_shard_buffer(
                 <<0x00, @max_payload_size + 1::big-16, payload::binary>>,
                 10,
                 1
               ),
               %{},
               state
             )

    assert state.counters.oversized_payload_drops == 1
  end

  test "accepts zero-length payloads" do
    state = payload_unwrap_state()

    assert {[buffer: {:output, output_buffer}], state} =
             PayloadUnwrap.handle_buffer(
               :input,
               WFBFixtures.ordered_shard_buffer(<<0x00, 0x00, 0x00>>, 10, 1),
               %{},
               state
             )

    assert output_buffer.payload == <<>>
    assert output_buffer.metadata.wfb.packet_size == 0
    assert state.counters.passed_packets == 1
  end

  defp payload_unwrap_state do
    {[], state} = PayloadUnwrap.handle_init(%{}, %{})
    state
  end
end
