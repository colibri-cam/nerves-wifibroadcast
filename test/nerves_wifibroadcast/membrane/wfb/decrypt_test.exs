defmodule NervesWifibroadcast.Membrane.WFB.DecryptTest do
  use ExUnit.Case, async: true

  alias Membrane.Buffer
  alias NervesWifibroadcast.Membrane.WFB.Decrypt
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.TestSupport.WFBFixtures

  test "forwards the packet stream format unchanged" do
    keys = WFBFixtures.key_material()
    stream_format = WFBFixtures.ingress_stream_format()
    state = decrypt_state(keys)

    assert {[stream_format: {:output, %StreamFormat{} = forwarded_stream_format}], state} =
             Decrypt.handle_stream_format(:input, stream_format, %{}, state)

    assert forwarded_stream_format == stream_format
    assert state.input_stream_format == stream_format
  end

  test "accepts a session and emits its decrypted payload" do
    keys = WFBFixtures.key_material()
    stream_format = WFBFixtures.ingress_stream_format()

    {session, packet} =
      WFBFixtures.encrypted_session_packet(keys, epoch: 55, fec_k: 10, fec_n: 14)

    state = decrypt_state(keys)
    {[_stream_format], state} = Decrypt.handle_stream_format(:input, stream_format, %{}, state)

    buffer = %Buffer{
      payload: WFBFixtures.session_packet_payload(packet),
      metadata: WFBFixtures.session_metadata(session)
    }

    assert {[buffer: {:output, %Buffer{} = output_buffer}], state} =
             Decrypt.handle_buffer(:input, buffer, %{}, state)

    assert output_buffer.payload == session.plaintext
    assert output_buffer.metadata.wfb.channel_id == session.channel_id
    assert output_buffer.metadata.wfb.session_epoch == session.epoch
    assert output_buffer.metadata.wfb.fec_k == session.fec_k
    assert output_buffer.metadata.wfb.fec_n == session.fec_n
    assert output_buffer.metadata.wfb_session.session_key == session.session_key
    assert state.current_session.session_key == session.session_key
    assert state.epoch_floor == session.epoch
  end

  test "decrypts data packets after a session is installed" do
    keys = WFBFixtures.key_material()
    stream_format = WFBFixtures.ingress_stream_format()

    {session, session_packet} =
      WFBFixtures.encrypted_session_packet(keys, epoch: 7, fec_k: 8, fec_n: 12)

    {data, data_packet} =
      WFBFixtures.encrypted_data_packet(session.session_key, block_idx: 22, fragment_idx: 4)

    state = decrypt_state(keys)
    {[_stream_format], state} = Decrypt.handle_stream_format(:input, stream_format, %{}, state)

    {[_buffer], state} =
      Decrypt.handle_buffer(
        :input,
        %Buffer{
          payload: WFBFixtures.session_packet_payload(session_packet),
          metadata: WFBFixtures.session_metadata(session)
        },
        %{},
        state
      )

    assert {[buffer: {:output, %Buffer{} = output_buffer}], state} =
             Decrypt.handle_buffer(
               :input,
               %Buffer{
                 payload: WFBFixtures.data_packet_payload(data_packet),
                 metadata: WFBFixtures.data_metadata(data)
               },
               %{},
               state
             )

    assert output_buffer.payload == data.plaintext
    assert output_buffer.metadata.wfb.block_idx == data.block_idx
    assert output_buffer.metadata.wfb.fragment_idx == data.fragment_idx
    assert output_buffer.metadata.wfb.fec_k == session.fec_k
    assert output_buffer.metadata.wfb.fec_n == session.fec_n
    assert output_buffer.metadata.wfb.session_epoch == session.epoch
    assert output_buffer.metadata.wfb_session.session_key == session.session_key
    assert state.counters.passed_packets == 1
  end

  test "drops data before a session arrives" do
    keys = WFBFixtures.key_material()
    {data, packet} = WFBFixtures.encrypted_data_packet(:crypto.strong_rand_bytes(32))
    state = decrypt_state(keys)

    assert {[], state} =
             Decrypt.handle_buffer(
               :input,
               %Buffer{
                 payload: WFBFixtures.data_packet_payload(packet),
                 metadata: WFBFixtures.data_metadata(data)
               },
               %{},
               state
             )

    assert state.counters.data_without_session_drops == 1
  end

  test "drops sessions for the wrong channel id" do
    keys = WFBFixtures.key_material()
    stream_format = WFBFixtures.ingress_stream_format()
    {session, packet} = WFBFixtures.encrypted_session_packet(keys)
    state = decrypt_state(keys)
    {[_stream_format], state} = Decrypt.handle_stream_format(:input, stream_format, %{}, state)

    bad_metadata =
      put_in(WFBFixtures.session_metadata(session), [:wfb, :channel_id], session.channel_id + 1)

    assert {actions, state} =
             Decrypt.handle_buffer(
               :input,
               %Buffer{
                 payload: WFBFixtures.session_packet_payload(packet),
                 metadata: bad_metadata
               },
               %{},
               state
             )

    assert {:notify_parent, {:wfb_session_rejected, :wrong_channel_id, notification}} =
             Enum.find(actions, fn
               {:notify_parent, {:wfb_session_rejected, :wrong_channel_id, _notification}} -> true
               _other -> false
             end)

    assert notification.channel_id == session.channel_id + 1
    assert state.counters.wrong_channel_id_drops == 1
  end

  test "drops sessions older than the configured epoch floor" do
    keys = WFBFixtures.key_material()
    {session, packet} = WFBFixtures.encrypted_session_packet(keys, epoch: 2)
    state = decrypt_state(keys, min_epoch: 5)

    assert {actions, state} =
             Decrypt.handle_buffer(
               :input,
               %Buffer{
                 payload: WFBFixtures.session_packet_payload(packet),
                 metadata: WFBFixtures.session_metadata(session)
               },
               %{},
               state
             )

    assert {:notify_parent, {:wfb_session_rejected, :old_epoch, notification}} =
             Enum.find(actions, fn
               {:notify_parent, {:wfb_session_rejected, :old_epoch, _notification}} -> true
               _other -> false
             end)

    assert notification.channel_id == session.channel_id
    assert state.counters.old_epoch_drops == 1
  end

  test "suppresses duplicate accepted session packets before decrypt" do
    keys = WFBFixtures.key_material()
    stream_format = WFBFixtures.ingress_stream_format()

    {session, packet} =
      WFBFixtures.encrypted_session_packet(keys, epoch: 55, fec_k: 10, fec_n: 14)

    state = decrypt_state(keys)
    {[_stream_format], state} = Decrypt.handle_stream_format(:input, stream_format, %{}, state)

    buffer = %Buffer{
      payload: WFBFixtures.session_packet_payload(packet),
      metadata: WFBFixtures.session_metadata(session)
    }

    assert {[buffer: {:output, _output_buffer}], state} =
             Decrypt.handle_buffer(:input, buffer, %{}, state)

    assert {[], state} = Decrypt.handle_buffer(:input, buffer, %{}, state)
    assert state.counters.duplicate_session_drops == 1
  end

  test "drops too-short encrypted data packets before decrypt" do
    keys = WFBFixtures.key_material()
    stream_format = WFBFixtures.ingress_stream_format()

    {session, session_packet} =
      WFBFixtures.encrypted_session_packet(keys, epoch: 7, fec_k: 8, fec_n: 12)

    state = decrypt_state(keys)
    {[_stream_format], state} = Decrypt.handle_stream_format(:input, stream_format, %{}, state)

    {_, state} =
      Decrypt.handle_buffer(
        :input,
        %Buffer{
          payload: WFBFixtures.session_packet_payload(session_packet),
          metadata: WFBFixtures.session_metadata(session)
        },
        %{},
        state
      )

    short_packet = <<0::size(16 * 8)>>

    assert {[], state} =
             Decrypt.handle_buffer(
               :input,
               %Buffer{
                 payload: short_packet,
                 metadata:
                   WFBFixtures.data_metadata(%{
                     block_idx: 0x01020304050607,
                     data_nonce: 0x0102030405060708,
                     fragment_idx: 0x08
                   })
               },
               %{},
               state
             )

    assert state.counters.short_data_packet_drops == 1
    assert state.counters.data_decrypt_errors == 0
  end

  defp decrypt_state(keys, opts \\ []) do
    opts =
      Keyword.merge(
        [
          min_epoch: 0,
          rx_secretkey: keys.rx_secretkey,
          tx_publickey: keys.tx_publickey
        ],
        opts
      )

    {[], state} = Decrypt.handle_init(%{}, struct(Decrypt, opts))
    state
  end
end
