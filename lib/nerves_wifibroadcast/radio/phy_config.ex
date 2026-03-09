defmodule NervesWifibroadcast.Radio.PhyConfig do
  @moduledoc """
  Injection-side PHY hints used by the radio sink.
  """

  @type gi_t :: :short | :long | boolean()

  @type t :: %__MODULE__{
          bandwidth: non_neg_integer(),
          ldpc: boolean(),
          mcs_index: non_neg_integer(),
          short_gi: gi_t(),
          stbc: non_neg_integer(),
          vht_mode: boolean(),
          vht_nss: non_neg_integer()
        }

  defstruct bandwidth: 20,
            ldpc: false,
            mcs_index: 1,
            short_gi: :long,
            stbc: 0,
            vht_mode: false,
            vht_nss: 1
end
