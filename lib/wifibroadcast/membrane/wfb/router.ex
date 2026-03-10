defmodule Wifibroadcast.Membrane.WFB.Router do
  @moduledoc false

  import Bitwise

  alias Membrane.Buffer
  alias Wifibroadcast.Membrane.WFB.StreamFormat
  alias Wifibroadcast.Radiotap

  @header_size 24
  @fcs_size 4
  @wfb_prefix <<0x57, 0x42>>
  @packet_type_data 0x01
  @packet_type_session 0x02
  @session_nonce_size 24
  @default_link_id 7_669_206

  @spec default_link_id() :: non_neg_integer()
  def default_link_id, do: @default_link_id

  @spec route_buffer(Buffer.t(), map()) ::
          {:ok, non_neg_integer(), Buffer.t()} | {:drop, atom()}
  def route_buffer(%Buffer{} = buffer, state) do
    radiotap = get_in(buffer.metadata, [:radio, :radiotap])

    cond do
      Map.get(state, :drop_self_injected?, true) and self_injected?(radiotap) ->
        {:drop, :self_injected_drops}

      Map.get(state, :drop_bad_fcs?, true) and bad_fcs?(radiotap) ->
        {:drop, :bad_fcs_drops}

      true ->
        buffer.payload
        |> maybe_trim_fcs(radiotap, Map.get(state, :trim_fcs?, true))
        |> parse_frame(buffer, state)
    end
  end

  @spec output_stream_format(non_neg_integer(), non_neg_integer(), [String.t()]) ::
          StreamFormat.t()
  def output_stream_format(link_id, radio_port, interfaces) do
    %StreamFormat{
      channel_id: make_channel_id(link_id, radio_port),
      interfaces: interfaces,
      link_id: link_id,
      radio_port: radio_port
    }
  end

  @spec build_data_packet(non_neg_integer(), binary()) :: binary()
  def build_data_packet(data_nonce, payload) when is_integer(data_nonce) and data_nonce >= 0 do
    <<@packet_type_data, data_nonce::big-64, payload::binary>>
  end

  @spec build_session_packet(binary(), binary()) :: binary()
  def build_session_packet(session_nonce, payload)
      when is_binary(session_nonce) and byte_size(session_nonce) == @session_nonce_size do
    <<@packet_type_session, session_nonce::binary-size(@session_nonce_size), payload::binary>>
  end

  @spec normalize_radio_ports!([term()]) :: MapSet.t()
  def normalize_radio_ports!(radio_ports) when is_list(radio_ports) do
    radio_ports
    |> Enum.map(&validate_radio_port!/1)
    |> MapSet.new()
  end

  def normalize_radio_ports!(radio_ports) do
    raise ArgumentError,
          "expected radio_ports to be a list, got: #{inspect(radio_ports)}"
  end

  @spec normalize_initial_radio_ports!([term()], integer() | nil) :: MapSet.t()
  def normalize_initial_radio_ports!(radio_ports, radio_port)
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

  def normalize_initial_radio_ports!(radio_ports, radio_port) do
    raise ArgumentError,
          "expected radio_ports to be a list and radio_port to be an integer or nil, got: #{inspect(radio_ports)} and #{inspect(radio_port)}"
  end

  @spec validate_link_id!(term()) :: non_neg_integer()
  def validate_link_id!(link_id)
      when is_integer(link_id) and link_id >= 0 and link_id <= 0xFF_FFFF,
      do: link_id

  def validate_link_id!(link_id) do
    raise ArgumentError,
          "expected link_id to be a non-negative 24-bit integer, got: #{inspect(link_id)}"
  end

  @spec validate_radio_port!(term()) :: non_neg_integer()
  def validate_radio_port!(radio_port)
      when is_integer(radio_port) and radio_port >= 0 and radio_port <= 0xFF,
      do: radio_port

  def validate_radio_port!(radio_port) do
    raise ArgumentError,
          "expected radio_port to be a non-negative 8-bit integer, got: #{inspect(radio_port)}"
  end

  @spec make_channel_id(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def make_channel_id(link_id, radio_port), do: (link_id <<< 8) + radio_port

  defp parse_frame(frame, %Buffer{} = buffer, state) do
    with {:ok, ieee80211, wfb_packet} <- parse_ieee80211_frame(frame),
         {:ok, channel_id} <- extract_channel_id(ieee80211),
         {:ok, link_id, radio_port} <- split_channel_id(channel_id),
         :ok <- ensure_link_id_matches(link_id, state.link_id),
         :ok <- ensure_radio_port_enabled(radio_port, state.enabled_radio_ports),
         {:ok, packet_payload, wfb_metadata} <-
           parse_wfb_packet(wfb_packet, channel_id, link_id, radio_port) do
      routed_buffer =
        %Buffer{buffer | payload: packet_payload}
        |> put_metadata(:ieee80211, ieee80211)
        |> put_metadata(:wfb, wfb_metadata)

      {:ok, radio_port, routed_buffer}
    else
      {:error, :short_frame} -> {:drop, :short_frame_drops}
      {:error, :invalid_wfb_header} -> {:drop, :invalid_wfb_header_drops}
      {:error, :short_wfb_packet} -> {:drop, :short_wfb_packet_drops}
      {:error, :unknown_packet_type} -> {:drop, :unknown_packet_type_drops}
      {:error, :unknown_radio_port} -> {:drop, :unknown_radio_port_drops}
      {:error, :wrong_link_id} -> {:drop, :wrong_link_id_drops}
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

  defp split_channel_id(channel_id), do: {:ok, channel_id >>> 8, channel_id &&& 0xFF}

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

  defp parse_wfb_packet(
         <<@packet_type_data, data_nonce::big-64, payload::binary>>,
         channel_id,
         link_id,
         radio_port
       ) do
    {:ok, payload,
     %{
       block_idx: data_nonce >>> 8,
       channel_id: channel_id,
       data_nonce: data_nonce,
       framing: :inner_payload,
       fragment_idx: data_nonce &&& 0xFF,
       link_id: link_id,
       packet_type: :data,
       packet_type_byte: @packet_type_data,
       radio_port: radio_port,
       session_nonce: nil
     }}
  end

  defp parse_wfb_packet(
         <<@packet_type_session, session_nonce::binary-size(@session_nonce_size),
           payload::binary>>,
         channel_id,
         link_id,
         radio_port
       ) do
    {:ok, payload,
     %{
       block_idx: nil,
       channel_id: channel_id,
       data_nonce: nil,
       framing: :inner_payload,
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

  defp put_metadata(%Buffer{metadata: metadata} = buffer, key, value) when is_map(metadata) do
    %Buffer{buffer | metadata: Map.put(metadata, key, value)}
  end

  defp put_metadata(%Buffer{} = buffer, key, value) do
    %Buffer{buffer | metadata: %{key => value}}
  end
end
