defmodule Wifibroadcast.Membrane.WFB.FecEncoderTest do
  use ExUnit.Case, async: true

  alias Wifibroadcast.Membrane.WFB.FecDecoder
  alias Wifibroadcast.Membrane.WFB.FecEncoder
  alias Wifibroadcast.Membrane.WFB.PayloadUnwrap
  alias Wifibroadcast.Membrane.WFB.PayloadWrap
  alias Wifibroadcast.Membrane.WFB.StreamFormat
  alias Wifibroadcast.TestSupport.WFBFixtures
  alias Wifibroadcast.WFB.Session

  test "emits packet stream format on wrapped input stream" do
    state = fec_encoder_state(k: 2, n: 3, session_repeat_count: 1)

    assert {[stream_format: {:output, %StreamFormat{} = output_stream_format}], state} =
             FecEncoder.handle_stream_format(
               :input,
               WFBFixtures.wrapped_payload_stream_format(link_id: 0x7505D6, radio_port: 4),
               %{},
               state
             )

    assert output_stream_format.channel_id == WFBFixtures.channel_id(0x7505D6, 4)
    assert output_stream_format.link_id == 0x7505D6
    assert output_stream_format.radio_port == 4
    assert output_stream_format.encrypted? == false
    assert state.current_session.fec_k == 2
    assert state.current_session.fec_n == 3
    assert state.session_pending == true
  end

  test "emits session packets before the first source fragment" do
    state = started_encoder_state(k: 2, n: 3, session_repeat_count: 1)
    input_buffer = WFBFixtures.wrapped_payload_buffer("alpha")

    {actions, _state} = FecEncoder.handle_buffer(:input, input_buffer, %{}, state)

    assert [buffer: {:output, session_buffer}, buffer: {:output, source_buffer}] = actions

    assert {:ok, session} = Session.parse(session_buffer.payload)
    assert session.channel_id == WFBFixtures.channel_id()
    assert session.fec_k == 2
    assert session.fec_n == 3
    assert source_buffer.payload == WFBFixtures.source_shard("alpha")
    assert source_buffer.metadata.wfb.block_idx == 0
    assert source_buffer.metadata.wfb.fragment_idx == 0
    assert source_buffer.metadata.wfb.data_nonce == 0
    assert source_buffer.metadata.wfb.shard_role == :source
    assert length(actions) == 2
  end

  test "emits parity shards after a block reaches k source packets" do
    state = started_encoder_state(k: 2, n: 3, session_repeat_count: 1)
    source_a = WFBFixtures.wrapped_payload_buffer("alpha")
    source_b = WFBFixtures.wrapped_payload_buffer("beta")

    {_, state} = FecEncoder.handle_buffer(:input, source_a, %{}, state)

    assert {[buffer: {:output, source_buffer}, buffer: {:output, parity_buffer}], state} =
             FecEncoder.handle_buffer(:input, source_b, %{}, state)

    %{parity_shards: [expected_parity]} =
      WFBFixtures.encode_block([source_a.payload, source_b.payload], 2, 3)

    assert source_buffer.payload == source_b.payload
    assert source_buffer.metadata.wfb.fragment_idx == 1
    assert source_buffer.metadata.wfb.shard_role == :source
    assert parity_buffer.payload == expected_parity
    assert parity_buffer.metadata.wfb.block_idx == 0
    assert parity_buffer.metadata.wfb.fragment_idx == 2
    assert parity_buffer.metadata.wfb.data_nonce == 2
    assert parity_buffer.metadata.wfb.shard_role == :parity
    assert state.block_idx == 1
    assert state.next_fragment_idx == 0
    assert state.counters.emitted_parity_fragments == 1
  end

  test "closes a partial block on timeout with fec-only source shards" do
    state = started_encoder_state(k: 2, n: 3, session_repeat_count: 1, fec_timeout_ms: 1_000)
    source = WFBFixtures.wrapped_payload_buffer("alpha")

    assert {[start_timer: {:fec_timeout, _interval}], state} =
             FecEncoder.handle_playing(%{}, state)

    {_, state} = FecEncoder.handle_buffer(:input, source, %{}, state)
    state = %{state | fec_close_at_ms: System.monotonic_time(:millisecond) - 1}

    assert {[buffer: {:output, fec_only_buffer}, buffer: {:output, parity_buffer}], state} =
             FecEncoder.handle_tick(:fec_timeout, %{}, state)

    %{parity_shards: [expected_parity]} =
      WFBFixtures.encode_block([source.payload, <<0x01, 0x00, 0x00>>], 2, 3)

    assert fec_only_buffer.payload == <<0x01, 0x00, 0x00>>
    assert fec_only_buffer.metadata.wfb.fragment_idx == 1
    assert fec_only_buffer.metadata.wfb.shard_role == :source
    assert parity_buffer.payload == expected_parity
    assert parity_buffer.metadata.wfb.fragment_idx == 2
    assert state.block_idx == 1
    assert state.next_fragment_idx == 0
    assert state.counters.emitted_fec_only_fragments == 1
    assert state.counters.fec_timeouts == 1
  end

  test "applies set_fec by closing the current block and announcing a new session" do
    state = started_encoder_state(k: 2, n: 3)
    source = WFBFixtures.wrapped_payload_buffer("alpha")

    {_, state} = FecEncoder.handle_buffer(:input, source, %{}, state)

    assert {actions, state} =
             FecEncoder.handle_parent_notification({:set_fec, %{k: 4, n: 6}}, %{}, state)

    assert [
             buffer: {:output, fec_only_buffer},
             buffer: {:output, parity_a},
             buffer: {:output, session_buffer},
             buffer: {:output, session_buffer_2},
             buffer: {:output, session_buffer_3},
             notify_parent: {:wfb_fec_config_applied, notification}
           ] = actions

    assert fec_only_buffer.payload == <<0x01, 0x00, 0x00>>
    assert parity_a.metadata.wfb.shard_role == :parity
    assert {:ok, session} = Session.parse(session_buffer.payload)
    assert session == state.current_session
    assert {:ok, ^session} = Session.parse(session_buffer_2.payload)
    assert {:ok, ^session} = Session.parse(session_buffer_3.payload)
    assert session.fec_k == 4
    assert session.fec_n == 6
    assert notification.fec_k == 4
    assert notification.fec_n == 6
    assert state.block_idx == 0
    assert state.next_fragment_idx == 0
    assert state.k == 4
    assert state.n == 6
    assert state.session_pending == false
    assert state.counters.fec_updates == 1
  end

  test "roundtrips a full block through the RX decoder and payload unwrap" do
    {wrap_state, encoder_state, decoder_state, unwrap_state} = start_roundtrip(k: 2, n: 3)

    {outputs, _states} =
      ["one", "two"]
      |> Enum.reduce({[], {wrap_state, encoder_state, decoder_state, unwrap_state}}, fn payload,
                                                                                        {outputs,
                                                                                         states} ->
        {new_outputs, states} = roundtrip_payload(payload, states)
        {outputs ++ new_outputs, states}
      end)

    assert outputs == ["one", "two"]
  end

  test "recovers a dropped source fragment through parity" do
    {wrap_state, encoder_state, decoder_state, unwrap_state} = start_roundtrip(k: 2, n: 3)

    {_, {wrap_state, encoder_state, decoder_state, unwrap_state}} =
      roundtrip_payload(
        "first",
        {wrap_state, encoder_state, decoder_state, unwrap_state},
        fn buffer ->
          get_in(buffer.metadata, [:wfb, :packet_type]) == :data and
            get_in(buffer.metadata, [:wfb, :fragment_idx]) == 0
        end
      )

    {outputs, _states} =
      roundtrip_payload("second", {wrap_state, encoder_state, decoder_state, unwrap_state})

    assert outputs == ["first", "second"]
  end

  defp start_roundtrip(opts) do
    wrap_state = payload_wrap_state(radio_port: 4)
    encoder_state = fec_encoder_state(Keyword.merge([session_repeat_count: 1], opts))
    decoder_state = fec_decoder_state()
    unwrap_state = payload_unwrap_state()

    {[stream_format: {:output, wrapped_stream_format}], wrap_state} =
      PayloadWrap.handle_stream_format(
        :input,
        WFBFixtures.remote_stream_format(),
        %{},
        wrap_state
      )

    {[stream_format: {:output, packet_stream_format}], encoder_state} =
      FecEncoder.handle_stream_format(:input, wrapped_stream_format, %{}, encoder_state)

    {[], decoder_state} =
      FecDecoder.handle_stream_format(:input, packet_stream_format, %{}, decoder_state)

    {wrap_state, encoder_state, decoder_state, unwrap_state}
  end

  defp roundtrip_payload(payload, states, drop_fun \\ fn _buffer -> false end) do
    {wrap_state, encoder_state, decoder_state, unwrap_state} = states

    {[buffer: {:output, wrapped_buffer}], wrap_state} =
      PayloadWrap.handle_buffer(
        :input,
        WFBFixtures.remote_packet_buffer(payload),
        %{},
        wrap_state
      )

    {encoder_actions, encoder_state} =
      FecEncoder.handle_buffer(:input, wrapped_buffer, %{}, encoder_state)

    {outputs, {decoder_state, unwrap_state}} =
      Enum.reduce(encoder_actions, {[], {decoder_state, unwrap_state}}, fn
        {:buffer, {:output, buffer}}, {outputs, states} ->
          if drop_fun.(buffer) do
            {outputs, states}
          else
            route_to_rx(buffer, outputs, states)
          end

        _other, acc ->
          acc
      end)

    {outputs, {wrap_state, encoder_state, decoder_state, unwrap_state}}
  end

  defp route_to_rx(buffer, outputs, {decoder_state, unwrap_state}) do
    {decoder_actions, decoder_state} =
      FecDecoder.handle_buffer(:input, buffer, %{}, decoder_state)

    Enum.reduce(decoder_actions, {outputs, {decoder_state, unwrap_state}}, fn
      {:stream_format, {:output, ordered_stream_format}},
      {outputs, {decoder_state, unwrap_state}} ->
        {[_stream_format], unwrap_state} =
          PayloadUnwrap.handle_stream_format(:input, ordered_stream_format, %{}, unwrap_state)

        {outputs, {decoder_state, unwrap_state}}

      {:buffer, {:output, ordered_buffer}}, {outputs, {decoder_state, unwrap_state}} ->
        {[buffer: {:output, output_buffer}], unwrap_state} =
          PayloadUnwrap.handle_buffer(:input, ordered_buffer, %{}, unwrap_state)

        {outputs ++ [output_buffer.payload], {decoder_state, unwrap_state}}

      _other, acc ->
        acc
    end)
  end

  defp started_encoder_state(opts) do
    state = fec_encoder_state(opts)

    {[stream_format: {:output, _packet_stream_format}], state} =
      FecEncoder.handle_stream_format(
        :input,
        WFBFixtures.wrapped_payload_stream_format(),
        %{},
        state
      )

    state
  end

  defp fec_encoder_state(opts) do
    {[], state} = FecEncoder.handle_init(%{}, struct(FecEncoder, opts))
    state
  end

  defp payload_wrap_state(opts) do
    {[], state} = PayloadWrap.handle_init(%{}, struct(PayloadWrap, opts))
    state
  end

  defp fec_decoder_state do
    {[], state} = FecDecoder.handle_init(%{}, struct(FecDecoder, []))
    state
  end

  defp payload_unwrap_state do
    {[], state} = PayloadUnwrap.handle_init(%{}, %{})
    state
  end
end
