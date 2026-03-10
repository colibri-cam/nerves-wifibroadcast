defmodule Wifibroadcast.Membrane.WFB.PayloadWrap do
  @moduledoc """
  Wraps packetized payloads into `wpacket_hdr_t <> payload` shards for TX.
  """

  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.RemoteStream
  alias Wifibroadcast.Membrane.WFB.WrappedPayloadStreamFormat

  @fec_only_flag 0x01
  @max_payload_size 3993
  @default_link_id 7_669_206

  def_options(
    interfaces: [spec: [String.t()], default: []],
    link_id: [spec: non_neg_integer(), default: @default_link_id],
    radio_port: [spec: non_neg_integer() | nil, default: nil]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: RemoteStream,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: WrappedPayloadStreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    radio_port = validate_radio_port!(opts.radio_port)

    state = %{
      counters: %{
        oversized_payload_drops: 0,
        passed_packets: 0
      },
      output_stream_format: %WrappedPayloadStreamFormat{
        channel_id: make_channel_id(opts.link_id, radio_port),
        interfaces: opts.interfaces,
        link_id: opts.link_id,
        radio_port: radio_port
      }
    }

    {[], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state), do: {[], state}

  @impl true
  def handle_event(_pad, event, _ctx, state), do: {[forward: event], state}

  @impl true
  def handle_stream_format(:input, %RemoteStream{}, _ctx, state) do
    {[stream_format: {:output, state.output_stream_format}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state), do: {[end_of_stream: :output], state}

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    payload_size = byte_size(buffer.payload)

    if payload_size > @max_payload_size do
      {[], increment_counter(state, :oversized_payload_drops)}
    else
      flags = extract_flags(buffer.metadata)

      output_buffer =
        %Buffer{buffer | payload: <<flags, payload_size::big-16, buffer.payload::binary>>}
        |> put_wfb_fields(flags, payload_size, state.output_stream_format)

      {[buffer: {:output, output_buffer}], increment_counter(state, :passed_packets)}
    end
  end

  defp put_wfb_fields(%Buffer{} = buffer, flags, packet_size, stream_format) do
    wfb_fields = %{
      channel_id: stream_format.channel_id,
      flags: flags,
      link_id: stream_format.link_id,
      packet_size: packet_size,
      radio_port: stream_format.radio_port
    }

    metadata =
      normalize_metadata(buffer.metadata)
      |> Map.update(:wfb, wfb_fields, fn wfb ->
        Map.merge(wfb, wfb_fields)
      end)

    %Buffer{buffer | metadata: metadata}
  end

  defp extract_flags(metadata) do
    metadata
    |> normalize_metadata()
    |> get_in([:wfb, :flags])
    |> case do
      flags when is_integer(flags) and flags >= 0 and flags <= 0xFF -> flags
      true -> @fec_only_flag
      _other -> 0
    end
  end

  defp make_channel_id(link_id, radio_port), do: (link_id <<< 8) + radio_port

  defp validate_radio_port!(radio_port)
       when is_integer(radio_port) and radio_port >= 0 and radio_port <= 0xFF,
       do: radio_port

  defp validate_radio_port!(radio_port) do
    raise ArgumentError,
          "expected radio_port to be a non-negative 8-bit integer, got: #{inspect(radio_port)}"
  end

  defp increment_counter(state, counter) do
    update_in(state.counters[counter], &((&1 || 0) + 1))
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
