defmodule Wifibroadcast.Radio.Inventory.Selection do
  @moduledoc """
  A resolved subset of interfaces from radio inventory discovery.
  """

  alias Wifibroadcast.Radio.Interface

  @enforce_keys [:drivers, :interfaces, :members]

  @type t :: %__MODULE__{
          drivers: [atom()],
          interfaces: [String.t()],
          members: [Interface.t()]
        }

  defstruct drivers: [],
            interfaces: [],
            members: []
end
