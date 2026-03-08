defmodule NervesWifibroadcast.Membrane.Radio.StreamFormat do
  @moduledoc """
  Stream format emitted by the radio source.
  """

  @enforce_keys [:interfaces]
  defstruct interfaces: [],
            link_layer: :ieee80211,
            radiotap?: true

  @type t :: %__MODULE__{
          interfaces: [String.t()],
          link_layer: atom(),
          radiotap?: boolean()
        }
end
