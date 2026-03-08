defmodule NervesWifibroadcast.TestSupport.FakeAFPacket do
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

defmodule NervesWifibroadcast.Membrane.Radio.SourceTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias NervesWifibroadcast.Membrane.Radio.Source
  alias NervesWifibroadcast.Membrane.Radio.StreamFormat
  alias NervesWifibroadcast.Radiotap
  alias NervesWifibroadcast.TestSupport.FakeAFPacket

  setup do
    Process.delete(:fake_af_packet_results)
    :ok
  end

  test "playing arms an async recvmsg operation for each interface" do
    put_fake_results(%{
      socket("wlan0") => [:select],
      socket("wlan1") => [:select]
    })

    state = source_state(["wlan0", "wlan1"])
    {[], state} = Source.handle_setup(%{}, state)

    assert {[{:stream_format, {:output, %StreamFormat{interfaces: ["wlan0", "wlan1"]}}}], state} =
             Source.handle_playing(%{}, state)

    assert %{read_state: {:waiting, handle0}, receiver_idx: 0} = state.receivers[socket("wlan0")]
    assert %{read_state: {:waiting, handle1}, receiver_idx: 1} = state.receivers[socket("wlan1")]
    assert is_reference(handle0)
    assert is_reference(handle1)
  end

  test "select notification drains one packet from the matching socket and re-arms it" do
    packet = radiotap_packet()

    put_fake_results(%{
      socket("wlan0") => [
        :select,
        {:ok, %{iov: [packet], flags: [], addr: %{ifindex: 7}, ctrl: []}},
        :select
      ],
      socket("wlan1") => [:select]
    })

    state = source_state(["wlan0", "wlan1"])
    {[], state} = Source.handle_setup(%{}, state)
    {[_stream_format], state} = Source.handle_playing(%{}, state)
    %{read_state: {:waiting, handle}} = state.receivers[socket("wlan0")]

    {[], state} = Source.handle_demand(:output, 1, :buffers, %{}, state)

    assert {[{:buffer, {:output, %Buffer{} = buffer}}], state} =
             Source.handle_info({:"$socket", socket("wlan0"), :select, handle}, %{}, state)

    assert buffer.payload == <<0x08, 0x01>>
    assert buffer.metadata.radio.capture_ts == 123
    assert buffer.metadata.radio.raw_length == byte_size(packet)
    assert buffer.metadata.radio.receiver_idx == 0
    assert buffer.metadata.radio.socket_addr == %{ifindex: 7}
    assert buffer.metadata.radio.socket_flags == []
    assert %Radiotap{} = buffer.metadata.radio.radiotap

    assert {:waiting, next_handle} = state.receivers[socket("wlan0")].read_state
    refute next_handle == handle
    assert match?({:waiting, _handle}, state.receivers[socket("wlan1")].read_state)
  end

  test "closing one socket keeps the source alive on remaining interfaces" do
    put_fake_results(%{
      socket("wlan0") => [:select],
      socket("wlan1") => [:select]
    })

    state = source_state(["wlan0", "wlan1"])
    {[], state} = Source.handle_setup(%{}, state)
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

    state = source_state(["wlan0", "wlan1"])
    {[], state} = Source.handle_setup(%{}, state)
    {[_stream_format], state} = Source.handle_playing(%{}, state)
    %{read_state: {:waiting, handle0}} = state.receivers[socket("wlan0")]
    %{read_state: {:waiting, handle1}} = state.receivers[socket("wlan1")]

    assert {[{:terminate, :normal}], _state} = Source.handle_terminate_request(%{}, state)

    assert_received {:fake_af_packet_cancel, {:fake_socket, "wlan0"}, ^handle0}
    assert_received {:fake_af_packet_cancel, {:fake_socket, "wlan1"}, ^handle1}
    assert_received {:fake_af_packet_close, {:fake_socket, "wlan0"}}
    assert_received {:fake_af_packet_close, {:fake_socket, "wlan1"}}
  end

  defp source_state(interfaces) do
    opts =
      struct(Source,
        capture_ts_fun: fn -> 123 end,
        interfaces: interfaces,
        max_read_burst: 8,
        socket_backend: FakeAFPacket
      )

    {[], state} = Source.handle_init(%{}, opts)
    state
  end

  defp socket(interface), do: {:fake_socket, interface}

  defp put_fake_results(results_by_socket) do
    Process.put(:fake_af_packet_results, results_by_socket)
  end

  defp radiotap_packet do
    <<
      0,
      0,
      8::little-16,
      0::little-32,
      0x08,
      0x01
    >>
  end
end
