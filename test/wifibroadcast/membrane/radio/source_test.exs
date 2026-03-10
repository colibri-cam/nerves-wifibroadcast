defmodule Wifibroadcast.TestSupport.FakeAFPacket do
  def open(opts) do
    interface = Keyword.fetch!(opts, :interface)
    {:ok, {:fake_socket, interface}}
  end

  def recvmsg(socket, _buffer_size, _control_size, handle) do
    case pop_result(socket) do
      {:ok, result} -> normalize_result(result, handle)
      :empty -> {:select, {:select_info, :recvmsg, handle}}
    end
  end

  def cancel(socket, handle) do
    send(self(), {:fake_af_packet_cancel, socket, handle})
    :ok
  end

  def close(socket) do
    send(self(), {:fake_af_packet_close, socket})
    :ok
  end

  defp pop_result(socket) do
    results_by_socket = Process.get(:fake_af_packet_results, %{})

    case Map.get(results_by_socket, socket, []) do
      [result | rest] ->
        Process.put(:fake_af_packet_results, Map.put(results_by_socket, socket, rest))
        {:ok, result}

      [] ->
        :empty
    end
  end

  defp normalize_result(:select, handle), do: {:select, {:select_info, :recvmsg, handle}}
  defp normalize_result({:ok, msg}, _handle), do: {:ok, msg}
  defp normalize_result({:error, reason}, _handle), do: {:error, reason}
end

defmodule Wifibroadcast.Membrane.Radio.SourceTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.Pad
  alias Wifibroadcast.Membrane.Radio.Source
  alias Wifibroadcast.Membrane.WFB.StreamFormat
  alias Wifibroadcast.Radiotap
  alias Wifibroadcast.TestSupport.FakeAFPacket

  require Membrane.Pad

  @link_id 0x010203
  @radio_port 0x04
  @other_radio_port 0x08
  @channel_id (@link_id <<< 8) + @radio_port
  @other_channel_id (@link_id <<< 8) + @other_radio_port

  setup do
    Process.delete(:fake_af_packet_results)
    :ok
  end

  test "playing arms an async recvmsg operation for each interface and emits per-pad stream formats" do
    put_fake_results(%{
      socket("wlan0") => [:select],
      socket("wlan1") => [:select]
    })

    state = source_state(["wlan0", "wlan1"], radio_ports: [@radio_port, @other_radio_port])
    {[], state} = Source.handle_setup(%{}, state)

    pad0 = Pad.ref(:output, @radio_port)
    pad1 = Pad.ref(:output, @other_radio_port)

    {[], state} = Source.handle_pad_added(pad0, %{}, state)
    {[], state} = Source.handle_pad_added(pad1, %{}, state)

    assert {[
              stream_format:
                {^pad0, %StreamFormat{channel_id: @channel_id, interfaces: ["wlan0", "wlan1"]}},
              stream_format:
                {^pad1,
                 %StreamFormat{channel_id: @other_channel_id, interfaces: ["wlan0", "wlan1"]}}
            ], state} = Source.handle_playing(%{}, state)

    assert %{read_state: {:waiting, handle0}, receiver_idx: 0} = state.receivers[socket("wlan0")]
    assert %{read_state: {:waiting, handle1}, receiver_idx: 1} = state.receivers[socket("wlan1")]
    assert is_reference(handle0)
    assert is_reference(handle1)
  end

  test "select notification routes one packet to the matching radio_port and re-arms it" do
    packet =
      radiotap_packet(wfb_frame(@channel_id, data_packet(0x0102030405060708, <<0x08, 0x01>>)))

    put_fake_results(%{
      socket("wlan0") => [
        :select,
        {:ok, %{iov: [packet], flags: [], addr: %{ifindex: 7}, ctrl: []}},
        :select
      ],
      socket("wlan1") => [:select]
    })

    pad = Pad.ref(:output, @radio_port)

    state = source_state(["wlan0", "wlan1"], radio_ports: [@radio_port])
    {[], state} = Source.handle_setup(%{}, state)
    {[], state} = Source.handle_pad_added(pad, %{}, state)

    {[stream_format: {^pad, %StreamFormat{channel_id: @channel_id}}], state} =
      Source.handle_playing(%{}, state)

    %{read_state: {:waiting, handle}} = state.receivers[socket("wlan0")]

    {[], state} = Source.handle_demand(pad, 1, :buffers, %{}, state)

    assert {[buffer: {^pad, %Buffer{} = buffer}], state} =
             Source.handle_info({:"$socket", socket("wlan0"), :select, handle}, %{}, state)

    assert buffer.payload == <<0x08, 0x01>>
    assert buffer.metadata.ieee80211.header_len == 24
    assert buffer.metadata.wfb.channel_id == @channel_id
    assert buffer.metadata.wfb.packet_type == :data
    assert buffer.metadata.wfb.packet_type_byte == 0x01
    assert buffer.metadata.wfb.data_nonce == 0x0102030405060708
    assert buffer.metadata.wfb.block_idx == 0x01020304050607
    assert buffer.metadata.wfb.fragment_idx == 0x08
    assert buffer.metadata.wfb.link_id == @link_id
    assert buffer.metadata.wfb.radio_port == @radio_port
    assert buffer.metadata.radio.capture_ts == 123
    assert buffer.metadata.radio.raw_length == byte_size(packet)
    assert buffer.metadata.radio.receiver_idx == 0
    assert buffer.metadata.radio.socket_addr == %{ifindex: 7}
    assert buffer.metadata.radio.socket_flags == []
    assert %Radiotap{} = buffer.metadata.radio.radiotap
    assert state.counters.passed_packets == 1

    assert {:waiting, next_handle} = state.receivers[socket("wlan0")].read_state
    refute next_handle == handle
    assert match?({:waiting, _handle}, state.receivers[socket("wlan1")].read_state)
  end

  test "drops unknown radio ports until they are enabled at runtime" do
    packet = radiotap_packet(wfb_frame(@other_channel_id, data_packet(0xAA, <<0x01>>)))

    put_fake_results(%{
      socket("wlan0") => [:select],
      socket("wlan1") => [:select]
    })

    pad = Pad.ref(:output, @other_radio_port)

    state = source_state(["wlan0", "wlan1"], radio_ports: [@radio_port])
    {[], state} = Source.handle_setup(%{}, state)
    {[], state} = Source.handle_pad_added(pad, %{}, state)

    {[stream_format: {^pad, %StreamFormat{channel_id: @other_channel_id}}], state} =
      Source.handle_playing(%{}, state)

    {[], state} = Source.handle_demand(pad, 1, :buffers, %{}, state)

    assert {[], state} = Source.handle_info({:radio_packet, 0, packet}, %{}, state)
    assert state.counters.unknown_radio_port_drops == 1

    {[], state} =
      Source.handle_parent_notification({:add_radio_port, @other_radio_port}, %{}, state)

    assert {[buffer: {^pad, %Buffer{} = buffer}], state} =
             Source.handle_info({:radio_packet, 0, packet}, %{}, state)

    assert buffer.metadata.wfb.radio_port == @other_radio_port
    assert state.counters.passed_packets == 1
  end

  test "closing one socket keeps the source alive on remaining interfaces" do
    put_fake_results(%{
      socket("wlan0") => [:select],
      socket("wlan1") => [:select]
    })

    pad = Pad.ref(:output, @radio_port)

    state = source_state(["wlan0", "wlan1"], radio_ports: [@radio_port])
    {[], state} = Source.handle_setup(%{}, state)
    {[], state} = Source.handle_pad_added(pad, %{}, state)
    {[_stream_format], state} = Source.handle_playing(%{}, state)
    %{read_state: {:waiting, handle}} = state.receivers[socket("wlan0")]

    put_fake_results(%{
      socket("wlan0") => [{:error, :closed}],
      socket("wlan1") => []
    })

    assert {[notify_parent: {:radio_source_socket_closed, "wlan0"}], state} =
             Source.handle_info({:"$socket", socket("wlan0"), :select, handle}, %{}, state)

    refute Map.has_key?(state.receivers, socket("wlan0"))
    assert Map.has_key?(state.receivers, socket("wlan1"))
    assert_received {:fake_af_packet_close, {:fake_socket, "wlan0"}}
  end

  test "terminate request cancels pending recvmsg operations and closes all sockets" do
    put_fake_results(%{
      socket("wlan0") => [:select],
      socket("wlan1") => [:select]
    })

    pad = Pad.ref(:output, @radio_port)

    state = source_state(["wlan0", "wlan1"], radio_ports: [@radio_port])
    {[], state} = Source.handle_setup(%{}, state)
    {[], state} = Source.handle_pad_added(pad, %{}, state)
    {[_stream_format], state} = Source.handle_playing(%{}, state)
    %{read_state: {:waiting, handle0}} = state.receivers[socket("wlan0")]
    %{read_state: {:waiting, handle1}} = state.receivers[socket("wlan1")]

    assert {[{:terminate, :normal}], _state} = Source.handle_terminate_request(%{}, state)

    assert_received {:fake_af_packet_cancel, {:fake_socket, "wlan0"}, ^handle0}
    assert_received {:fake_af_packet_cancel, {:fake_socket, "wlan1"}, ^handle1}
    assert_received {:fake_af_packet_close, {:fake_socket, "wlan0"}}
    assert_received {:fake_af_packet_close, {:fake_socket, "wlan1"}}
  end

  defp source_state(interfaces, opts) do
    opts =
      Keyword.merge(
        [
          capture_ts_fun: fn -> 123 end,
          interfaces: interfaces,
          link_id: @link_id,
          max_read_burst: 8,
          radio_ports: [@radio_port],
          socket_backend: FakeAFPacket
        ],
        opts
      )

    {[], state} = Source.handle_init(%{}, struct(Source, opts))
    state
  end

  defp socket(interface), do: {:fake_socket, interface}

  defp put_fake_results(results_by_socket) do
    Process.put(:fake_af_packet_results, results_by_socket)
  end

  defp radiotap_packet(frame) do
    <<0, 0, 8::little-16, 0::little-32, frame::binary>>
  end

  defp wfb_frame(channel_id, wfb_packet, opts \\ []) do
    receiver_mac = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
    source_mac = Keyword.get(opts, :source_mac, <<0x57, 0x42, channel_id::big-32>>)
    bssid_mac = Keyword.get(opts, :bssid_mac, <<0x57, 0x42, channel_id::big-32>>)

    frame =
      <<0x0108::little-16, 0::little-16, receiver_mac::binary, source_mac::binary,
        bssid_mac::binary, 0::little-16, wfb_packet::binary>>

    if Keyword.get(opts, :append_fcs?, false) do
      frame <> <<0xDE, 0xAD, 0xBE, 0xEF>>
    else
      frame
    end
  end

  defp data_packet(data_nonce, ciphertext), do: <<0x01, data_nonce::big-64, ciphertext::binary>>
end
