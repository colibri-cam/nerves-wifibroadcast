defmodule Wifibroadcast.TestSupport.FakeTxAFPacket do
  import Kernel, except: [send: 2]

  def open_tx(opts) do
    interface = Keyword.fetch!(opts, :interface)

    if interface in Process.get(:fake_tx_open_failures, []) do
      {:error, :open_failed}
    else
      socket = {:fake_tx_socket, interface}
      Kernel.send(self(), {:fake_tx_open, interface, opts})
      {:ok, socket}
    end
  end

  def set_tx_mark(socket, fwmark) do
    Kernel.send(self(), {:fake_tx_mark, socket, fwmark})
    :ok
  end

  def send(socket, packet) do
    case pop_send_result(socket) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        Kernel.send(self(), {:fake_tx_send, socket, IO.iodata_to_binary(packet)})
        :ok
    end
  end

  def close(socket) do
    Kernel.send(self(), {:fake_tx_close, socket})
    :ok
  end

  defp pop_send_result(socket) do
    results_by_socket = Process.get(:fake_tx_send_results, %{})

    case Map.get(results_by_socket, socket, []) do
      [result | rest] ->
        Process.put(:fake_tx_send_results, Map.put(results_by_socket, socket, rest))
        result

      [] ->
        :ok
    end
  end
end

defmodule Wifibroadcast.Membrane.Radio.SinkTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias Membrane.Pad
  alias Wifibroadcast.Membrane.Radio.Sink
  alias Wifibroadcast.Membrane.WFB.Router
  alias Wifibroadcast.Radiotap.Parser
  alias Wifibroadcast.TestSupport.WFBFixtures

  require Membrane.Pad

  @link_id 0x010203
  @radio_port 0x04
  @other_radio_port 0x08

  setup do
    Process.delete(:fake_tx_open_failures)
    Process.delete(:fake_tx_send_results)
    :ok
  end

  test "injects one WFB frame per interface for incoming data packets" do
    pad = Pad.ref(:input, @radio_port)

    session =
      WFBFixtures.session_plaintext(
        link_id: @link_id,
        radio_port: @radio_port,
        fec_k: 2,
        fec_n: 3
      )

    buffer = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("alpha"), session, 22, 1)

    state = sink_state(["wlan0", "wlan1"], [])
    {[], state} = Sink.handle_setup(%{}, state)
    assert_received {:fake_tx_open, "wlan0", open_opts0}
    assert_received {:fake_tx_open, "wlan1", open_opts1}
    assert open_opts0[:use_qdisc?] == false
    assert open_opts1[:use_qdisc?] == false
    {[], state} = Sink.handle_pad_added(pad, %{}, state)

    {[], state} =
      Sink.handle_stream_format(
        pad,
        WFBFixtures.ingress_stream_format(
          link_id: @link_id,
          radio_port: @radio_port,
          encrypted?: false
        ),
        %{},
        state
      )

    {[], state} = Sink.handle_playing(%{}, state)
    {[], state} = Sink.handle_buffer(pad, buffer, %{}, state)

    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, frame0}
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan1"}, frame1}

    {radiotap0, routed0} = decode_frame(frame0, [@radio_port])
    {radiotap1, routed1} = decode_frame(frame1, [@radio_port])

    assert routed0.payload == buffer.payload
    assert routed1.payload == buffer.payload
    assert routed0.metadata.wfb.block_idx == 22
    assert routed0.metadata.wfb.fragment_idx == 1
    assert routed0.metadata.wfb.radio_port == @radio_port
    assert radiotap0.mcs.index == 1
    assert radiotap0.mcs.bandwidth == 20
    assert radiotap1.mcs.index == 1
    assert state.counters.injected_packets == 2
    assert state.counters.injected_bytes == byte_size(frame0) + byte_size(frame1)
    refute_received {:fake_tx_mark, _, _}
  end

  test "wraps clear session packets with a generated nonce" do
    pad = Pad.ref(:input, @radio_port)

    session =
      WFBFixtures.session_plaintext(
        link_id: @link_id,
        radio_port: @radio_port,
        fec_k: 2,
        fec_n: 3
      )

    buffer = WFBFixtures.tx_session_buffer(session)

    state = sink_state(["wlan0"], [])
    {[], state} = Sink.handle_setup(%{}, state)
    {[], state} = Sink.handle_pad_added(pad, %{}, state)

    {[], state} =
      Sink.handle_stream_format(
        pad,
        WFBFixtures.ingress_stream_format(
          link_id: @link_id,
          radio_port: @radio_port,
          encrypted?: false
        ),
        %{},
        state
      )

    {[], state} = Sink.handle_playing(%{}, state)
    {[], state} = Sink.handle_buffer(pad, buffer, %{}, state)

    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, frame}

    {_radiotap, routed_buffer} = decode_frame(frame, [@radio_port])

    assert routed_buffer.payload == session.plaintext
    assert routed_buffer.metadata.wfb.packet_type == :session
    assert is_binary(routed_buffer.metadata.wfb.session_nonce)
    assert byte_size(routed_buffer.metadata.wfb.session_nonce) == 24
    assert state.counters.injected_packets == 1
  end

  test "updates radiotap configuration at runtime" do
    pad = Pad.ref(:input, @radio_port)

    session =
      WFBFixtures.session_plaintext(
        link_id: @link_id,
        radio_port: @radio_port,
        fec_k: 2,
        fec_n: 3
      )

    buffer = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("alpha"), session, 22, 1)

    state = sink_state(["wlan0"], [])
    {[], state} = Sink.handle_setup(%{}, state)
    {[], state} = Sink.handle_pad_added(pad, %{}, state)

    {[], state} =
      Sink.handle_stream_format(
        pad,
        WFBFixtures.ingress_stream_format(
          link_id: @link_id,
          radio_port: @radio_port,
          encrypted?: false
        ),
        %{},
        state
      )

    {[], state} = Sink.handle_playing(%{}, state)
    {[], state} = Sink.handle_buffer(pad, buffer, %{}, state)
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, frame0}
    {radiotap0, _routed0} = decode_frame(frame0, [@radio_port])

    assert radiotap0.mcs.index == 1
    assert radiotap0.mcs.bandwidth == 20
    refute radiotap0.mcs.short_gi?

    assert {[notify_parent: {:radio_sink_config_applied, notification}], state} =
             Sink.handle_parent_notification(
               {:set_radio_config,
                %{bandwidth: 40, ldpc: true, mcs_index: 7, short_gi: :short, stbc: 2}},
               %{},
               state
             )

    assert notification.phy.mcs_index == 7
    assert notification.phy.bandwidth == 40

    {[], _state} = Sink.handle_buffer(pad, buffer, %{}, state)
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, frame1}
    {radiotap1, _routed1} = decode_frame(frame1, [@radio_port])

    assert radiotap1.mcs.index == 7
    assert radiotap1.mcs.bandwidth == 40
    assert radiotap1.mcs.short_gi?
    assert radiotap1.mcs.fec == :ldpc
    assert radiotap1.mcs.stbc_streams == 2
  end

  test "applies fwmarks when qdisc is enabled" do
    pad = Pad.ref(:input, @radio_port)

    session =
      WFBFixtures.session_plaintext(
        link_id: @link_id,
        radio_port: @radio_port,
        fec_k: 2,
        fec_n: 3
      )

    source_buffer = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("alpha"), session, 22, 0)

    parity_buffer =
      WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("parity"), session, 22, 2,
        shard_role: :parity
      )

    state = sink_state(["wlan0"], use_qdisc?: true, fwmark_base: 100)
    {[], state} = Sink.handle_setup(%{}, state)
    assert_received {:fake_tx_open, "wlan0", open_opts}
    assert open_opts[:use_qdisc?] == true

    {[], state} = Sink.handle_pad_added(pad, %{}, state)

    {[], state} =
      Sink.handle_stream_format(
        pad,
        WFBFixtures.ingress_stream_format(
          link_id: @link_id,
          radio_port: @radio_port,
          encrypted?: false
        ),
        %{},
        state
      )

    {[], state} = Sink.handle_playing(%{}, state)
    {[], state} = Sink.handle_buffer(pad, source_buffer, %{}, state)
    {[], state} = Sink.handle_buffer(pad, source_buffer, %{}, state)
    {[], state} = Sink.handle_buffer(pad, parity_buffer, %{}, state)

    assert_receive {:fake_tx_mark, {:fake_tx_socket, "wlan0"}, 100}
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, _frame0}
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, _frame1}
    assert_receive {:fake_tx_mark, {:fake_tx_socket, "wlan0"}, 101}
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, _frame2}
    assert state.counters.fwmark_updates == 2
  end

  test "drains queued packets in round-robin order across radio ports" do
    pad0 = Pad.ref(:input, @radio_port)
    pad1 = Pad.ref(:input, @other_radio_port)

    session0 =
      WFBFixtures.session_plaintext(
        link_id: @link_id,
        radio_port: @radio_port,
        fec_k: 2,
        fec_n: 3
      )

    session1 =
      WFBFixtures.session_plaintext(
        link_id: @link_id,
        radio_port: @other_radio_port,
        fec_k: 2,
        fec_n: 3
      )

    buffer0a = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("a0"), session0, 1, 0)
    buffer0b = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("a1"), session0, 1, 1)
    buffer1a = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("b0"), session1, 1, 0)

    state = sink_state(["wlan0"], [])
    {[], state} = Sink.handle_setup(%{}, state)
    {[], state} = Sink.handle_pad_added(pad0, %{}, state)
    {[], state} = Sink.handle_pad_added(pad1, %{}, state)

    {[], state} =
      Sink.handle_stream_format(
        pad0,
        WFBFixtures.ingress_stream_format(
          link_id: @link_id,
          radio_port: @radio_port,
          encrypted?: false
        ),
        %{},
        state
      )

    {[], state} =
      Sink.handle_stream_format(
        pad1,
        WFBFixtures.ingress_stream_format(
          link_id: @link_id,
          radio_port: @other_radio_port,
          encrypted?: false
        ),
        %{},
        state
      )

    {[], state} = Sink.handle_buffer(pad0, buffer0a, %{}, state)
    {[], state} = Sink.handle_buffer(pad0, buffer0b, %{}, state)
    {[], state} = Sink.handle_buffer(pad1, buffer1a, %{}, state)
    {[], state} = Sink.handle_playing(%{}, state)

    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, frame_a0}
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, frame_b0}
    assert_receive {:fake_tx_send, {:fake_tx_socket, "wlan0"}, frame_a1}

    {_radiotap_a0, routed_a0} = decode_frame(frame_a0, [@radio_port, @other_radio_port])
    {_radiotap_b0, routed_b0} = decode_frame(frame_b0, [@radio_port, @other_radio_port])
    {_radiotap_a1, routed_a1} = decode_frame(frame_a1, [@radio_port, @other_radio_port])

    assert routed_a0.metadata.wfb.radio_port == @radio_port
    assert routed_b0.metadata.wfb.radio_port == @other_radio_port
    assert routed_a1.metadata.wfb.radio_port == @radio_port
    assert routed_a0.payload == buffer0a.payload
    assert routed_b0.payload == buffer1a.payload
    assert routed_a1.payload == buffer0b.payload
    assert state.counters.injected_packets == 3
  end

  test "terminate request closes all sockets" do
    pad = Pad.ref(:input, @radio_port)

    state = sink_state(["wlan0", "wlan1"], [])
    {[], state} = Sink.handle_setup(%{}, state)
    {[], state} = Sink.handle_pad_added(pad, %{}, state)

    assert {[terminate: :normal], _state} = Sink.handle_terminate_request(%{}, state)
    assert_receive {:fake_tx_close, {:fake_tx_socket, "wlan0"}}
    assert_receive {:fake_tx_close, {:fake_tx_socket, "wlan1"}}
  end

  defp sink_state(interfaces, opts) do
    opts =
      Keyword.merge(
        [
          interfaces: interfaces,
          socket_backend: Wifibroadcast.TestSupport.FakeTxAFPacket
        ],
        opts
      )

    {[], state} = Sink.handle_init(%{}, struct(Sink, opts))
    state
  end

  defp decode_frame(frame, radio_ports) do
    assert {:ok, radiotap, payload} = Parser.parse(frame)

    buffer = %Buffer{payload: payload, metadata: %{radio: %{radiotap: radiotap}}}

    assert {:ok, _radio_port, routed_buffer} =
             Router.route_buffer(buffer, %{
               drop_bad_fcs?: false,
               drop_self_injected?: false,
               enabled_radio_ports: MapSet.new(radio_ports),
               link_id: @link_id,
               trim_fcs?: true
             })

    {radiotap, routed_buffer}
  end
end
