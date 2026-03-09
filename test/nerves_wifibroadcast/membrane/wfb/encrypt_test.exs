defmodule NervesWifibroadcast.Membrane.WFB.EncryptTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias NervesWifibroadcast.Membrane.WFB.Decrypt
  alias NervesWifibroadcast.Membrane.WFB.Encrypt
  alias NervesWifibroadcast.Membrane.WFB.Router
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.TestSupport.WFBFixtures
  alias NervesWifibroadcast.WFB.CryptoNif

  test "marks the packet stream as encrypted" do
    keys = WFBFixtures.key_material()
    stream_format = WFBFixtures.ingress_stream_format(encrypted?: false)
    state = encrypt_state(keys)

    assert {[stream_format: {:output, %StreamFormat{} = output_stream_format}], _state} =
             Encrypt.handle_stream_format(:input, stream_format, %{}, state)

    assert output_stream_format.channel_id == stream_format.channel_id
    assert output_stream_format.link_id == stream_format.link_id
    assert output_stream_format.radio_port == stream_format.radio_port
    assert output_stream_format.encrypted? == true
  end

  test "encrypts session packets and reuses the same ciphertext for repeats" do
    keys = WFBFixtures.key_material()
    session = WFBFixtures.session_plaintext(epoch: 55, fec_k: 10, fec_n: 14)
    buffer = WFBFixtures.tx_session_buffer(session)
    state = encrypt_state(keys)

    assert {[buffer: {:output, first_output}], state} =
             Encrypt.handle_buffer(:input, buffer, %{}, state)

    assert {[buffer: {:output, second_output}], state} =
             Encrypt.handle_buffer(:input, buffer, %{}, state)

    assert first_output.payload == second_output.payload
    assert first_output.metadata.wfb.session_nonce == second_output.metadata.wfb.session_nonce
    assert first_output.payload != session.plaintext
    assert state.current_session.session_key == session.session_key
    assert state.counters.passed_packets == 2
  end

  test "encrypts data packets after a session has been installed" do
    keys = WFBFixtures.key_material()
    session = WFBFixtures.session_plaintext(epoch: 7, fec_k: 8, fec_n: 12)
    state = encrypt_state(keys)

    {[_session_action], state} =
      Encrypt.handle_buffer(:input, WFBFixtures.tx_session_buffer(session), %{}, state)

    data_buffer = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("payload"), session, 22, 4)

    assert {[buffer: {:output, output_buffer}], state} =
             Encrypt.handle_buffer(:input, data_buffer, %{}, state)

    assert output_buffer.payload != data_buffer.payload
    assert output_buffer.metadata.wfb.block_idx == 22
    assert output_buffer.metadata.wfb.fragment_idx == 4
    assert output_buffer.metadata.wfb.data_nonce == (22 <<< 8) + 4
    assert output_buffer.metadata.wfb_session.session_key == session.session_key

    assert {:ok, plaintext} =
             output_buffer.payload
             |> then(&Router.build_data_packet(output_buffer.metadata.wfb.data_nonce, &1))
             |> CryptoNif.open_data(session.session_key)

    assert plaintext == data_buffer.payload
    assert state.counters.passed_packets == 2
  end

  test "drops data packets before a session arrives" do
    keys = WFBFixtures.key_material()
    session = WFBFixtures.session_plaintext(epoch: 7, fec_k: 8, fec_n: 12)
    data_buffer = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("payload"), session, 22, 4)
    state = encrypt_state(keys)

    assert {[], state} = Encrypt.handle_buffer(:input, data_buffer, %{}, state)
    assert state.counters.data_without_session_drops == 1
  end

  test "roundtrips through decrypt" do
    keys = WFBFixtures.key_material()
    clear_stream_format = WFBFixtures.ingress_stream_format(encrypted?: false)
    session = WFBFixtures.session_plaintext(epoch: 42, fec_k: 2, fec_n: 3)
    data_buffer = WFBFixtures.tx_data_buffer(WFBFixtures.source_shard("alpha"), session, 10, 1)

    encrypt_state = encrypt_state(keys)
    decrypt_state = decrypt_state(keys)

    assert {[stream_format: {:output, encrypted_stream_format}], encrypt_state} =
             Encrypt.handle_stream_format(:input, clear_stream_format, %{}, encrypt_state)

    assert {[stream_format: {:output, decrypt_stream_format}], decrypt_state} =
             Decrypt.handle_stream_format(:input, encrypted_stream_format, %{}, decrypt_state)

    assert decrypt_stream_format.encrypted? == true

    assert {[buffer: {:output, encrypted_session_buffer}], encrypt_state} =
             Encrypt.handle_buffer(
               :input,
               WFBFixtures.tx_session_buffer(session),
               %{},
               encrypt_state
             )

    assert {[buffer: {:output, decrypted_session_buffer}], decrypt_state} =
             Decrypt.handle_buffer(:input, encrypted_session_buffer, %{}, decrypt_state)

    assert decrypted_session_buffer.payload == session.plaintext

    assert {[buffer: {:output, encrypted_data_buffer}], _encrypt_state} =
             Encrypt.handle_buffer(:input, data_buffer, %{}, encrypt_state)

    assert {[buffer: {:output, decrypted_data_buffer}], _decrypt_state} =
             Decrypt.handle_buffer(:input, encrypted_data_buffer, %{}, decrypt_state)

    assert decrypted_data_buffer.payload == data_buffer.payload
    assert decrypted_data_buffer.metadata.wfb.block_idx == 10
    assert decrypted_data_buffer.metadata.wfb.fragment_idx == 1
    assert decrypted_data_buffer.metadata.wfb.session_epoch == 42
  end

  defp encrypt_state(keys) do
    opts = [rx_publickey: keys.rx_publickey, tx_secretkey: keys.tx_secretkey]
    {[], state} = Encrypt.handle_init(%{}, struct(Encrypt, opts))
    state
  end

  defp decrypt_state(keys) do
    opts = [rx_secretkey: keys.rx_secretkey, tx_publickey: keys.tx_publickey]
    {[], state} = Decrypt.handle_init(%{}, struct(Decrypt, opts))
    state
  end
end
