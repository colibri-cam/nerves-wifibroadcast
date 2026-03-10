defmodule Wifibroadcast.Radio.Netlink.Rtnetlink do
  @moduledoc false

  alias Wifibroadcast.Radio.Netlink.Client
  alias Wifibroadcast.Radio.Netlink.Header

  @rtm_newlink 16
  @iff_up 0x1

  @spec set_link_state(pos_integer(), boolean(), Keyword.t()) :: :ok | {:error, term()}
  def set_link_state(ifindex, up?, opts \\ []) when is_integer(ifindex) and ifindex > 0 do
    with payload <- Header.ifinfomsg(ifindex, if(up?, do: @iff_up, else: 0), @iff_up),
         {:ok, _replies} <- Client.request(Client.netlink_route(), @rtm_newlink, payload, opts) do
      :ok
    end
  end
end
