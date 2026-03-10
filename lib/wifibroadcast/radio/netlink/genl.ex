defmodule Wifibroadcast.Radio.Netlink.Genl do
  @moduledoc false

  alias Wifibroadcast.Radio.Netlink.Attr
  alias Wifibroadcast.Radio.Netlink.Client
  alias Wifibroadcast.Radio.Netlink.Header
  alias Wifibroadcast.Radio.Netlink.Socket

  @genl_id_ctrl 0x10
  @ctrl_cmd_getfamily 3
  @ctrl_attr_family_id 1
  @ctrl_attr_family_name 2
  @ctrl_version 2

  @spec family_id(String.t(), Keyword.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def family_id(name, opts \\ []) when is_binary(name) do
    payload =
      Header.genlmsg(@ctrl_cmd_getfamily, @ctrl_version, [
        Attr.string(@ctrl_attr_family_name, name)
      ])

    with {:ok, [message | _rest]} <-
           Client.request(Socket.netlink_generic(), @genl_id_ctrl, payload, opts),
         %{attrs: attrs_binary} <- Header.decode_genlmsg(message.payload),
         {:ok, family_id} <- attrs_binary |> Attr.decode() |> Attr.get_u16(@ctrl_attr_family_id) do
      {:ok, family_id}
    else
      {:ok, []} -> {:error, :missing_family_reply}
      :error -> {:error, :missing_family_id}
      {:error, _reason} = error -> error
    end
  end
end
