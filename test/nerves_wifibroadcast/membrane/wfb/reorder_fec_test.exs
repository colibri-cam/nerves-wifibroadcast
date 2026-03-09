defmodule NervesWifibroadcast.Membrane.WFB.ReorderFecTest do
  use ExUnit.Case, async: true

  alias NervesWifibroadcast.Membrane.WFB.OrderedShardStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.ReorderFec
  alias NervesWifibroadcast.TestSupport.WFBFixtures

  test "emits in-order source shards immediately for the front block" do
    stream_format = WFBFixtures.decrypted_stream_format(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("one")
    shard1 = WFBFixtures.source_shard("two")
    state = reorder_state()

    assert {[stream_format: {:output, %OrderedShardStreamFormat{}}], state} =
             ReorderFec.handle_stream_format(:input, stream_format, %{}, state)

    assert {[buffer: {:output, buffer0}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0),
               %{},
               state
             )

    assert buffer0.payload == shard0
    assert buffer0.metadata.wfb.ordered_seq == 20
    refute Map.has_key?(buffer0.metadata, :recovery)

    assert {[buffer: {:output, buffer1}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard1, 10, 1),
               %{},
               state
             )

    assert buffer1.payload == shard1
    assert buffer1.metadata.wfb.ordered_seq == 21
    assert state.counters.emitted_source_shards == 2
  end

  test "reorders out-of-order source shards" do
    stream_format = WFBFixtures.decrypted_stream_format(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("one")
    shard1 = WFBFixtures.source_shard("two")
    state = reorder_state()
    {[_stream_format], state} = ReorderFec.handle_stream_format(:input, stream_format, %{}, state)

    assert {[], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard1, 10, 1),
               %{},
               state
             )

    assert {actions, state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0),
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
    stream_format = WFBFixtures.decrypted_stream_format(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("source-a")
    shard1 = WFBFixtures.source_shard("source-b")
    %{parity_shards: [parity]} = WFBFixtures.encode_block([shard0, shard1], 2, 3)
    state = reorder_state()
    {[_stream_format], state} = ReorderFec.handle_stream_format(:input, stream_format, %{}, state)

    assert {[buffer: {:output, buffer0}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 22, 0),
               %{},
               state
             )

    assert buffer0.payload == shard0

    assert {[buffer: {:output, recovered_buffer}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(parity, 22, 2),
               %{},
               state
             )

    assert recovered_buffer.payload == shard1
    assert recovered_buffer.metadata.wfb.ordered_seq == 45
    assert recovered_buffer.metadata.recovery.receiver_mask == 1
    assert state.counters.fec_recovered_fragments == 1
  end

  test "tracks recovery provenance across multiple receiver indexes" do
    stream_format =
      WFBFixtures.decrypted_stream_format(fec_k: 2, fec_n: 3, interfaces: ["wlan0", "wlan1"])

    shard0 = WFBFixtures.source_shard("source-a")
    shard1 = WFBFixtures.source_shard("source-b")
    %{parity_shards: [parity]} = WFBFixtures.encode_block([shard0, shard1], 2, 3)
    state = reorder_state()
    {[_stream_format], state} = ReorderFec.handle_stream_format(:input, stream_format, %{}, state)

    assert {[buffer: {:output, _buffer0}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 33, 0, receiver_idx: 0),
               %{},
               state
             )

    assert {[buffer: {:output, recovered_buffer}], _state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(parity, 33, 2, receiver_idx: 1),
               %{},
               state
             )

    assert recovered_buffer.payload == shard1
    assert recovered_buffer.metadata.recovery.receiver_mask == 0b11
  end

  test "flushes older unfinished blocks when a newer block becomes decodable" do
    stream_format = WFBFixtures.decrypted_stream_format(fec_k: 2, fec_n: 3)
    old_shard0 = WFBFixtures.source_shard("old-0")
    new_shard0 = WFBFixtures.source_shard("new-0")
    new_shard1 = WFBFixtures.source_shard("new-1")
    %{parity_shards: [new_parity]} = WFBFixtures.encode_block([new_shard0, new_shard1], 2, 3)
    state = reorder_state()
    {[_stream_format], state} = ReorderFec.handle_stream_format(:input, stream_format, %{}, state)

    assert {[buffer: {:output, _old_buffer0}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(old_shard0, 100, 0),
               %{},
               state
             )

    assert {[], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(new_shard0, 101, 0),
               %{},
               state
             )

    assert {actions, state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(new_parity, 101, 2),
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
    stream_format = WFBFixtures.decrypted_stream_format(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("one")
    state = reorder_state()
    {[_stream_format], state} = ReorderFec.handle_stream_format(:input, stream_format, %{}, state)

    assert {[buffer: {:output, _buffer0}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0),
               %{},
               state
             )

    assert {[], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0),
               %{},
               state
             )

    assert state.counters.duplicate_fragments == 1
  end

  test "emits opt-in periodic stats notifications" do
    stream_format = WFBFixtures.decrypted_stream_format(fec_k: 2, fec_n: 3)
    shard0 = WFBFixtures.source_shard("one")
    state = reorder_state(stats_interval_ms: 1_000)

    assert {[start_timer: {:stats, _interval}], state} = ReorderFec.handle_playing(%{}, state)

    assert {[stream_format: {:output, %OrderedShardStreamFormat{}}], state} =
             ReorderFec.handle_stream_format(:input, stream_format, %{}, state)

    assert {[buffer: {:output, _buffer0}], state} =
             ReorderFec.handle_buffer(
               :input,
               WFBFixtures.decrypted_buffer(shard0, 10, 0),
               %{},
               state
             )

    assert {[notify_parent: {:wfb_reorder_fec_stats, stats}], state} =
             ReorderFec.handle_tick(:stats, %{}, state)

    assert stats.channel_id == stream_format.channel_id
    assert stats.epoch == stream_format.epoch
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
             ReorderFec.handle_tick(:stats, %{}, state)

    assert next_stats.counters.emitted_source_shards == 0
    assert next_stats.counters.lost_source_shards == 0
    assert next_stats.blocks_in_ring == 1
  end

  defp reorder_state(opts \\ []) do
    {[], state} = ReorderFec.handle_init(%{}, struct(ReorderFec, opts))
    state
  end
end
