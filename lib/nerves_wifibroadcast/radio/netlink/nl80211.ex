defmodule NervesWifibroadcast.Radio.Netlink.Nl80211 do
  @moduledoc false

  alias NervesWifibroadcast.Radio.Channel
  alias NervesWifibroadcast.Radio.Netlink.Attr
  alias NervesWifibroadcast.Radio.Netlink.Client
  alias NervesWifibroadcast.Radio.Netlink.Genl
  alias NervesWifibroadcast.Radio.Netlink.Header
  alias NervesWifibroadcast.Radio.Netlink.Socket

  @family_name "nl80211"
  @version 1

  @cmd_set_wiphy 2
  @cmd_set_interface 6
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
    with {:ok, family_id} <- Genl.family_id(@family_name, opts),
         payload <- Header.genlmsg(cmd, @version, attrs),
         {:ok, _replies} <- Client.request(Socket.netlink_generic(), family_id, payload, opts) do
      :ok
    end
  end

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
