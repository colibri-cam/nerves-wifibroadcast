defmodule NervesWifibroadcast.WFB.CryptoNifTest do
  use ExUnit.Case, async: true

  alias NervesWifibroadcast.WFB.CryptoNif
  alias NervesWifibroadcast.WFB.Keys
  alias NervesWifibroadcast.TestSupport.WFBFixtures

  test "session packets roundtrip through the NIF" do
    keys = WFBFixtures.key_material()
    {session, packet} = WFBFixtures.encrypted_session_packet(keys, epoch: 42)

    box_key = CryptoNif.box_beforenm(keys.tx_publickey, keys.rx_secretkey)

    assert is_reference(box_key)
    assert {:ok, plaintext} = CryptoNif.open_session(packet, box_key)
    assert plaintext == session.plaintext
  end

  test "data packets roundtrip through the NIF" do
    session_key = :crypto.strong_rand_bytes(32)

    {data, packet} =
      WFBFixtures.encrypted_data_packet(session_key, block_idx: 10, fragment_idx: 2)

    assert {:ok, plaintext} = CryptoNif.open_data(packet, session_key)
    assert plaintext == data.plaintext
  end

  test "wrong keys fail session decrypt and key loader parses rx.key files" do
    keys = WFBFixtures.key_material()
    other_keys = WFBFixtures.key_material()
    {_session, packet} = WFBFixtures.encrypted_session_packet(keys)

    wrong_box_key = CryptoNif.box_beforenm(other_keys.tx_publickey, other_keys.rx_secretkey)

    assert :error = CryptoNif.open_session(packet, wrong_box_key)
    assert {:ok, loaded_keys} = Keys.from_rx_key_file(WFBFixtures.rx_key_file_content(keys))
    assert loaded_keys.rx_secretkey == keys.rx_secretkey
    assert loaded_keys.tx_publickey == keys.tx_publickey
    assert is_reference(loaded_keys.box_key)
  end
end
