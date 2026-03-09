defmodule NervesWifibroadcast.Membrane.WFB.FecDecoderTest do
  use ExUnit.Case, async: true

  alias NervesWifibroadcast.Membrane.WFB.FecDecoder
  alias NervesWifibroadcast.Membrane.WFB.OrderedShardStreamFormat
  alias NervesWifibroadcast.TestSupport.WFBFixtures

  test "accepts a session and emits the ordered-shard stream format" do
    stream_format = WFBFixtures.ingress_stream_format()
    session = WFBFixtures.session_plaintext(epoch: 7, fec_k: 2, fec_n: 3)
    state = decoder_state()

    {[], state} = FecDecoder.handle_stream_format(:input, stream_format, %{}, state)

    assert {actions, state} =
             FecDecoder.handle_buffer(:input, WFBFixtures.session_buffer(session), %{}, state)

    assert {:stream_format, {:output, %OrderedShardStreamFormat{} = ordered_format}} =
             Enum.find(actions, fn
               {:stream_format, {:output, %OrderedShardStreamFormat{}}} -> true
               _other -> false
             end)

    assert {:notify_parent, {:wfb_session_accepted, notification}} =
             Enum.find(actions, fn
               {:notify_parent, {:wfb_session_accepted, _notification}} -> true
               _other -> false
             end)

    assert ordered_format.channel_id == session.channel_id
    assert ordered_format.epoch == session.epoch
    assert ordered_format.fec_k == session.fec_k
    assert ordered_format.fec_n == session.fec_n
    assert notification.channel_id == session.channel_id
    assert notification.epoch == session.epoch
    assert state.current_session.session_key == session.session_key
  end

  test "emits in-order source shards immediately for the front block" do
    stream_format = WFBFixtures.ingress_stream_format()
    session = WFBFixtures.session_plaintext(epoch: 1, fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("one")
    shard1 = WFBFixtures.source_shard("two")

    state = decoder_state()
    {[], state} = FecDecoder.handle_stream_format(:input, stream_format, %{}, state)
    {_, state} = FecDecoder.handle_buffer(:input, WFBFixtures.session_buffer(session), %{}, state)

    assert {[buffer: {:output, buffer0}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert buffer0.payload == shard0
    assert buffer0.metadata.wfb.ordered_seq == 20
    assert buffer0.metadata.wfb.session_epoch == session.epoch
    refute Map.has_key?(buffer0.metadata, :recovery)

    assert {[buffer: {:output, buffer1}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard1, 10, 1, session_epoch: session.epoch),
               %{},
               state
             )

    assert buffer1.payload == shard1
    assert buffer1.metadata.wfb.ordered_seq == 21
    assert state.counters.emitted_source_shards == 2
  end

  test "reorders out-of-order source shards" do
    {state, session} = started_decoder_state(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("one")
    shard1 = WFBFixtures.source_shard("two")

    assert {[], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard1, 10, 1, session_epoch: session.epoch),
               %{},
               state
             )

    assert {actions, state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert [buffer: {:output, buffer0}, buffer: {:output, buffer1}] = actions
    assert buffer0.payload == shard0
    assert buffer1.payload == shard1
    assert buffer0.metadata.wfb.ordered_seq == 20
    assert buffer1.metadata.wfb.ordered_seq == 21
    assert state.order == []
  end

  test "recovers a missing source shard from parity and emits only source shards" do
    {state, session} = started_decoder_state(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("source-a")
    shard1 = WFBFixtures.source_shard("source-b")
    %{parity_shards: [parity]} = WFBFixtures.encode_block([shard0, shard1], 2, 3)

    assert {[buffer: {:output, buffer0}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 22, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert buffer0.payload == shard0

    assert {[buffer: {:output, recovered_buffer}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(parity, 22, 2, session_epoch: session.epoch),
               %{},
               state
             )

    assert recovered_buffer.payload == shard1
    assert recovered_buffer.metadata.wfb.ordered_seq == 45
    assert recovered_buffer.metadata.recovery.receiver_mask == 1
    assert state.counters.fec_recovered_fragments == 1
  end

  test "tracks recovery provenance across multiple receiver indexes" do
    stream_format = WFBFixtures.ingress_stream_format(interfaces: ["wlan0", "wlan1"])
    session = WFBFixtures.session_plaintext(epoch: 1, fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("source-a")
    shard1 = WFBFixtures.source_shard("source-b")
    %{parity_shards: [parity]} = WFBFixtures.encode_block([shard0, shard1], 2, 3)

    state = decoder_state()
    {[], state} = FecDecoder.handle_stream_format(:input, stream_format, %{}, state)

    {_, state} =
      FecDecoder.handle_buffer(
        :input,
        WFBFixtures.session_buffer(session, interfaces: ["wlan0", "wlan1"]),
        %{},
        state
      )

    assert {[buffer: {:output, _buffer0}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 33, 0,
                 receiver_idx: 0,
                 session_epoch: session.epoch
               ),
               %{},
               state
             )

    assert {[buffer: {:output, recovered_buffer}], _state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(parity, 33, 2,
                 receiver_idx: 1,
                 session_epoch: session.epoch
               ),
               %{},
               state
             )

    assert recovered_buffer.payload == shard1
    assert recovered_buffer.metadata.recovery.receiver_mask == 0b11
  end

  test "flushes older unfinished blocks when a newer block becomes decodable" do
    {state, session} = started_decoder_state(fec_k: 2, fec_n: 3)
    old_shard0 = WFBFixtures.source_shard("old-0")
    new_shard0 = WFBFixtures.source_shard("new-0")
    new_shard1 = WFBFixtures.source_shard("new-1")
    %{parity_shards: [new_parity]} = WFBFixtures.encode_block([new_shard0, new_shard1], 2, 3)

    assert {[buffer: {:output, _old_buffer0}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(old_shard0, 100, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert {[], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(new_shard0, 101, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert {actions, state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(new_parity, 101, 2, session_epoch: session.epoch),
               %{},
               state
             )

    assert [
             notify_parent: {:wfb_packet_loss, loss_notification},
             buffer: {:output, buffer0},
             buffer: {:output, buffer1}
           ] = actions

    assert loss_notification.lost_count == 1
    assert loss_notification.last_ordered_seq == 200
    assert loss_notification.ordered_seq == 202
    assert loss_notification.block_idx == 101
    assert loss_notification.fragment_idx == 0
    assert buffer0.payload == new_shard0
    assert buffer1.payload == new_shard1
    assert state.counters.lost_source_shards == 1
  end

  test "ignores duplicate fragments" do
    {state, session} = started_decoder_state(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("one")

    assert {[buffer: {:output, _buffer0}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert {[], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert state.counters.duplicate_fragments == 1
  end

  test "emits opt-in periodic stats notifications" do
    session = WFBFixtures.session_plaintext(epoch: 1, fec_k: 2, fec_n: 3)
    stream_format = WFBFixtures.ingress_stream_format()
    shard0 = WFBFixtures.source_shard("one")
    state = decoder_state(stats_interval_ms: 1_000)

    assert {[start_timer: {:stats, _interval}], state} = FecDecoder.handle_playing(%{}, state)
    {[], state} = FecDecoder.handle_stream_format(:input, stream_format, %{}, state)
    {_, state} = FecDecoder.handle_buffer(:input, WFBFixtures.session_buffer(session), %{}, state)

    assert {[buffer: {:output, _buffer0}], state} =
             FecDecoder.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0, session_epoch: session.epoch),
               %{},
               state
             )

    assert {[notify_parent: {:wfb_reorder_fec_stats, stats}], state} =
             FecDecoder.handle_tick(:stats, %{}, state)

    assert stats.channel_id == stream_format.channel_id
    assert stats.epoch == session.epoch
    assert stats.link_id == stream_format.link_id
    assert stats.radio_port == stream_format.radio_port
    assert stats.interfaces == stream_format.interfaces
    assert stats.blocks_in_ring == 1
    assert stats.last_known_block == 10
    assert stats.last_emitted_seq == 20
    assert stats.stats_interval_ms == 1_000
    assert stats.counters.emitted_source_shards == 1
    assert stats.counters.lost_source_shards == 0
    assert stats.counters.fec_recovered_fragments == 0

    assert {[notify_parent: {:wfb_reorder_fec_stats, next_stats}], _state} =
             FecDecoder.handle_tick(:stats, %{}, state)

    assert next_stats.counters.emitted_source_shards == 0
    assert next_stats.counters.lost_source_shards == 0
    assert next_stats.blocks_in_ring == 1
  end

  defp started_decoder_state(opts) do
    stream_format = WFBFixtures.ingress_stream_format(opts)

    session =
      WFBFixtures.session_plaintext(
        epoch: Keyword.get(opts, :epoch, 1),
        fec_k: Keyword.get(opts, :fec_k, 2),
        fec_n: Keyword.get(opts, :fec_n, 3),
        interfaces: Keyword.get(opts, :interfaces, ["wlan0"])
      )

    state = decoder_state(Keyword.take(opts, [:stats_interval_ms, :min_epoch, :ring_size]))
    {[], state} = FecDecoder.handle_stream_format(:input, stream_format, %{}, state)
    {_, state} = FecDecoder.handle_buffer(:input, WFBFixtures.session_buffer(session), %{}, state)
    {state, session}
  end

  defp decoder_state(opts \\ []) do
    {[], state} = FecDecoder.handle_init(%{}, struct(FecDecoder, opts))
    state
  end
end
