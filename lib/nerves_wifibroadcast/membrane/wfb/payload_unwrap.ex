defmodule NervesWifibroadcast.Membrane.WFB.PayloadUnwrap do
  @moduledoc """
  Extracts packet payloads from ordered WFB source shards.

  The input payload is expected to be `wpacket_hdr_t <> payload`. The emitted
  buffers contain only the unwrapped packet payload, matching what `rx.cpp`
  forwards over UDP.
  """

  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.RemoteStream
  alias NervesWifibroadcast.Membrane.WFB.OrderedShardStreamFormat

  @fec_only_flag 0x01
  @max_payload_size 3993

  def_input_pad(:input,
    availability: :always,
    accepted_format: OrderedShardStreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: RemoteStream,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, _opts) do
    state = %{
      counters: %{
        fec_only_drops: 0,
        oversized_payload_drops: 0,
        passed_packets: 0,
        short_header_drops: 0,
        truncated_payload_drops: 0
      }
    }

    {[], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state), do: {[], state}

  @impl true
  def handle_event(_pad, event, _ctx, state), do: {[forward: event], state}

  @impl true
  def handle_stream_format(:input, %OrderedShardStreamFormat{}, _ctx, state) do
    {[stream_format: {:output, %RemoteStream{type: :packetized, content_format: nil}}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state), do: {[end_of_stream: :output], state}

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    case unwrap_buffer(buffer) do
      {:ok, %Buffer{} = output_buffer} ->
        {[buffer: {:output, output_buffer}], increment_counter(state, :passed_packets)}

      {:error, :fec_only} ->
        {[], increment_counter(state, :fec_only_drops)}

      {:error, :oversized_payload} ->
        {[], increment_counter(state, :oversized_payload_drops)}

      {:error, :short_header} ->
        {[], increment_counter(state, :short_header_drops)}

      {:error, :truncated_payload} ->
        {[], increment_counter(state, :truncated_payload_drops)}
    end
  end

  defp unwrap_buffer(%Buffer{payload: <<flags, packet_size::big-16, rest::binary>>} = buffer) do
    cond do
      packet_size > @max_payload_size ->
        {:error, :oversized_payload}

      packet_size > byte_size(rest) ->
        {:error, :truncated_payload}

      (flags &&& @fec_only_flag) != 0 ->
        {:error, :fec_only}

      true ->
        payload = binary_part(rest, 0, packet_size)
        metadata = put_wfb_fields(buffer.metadata, flags, packet_size)
        {:ok, %Buffer{buffer | payload: payload, metadata: metadata}}
    end
  end

  defp unwrap_buffer(%Buffer{}), do: {:error, :short_header}

  defp put_wfb_fields(metadata, flags, packet_size) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    Map.update(metadata, :wfb, %{flags: flags, packet_size: packet_size}, fn wfb ->
      Map.merge(wfb, %{flags: flags, packet_size: packet_size})
    end)
  end

  defp increment_counter(state, counter) do
    update_in(state.counters[counter], &((&1 || 0) + 1))
  end
end
