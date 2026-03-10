defmodule NervesWifibroadcast.WFB.KeysTest do
  use ExUnit.Case, async: false

  alias NervesWifibroadcast
  alias NervesWifibroadcast.WFB.Keys

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "nerves-wifibroadcast-keys-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    {:ok,
     base_dir: base_dir,
     drone_path: Path.join(base_dir, "drone.key"),
     gs_path: Path.join(base_dir, "gs.key")}
  end

  test "generate_files writes password-compatible drone and gs key files", %{
    drone_path: drone_path,
    gs_path: gs_path
  } do
    assert {:ok, %{drone_path: ^drone_path, gs_path: ^gs_path, keys: keys}} =
             Keys.generate_files(
               password: "compat-password",
               drone_path: drone_path,
               gs_path: gs_path
             )

    assert File.read!(drone_path) == Keys.drone_key_file_content(keys)
    assert File.read!(gs_path) == Keys.gs_key_file_content(keys)

    assert {:ok, tx_keys} = Keys.load_tx(drone_path)
    assert tx_keys.tx_secretkey == keys.drone_secretkey
    assert tx_keys.rx_publickey == keys.gs_publickey

    assert %Keys{} = Keys.load!(gs_path)
  end

  test "generate_files without password writes valid key files", %{
    drone_path: drone_path,
    gs_path: gs_path
  } do
    assert {:ok, %{keys: keys}} = Keys.generate_files(drone_path: drone_path, gs_path: gs_path)

    assert byte_size(Keys.drone_key_file_content(keys)) == 64
    assert byte_size(Keys.gs_key_file_content(keys)) == 64
    assert {:ok, _tx_keys} = Keys.load_tx(drone_path)
    assert {:ok, _rx_keys} = Keys.load(gs_path)
  end

  test "top-level generate_wfb_keys delegates to file generator", %{
    drone_path: drone_path,
    gs_path: gs_path
  } do
    File.rm_rf!(drone_path)
    File.rm_rf!(gs_path)

    original_cwd = File.cwd!()
    File.cd!(Path.dirname(drone_path))

    try do
      assert {:ok, %{drone_path: "drone.key", gs_path: "gs.key"}} =
               NervesWifibroadcast.generate_wfb_keys("compat-password")

      assert File.exists?(drone_path)
      assert File.exists?(gs_path)
    after
      File.cd!(original_cwd)
    end
  end
end
