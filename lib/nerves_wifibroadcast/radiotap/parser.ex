defmodule NervesWifibroadcast.Radiotap.Parser do
  @moduledoc """
  Pure Elixir radiotap parser used by the Membrane radio source.
  """

  import Bitwise

  alias NervesWifibroadcast.Radiotap
  alias NervesWifibroadcast.Radiotap.Observation

  @mcs_have_bw 0x01
  @mcs_have_mcs 0x02
  @mcs_have_gi 0x04
  @mcs_have_format 0x08
  @mcs_have_fec 0x10
  @mcs_have_stbc 0x20
  @mcs_bw_mask 0x03
  @mcs_sgi 0x04
  @mcs_format_greenfield 0x08
  @mcs_fec_ldpc 0x10
  @mcs_stbc_mask 0x60
  @mcs_stbc_shift 5
  @radiotap_f_fcs 0x10
  @radiotap_f_datapad 0x20
  @radiotap_f_badfcs 0x40
  @radiotap_f_rx_badplcp 0x0002
  @radiotap_f_tx_fail 0x0001
  @radiotap_f_tx_cts 0x0002
  @radiotap_f_tx_rts 0x0004
  @radiotap_f_tx_noack 0x0008
  @ampdu_report_zero_length 0x0001
  @ampdu_zero_length 0x0002
  @ampdu_last_known 0x0004
  @ampdu_last 0x0008
  @ampdu_delimiter_crc_error 0x0010
  @ampdu_delimiter_crc_known 0x0020
  @vht_known_stbc 0x0001
  @vht_known_gi 0x0004
  @vht_known_ldpc_extra_ofdm_symbol 0x0010
  @vht_known_beamformed 0x0020
  @vht_known_bandwidth 0x0040
  @vht_known_group_id 0x0080
  @vht_known_partial_aid 0x0100
  @vht_flag_stbc 0x01
  @vht_flag_sgi 0x04
  @vht_flag_ldpc_extra_ofdm_symbol 0x10
  @vht_flag_beamformed 0x20

  @field_layout %{
    0 => {8, 8},
    1 => {1, 1},
    2 => {1, 1},
    3 => {2, 4},
    4 => {2, 2},
    5 => {1, 1},
    6 => {1, 1},
    7 => {2, 2},
    8 => {2, 2},
    9 => {2, 2},
    10 => {1, 1},
    11 => {1, 1},
    12 => {1, 1},
    13 => {1, 1},
    14 => {2, 2},
    15 => {2, 2},
    16 => {1, 1},
    17 => {1, 1},
    19 => {1, 3},
    20 => {4, 8},
    21 => {2, 12},
    22 => {8, 12}
  }

  @type error_reason ::
          :short_header
          | :unsupported_version
          | :invalid_length
          | {:truncated_field, non_neg_integer()}

  @spec parse(binary()) :: {:ok, Radiotap.t(), binary()} | {:error, error_reason()}
  def parse(packet) when is_binary(packet) do
    with {:ok, version, length, radiotap_bin, payload} <- split_packet(packet),
         {:ok, present_words, present_indexes, cursor} <- parse_present_words(radiotap_bin),
         {:ok, radiotap} <-
           decode_fields(radiotap_bin, version, length, present_words, present_indexes, cursor) do
      {:ok, radiotap, payload}
    end
  end

  def parse(_packet), do: {:error, :short_header}

  defp split_packet(packet) when byte_size(packet) < 8, do: {:error, :short_header}

  defp split_packet(<<version, _pad, length::little-16, _rest::binary>> = packet) do
    cond do
      version != 0 ->
        {:error, :unsupported_version}

      length < 8 ->
        {:error, :invalid_length}

      byte_size(packet) < length ->
        {:error, :invalid_length}

      true ->
        radiotap_bin = binary_part(packet, 0, length)
        payload = binary_part(packet, length, byte_size(packet) - length)
        {:ok, version, length, radiotap_bin, payload}
    end
  end

  defp parse_present_words(radiotap_bin), do: parse_present_words(radiotap_bin, 4, 0, [], [])

  defp parse_present_words(radiotap_bin, offset, word_index, words, indexes) do
    if byte_size(radiotap_bin) < offset + 4 do
      {:error, :invalid_length}
    else
      <<_::binary-size(offset), word::little-32, _::binary>> = radiotap_bin

      words = [word | words]
      indexes = decode_present_indexes(word, word_index, indexes)

      if (word &&& 0x8000_0000) != 0 do
        parse_present_words(radiotap_bin, offset + 4, word_index + 1, words, indexes)
      else
        {:ok, Enum.reverse(words), Enum.reverse(indexes), offset + 4}
      end
    end
  end

  defp decode_present_indexes(word, word_index, indexes) do
    Enum.reduce(0..30, indexes, fn bit, acc ->
      if (word &&& 1 <<< bit) != 0 do
        [word_index * 32 + bit | acc]
      else
        acc
      end
    end)
  end

  defp decode_fields(radiotap_bin, version, length, present_words, present_indexes, cursor) do
    radiotap = %Radiotap{
      version: version,
      length: length,
      present_words: present_words,
      present_indexes: present_indexes
    }

    Enum.reduce_while(present_indexes, {:ok, radiotap, cursor}, fn index,
                                                                   {:ok, rtap, current_cursor} ->
      case Map.fetch(@field_layout, index) do
        :error ->
          {:halt, {:ok, add_unsupported_field(rtap, index), current_cursor}}

        {:ok, {align, size}} ->
          aligned_cursor = align_cursor(current_cursor, align)

          if aligned_cursor + size > byte_size(radiotap_bin) do
            {:halt, {:error, {:truncated_field, index}}}
          else
            field = binary_part(radiotap_bin, aligned_cursor, size)
            updated = decode_field(index, field, rtap)
            {:cont, {:ok, updated, aligned_cursor + size}}
          end
      end
    end)
    |> case do
      {:ok, rtap, _cursor} ->
        {:ok, %{rtap | observations: compact_observations(rtap.observations)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp align_cursor(cursor, 1), do: cursor

  defp align_cursor(cursor, align) do
    case rem(cursor, align) do
      0 -> cursor
      remainder -> cursor + align - remainder
    end
  end

  defp decode_field(1, <<raw>>, radiotap) do
    %{
      radiotap
      | flags: %{
          raw: raw,
          fcs?: flag_set?(raw, @radiotap_f_fcs),
          bad_fcs?: flag_set?(raw, @radiotap_f_badfcs),
          datapad?: flag_set?(raw, @radiotap_f_datapad)
        }
    }
  end

  defp decode_field(0, <<tsft::little-64>>, radiotap), do: %{radiotap | tsft: tsft}

  defp decode_field(2, <<raw>>, radiotap) do
    %{radiotap | rate: %{raw: raw, mbps: raw / 2.0}}
  end

  defp decode_field(3, <<freq::little-16, flags::little-16>>, radiotap) do
    %{radiotap | channel_freq: freq, channel_flags: flags}
  end

  defp decode_field(5, <<rssi::signed-8>>, radiotap),
    do: put_observation(radiotap, :rssi_dbm, rssi)

  defp decode_field(6, <<noise::signed-8>>, radiotap),
    do: put_observation(radiotap, :noise_dbm, noise)

  defp decode_field(12, <<rssi::unsigned-8>>, radiotap),
    do: put_observation(radiotap, :rssi_db, rssi)

  defp decode_field(13, <<noise::unsigned-8>>, radiotap),
    do: put_observation(radiotap, :noise_db, noise)

  defp decode_field(11, <<antenna>>, radiotap) do
    observations =
      radiotap.observations
      |> ensure_current_observation()
      |> update_last_observation(fn %Observation{} = observation ->
        %Observation{observation | antenna: antenna}
      end)
      |> Kernel.++([%Observation{}])

    %{radiotap | observations: observations}
  end

  defp decode_field(15, <<raw::little-16>>, radiotap) do
    %{
      radiotap
      | tx_flags: %{
          raw: raw,
          fail?: flag_set?(raw, @radiotap_f_tx_fail),
          cts?: flag_set?(raw, @radiotap_f_tx_cts),
          rts?: flag_set?(raw, @radiotap_f_tx_rts),
          no_ack?: flag_set?(raw, @radiotap_f_tx_noack)
        }
    }
  end

  defp decode_field(14, <<raw::little-16>>, radiotap) do
    %{radiotap | rx_flags: %{raw: raw, bad_plcp?: flag_set?(raw, @radiotap_f_rx_badplcp)}}
  end

  defp decode_field(19, <<known, flags, index>>, radiotap) do
    bandwidth_code = if(flag_set?(known, @mcs_have_bw), do: flags &&& @mcs_bw_mask, else: nil)

    {bandwidth, bandwidth_detail} = decode_mcs_bandwidth(bandwidth_code)

    mcs_index = if(flag_set?(known, @mcs_have_mcs), do: index &&& 0x7F, else: nil)

    short_gi? =
      if flag_set?(known, @mcs_have_gi), do: flag_set?(flags, @mcs_sgi), else: nil

    format =
      if flag_set?(known, @mcs_have_format) do
        if flag_set?(flags, @mcs_format_greenfield), do: :greenfield, else: :mixed
      else
        nil
      end

    fec =
      if flag_set?(known, @mcs_have_fec) do
        if flag_set?(flags, @mcs_fec_ldpc), do: :ldpc, else: :bcc
      else
        nil
      end

    stbc_streams =
      if flag_set?(known, @mcs_have_stbc) do
        (flags &&& @mcs_stbc_mask) >>> @mcs_stbc_shift
      else
        nil
      end

    %{
      radiotap
      | mcs: %{
          known: known,
          flags: flags,
          index: mcs_index,
          bandwidth_code: bandwidth_code,
          bandwidth: bandwidth,
          bandwidth_detail: bandwidth_detail,
          short_gi?: short_gi?,
          format: format,
          fec: fec,
          stbc_streams: stbc_streams
        }
    }
  end

  defp decode_field(
         20,
         <<reference::little-32, flags::little-16, delimiter_crc, _reserved>>,
         radiotap
       ) do
    %{
      radiotap
      | ampdu_status: %{
          reference: reference,
          flags: flags,
          report_zero_length?: flag_set?(flags, @ampdu_report_zero_length),
          zero_length?: flag_set?(flags, @ampdu_zero_length),
          last_known?: flag_set?(flags, @ampdu_last_known),
          last?: flag_set?(flags, @ampdu_last),
          delimiter_crc_error?: flag_set?(flags, @ampdu_delimiter_crc_error),
          delimiter_crc_known?: flag_set?(flags, @ampdu_delimiter_crc_known),
          delimiter_crc:
            if(flag_set?(flags, @ampdu_delimiter_crc_known), do: delimiter_crc, else: nil)
        }
    }
  end

  defp decode_field(
         21,
         <<known::little-16, flags, bandwidth_code, mcs_nss0, mcs_nss1, mcs_nss2, mcs_nss3,
           coding, group_id, partial_aid::little-16>>,
         radiotap
       ) do
    bandwidth = decode_vht_bandwidth(known, bandwidth_code)
    users = decode_vht_users([mcs_nss0, mcs_nss1, mcs_nss2, mcs_nss3], coding)

    primary_user = List.first(users)

    %{
      radiotap
      | vht: %{
          known: known,
          flags: flags,
          bandwidth_code: bandwidth_code,
          bandwidth: bandwidth,
          short_gi?:
            if(flag_set?(known, @vht_known_gi), do: flag_set?(flags, @vht_flag_sgi), else: nil),
          stbc?:
            if(flag_set?(known, @vht_known_stbc), do: flag_set?(flags, @vht_flag_stbc), else: nil),
          beamformed?:
            if(flag_set?(known, @vht_known_beamformed),
              do: flag_set?(flags, @vht_flag_beamformed),
              else: nil
            ),
          ldpc_extra_ofdm_symbol?:
            if(
              flag_set?(known, @vht_known_ldpc_extra_ofdm_symbol),
              do: flag_set?(flags, @vht_flag_ldpc_extra_ofdm_symbol),
              else: nil
            ),
          group_id: if(flag_set?(known, @vht_known_group_id), do: group_id, else: nil),
          partial_aid: if(flag_set?(known, @vht_known_partial_aid), do: partial_aid, else: nil),
          users: users,
          nss: primary_user && primary_user.nss,
          mcs_index:
            case primary_user do
              %{mcs_index: mcs_index} when is_integer(mcs_index) -> mcs_index
              _other -> nil
            end
        }
    }
  end

  defp decode_field(_index, _field, radiotap), do: radiotap

  defp put_observation(radiotap, key, value) do
    observations =
      radiotap.observations
      |> ensure_current_observation()
      |> update_last_observation(&Map.put(&1, key, value))

    %{radiotap | observations: observations}
  end

  defp ensure_current_observation([]), do: [%Observation{}]
  defp ensure_current_observation(observations), do: observations

  defp update_last_observation(observations, fun) do
    {prefix, [last]} = Enum.split(observations, -1)
    prefix ++ [fun.(last)]
  end

  defp compact_observations(observations) do
    observations
    |> Enum.reject(&empty_observation?/1)
  end

  defp empty_observation?(%Observation{
         antenna: nil,
         rssi_dbm: nil,
         noise_dbm: nil,
         rssi_db: nil,
         noise_db: nil
       }),
       do: true

  defp empty_observation?(%Observation{}), do: false

  defp decode_mcs_bandwidth(nil), do: {20, nil}
  defp decode_mcs_bandwidth(0), do: {20, :mhz20}
  defp decode_mcs_bandwidth(1), do: {40, :mhz40}
  defp decode_mcs_bandwidth(2), do: {20, :mhz20_lower}
  defp decode_mcs_bandwidth(3), do: {20, :mhz20_upper}

  defp decode_vht_bandwidth(known, bandwidth_code) do
    cond do
      not flag_set?(known, @vht_known_bandwidth) -> 20
      bandwidth_code in 1..3 -> 40
      bandwidth_code in 4..10 -> 80
      bandwidth_code in 11..25 -> 160
      true -> 20
    end
  end

  defp decode_vht_users(mcs_nss_values, coding) do
    mcs_nss_values
    |> Enum.with_index()
    |> Enum.reduce([], fn {mcs_nss, user_index}, acc ->
      nss = mcs_nss &&& 0x0F

      if nss == 0 do
        acc
      else
        mcs_index = mcs_nss >>> 4 &&& 0x0F

        [
          %{
            user_index: user_index,
            nss: nss,
            mcs_index: if(mcs_index == 0x0F, do: :unknown, else: mcs_index),
            ldpc?: flag_set?(coding, 1 <<< user_index)
          }
          | acc
        ]
      end
    end)
    |> Enum.reverse()
  end

  defp add_unsupported_field(radiotap, index) do
    %{radiotap | unsupported_fields: radiotap.unsupported_fields ++ [index]}
  end

  defp flag_set?(value, mask), do: (value &&& mask) != 0
end
