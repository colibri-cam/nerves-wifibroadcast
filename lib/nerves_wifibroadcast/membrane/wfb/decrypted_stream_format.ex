defmodule NervesWifibroadcast.Membrane.WFB.DecryptedStreamFormat do
  @moduledoc """
  Stream format emitted by the decrypt stage once a session has been accepted.
  """

  @enforce_keys [
    :channel_id,
    :epoch,
    :fec_k,
    :fec_n,
    :fec_type,
    :interfaces,
    :link_id,
    :radio_port
  ]
  defstruct channel_id: nil,
            epoch: nil,
            fec_k: nil,
            fec_n: nil,
            fec_type: nil,
            framing: :fec_fragment,
            interfaces: [],
            link_id: nil,
            radio_port: nil

  @type t :: %__MODULE__{
          channel_id: non_neg_integer(),
          epoch: non_neg_integer(),
          fec_k: non_neg_integer(),
          fec_n: non_neg_integer(),
          fec_type: non_neg_integer(),
          framing: :fec_fragment,
          interfaces: [String.t()],
          link_id: non_neg_integer(),
          radio_port: non_neg_integer()
        }
end
