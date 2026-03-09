defmodule NervesWifibroadcast.Radio.ControlTest do
  use ExUnit.Case, async: true

  alias NervesWifibroadcast.Radio.Control

  test "set_monitor_mode applies the expected command sequence" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok = Control.set_monitor_mode("wlan0", runner)

    assert_received {:cmd, "ip", ["link", "set", "wlan0", "down"]}
    assert_received {:cmd, "iw", ["dev", "wlan0", "set", "monitor", "otherbss"]}
    assert_received {:cmd, "ip", ["link", "set", "wlan0", "up"]}
  end

  test "set_region uses iw reg set" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok = Control.set_region("BO", runner)
    assert_received {:cmd, "iw", ["reg", "set", "BO"]}
  end

  test "set_channel normalizes width to wfb-ng ht mode" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok = Control.set_channel("wlan0", 149, 20, runner)
    assert_received {:cmd, "iw", ["dev", "wlan0", "set", "channel", "149", "HT20"]}
  end

  test "set_frequency uses iw freq syntax" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok = Control.set_frequency("wlan0", 5825, 80, runner)
    assert_received {:cmd, "iw", ["dev", "wlan0", "set", "freq", "5825", "80MHz"]}
  end

  test "set_tx_power maps rtl8812au dbm values to negative mbm" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok =
             Control.set_tx_power("wlan0", {:dbm, 30}, driver: :rtl8812au, command_runner: runner)

    assert_received {:cmd, "iw", ["dev", "wlan0", "set", "txpower", "fixed", "-3000"]}
  end

  test "set_tx_power maps rtl8812eu dbm values to positive mbm" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok =
             Control.set_tx_power("wlan0", {:dbm, 30}, driver: :rtl8812eu, command_runner: runner)

    assert_received {:cmd, "iw", ["dev", "wlan0", "set", "txpower", "fixed", "3000"]}
  end

  test "set_tx_power accepts raw iw values" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok = Control.set_tx_power("wlan0", {:raw, -100}, command_runner: runner)
    assert_received {:cmd, "iw", ["dev", "wlan0", "set", "txpower", "fixed", "-100"]}
  end

  test "set_tx_power skips commands for rx-only cards" do
    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})
      {:ok, ""}
    end

    assert :ok = Control.set_tx_power("wlan0", :off, command_runner: runner)
    refute_received {:cmd, _, _}
  end

  test "set_channel reports interface failures" do
    runner = fn _cmd, _args, _opts ->
      {:error, :eperm}
    end

    assert {:error, {:set_channel_failed, "wlan0", :eperm}} =
             Control.set_channel("wlan0", 149, 20, runner)
  end
end
