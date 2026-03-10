defmodule Wifibroadcast.Radio.Interface do
  @moduledoc """
  Snapshot of a discovered wireless interface and its attached radio hardware.
  """

  @enforce_keys [:ifname]

  @known_iftypes [
    :unspecified,
    :adhoc,
    :station,
    :ap,
    :ap_vlan,
    :wds,
    :monitor,
    :mesh_point,
    :p2p_client,
    :p2p_go,
    :p2p_device,
    :ocb,
    :nan
  ]

  @type group_t :: atom() | String.t()

  @type known_iftype_t ::
          :unspecified
          | :adhoc
          | :station
          | :ap
          | :ap_vlan
          | :wds
          | :monitor
          | :mesh_point
          | :p2p_client
          | :p2p_go
          | :p2p_device
          | :ocb
          | :nan

  @type iftype_t :: known_iftype_t() | {:unknown, non_neg_integer()}

  @type t :: %__MODULE__{
          bus_path: String.t() | nil,
          device_path: String.t() | nil,
          driver: atom() | nil,
          driver_name: String.t() | nil,
          groups: [group_t()],
          ifindex: pos_integer() | nil,
          ifname: String.t(),
          iftype: iftype_t() | nil,
          mac: String.t() | nil,
          modalias: String.t() | nil,
          phy: String.t() | nil
        }

  defstruct bus_path: nil,
            device_path: nil,
            driver: nil,
            driver_name: nil,
            groups: [],
            ifindex: nil,
            ifname: nil,
            iftype: nil,
            mac: nil,
            modalias: nil,
            phy: nil

  @spec known_iftypes() :: [known_iftype_t()]
  def known_iftypes, do: @known_iftypes

  @spec normalize_iftype!(iftype_t()) :: iftype_t()
  def normalize_iftype!(iftype) when iftype in @known_iftypes, do: iftype

  def normalize_iftype!({:unknown, value}) when is_integer(value) and value >= 0,
    do: {:unknown, value}

  def normalize_iftype!(iftype) do
    raise ArgumentError,
          "expected iftype to be one of #{Enum.map_join(@known_iftypes, ", ", &inspect/1)} or {:unknown, non_neg_integer}, got: #{inspect(iftype)}"
  end
end
