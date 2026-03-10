defmodule Wifibroadcast.Membrane.WFB.StreamFormat do
  @moduledoc """
  Stream format emitted by the WFB ingress/router element.
  """

  @enforce_keys [:channel_id, :interfaces]
  defstruct channel_id: nil,
            encrypted?: true,
            framing: :wfb_packet,
            interfaces: [],
            link_id: nil,
            radio_port: nil

  @type t :: %__MODULE__{
          channel_id: non_neg_integer(),
          encrypted?: boolean(),
          framing: :wfb_packet,
          interfaces: [String.t()],
          link_id: non_neg_integer(),
          radio_port: non_neg_integer()
        }
end
