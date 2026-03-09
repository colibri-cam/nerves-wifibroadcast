defmodule NervesWifibroadcast.Membrane.WFB.FecDecoder do
  @moduledoc """
  Preferred name for the RX FEC/session decoder stage.

  This module delegates to `NervesWifibroadcast.Membrane.WFB.ReorderFec` so
  existing code can keep using the old name while new code adopts the clearer
  `FecDecoder` terminology.
  """

  use Membrane.Filter

  alias NervesWifibroadcast.Membrane.WFB.OrderedShardStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.ReorderFec
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat

  def_options(
    min_epoch: [spec: non_neg_integer(), default: 0],
    ring_size: [spec: pos_integer(), default: 40],
    stats_interval_ms: [spec: pos_integer() | nil, default: nil]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: OrderedShardStreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(ctx, opts), do: ReorderFec.handle_init(ctx, opts)

  @impl true
  def handle_start_of_stream(pad, ctx, state),
    do: ReorderFec.handle_start_of_stream(pad, ctx, state)

  @impl true
  def handle_event(pad, event, ctx, state), do: ReorderFec.handle_event(pad, event, ctx, state)

  @impl true
  def handle_playing(ctx, state), do: ReorderFec.handle_playing(ctx, state)

  @impl true
  def handle_stream_format(pad, stream_format, ctx, state),
    do: ReorderFec.handle_stream_format(pad, stream_format, ctx, state)

  @impl true
  def handle_end_of_stream(pad, ctx, state), do: ReorderFec.handle_end_of_stream(pad, ctx, state)

  @impl true
  def handle_tick(timer_id, ctx, state), do: ReorderFec.handle_tick(timer_id, ctx, state)

  @impl true
  def handle_buffer(pad, buffer, ctx, state),
    do: ReorderFec.handle_buffer(pad, buffer, ctx, state)
end
