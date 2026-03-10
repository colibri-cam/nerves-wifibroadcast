defmodule Wifibroadcast.WFB.CryptoNifTest do
  use ExUnit.Case, async: true

  alias Wifibroadcast.WFB.CryptoNif
  alias Wifibroadcast.WFB.Keys
  alias Wifibroadcast.TestSupport.WFBFixtures

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

  test "derive_keypairs matches wfb-ng password key output" do
    expected_drone =
      Base.decode16!(
        "342e402edacd9483292ae0ad82ad1dfb1913e33708e240a6d8d897bb436d3f991bcd67b6abd46a8652cd2cfab5609617eb51706509fc8237c2dc2441c12cc721",
        case: :mixed
      )

    expected_gs =
      Base.decode16!(
        "ef48e9077f58c040e43696a98365f141d832f4266119ea643274d036167c5712da391167f46bbf818c733dc01657170763920c451ed577a6b54b05bf4ecb5a6c",
        case: :mixed
      )

    assert {:ok, key_material} = CryptoNif.derive_keypairs("compat-password")

    assert Keys.drone_key_file_content(key_material) == expected_drone
    assert Keys.gs_key_file_content(key_material) == expected_gs
  end

  test "generate_keypairs returns loadable drone and gs key files" do
    assert {:ok, key_material} = CryptoNif.generate_keypairs()

    assert {:ok, tx_keys} = Keys.from_tx_key_file(Keys.drone_key_file_content(key_material))
    assert tx_keys.tx_secretkey == key_material.drone_secretkey
    assert tx_keys.rx_publickey == key_material.gs_publickey

    assert {:ok, rx_keys} = Keys.from_rx_key_file(Keys.gs_key_file_content(key_material))
    assert rx_keys.rx_secretkey == key_material.gs_secretkey
    assert rx_keys.tx_publickey == key_material.drone_publickey
    assert is_reference(rx_keys.box_key)
  end
end
