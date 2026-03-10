defmodule NervesWifibroadcast.Radio.InventoryTest do
  use ExUnit.Case, async: true

  alias NervesWifibroadcast.Radio.Interface
  alias NervesWifibroadcast.Radio.Inventory

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "nerves-wifibroadcast-inventory-#{System.unique_integer([:positive])}"
      )

    sysfs_root = Path.join(base_dir, "class/net")
    File.mkdir_p!(sysfs_root)

    on_exit(fn ->
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir, sysfs_root: sysfs_root}
  end

  test "discover returns wireless interfaces with normalized metadata", %{
    base_dir: base_dir,
    sysfs_root: sysfs_root
  } do
    create_wireless_interface(base_dir, sysfs_root, "wlan1",
      driver_name: "rtl8812eu",
      mac: "AA:BB:CC:DD:EE:FF",
      modalias: "usb:v1D6Bp0002",
      wireless_marker: :wireless,
      device_suffix: "usb2/2-1:1.0"
    )

    create_wireless_interface(base_dir, sysfs_root, "wlan0",
      driver_name: "88XXau",
      mac: "00:11:22:33:44:55",
      modalias: "usb:v0BDAp8812",
      device_link: :relative,
      phy: "phy0",
      wireless_marker: :phy,
      device_suffix: "usb1/1-1:1.0"
    )

    File.mkdir_p!(Path.join(sysfs_root, "eth0"))

    assert {:ok, inventory} =
             Inventory.discover(
               ifindex_resolver: &ifindex_resolver/1,
               iftype_resolver: &iftype_resolver/2,
               sysfs_root: sysfs_root
             )

    assert Enum.map(inventory, & &1.ifname) == ["wlan0", "wlan1"]

    assert [wlan0, wlan1] = inventory

    assert %Interface{
             bus_path: "usb1/1-1:1.0",
             device_path: device_path,
             driver: :rtl8812au,
             driver_name: "88XXau",
             ifindex: 7,
             ifname: "wlan0",
             iftype: :monitor,
             mac: "00:11:22:33:44:55",
             modalias: "usb:v0BDAp8812",
             phy: "phy0"
           } = wlan0

    assert String.ends_with?(device_path, "/devices/usb1/1-1:1.0")

    assert %Interface{
             bus_path: "usb2/2-1:1.0",
             driver: :rtl8812eu,
             driver_name: "rtl8812eu",
             ifindex: 8,
             ifname: "wlan1",
             iftype: :station,
             mac: "aa:bb:cc:dd:ee:ff",
             modalias: "usb:v1D6Bp0002",
             phy: nil
           } = wlan1
  end

  test "discover accepts uevent wireless markers and preserves partial metadata", %{
    base_dir: base_dir,
    sysfs_root: sysfs_root
  } do
    create_wireless_interface(base_dir, sysfs_root, "mon0",
      wireless_marker: :uevent,
      device_suffix: "platform/virtual0"
    )

    assert {:ok, [%Interface{} = interface]} =
             Inventory.discover(
               iftype_resolver: &iftype_resolver/2,
               sysfs_root: sysfs_root,
               ifindex_resolver: fn _ifname -> {:error, :enoent} end
             )

    assert interface.ifname == "mon0"
    assert interface.ifindex == nil
    assert interface.iftype == nil
    assert interface.driver == nil
    assert interface.driver_name == nil
    assert interface.mac == nil
    assert interface.modalias == nil
    assert interface.phy == nil
  end

  test "discover resolves relative device links to absolute paths", %{
    base_dir: base_dir,
    sysfs_root: sysfs_root
  } do
    create_wireless_interface(base_dir, sysfs_root, "wlan2",
      device_link: :relative,
      device_suffix: "pci0000:60/0000:60:01.0/0000:61:00.0/0000:62:00.0",
      driver_name: "mt7921e",
      phy: "phy1",
      wireless_marker: :phy
    )

    assert {:ok, [%Interface{} = interface]} =
             Inventory.discover(
               iftype_resolver: &iftype_resolver/2,
               sysfs_root: sysfs_root,
               ifindex_resolver: fn "wlan2" -> {:ok, 5} end
             )

    assert interface.bus_path == "0000:62:00.0"
    assert interface.iftype == {:unknown, 99}

    assert interface.device_path ==
             Path.join(base_dir, "devices/pci0000:60/0000:60:01.0/0000:61:00.0/0000:62:00.0")
  end

  test "discover! raises on unreadable sysfs root", %{base_dir: base_dir} do
    missing_root = Path.join(base_dir, "missing")

    assert_raise RuntimeError,
                 ~r/failed to discover radio inventory from .*missing.*enoent/,
                 fn ->
                   Inventory.discover!(sysfs_root: missing_root)
                 end
  end

  test "selection helpers filter interfaces and resolve a unique driver" do
    inventory = [
      %Interface{
        driver: :rtl8812au,
        driver_name: "88XXau",
        groups: [:wfb],
        ifname: "wlan0",
        iftype: :monitor,
        mac: "00:11:22:33:44:55",
        phy: "phy0"
      },
      %Interface{
        driver: :rtl8812au,
        driver_name: "rtl88xxau",
        groups: ["WFB"],
        ifname: "wlan1",
        iftype: :monitor,
        mac: "00:11:22:33:44:66",
        phy: "phy1"
      },
      %Interface{
        driver: :ath9k_htc,
        driver_name: "ath9k_htc",
        groups: [:mgmt],
        ifname: "wlan2",
        iftype: :station,
        mac: "00:11:22:33:44:77",
        phy: "phy2"
      }
    ]

    selection = Inventory.select!(inventory, driver: "88XXau", group: :wfb, iftype: :monitor)

    assert selection.interfaces == ["wlan0", "wlan1"]
    assert selection.drivers == [:rtl8812au]
    assert Enum.map(selection.members, & &1.ifname) == ["wlan0", "wlan1"]

    assert Inventory.interfaces(selection) == ["wlan0", "wlan1"]
    assert Inventory.interfaces(inventory, driver_name: "RTL88XXAU") == ["wlan1"]
    assert Inventory.interfaces(inventory, iftype: :station) == ["wlan2"]
    assert Inventory.interfaces(inventory, ifname: ["wlan2"]) == ["wlan2"]
    assert Inventory.interfaces(inventory, mac: "00:11:22:33:44:66") == ["wlan1"]
    assert Inventory.unique_driver!(selection) == :rtl8812au
  end

  test "selection helpers raise for empty matches, mixed drivers, and invalid selectors" do
    inventory = [
      %Interface{driver: :rtl8812au, ifname: "wlan0", iftype: :monitor},
      %Interface{driver: :rtl8812eu, ifname: "wlan1", iftype: {:unknown, 99}}
    ]

    assert_raise ArgumentError, ~r/at least one interface/, fn ->
      Inventory.select!(inventory, driver: :ath9k_htc)
    end

    assert_raise ArgumentError, ~r/exactly one driver/, fn ->
      Inventory.unique_driver!(inventory)
    end

    assert_raise ArgumentError, ~r/unsupported inventory selector :unknown/, fn ->
      Inventory.select(inventory, unknown: :value)
    end

    assert Inventory.interfaces(inventory, iftype: {:unknown, 99}) == ["wlan1"]

    assert_raise ArgumentError, ~r/expected iftype to be one of/, fn ->
      Inventory.select(inventory, iftype: :bogus)
    end
  end

  defp create_wireless_interface(base_dir, sysfs_root, ifname, opts) do
    interface_path = Path.join(sysfs_root, ifname)
    device_suffix = Keyword.get(opts, :device_suffix, ifname)
    device_path = Path.join(base_dir, Path.join("devices", device_suffix))
    driver_name = Keyword.get(opts, :driver_name)
    phy = Keyword.get(opts, :phy)
    wireless_marker = Keyword.get(opts, :wireless_marker, :phy)
    device_link = Keyword.get(opts, :device_link, :absolute)

    File.mkdir_p!(interface_path)
    File.mkdir_p!(device_path)

    device_target =
      case device_link do
        :absolute -> device_path
        :relative -> Path.relative_to(device_path, interface_path)
      end

    File.ln_s!(device_target, Path.join(interface_path, "device"))

    maybe_write(Path.join(interface_path, "address"), Keyword.get(opts, :mac))
    maybe_write(Path.join(device_path, "modalias"), Keyword.get(opts, :modalias))

    case driver_name do
      nil ->
        :ok

      driver_name ->
        driver_path = Path.join(base_dir, Path.join("drivers", driver_name))
        File.mkdir_p!(driver_path)
        File.ln_s!(driver_path, Path.join(device_path, "driver"))
    end

    case wireless_marker do
      :phy ->
        phy_name = phy || "phy-#{ifname}"
        phy_path = Path.join(base_dir, Path.join("ieee80211", phy_name))
        File.mkdir_p!(phy_path)
        File.ln_s!(phy_path, Path.join(interface_path, "phy80211"))

      :wireless ->
        File.mkdir_p!(Path.join(interface_path, "wireless"))

      :uevent ->
        File.write!(Path.join(interface_path, "uevent"), "DEVTYPE=wlan\n")
    end
  end

  defp maybe_write(_path, nil), do: :ok
  defp maybe_write(path, value), do: File.write!(path, value <> "\n")

  defp ifindex_resolver("wlan0"), do: {:ok, 7}
  defp ifindex_resolver("wlan1"), do: 8
  defp ifindex_resolver("wlan2"), do: {:ok, 5}
  defp ifindex_resolver(_ifname), do: {:error, :enoent}

  defp iftype_resolver("wlan0", 7), do: {:ok, :monitor}
  defp iftype_resolver("wlan1", 8), do: :station
  defp iftype_resolver("wlan2", 5), do: {:ok, {:unknown, 99}}
  defp iftype_resolver(_ifname, _ifindex), do: {:error, :not_supported}
end
