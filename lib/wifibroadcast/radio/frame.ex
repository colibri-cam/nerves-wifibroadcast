defmodule Wifibroadcast.Radio.Frame do
  @moduledoc false

  import Bitwise

  alias Membrane.Buffer
  alias Wifibroadcast.Membrane.WFB.Router
  alias Wifibroadcast.Radio.PhyConfig

  @frame_type_data 0x08
  @frame_type_rts 0xB4
  @ht_radiotap_known 0x37
  @session_nonce_size 24
  @source_prefix <<0x57, 0x42>>

  @spec normalize_phy_config!(PhyConfig.t() | map()) :: PhyConfig.t()
  def normalize_phy_config!(%PhyConfig{} = phy_config), do: validate_phy_config!(phy_config)

  def normalize_phy_config!(attrs) when is_map(attrs) do
    attrs
    |> Enum.into(%{})
    |> then(&struct(PhyConfig, &1))
    |> validate_phy_config!()
  end

  def normalize_phy_config!(phy_config) do
    raise ArgumentError,
          "expected phy_config to be a #{inspect(PhyConfig)} or map, got: #{inspect(phy_config)}"
  end

  @spec merge_phy_config!(PhyConfig.t(), map()) :: PhyConfig.t()
  def merge_phy_config!(%PhyConfig{} = current_config, attrs) when is_map(attrs) do
    current_config
    |> Map.from_struct()
    |> Map.merge(Enum.into(attrs, %{}))
    |> normalize_phy_config!()
  end

  def merge_phy_config!(%PhyConfig{}, attrs) do
    raise ArgumentError,
          "expected radio config update to be a map or #{inspect(PhyConfig)}, got: #{inspect(attrs)}"
  end

  @spec radiotap_header(PhyConfig.t()) :: binary()
  def radiotap_header(%PhyConfig{} = phy_config) do
    case phy_config.vht_mode do
      false -> ht_radiotap_header(phy_config)
      true -> vht_radiotap_header(phy_config)
    end
  end

  @spec ieee80211_header(non_neg_integer(), non_neg_integer(), atom() | non_neg_integer()) ::
          binary()
  def ieee80211_header(channel_id, sequence_control, frame_type) do
    frame_type = normalize_frame_type!(frame_type)

    <<
      frame_type,
      0x01,
      0::little-16,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      @source_prefix::binary,
      channel_id::big-32,
      @source_prefix::binary,
      channel_id::big-32,
      sequence_control::little-16
    >>
  end

  @spec tx_frame(Buffer.t(), non_neg_integer(), atom() | non_neg_integer(), map()) ::
          {:ok, binary()} | {:error, term()}
  def tx_frame(%Buffer{} = buffer, sequence_control, frame_type, format_context) do
    with {:ok, channel_id} <- resolve_channel_id(buffer, format_context),
         {:ok, payload} <- wfb_payload(buffer, format_context) do
      {:ok,
       radiotap_header(Map.fetch!(format_context, :phy_config)) <>
         ieee80211_header(channel_id, sequence_control, frame_type) <> payload}
    end
  end

  @spec next_sequence_control(non_neg_integer()) :: non_neg_integer()
  def next_sequence_control(sequence_control), do: rem(sequence_control + 16, 1 <<< 16)

  defp wfb_payload(%Buffer{} = buffer, _format_context) do
    case get_in(buffer.metadata, [:wfb, :packet_type]) do
      :data -> build_data_payload(buffer)
      :session -> build_session_payload(buffer)
      packet_type -> {:error, {:unsupported_packet_type, packet_type}}
    end
  end

  defp build_data_payload(%Buffer{} = buffer) do
    case get_in(buffer.metadata, [:wfb, :data_nonce]) do
      data_nonce
      when is_integer(data_nonce) and data_nonce >= 0 and data_nonce <= 0xFFFFFFFFFFFFFFFF ->
        {:ok, Router.build_data_packet(data_nonce, buffer.payload)}

      data_nonce ->
        {:error, {:invalid_data_nonce, data_nonce}}
    end
  end

  defp build_session_payload(%Buffer{} = buffer) do
    session_nonce =
      get_in(buffer.metadata, [:wfb, :session_nonce]) ||
        :crypto.strong_rand_bytes(@session_nonce_size)

    if is_binary(session_nonce) and byte_size(session_nonce) == @session_nonce_size do
      {:ok, Router.build_session_packet(session_nonce, buffer.payload)}
    else
      {:error, {:invalid_session_nonce, session_nonce}}
    end
  end

  defp resolve_channel_id(%Buffer{} = buffer, format_context) do
    case get_in(buffer.metadata, [:wfb, :channel_id]) do
      channel_id when is_integer(channel_id) and channel_id >= 0 and channel_id <= 0xFFFFFFFF ->
        {:ok, channel_id}

      _other ->
        case Map.get(format_context, :channel_id) do
          channel_id
          when is_integer(channel_id) and channel_id >= 0 and channel_id <= 0xFFFFFFFF ->
            {:ok, channel_id}

          channel_id ->
            {:error, {:invalid_channel_id, channel_id}}
        end
    end
  end

  defp ht_radiotap_header(%PhyConfig{} = phy_config) do
    <<
      0,
      0,
      13::little-16,
      0x00088000::little-32,
      0x08,
      0x00,
      @ht_radiotap_known,
      ht_flags(phy_config),
      phy_config.mcs_index
    >>
  end

  defp vht_radiotap_header(%PhyConfig{} = phy_config) do
    <<
      0,
      0,
      22::little-16,
      0x00208000::little-32,
      0x08,
      0x00,
      0x45,
      0x00,
      vht_flags(phy_config),
      vht_bandwidth_code(phy_config.bandwidth),
      vht_mcs_nss(phy_config),
      0,
      0,
      0,
      vht_coding(phy_config),
      0,
      0,
      0
    >>
  end

  defp ht_flags(%PhyConfig{} = phy_config) do
    bandwidth_flag =
      case phy_config.bandwidth do
        10 -> 0
        20 -> 0
        40 -> 1
      end

    short_gi_flag = if short_gi?(phy_config.short_gi), do: 0x04, else: 0x00
    stbc_flag = (phy_config.stbc &&& 0x03) <<< 5
    ldpc_flag = if phy_config.ldpc, do: 0x10, else: 0x00

    bandwidth_flag ||| short_gi_flag ||| stbc_flag ||| ldpc_flag
  end

  defp vht_flags(%PhyConfig{} = phy_config) do
    short_gi_flag = if short_gi?(phy_config.short_gi), do: 0x04, else: 0x00
    stbc_flag = if phy_config.stbc > 0, do: 0x01, else: 0x00
    short_gi_flag ||| stbc_flag
  end

  defp vht_mcs_nss(%PhyConfig{} = phy_config) do
    (phy_config.mcs_index <<< 4 &&& 0xF0) ||| (phy_config.vht_nss &&& 0x0F)
  end

  defp vht_coding(%PhyConfig{} = phy_config) do
    if phy_config.ldpc, do: 0x01, else: 0x00
  end

  defp vht_bandwidth_code(10), do: 0x00
  defp vht_bandwidth_code(20), do: 0x00
  defp vht_bandwidth_code(40), do: 0x01
  defp vht_bandwidth_code(80), do: 0x04
  defp vht_bandwidth_code(160), do: 0x0B

  defp normalize_frame_type!(:data), do: @frame_type_data
  defp normalize_frame_type!(:rts), do: @frame_type_rts

  defp normalize_frame_type!(frame_type)
       when is_integer(frame_type) and frame_type >= 0 and frame_type <= 0xFF,
       do: frame_type

  defp normalize_frame_type!(frame_type) do
    raise ArgumentError,
          "expected frame_type to be :data, :rts, or a byte value, got: #{inspect(frame_type)}"
  end

  defp validate_phy_config!(%PhyConfig{} = phy_config) do
    cond do
      phy_config.bandwidth not in [10, 20, 40, 80, 160] ->
        raise ArgumentError, "unsupported bandwidth #{inspect(phy_config.bandwidth)}"

      not is_integer(phy_config.mcs_index) or phy_config.mcs_index < 0 or
          phy_config.mcs_index > 15 ->
        raise ArgumentError,
              "expected mcs_index to be between 0 and 15, got: #{inspect(phy_config.mcs_index)}"

      not is_integer(phy_config.stbc) or phy_config.stbc < 0 or phy_config.stbc > 3 ->
        raise ArgumentError,
              "expected stbc to be between 0 and 3, got: #{inspect(phy_config.stbc)}"

      not is_boolean(phy_config.ldpc) ->
        raise ArgumentError, "expected ldpc to be boolean, got: #{inspect(phy_config.ldpc)}"

      not short_gi_value?(phy_config.short_gi) ->
        raise ArgumentError,
              "expected short_gi to be :short, :long, or boolean, got: #{inspect(phy_config.short_gi)}"

      not is_boolean(phy_config.vht_mode) ->
        raise ArgumentError,
              "expected vht_mode to be boolean, got: #{inspect(phy_config.vht_mode)}"

      not is_integer(phy_config.vht_nss) or phy_config.vht_nss < 1 or phy_config.vht_nss > 4 ->
        raise ArgumentError,
              "expected vht_nss to be between 1 and 4, got: #{inspect(phy_config.vht_nss)}"

      not phy_config.vht_mode and phy_config.bandwidth not in [10, 20, 40] ->
        raise ArgumentError,
              "unsupported HT bandwidth #{inspect(phy_config.bandwidth)}; expected 10, 20, or 40"

      true ->
        phy_config
    end
  end

  defp short_gi?(true), do: true
  defp short_gi?(:short), do: true
  defp short_gi?(_other), do: false

  defp short_gi_value?(value), do: value in [true, false, :short, :long]
end
