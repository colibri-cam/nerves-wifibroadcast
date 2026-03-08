defmodule NervesWifibroadcast.Membrane.WFB.Ingress do
  @moduledoc """
  WFB-specific ingress filter and channel router.

  It consumes 802.11 frames emitted by `Radio.Source`, applies the fixed ingress
  rules used by WFB, extracts `channel_id` from the synthetic MAC header, and
  routes packets to dynamic output pads keyed by `radio_port` for a single
  configured `link_id`.
  """

  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.Pad
  alias NervesWifibroadcast.Membrane.Radio.StreamFormat, as: RadioStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.Radiotap

  @header_size 24
  @fcs_size 4
  @wfb_prefix <<0x57, 0x42>>
  @packet_type_data 0x01
  @packet_type_session 0x02
  @session_nonce_size 24
  @default_link_id 7_669_206

  def_options(
    link_id: [spec: non_neg_integer(), default: @default_link_id],
    radio_port: [spec: non_neg_integer() | nil, default: nil],
    radio_ports: [spec: [non_neg_integer()], default: []],
    drop_bad_fcs?: [spec: boolean(), default: true],
    drop_self_injected?: [spec: boolean(), default: true],
    trim_fcs?: [spec: boolean(), default: true]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: RadioStreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :on_request,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      counters: %{
        bad_fcs_drops: 0,
        invalid_wfb_header_drops: 0,
        passed_packets: 0,
        self_injected_drops: 0,
        short_frame_drops: 0,
        short_wfb_packet_drops: 0,
        unknown_packet_type_drops: 0,
        unknown_radio_port_drops: 0,
        unlinked_radio_port_drops: 0,
        wrong_link_id_drops: 0
      },
      drop_bad_fcs?: opts.drop_bad_fcs?,
      drop_self_injected?: opts.drop_self_injected?,
      enabled_radio_ports: normalize_initial_radio_ports!(opts.radio_ports, opts.radio_port),
      input_end_of_stream?: false,
      input_stream_format: nil,
      link_id: validate_link_id!(opts.link_id),
      output_pads: %{},
      trim_fcs?: opts.trim_fcs?
    }

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, radio_port) = pad, _ctx, state) do
    validate_radio_port!(radio_port)

    next_state = put_in(state.output_pads[radio_port], pad)

    actions =
      maybe_output_stream_format(next_state.input_stream_format, pad, state.link_id, radio_port) ++
        maybe_end_of_stream(next_state.input_end_of_stream?, pad)

    {actions, next_state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, radio_port), _ctx, state) do
    {[], %{state | output_pads: Map.delete(state.output_pads, radio_port)}}
  end

  @impl true
  def handle_stream_format(:input, %RadioStreamFormat{} = stream_format, _ctx, state) do
    actions =
      Enum.map(state.output_pads, fn {radio_port, pad} ->
        {:stream_format, {pad, output_stream_format(state.link_id, radio_port, stream_format)}}
      end)

    {actions, %{state | input_stream_format: stream_format}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    actions = Enum.map(state.output_pads, fn {_channel_id, pad} -> {:end_of_stream, pad} end)
    {actions, %{state | input_end_of_stream?: true}}
  end

  @impl true
  def handle_parent_notification({:set_radio_ports, radio_ports}, _ctx, state) do
    {[], %{state | enabled_radio_ports: normalize_radio_ports!(radio_ports)}}
  end

  def handle_parent_notification({:add_radio_port, radio_port}, _ctx, state) do
    validate_radio_port!(radio_port)
    {[], %{state | enabled_radio_ports: MapSet.put(state.enabled_radio_ports, radio_port)}}
  end

  def handle_parent_notification({:remove_radio_port, radio_port}, _ctx, state) do
    validate_radio_port!(radio_port)
    {[], %{state | enabled_radio_ports: MapSet.delete(state.enabled_radio_ports, radio_port)}}
  end

  def handle_parent_notification({:set_link_id, link_id}, _ctx, state) do
    link_id = validate_link_id!(link_id)

    actions =
      Enum.map(state.output_pads, fn {radio_port, pad} ->
        case state.input_stream_format do
          %RadioStreamFormat{} = input_stream_format ->
            {:stream_format,
             {pad, output_stream_format(link_id, radio_port, input_stream_format)}}

          nil ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {actions, %{state | link_id: link_id}}
  end

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    case route_buffer(buffer, state) do
      {:ok, pad, routed_buffer, next_state} ->
        {[buffer: {pad, routed_buffer}], increment_counter(next_state, :passed_packets)}

      {:drop, counter, next_state} ->
        {[], increment_counter(next_state, counter)}
    end
  end

  defp route_buffer(buffer, state) do
    radiotap = get_in(buffer.metadata, [:radio, :radiotap])

    cond do
      state.drop_self_injected? and self_injected?(radiotap) ->
        {:drop, :self_injected_drops, state}

      state.drop_bad_fcs? and bad_fcs?(radiotap) ->
        {:drop, :bad_fcs_drops, state}

      true ->
        buffer.payload
        |> maybe_trim_fcs(radiotap, state.trim_fcs?)
        |> parse_frame(buffer, state)
    end
  end

  defp parse_frame(frame, %Buffer{} = buffer, state) do
    with {:ok, ieee80211, wfb_packet} <- parse_ieee80211_frame(frame),
         {:ok, channel_id} <- extract_channel_id(ieee80211),
         {:ok, link_id, radio_port} <- split_channel_id(channel_id),
         :ok <- ensure_link_id_matches(link_id, state.link_id),
         :ok <- ensure_radio_port_enabled(radio_port, state.enabled_radio_ports),
         {:ok, pad} <- fetch_output_pad(radio_port, state.output_pads),
         {:ok, wfb_metadata} <- parse_wfb_packet(wfb_packet, channel_id, link_id, radio_port) do
      routed_buffer =
        %Buffer{buffer | payload: wfb_packet}
        |> put_metadata(:ieee80211, ieee80211)
        |> put_metadata(:wfb, wfb_metadata)

      {:ok, pad, routed_buffer, state}
    else
      {:error, :short_frame} -> {:drop, :short_frame_drops, state}
      {:error, :invalid_wfb_header} -> {:drop, :invalid_wfb_header_drops, state}
      {:error, :short_wfb_packet} -> {:drop, :short_wfb_packet_drops, state}
      {:error, :unknown_packet_type} -> {:drop, :unknown_packet_type_drops, state}
      {:error, :unknown_radio_port} -> {:drop, :unknown_radio_port_drops, state}
      {:error, :unlinked_radio_port} -> {:drop, :unlinked_radio_port_drops, state}
      {:error, :wrong_link_id} -> {:drop, :wrong_link_id_drops, state}
    end
  end

  defp parse_ieee80211_frame(frame) when byte_size(frame) < @header_size,
    do: {:error, :short_frame}

  defp parse_ieee80211_frame(frame) do
    <<frame_control::little-16, duration::little-16, receiver_mac::binary-size(6),
      source_mac::binary-size(6), bssid_mac::binary-size(6), sequence_control::little-16,
      payload::binary>> = frame

    ieee80211 = %{
      bssid_mac: bssid_mac,
      duration: duration,
      frame_control: frame_control,
      header_len: @header_size,
      receiver_mac: receiver_mac,
      sequence_control: sequence_control,
      source_mac: source_mac
    }

    {:ok, ieee80211, payload}
  end

  defp extract_channel_id(%{source_mac: <<@wfb_prefix, channel_id::big-32>>}),
    do: {:ok, channel_id}

  defp extract_channel_id(_ieee80211), do: {:error, :invalid_wfb_header}

  defp ensure_link_id_matches(link_id, configured_link_id) do
    if link_id == configured_link_id do
      :ok
    else
      {:error, :wrong_link_id}
    end
  end

  defp ensure_radio_port_enabled(radio_port, enabled_radio_ports) do
    if MapSet.member?(enabled_radio_ports, radio_port) do
      :ok
    else
      {:error, :unknown_radio_port}
    end
  end

  defp fetch_output_pad(radio_port, output_pads) do
    case Map.fetch(output_pads, radio_port) do
      {:ok, pad} -> {:ok, pad}
      :error -> {:error, :unlinked_radio_port}
    end
  end

  defp parse_wfb_packet(
         <<@packet_type_data, data_nonce::big-64, _rest::binary>>,
         channel_id,
         link_id,
         radio_port
       ) do
    {:ok,
     %{
       block_idx: data_nonce >>> 8,
       channel_id: channel_id,
       data_nonce: data_nonce,
       fragment_idx: data_nonce &&& 0xFF,
       link_id: link_id,
       packet_type: :data,
       packet_type_byte: @packet_type_data,
       radio_port: radio_port,
       session_nonce: nil
     }}
  end

  defp parse_wfb_packet(
         <<@packet_type_session, session_nonce::binary-size(@session_nonce_size), _rest::binary>>,
         channel_id,
         link_id,
         radio_port
       ) do
    {:ok,
     %{
       block_idx: nil,
       channel_id: channel_id,
       data_nonce: nil,
       fragment_idx: nil,
       link_id: link_id,
       packet_type: :session,
       packet_type_byte: @packet_type_session,
       radio_port: radio_port,
       session_nonce: session_nonce
     }}
  end

  defp parse_wfb_packet(<<packet_type, _rest::binary>>, _channel_id, _link_id, _radio_port)
       when packet_type in [@packet_type_data, @packet_type_session],
       do: {:error, :short_wfb_packet}

  defp parse_wfb_packet(<<_packet_type, _rest::binary>>, _channel_id, _link_id, _radio_port),
    do: {:error, :unknown_packet_type}

  defp parse_wfb_packet(<<>>, _channel_id, _link_id, _radio_port), do: {:error, :short_wfb_packet}

  defp maybe_trim_fcs(frame, %Radiotap{flags: %{fcs?: true}}, true)
       when byte_size(frame) >= @fcs_size do
    binary_part(frame, 0, byte_size(frame) - @fcs_size)
  end

  defp maybe_trim_fcs(frame, _radiotap, _trim_fcs?), do: frame

  defp self_injected?(%Radiotap{tx_flags: tx_flags}) when not is_nil(tx_flags), do: true
  defp self_injected?(_radiotap), do: false

  defp bad_fcs?(%Radiotap{flags: %{bad_fcs?: true}}), do: true
  defp bad_fcs?(_radiotap), do: false

  defp maybe_output_stream_format(nil, _pad, _link_id, _radio_port), do: []

  defp maybe_output_stream_format(
         %RadioStreamFormat{} = input_stream_format,
         pad,
         link_id,
         radio_port
       ) do
    [{:stream_format, {pad, output_stream_format(link_id, radio_port, input_stream_format)}}]
  end

  defp maybe_end_of_stream(false, _pad), do: []
  defp maybe_end_of_stream(true, pad), do: [{:end_of_stream, pad}]

  defp output_stream_format(link_id, radio_port, %RadioStreamFormat{interfaces: interfaces}) do
    %StreamFormat{
      channel_id: make_channel_id(link_id, radio_port),
      interfaces: interfaces,
      link_id: link_id,
      radio_port: radio_port
    }
  end

  defp put_metadata(%Buffer{metadata: metadata} = buffer, key, value) when is_map(metadata) do
    %Buffer{buffer | metadata: Map.put(metadata, key, value)}
  end

  defp put_metadata(%Buffer{} = buffer, key, value) do
    %Buffer{buffer | metadata: %{key => value}}
  end

  defp increment_counter(state, counter) do
    update_in(state.counters[counter], &((&1 || 0) + 1))
  end

  defp normalize_radio_ports!(radio_ports) when is_list(radio_ports) do
    radio_ports
    |> Enum.map(&validate_radio_port!/1)
    |> MapSet.new()
  end

  defp normalize_radio_ports!(radio_ports) do
    raise ArgumentError,
          "expected radio_ports to be a list, got: #{inspect(radio_ports)}"
  end

  defp normalize_initial_radio_ports!(radio_ports, radio_port)
       when is_list(radio_ports) and (is_integer(radio_port) or is_nil(radio_port)) do
    radio_ports =
      case {radio_ports, radio_port} do
        {[], nil} -> [0]
        {[], radio_port} -> [radio_port]
        {radio_ports, nil} -> radio_ports
        {radio_ports, radio_port} -> [radio_port | radio_ports]
      end

    normalize_radio_ports!(radio_ports)
  end

  defp normalize_initial_radio_ports!(radio_ports, radio_port) do
    raise ArgumentError,
          "expected radio_ports to be a list and radio_port to be an integer or nil, got: #{inspect(radio_ports)} and #{inspect(radio_port)}"
  end

  defp split_channel_id(channel_id) do
    {:ok, channel_id >>> 8, channel_id &&& 0xFF}
  end

  defp make_channel_id(link_id, radio_port) do
    (link_id <<< 8) + radio_port
  end

  defp validate_link_id!(link_id)
       when is_integer(link_id) and link_id >= 0 and link_id <= 0xFF_FFFF,
       do: link_id

  defp validate_link_id!(link_id) do
    raise ArgumentError,
          "expected link_id to be a non-negative 24-bit integer, got: #{inspect(link_id)}"
  end

  defp validate_radio_port!(radio_port)
       when is_integer(radio_port) and radio_port >= 0 and radio_port <= 0xFF,
       do: radio_port

  defp validate_radio_port!(radio_port) do
    raise ArgumentError,
          "expected radio_port to be a non-negative 8-bit integer, got: #{inspect(radio_port)}"
  end
end
