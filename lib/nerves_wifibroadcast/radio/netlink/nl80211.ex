defmodule NervesWifibroadcast.Radio.Netlink.Nl80211 do
  @moduledoc false

  alias NervesWifibroadcast.Radio.Channel
  alias NervesWifibroadcast.Radio.Interface
  alias NervesWifibroadcast.Radio.Netlink.Attr
  alias NervesWifibroadcast.Radio.Netlink.Client
  alias NervesWifibroadcast.Radio.Netlink.Genl
  alias NervesWifibroadcast.Radio.Netlink.Header
  alias NervesWifibroadcast.Radio.Netlink.Socket

  @family_name "nl80211"
  @version 1

  @cmd_get_interface 5
  @cmd_set_wiphy 2
  @cmd_set_interface 6
  @cmd_new_interface 7
  @cmd_req_set_reg 27

  @attr_ifindex 3
  @attr_iftype 5
  @attr_mntr_flags 23
  @attr_reg_alpha2 33
  @attr_wiphy_freq 38
  @attr_wiphy_channel_type 39
  @attr_wiphy_tx_power_setting 96
  @attr_wiphy_tx_power_level 97
  @attr_channel_width 158
  @attr_center_freq1 159

  @iftype_monitor 6
  @mntr_flag_other_bss 4

  @chan_ht20 1
  @chan_ht40minus 2
  @chan_ht40plus 3

  @chan_width_80 3
  @chan_width_160 5
  @chan_width_5 6
  @chan_width_10 7

  @tx_power_fixed 2

  @spec set_region(String.t(), Keyword.t()) :: :ok | {:error, term()}
  def set_region(region, opts \\ []) do
    with {:ok, family_id} <- Genl.family_id(@family_name, opts),
         payload <-
           Header.genlmsg(@cmd_req_set_reg, @version, Attr.string(@attr_reg_alpha2, region)),
         {:ok, _replies} <- Client.request(Socket.netlink_generic(), family_id, payload, opts) do
      :ok
    end
  end

  @spec set_monitor_mode(pos_integer(), Keyword.t()) :: :ok | {:error, term()}
  def set_monitor_mode(ifindex, opts \\ []) when is_integer(ifindex) and ifindex > 0 do
    attrs = [
      Attr.u32(@attr_ifindex, ifindex),
      Attr.u32(@attr_iftype, @iftype_monitor),
      Attr.nested(@attr_mntr_flags, Attr.flag(@mntr_flag_other_bss))
    ]

    request(@cmd_set_interface, attrs, opts)
  end

  @spec get_iftype(pos_integer(), Keyword.t()) :: {:ok, Interface.iftype_t()} | {:error, term()}
  def get_iftype(ifindex, opts \\ []) when is_integer(ifindex) and ifindex > 0 do
    with {:ok, replies} <-
           request_reply(@cmd_get_interface, [Attr.u32(@attr_ifindex, ifindex)], opts),
         {:ok, attrs} <- interface_reply_attrs(replies, ifindex),
         {:ok, iftype_value} <- fetch_iftype(attrs) do
      {:ok, decode_iftype(iftype_value)}
    end
  end

  @spec set_frequency(pos_integer(), pos_integer(), Channel.width_spec(), Keyword.t()) ::
          :ok | {:error, term()}
  def set_frequency(ifindex, frequency_mhz, width, opts \\ [])
      when is_integer(ifindex) and ifindex > 0 do
    attrs =
      [
        Attr.u32(@attr_ifindex, ifindex),
        Attr.u32(@attr_wiphy_freq, frequency_mhz)
      ] ++ width_attrs(frequency_mhz, width)

    request(@cmd_set_wiphy, attrs, opts)
  end

  @spec set_tx_power(pos_integer(), nil | :off | integer(), Keyword.t()) :: :ok | {:error, term()}
  def set_tx_power(_ifindex, nil, _opts), do: :ok
  def set_tx_power(_ifindex, :off, _opts), do: :ok

  def set_tx_power(ifindex, mbm, opts)
      when is_integer(ifindex) and ifindex > 0 and is_integer(mbm) do
    attrs = [
      Attr.u32(@attr_ifindex, ifindex),
      Attr.u32(@attr_wiphy_tx_power_setting, @tx_power_fixed),
      Attr.s32(@attr_wiphy_tx_power_level, mbm)
    ]

    request(@cmd_set_wiphy, attrs, opts)
  end

  defp request(cmd, attrs, opts) do
    with {:ok, _replies} <- request_reply(cmd, attrs, opts) do
      :ok
    end
  end

  defp request_reply(cmd, attrs, opts) do
    with {:ok, family_id} <- Genl.family_id(@family_name, opts),
         payload <- Header.genlmsg(cmd, @version, attrs),
         {:ok, replies} <- Client.request(Socket.netlink_generic(), family_id, payload, opts) do
      {:ok, replies}
    end
  end

  defp interface_reply_attrs([], _ifindex), do: {:error, :missing_interface_reply}

  defp interface_reply_attrs(replies, ifindex) do
    Enum.find_value(replies, {:error, :missing_interface_reply}, fn message ->
      case Header.decode_genlmsg(message.payload) do
        %{cmd: @cmd_new_interface, attrs: attrs_binary} ->
          attrs = Attr.decode(attrs_binary)

          case Attr.get_u32(attrs, @attr_ifindex) do
            {:ok, ^ifindex} -> {:ok, attrs}
            {:ok, _other_ifindex} -> nil
            :error -> {:error, :missing_reply_ifindex}
          end

        _other ->
          nil
      end
    end)
  end

  defp fetch_iftype(attrs) do
    case Attr.get_u32(attrs, @attr_iftype) do
      {:ok, iftype_value} -> {:ok, iftype_value}
      :error -> {:error, :missing_iftype}
    end
  end

  defp decode_iftype(0), do: :unspecified
  defp decode_iftype(1), do: :adhoc
  defp decode_iftype(2), do: :station
  defp decode_iftype(3), do: :ap
  defp decode_iftype(4), do: :ap_vlan
  defp decode_iftype(5), do: :wds
  defp decode_iftype(6), do: :monitor
  defp decode_iftype(7), do: :mesh_point
  defp decode_iftype(8), do: :p2p_client
  defp decode_iftype(9), do: :p2p_go
  defp decode_iftype(10), do: :p2p_device
  defp decode_iftype(11), do: :ocb
  defp decode_iftype(12), do: :nan
  defp decode_iftype(value), do: {:unknown, value}

  defp width_attrs(_frequency_mhz, {:ofdm, 5}), do: [Attr.u32(@attr_channel_width, @chan_width_5)]

  defp width_attrs(_frequency_mhz, {:ofdm, 10}),
    do: [Attr.u32(@attr_channel_width, @chan_width_10)]

  defp width_attrs(_frequency_mhz, :ht20), do: [Attr.u32(@attr_wiphy_channel_type, @chan_ht20)]

  defp width_attrs(_frequency_mhz, {:ht40, :plus}),
    do: [Attr.u32(@attr_wiphy_channel_type, @chan_ht40plus)]

  defp width_attrs(_frequency_mhz, {:ht40, :minus}),
    do: [Attr.u32(@attr_wiphy_channel_type, @chan_ht40minus)]

  defp width_attrs(frequency_mhz, {:vht, 80}) do
    [
      Attr.u32(@attr_channel_width, @chan_width_80),
      Attr.u32(@attr_center_freq1, Channel.center_frequency1!(frequency_mhz, {:vht, 80}))
    ]
  end

  defp width_attrs(frequency_mhz, {:vht, 160}) do
    [
      Attr.u32(@attr_channel_width, @chan_width_160),
      Attr.u32(@attr_center_freq1, Channel.center_frequency1!(frequency_mhz, {:vht, 160}))
    ]
  end
end
