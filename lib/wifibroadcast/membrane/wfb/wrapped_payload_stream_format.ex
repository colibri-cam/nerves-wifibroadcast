defmodule Wifibroadcast.Membrane.WFB.WrappedPayloadStreamFormat do
  @moduledoc """
  Stream format emitted by the TX payload wrapper.
  """

  @enforce_keys [:channel_id, :interfaces, :link_id, :radio_port]
  defstruct channel_id: nil,
            framing: :wrapped_payload,
            interfaces: [],
            link_id: nil,
            radio_port: nil

  @type t :: %__MODULE__{
          channel_id: non_neg_integer(),
          framing: :wrapped_payload,
          interfaces: [String.t()],
          link_id: non_neg_integer(),
          radio_port: non_neg_integer()
        }
end
