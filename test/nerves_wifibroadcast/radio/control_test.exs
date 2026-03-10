defmodule NervesWifibroadcast.TestSupport.FakeNetlinkSocket do
  import Kernel, except: [send: 2]

  def open(domain, type, protocol) do
    socket = {:fake_netlink_socket, protocol, make_ref()}
    Kernel.send(self(), {:fake_netlink_open, socket, domain, type, protocol})
    {:ok, socket}
  end

  def bind(socket, sockaddr) do
    Kernel.send(self(), {:fake_netlink_bind, socket, sockaddr})
    :ok
  end

  def connect(socket, sockaddr) do
    Kernel.send(self(), {:fake_netlink_connect, socket, sockaddr})
    :ok
  end

  def send(socket, payload) do
    handler = Process.get(:fake_netlink_handler, fn _socket, _payload -> [] end)
    responses = List.wrap(handler.(socket, payload))
    queues = Process.get(:fake_netlink_recv_queues, %{})

    Process.put(:fake_netlink_recv_queues, Map.put(queues, socket, responses))
    Kernel.send(self(), {:fake_netlink_send, socket, payload})
    :ok
  end

  def recv(socket, _length, _timeout) do
    queues = Process.get(:fake_netlink_recv_queues, %{})

    case Map.get(queues, socket, []) do
      [response | rest] ->
        Process.put(:fake_netlink_recv_queues, Map.put(queues, socket, rest))
        {:ok, response}

      [] ->
        {:error, :timeout}
    end
  end

  def close(socket) do
    Kernel.send(self(), {:fake_netlink_close, socket})
    :ok
  end
end

defmodule NervesWifibroadcast.Radio.ControlTest do
  use ExUnit.Case, async: false

  alias NervesWifibroadcast.Radio.Control
  alias NervesWifibroadcast.Radio.Netlink.Nl80211
  alias NervesWifibroadcast.Radio.Netlink.Attr
  alias NervesWifibroadcast.Radio.Netlink.Header

  @nl80211_family_id 0x55

  setup do
    Process.delete(:fake_netlink_handler)
    Process.delete(:fake_netlink_recv_queues)
    Process.delete(:monitor_step)

    on_exit(fn ->
      Process.delete(:fake_netlink_handler)
      Process.delete(:fake_netlink_recv_queues)
      Process.delete(:monitor_step)
    end)

    :ok
  end

  test "set_region sends nl80211 regulatory request" do
    Process.put(:fake_netlink_handler, fn {:fake_netlink_socket, protocol, _ref}, payload ->
      [message] = Header.decode_messages(payload)

      case {protocol, message.type} do
        {16, 16} ->
          %{cmd: 3, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, family_name} = Attr.get_binary(attrs, 2)
          assert trim_null(family_name) == "nl80211"
          [family_reply_and_ack(message.seq, @nl80211_family_id)]

        {16, @nl80211_family_id} ->
          %{cmd: 27, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, region} = Attr.get_binary(attrs, 33)
          assert trim_null(region) == "BO"
          [ack(message.seq)]
      end
    end)

    assert :ok = Control.set_region("bo", netlink_opts())
  end

  test "set_tx_power resolves nl80211 family and applies tx power" do
    Process.put(:fake_netlink_handler, fn {:fake_netlink_socket, protocol, _ref}, payload ->
      [message] = Header.decode_messages(payload)

      case {protocol, message.type} do
        {16, 16} ->
          %{cmd: 3, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, family_name} = Attr.get_binary(attrs, 2)
          assert trim_null(family_name) == "nl80211"
          [family_reply_and_ack(message.seq, @nl80211_family_id)]

        {16, @nl80211_family_id} ->
          %{cmd: 2, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, 7} = Attr.get_u32(attrs, 3)
          assert {:ok, 2} = Attr.get_u32(attrs, 96)
          assert %{payload: <<3000::native-signed-32>>} = Attr.find(attrs, 97)
          [ack(message.seq)]
      end
    end)

    assert :ok =
             Control.set_tx_power("wlan0", {:dbm, 30},
               driver: :rtl8812eu,
               socket_module: NervesWifibroadcast.TestSupport.FakeNetlinkSocket,
               ifindex_resolver: &ifindex_resolver/1
             )

    assert_received {:fake_netlink_open, _, 16, 3, 16}
    assert_received {:fake_netlink_open, _, 16, 3, 16}
  end

  test "set_tx_power skips netlink work for :off" do
    assert :ok =
             Control.set_tx_power("missing0", :off,
               socket_module: NervesWifibroadcast.TestSupport.FakeNetlinkSocket,
               ifindex_resolver: fn _interface ->
                 flunk("ifindex should not be resolved for :off")
               end
             )

    refute_received {:fake_netlink_open, _, _, _, _}
  end

  test "set_monitor_mode uses rtnetlink down then nl80211 monitor then up" do
    Process.put(:monitor_step, :down)

    Process.put(:fake_netlink_handler, fn {:fake_netlink_socket, protocol, _ref}, payload ->
      [message] = Header.decode_messages(payload)

      case {protocol, message.type, Process.get(:monitor_step)} do
        {0, 16, :down} ->
          assert_ifinfomsg(message.payload, 7, 0x0, 0x1)
          Process.put(:monitor_step, :family)
          [ack(message.seq)]

        {16, 16, :family} ->
          %{cmd: 3, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, family_name} = Attr.get_binary(attrs, 2)
          assert trim_null(family_name) == "nl80211"
          Process.put(:monitor_step, :monitor)
          [family_reply_and_ack(message.seq, @nl80211_family_id)]

        {16, @nl80211_family_id, :monitor} ->
          %{cmd: 6, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, 7} = Attr.get_u32(attrs, 3)
          assert {:ok, 6} = Attr.get_u32(attrs, 5)
          assert %{nested?: true} = Attr.find(attrs, 23)
          Process.put(:monitor_step, :up)
          [ack(message.seq)]

        {0, 16, :up} ->
          assert_ifinfomsg(message.payload, 7, 0x1, 0x1)
          Process.put(:monitor_step, :done)
          [ack(message.seq)]
      end
    end)

    assert :ok = Control.set_monitor_mode("wlan0", netlink_opts())
    assert Process.get(:monitor_step) == :done
  end

  test "set_channel converts channel to frequency" do
    Process.put(:fake_netlink_handler, fn {:fake_netlink_socket, protocol, _ref}, payload ->
      [message] = Header.decode_messages(payload)

      case {protocol, message.type} do
        {16, 16} ->
          [family_reply_and_ack(message.seq, @nl80211_family_id)]

        {16, @nl80211_family_id} ->
          %{cmd: 2, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, 7} = Attr.get_u32(attrs, 3)
          assert {:ok, 5745} = Attr.get_u32(attrs, 38)
          assert {:ok, 1} = Attr.get_u32(attrs, 39)
          [ack(message.seq)]
      end
    end)

    assert :ok = Control.set_channel("wlan0", 149, 20, netlink_opts())
  end

  test "get_iftype resolves nl80211 family and decodes monitor mode" do
    Process.put(:fake_netlink_handler, fn {:fake_netlink_socket, protocol, _ref}, payload ->
      [message] = Header.decode_messages(payload)

      case {protocol, message.type} do
        {16, 16} ->
          [family_reply_and_ack(message.seq, @nl80211_family_id)]

        {16, @nl80211_family_id} ->
          %{cmd: 5, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, 7} = Attr.get_u32(attrs, 3)

          [
            Header.nlmsg(
              @nl80211_family_id,
              0,
              message.seq,
              0,
              Header.genlmsg(7, 1, [Attr.u32(3, 7), Attr.u32(5, 6)])
            ) <> ack(message.seq)
          ]
      end
    end)

    assert {:ok, :monitor} =
             Nl80211.get_iftype(7,
               socket_module: NervesWifibroadcast.TestSupport.FakeNetlinkSocket
             )
  end

  test "get_iftype preserves unknown nl80211 interface types" do
    Process.put(:fake_netlink_handler, fn {:fake_netlink_socket, protocol, _ref}, payload ->
      [message] = Header.decode_messages(payload)

      case {protocol, message.type} do
        {16, 16} ->
          [family_reply_and_ack(message.seq, @nl80211_family_id)]

        {16, @nl80211_family_id} ->
          [
            Header.nlmsg(
              @nl80211_family_id,
              0,
              message.seq,
              0,
              Header.genlmsg(7, 1, [Attr.u32(3, 7), Attr.u32(5, 42)])
            ) <> ack(message.seq)
          ]
      end
    end)

    assert {:ok, {:unknown, 42}} =
             Nl80211.get_iftype(7,
               socket_module: NervesWifibroadcast.TestSupport.FakeNetlinkSocket
             )
  end

  test "set_frequency includes center frequency for 80 MHz" do
    Process.put(:fake_netlink_handler, fn {:fake_netlink_socket, protocol, _ref}, payload ->
      [message] = Header.decode_messages(payload)

      case {protocol, message.type} do
        {16, 16} ->
          [family_reply_and_ack(message.seq, @nl80211_family_id)]

        {16, @nl80211_family_id} ->
          %{cmd: 2, attrs: attrs_binary} = Header.decode_genlmsg(message.payload)
          attrs = Attr.decode(attrs_binary)
          assert {:ok, 5775} = Attr.get_u32(attrs, 38)
          assert {:ok, 3} = Attr.get_u32(attrs, 158)
          assert {:ok, 5775} = Attr.get_u32(attrs, 159)
          [ack(message.seq)]
      end
    end)

    assert :ok = Control.set_frequency("wlan0", 5775, 80, netlink_opts())
  end

  defp netlink_opts do
    [
      socket_module: NervesWifibroadcast.TestSupport.FakeNetlinkSocket,
      ifindex_resolver: &ifindex_resolver/1
    ]
  end

  defp ifindex_resolver("wlan0"), do: {:ok, 7}
  defp ifindex_resolver(interface), do: {:error, {:unknown_interface, interface}}

  defp family_reply_and_ack(seq, family_id) do
    family_reply =
      Header.nlmsg(
        16,
        0,
        seq,
        0,
        Header.genlmsg(3, 2, [Attr.u16(1, family_id), Attr.string(2, "nl80211")])
      )

    family_reply <> ack(seq)
  end

  defp ack(seq) do
    Header.nlmsg(2, 0, seq, 0, <<0::native-signed-32, 0::size(128)>>)
  end

  defp assert_ifinfomsg(
         <<_family::8, _pad::8, _type::native-16, ifindex::native-signed-32, flags::native-32,
           change::native-32>>,
         expected_ifindex,
         expected_flags,
         expected_change
       ) do
    assert ifindex == expected_ifindex
    assert flags == expected_flags
    assert change == expected_change
  end

  defp trim_null(binary) do
    binary
    |> :binary.split(<<0>>, [:global])
    |> hd()
  end
end
