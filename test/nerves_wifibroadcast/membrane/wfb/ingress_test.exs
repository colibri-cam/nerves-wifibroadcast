defmodule NervesWifibroadcast.Membrane.WFB.IngressTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Membrane.Buffer
  alias NervesWifibroadcast.Membrane.Radio.StreamFormat, as: RadioStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.Ingress
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.Radiotap

  require Membrane.Pad

  @link_id 0x010203
  @other_link_id 0x050607
  @radio_port 0x04
  @other_radio_port 0x08
  @channel_id (@link_id <<< 8) + @radio_port
  @other_channel_id (@link_id <<< 8) + @other_radio_port
  @wrong_link_channel_id (@other_link_id <<< 8) + @radio_port

  test "routes valid data packets to the matching dynamic output pad" do
    {pad, state} = linked_state(link_id: @link_id, radio_ports: [@radio_port])

    buffer =
      %Buffer{
        payload: wfb_frame(@channel_id, data_packet(0x0102030405060708, <<0xAA, 0xBB>>)),
        metadata: radio_metadata(%Radiotap{})
      }

    assert {[buffer: {^pad, routed_buffer}], state} =
             Ingress.handle_buffer(:input, buffer, %{}, state)

    assert routed_buffer.payload == <<0xAA, 0xBB>>
    assert routed_buffer.metadata.ieee80211.header_len == 24
    assert routed_buffer.metadata.wfb.channel_id == @channel_id
    assert routed_buffer.metadata.wfb.packet_type == :data
    assert routed_buffer.metadata.wfb.packet_type_byte == 0x01
    assert routed_buffer.metadata.wfb.data_nonce == 0x0102030405060708
    assert routed_buffer.metadata.wfb.block_idx == 0x01020304050607
    assert routed_buffer.metadata.wfb.fragment_idx == 0x08
    assert routed_buffer.metadata.wfb.link_id == 0x010203
    assert routed_buffer.metadata.wfb.radio_port == 0x04
    assert state.counters.passed_packets == 1
  end

  test "trims FCS and exposes session nonce metadata" do
    {pad, state} = linked_state(link_id: @link_id, radio_ports: [@radio_port])
    session_nonce = for(i <- 0..23, into: <<>>, do: <<i>>)

    buffer = %Buffer{
      payload:
        wfb_frame(@channel_id, session_packet(session_nonce, <<0x11, 0x22>>), append_fcs?: true),
      metadata:
        radio_metadata(%Radiotap{
          flags: %{raw: 0x10, fcs?: true, bad_fcs?: false, datapad?: false}
        })
    }

    assert {[buffer: {^pad, routed_buffer}], _state} =
             Ingress.handle_buffer(:input, buffer, %{}, state)

    assert routed_buffer.payload == <<0x11, 0x22>>
    assert routed_buffer.metadata.wfb.packet_type == :session
    assert routed_buffer.metadata.wfb.session_nonce == session_nonce
  end

  test "drops unknown radio ports until they are enabled at runtime" do
    pad = Membrane.Pad.ref(:output, @other_radio_port)
    state = ingress_state(link_id: @link_id, radio_ports: [@radio_port])
    {[], state} = Ingress.handle_pad_added(pad, %{}, state)

    {[_stream_format], state} =
      Ingress.handle_stream_format(:input, %RadioStreamFormat{interfaces: ["wlan0"]}, %{}, state)

    buffer =
      %Buffer{
        payload: wfb_frame(@other_channel_id, data_packet(0xAA, <<0x01>>)),
        metadata: radio_metadata(%Radiotap{})
      }

    assert {[], state} = Ingress.handle_buffer(:input, buffer, %{}, state)
    assert state.counters.unknown_radio_port_drops == 1

    {[], state} =
      Ingress.handle_parent_notification({:add_radio_port, @other_radio_port}, %{}, state)

    assert {[buffer: {^pad, _routed_buffer}], state} =
             Ingress.handle_buffer(:input, buffer, %{}, state)

    assert state.counters.passed_packets == 1
  end

  test "drops packets for the wrong link id" do
    {_pad, state} = linked_state(link_id: @link_id, radio_ports: [@radio_port])

    buffer =
      %Buffer{
        payload: wfb_frame(@wrong_link_channel_id, data_packet(0x55, <<0x01>>)),
        metadata: radio_metadata(%Radiotap{})
      }

    assert {[], state} = Ingress.handle_buffer(:input, buffer, %{}, state)
    assert state.counters.wrong_link_id_drops == 1
  end

  test "drops self injected frames" do
    {_pad, state} = linked_state(link_id: @link_id, radio_ports: [@radio_port])

    buffer = %Buffer{
      payload: wfb_frame(@channel_id, data_packet(0x55, <<0x01>>)),
      metadata:
        radio_metadata(%Radiotap{
          tx_flags: %{raw: 0x0001, fail?: false, cts?: false, rts?: false, no_ack?: false}
        })
    }

    assert {[], state} = Ingress.handle_buffer(:input, buffer, %{}, state)
    assert state.counters.self_injected_drops == 1
  end

  test "drops bad fcs frames" do
    {_pad, state} = linked_state(link_id: @link_id, radio_ports: [@radio_port])

    buffer = %Buffer{
      payload: wfb_frame(@channel_id, data_packet(0x55, <<0x01>>), append_fcs?: true),
      metadata:
        radio_metadata(%Radiotap{
          flags: %{raw: 0x50, fcs?: true, bad_fcs?: true, datapad?: false}
        })
    }

    assert {[], state} = Ingress.handle_buffer(:input, buffer, %{}, state)
    assert state.counters.bad_fcs_drops == 1
  end

  test "sends radio-port specific stream format when a pad is linked after input stream format" do
    state = ingress_state(link_id: @link_id, radio_ports: [@radio_port])

    {[], state} =
      Ingress.handle_stream_format(:input, %RadioStreamFormat{interfaces: ["wlan0"]}, %{}, state)

    pad = Membrane.Pad.ref(:output, @radio_port)

    assert {[stream_format: {^pad, %StreamFormat{} = stream_format}], _state} =
             Ingress.handle_pad_added(pad, %{}, state)

    assert stream_format.channel_id == @channel_id
    assert stream_format.interfaces == ["wlan0"]
    assert stream_format.link_id == 0x010203
    assert stream_format.radio_port == 0x04
  end

  test "drops frames that do not match the WFB MAC signature" do
    {_pad, state} = linked_state(link_id: @link_id, radio_ports: [@radio_port])

    invalid_source_mac = <<0x00, 0x42, @channel_id::big-32>>

    buffer = %Buffer{
      payload:
        wfb_frame(@channel_id, data_packet(0x55, <<0x01>>), source_mac: invalid_source_mac),
      metadata: radio_metadata(%Radiotap{})
    }

    assert {[], state} = Ingress.handle_buffer(:input, buffer, %{}, state)
    assert state.counters.invalid_wfb_header_drops == 1
  end

  defp linked_state(opts) do
    state = ingress_state(opts)
    pad = Membrane.Pad.ref(:output, @radio_port)
    {[], state} = Ingress.handle_pad_added(pad, %{}, state)

    {[
       stream_format: {^pad, %StreamFormat{channel_id: @channel_id, interfaces: ["wlan0"]}}
     ], state} =
      Ingress.handle_stream_format(:input, %RadioStreamFormat{interfaces: ["wlan0"]}, %{}, state)

    {pad, state}
  end

  defp ingress_state(opts) do
    opts = Keyword.merge([link_id: @link_id, radio_ports: [@radio_port]], opts)
    {[], state} = Ingress.handle_init(%{}, struct(Ingress, opts))
    state
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

  defp session_packet(session_nonce, ciphertext),
    do: <<0x02, session_nonce::binary, ciphertext::binary>>

  defp radio_metadata(radiotap) do
    %{
      radio: %{
        capture_ts: 0,
        radiotap: radiotap,
        raw_length: 0,
        receiver_idx: 0,
        socket_flags: []
      }
    }
  end
end
