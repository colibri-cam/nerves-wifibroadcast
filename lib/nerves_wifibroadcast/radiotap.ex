defmodule NervesWifibroadcast.Radiotap do
  @moduledoc """
  Parsed radiotap metadata attached to captured radio packets.
  """

  alias NervesWifibroadcast.Radiotap.Observation

  @type flag_info :: %{
          raw: non_neg_integer(),
          fcs?: boolean(),
          bad_fcs?: boolean(),
          datapad?: boolean()
        }

  @type rx_flag_info :: %{
          raw: non_neg_integer(),
          bad_plcp?: boolean()
        }

  @type tx_flag_info :: %{
          raw: non_neg_integer(),
          fail?: boolean(),
          cts?: boolean(),
          rts?: boolean(),
          no_ack?: boolean()
        }

  @type rate_info :: %{
          raw: non_neg_integer(),
          mbps: float()
        }

  @type ampdu_status_info :: %{
          reference: non_neg_integer(),
          flags: non_neg_integer(),
          report_zero_length?: boolean(),
          zero_length?: boolean(),
          last_known?: boolean(),
          last?: boolean(),
          delimiter_crc_error?: boolean(),
          delimiter_crc_known?: boolean(),
          delimiter_crc: non_neg_integer() | nil
        }

  @type mcs_format :: :mixed | :greenfield
  @type mcs_bandwidth_detail :: :mhz20 | :mhz40 | :mhz20_lower | :mhz20_upper

  @type mcs_info :: %{
          known: non_neg_integer(),
          flags: non_neg_integer(),
          index: non_neg_integer() | nil,
          bandwidth_code: non_neg_integer() | nil,
          bandwidth: 20 | 40,
          bandwidth_detail: mcs_bandwidth_detail() | nil,
          short_gi?: boolean() | nil,
          format: mcs_format() | nil,
          fec: :bcc | :ldpc | nil,
          stbc_streams: non_neg_integer() | nil
        }

  @type vht_user_info :: %{
          user_index: non_neg_integer(),
          nss: non_neg_integer(),
          mcs_index: non_neg_integer() | :unknown,
          ldpc?: boolean() | nil
        }

  @type vht_info :: %{
          known: non_neg_integer(),
          flags: non_neg_integer(),
          bandwidth_code: non_neg_integer(),
          bandwidth: 20 | 40 | 80 | 160,
          short_gi?: boolean() | nil,
          stbc?: boolean() | nil,
          beamformed?: boolean() | nil,
          ldpc_extra_ofdm_symbol?: boolean() | nil,
          group_id: non_neg_integer() | nil,
          partial_aid: non_neg_integer() | nil,
          users: [vht_user_info()],
          nss: non_neg_integer() | nil,
          mcs_index: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          length: non_neg_integer(),
          present_words: [non_neg_integer()],
          present_indexes: [non_neg_integer()],
          tsft: non_neg_integer() | nil,
          flags: flag_info() | nil,
          rate: rate_info() | nil,
          tx_flags: tx_flag_info() | nil,
          rx_flags: rx_flag_info() | nil,
          channel_freq: non_neg_integer() | nil,
          channel_flags: non_neg_integer() | nil,
          mcs: mcs_info() | nil,
          vht: vht_info() | nil,
          ampdu_status: ampdu_status_info() | nil,
          observations: [Observation.t()],
          unsupported_fields: [non_neg_integer()]
        }

  defstruct version: 0,
            length: 0,
            present_words: [],
            present_indexes: [],
            tsft: nil,
            flags: nil,
            rate: nil,
            tx_flags: nil,
            rx_flags: nil,
            channel_freq: nil,
            channel_flags: nil,
            mcs: nil,
            vht: nil,
            ampdu_status: nil,
            observations: [],
            unsupported_fields: []
end

defmodule NervesWifibroadcast.Radiotap.Observation do
  @moduledoc """
  Ordered antenna observation extracted from a radiotap header.
  """

  @type t :: %__MODULE__{
          antenna: non_neg_integer() | nil,
          rssi_dbm: integer() | nil,
          noise_dbm: integer() | nil,
          rssi_db: non_neg_integer() | nil,
          noise_db: non_neg_integer() | nil
        }

  defstruct antenna: nil,
            rssi_dbm: nil,
            noise_dbm: nil,
            rssi_db: nil,
            noise_db: nil
end
