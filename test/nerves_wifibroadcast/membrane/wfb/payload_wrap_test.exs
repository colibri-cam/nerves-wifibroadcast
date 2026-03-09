defmodule NervesWifibroadcast.Membrane.WFB.PayloadWrapTest do
  use ExUnit.Case, async: true

  alias NervesWifibroadcast.Membrane.WFB.PayloadUnwrap
  alias NervesWifibroadcast.Membrane.WFB.PayloadWrap
  alias NervesWifibroadcast.Membrane.WFB.WrappedPayloadStreamFormat
  alias NervesWifibroadcast.Radiotap
  alias NervesWifibroadcast.TestSupport.WFBFixtures

  @max_payload_size 3993

  test "emits wrapped payload stream format" do
    state = payload_wrap_state(link_id: 0x7505D6, radio_port: 4, interfaces: ["wlan0"])

    assert {[stream_format: {:output, %WrappedPayloadStreamFormat{} = output_stream_format}],
            _state} =
             PayloadWrap.handle_stream_format(
               :input,
               WFBFixtures.remote_stream_format(),
               %{},
               state
             )

    assert output_stream_format.channel_id == WFBFixtures.channel_id(0x7505D6, 4)
    assert output_stream_format.link_id == 0x7505D6
    assert output_stream_format.radio_port == 4
    assert output_stream_format.interfaces == ["wlan0"]
  end

  test "wraps payloads and preserves metadata" do
    radiotap = %Radiotap{channel_freq: 5_805}
    state = payload_wrap_state(link_id: 0x7505D6, radio_port: 4)

    {[_stream_format], state} =
      PayloadWrap.handle_stream_format(:input, WFBFixtures.remote_stream_format(), %{}, state)

    buffer =
      WFBFixtures.remote_packet_buffer("abc",
        metadata: %{radio: %{radiotap: radiotap}, user: %{stream: :video}}
      )

    assert {[buffer: {:output, output_buffer}], state} =
             PayloadWrap.handle_buffer(:input, buffer, %{}, state)

    assert output_buffer.payload == <<0x00, 0x00, 0x03, "abc">>
    assert output_buffer.metadata.radio.radiotap == radiotap
    assert output_buffer.metadata.user == %{stream: :video}
    assert output_buffer.metadata.wfb.flags == 0
    assert output_buffer.metadata.wfb.packet_size == 3
    assert output_buffer.metadata.wfb.link_id == 0x7505D6
    assert output_buffer.metadata.wfb.radio_port == 4
    assert state.counters.passed_packets == 1
  end

  test "accepts zero-length payloads" do
    state = payload_wrap_state(radio_port: 4)

    assert {[buffer: {:output, output_buffer}], state} =
             PayloadWrap.handle_buffer(:input, WFBFixtures.remote_packet_buffer(<<>>), %{}, state)

    assert output_buffer.payload == <<0x00, 0x00, 0x00>>
    assert output_buffer.metadata.wfb.packet_size == 0
    assert state.counters.passed_packets == 1
  end

  test "drops payloads larger than the native max packet size" do
    state = payload_wrap_state(radio_port: 4)
    payload = :binary.copy(<<0xAA>>, @max_payload_size + 1)

    assert {[], state} =
             PayloadWrap.handle_buffer(
               :input,
               WFBFixtures.remote_packet_buffer(payload),
               %{},
               state
             )

    assert state.counters.oversized_payload_drops == 1
  end

  test "roundtrips with payload unwrap" do
    payload_wrap_state = payload_wrap_state(radio_port: 4)
    payload_unwrap_state = payload_unwrap_state()

    {[_wrapped_stream_format], payload_wrap_state} =
      PayloadWrap.handle_stream_format(
        :input,
        WFBFixtures.remote_stream_format(),
        %{},
        payload_wrap_state
      )

    {[_remote_stream_format], payload_unwrap_state} =
      PayloadUnwrap.handle_stream_format(
        :input,
        WFBFixtures.ordered_shard_stream_format(fec_k: 2, fec_n: 3),
        %{},
        payload_unwrap_state
      )

    source_buffer =
      WFBFixtures.remote_packet_buffer("payload", metadata: %{radio: %{capture_ts: 123}})

    assert {[buffer: {:output, wrapped_buffer}], payload_wrap_state} =
             PayloadWrap.handle_buffer(:input, source_buffer, %{}, payload_wrap_state)

    ordered_buffer = WFBFixtures.ordered_shard_buffer(wrapped_buffer.payload, 10, 0)

    ordered_buffer = %{
      ordered_buffer
      | metadata: Map.put(ordered_buffer.metadata, :radio, wrapped_buffer.metadata.radio)
    }

    assert {[buffer: {:output, output_buffer}], payload_unwrap_state} =
             PayloadUnwrap.handle_buffer(:input, ordered_buffer, %{}, payload_unwrap_state)

    assert output_buffer.payload == "payload"
    assert output_buffer.metadata.radio.capture_ts == 123
    assert output_buffer.metadata.wfb.packet_size == 7
    assert payload_wrap_state.counters.passed_packets == 1
    assert payload_unwrap_state.counters.passed_packets == 1
  end

  defp payload_wrap_state(opts) do
    opts = Keyword.put_new(opts, :radio_port, 4)
    {[], state} = PayloadWrap.handle_init(%{}, struct(PayloadWrap, opts))
    state
  end

  defp payload_unwrap_state do
    {[], state} = PayloadUnwrap.handle_init(%{}, %{})
    state
  end
end
