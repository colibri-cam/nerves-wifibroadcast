defmodule NervesWifibroadcast.Radio.Inventory do
  @moduledoc """
  Stateless radio inventory discovery and selection.

  `discover/0` scans sysfs for wireless interfaces and returns interface snapshots.
  Selection helpers can then target subsets such as all `rtl8812au` interfaces
  before handing their names to `NervesWifibroadcast.Radio.Control`.

  Example:

      inventory = NervesWifibroadcast.Radio.Inventory.discover!()

      target =
        NervesWifibroadcast.Radio.Inventory.select!(inventory, driver: :rtl8812au)

      NervesWifibroadcast.Radio.Control.set_monitor_mode(target.interfaces)
      NervesWifibroadcast.Radio.Control.set_channel(target.interfaces, 149, 20)
  """

  alias NervesWifibroadcast.Radio.Interface
  alias NervesWifibroadcast.Radio.Inventory.Selection
  alias NervesWifibroadcast.Radio.Netlink.Nl80211

  @default_sysfs_root "/sys/class/net"
  @supported_selector_keys [:driver, :driver_name, :group, :ifname, :iftype, :mac, :phy]
  @driver_aliases %{
    "8812au" => :rtl8812au,
    "88xxau" => :rtl8812au,
    "rtl8812au" => :rtl8812au,
    "rtl88xxau" => :rtl8812au,
    "8812eu" => :rtl8812eu,
    "88xxeu" => :rtl8812eu,
    "rtl8812eu" => :rtl8812eu,
    "rtl88xxeu" => :rtl8812eu
  }

  @type inventory_t :: [Interface.t()]
  @type selection_source_t :: inventory_t() | Selection.t()

  @spec discover(Keyword.t()) :: {:ok, inventory_t()} | {:error, term()}
  def discover(opts \\ []) do
    opts =
      Keyword.validate!(opts,
        sysfs_root: @default_sysfs_root,
        ifindex_resolver: &default_ifindex_resolver/1,
        iftype_resolver: nil,
        recv_size: nil,
        socket_module: :socket,
        timeout: nil
      )

    sysfs_root = Keyword.fetch!(opts, :sysfs_root)
    ifindex_resolver = Keyword.fetch!(opts, :ifindex_resolver)

    iftype_resolver =
      case Keyword.fetch!(opts, :iftype_resolver) do
        nil -> default_iftype_resolver(opts)
        resolver -> resolver
      end

    with {:ok, entries} <- File.ls(sysfs_root) do
      inventory =
        entries
        |> Enum.sort()
        |> Enum.filter(&wireless_interface?(Path.join(sysfs_root, &1)))
        |> Enum.map(
          &build_interface(&1, Path.join(sysfs_root, &1), ifindex_resolver, iftype_resolver)
        )

      {:ok, inventory}
    else
      {:error, reason} -> {:error, {:discover_failed, sysfs_root, reason}}
    end
  end

  @spec discover!(Keyword.t()) :: inventory_t()
  def discover!(opts \\ []) do
    case discover(opts) do
      {:ok, inventory} ->
        inventory

      {:error, {:discover_failed, sysfs_root, reason}} ->
        raise "failed to discover radio inventory from #{inspect(sysfs_root)}: #{inspect(reason)}"
    end
  end

  @spec select(selection_source_t(), Keyword.t()) :: Selection.t()
  def select(source, selector \\ []) when is_list(selector) do
    selector = validate_selector!(selector)

    source
    |> members_from!()
    |> Enum.filter(&matches_selector?(&1, selector))
    |> build_selection()
  end

  @spec select!(selection_source_t(), Keyword.t()) :: Selection.t()
  def select!(source, selector \\ []) do
    selection = select(source, selector)

    if selection.members == [] do
      raise ArgumentError, "expected at least one interface to match #{inspect(selector)}"
    else
      selection
    end
  end

  @spec interfaces(selection_source_t()) :: [String.t()]
  def interfaces(source), do: interfaces(source, [])

  @spec interfaces(selection_source_t(), Keyword.t()) :: [String.t()]
  def interfaces(%Selection{interfaces: interfaces}, []) do
    interfaces
  end

  def interfaces(source, selector) when is_list(selector) do
    source
    |> select(selector)
    |> Map.fetch!(:interfaces)
  end

  @spec unique_driver!(selection_source_t()) :: atom()
  def unique_driver!(source) do
    drivers =
      source
      |> build_selection_from_source!()
      |> Map.fetch!(:drivers)

    case drivers do
      [driver] ->
        driver

      [] ->
        raise ArgumentError, "expected selection to contain exactly one known driver, got none"

      _drivers ->
        raise ArgumentError,
              "expected selection to contain exactly one driver, got: #{inspect(drivers)}"
    end
  end

  defp build_selection_from_source!(%Selection{} = selection), do: selection
  defp build_selection_from_source!(source), do: build_selection(members_from!(source))

  defp build_selection(members) do
    %Selection{
      members: members,
      interfaces: Enum.map(members, & &1.ifname),
      drivers: members |> Enum.map(& &1.driver) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  defp members_from!(%Selection{members: members}), do: members

  defp members_from!(source) when is_list(source) do
    Enum.map(source, fn
      %Interface{} = interface ->
        interface

      other ->
        raise ArgumentError,
              "expected inventory entries to be #{inspect(Interface)}, got: #{inspect(other)}"
    end)
  end

  defp members_from!(source) do
    raise ArgumentError,
          "expected inventory source to be a list of #{inspect(Interface)} or #{inspect(Selection)}, got: #{inspect(source)}"
  end

  defp validate_selector!(selector) do
    Enum.each(selector, fn {key, _value} ->
      if key not in @supported_selector_keys do
        raise ArgumentError,
              "unsupported inventory selector #{inspect(key)}; expected one of #{@supported_selector_keys |> Enum.map(&inspect/1) |> Enum.join(", ")}"
      end
    end)

    selector
  end

  defp matches_selector?(%Interface{} = interface, selector) do
    Enum.all?(selector, &matches_selector_entry?(interface, &1))
  end

  defp matches_selector_entry?(%Interface{} = interface, {:driver, value}) do
    driver_tokens = MapSet.new(driver_tokens(interface.driver))

    value
    |> List.wrap()
    |> Enum.flat_map(&driver_tokens/1)
    |> Enum.any?(&MapSet.member?(driver_tokens, &1))
  end

  defp matches_selector_entry?(%Interface{} = interface, {:driver_name, value}) do
    match_string_field?(interface.driver_name, value, &normalize_case_insensitive_string!/1)
  end

  defp matches_selector_entry?(%Interface{} = interface, {:group, value}) do
    groups = MapSet.new(Enum.map(interface.groups, &normalize_group!/1))

    value
    |> List.wrap()
    |> Enum.map(&normalize_group!/1)
    |> Enum.any?(&MapSet.member?(groups, &1))
  end

  defp matches_selector_entry?(%Interface{} = interface, {:ifname, value}) do
    match_string_field?(interface.ifname, value, &normalize_exact_string!/1)
  end

  defp matches_selector_entry?(%Interface{iftype: nil}, {:iftype, _value}), do: false

  defp matches_selector_entry?(%Interface{} = interface, {:iftype, value}) do
    match_field?(interface.iftype, value, &Interface.normalize_iftype!/1)
  end

  defp matches_selector_entry?(%Interface{} = interface, {:mac, value}) do
    match_string_field?(interface.mac, value, &normalize_mac!/1)
  end

  defp matches_selector_entry?(%Interface{} = interface, {:phy, value}) do
    match_string_field?(interface.phy, value, &normalize_exact_string!/1)
  end

  defp match_string_field?(nil, _value, _normalizer), do: false

  defp match_string_field?(field_value, selector_value, normalizer) do
    field_value = normalizer.(field_value)

    match_field?(field_value, selector_value, normalizer)
  end

  defp match_field?(field_value, selector_value, normalizer) do
    selector_value
    |> List.wrap()
    |> Enum.map(normalizer)
    |> Enum.any?(&(&1 == field_value))
  end

  defp build_interface(ifname, interface_path, ifindex_resolver, iftype_resolver) do
    interface_path = realpath(interface_path) || Path.expand(interface_path)
    device_link_path = Path.join(interface_path, "device")
    device_link_target = read_link(device_link_path)
    device_path = realpath(device_link_path)
    driver_name = device_link_path |> Path.join("driver") |> realpath() |> basename_or_nil()
    ifindex = resolve_ifindex(ifname, ifindex_resolver)

    %Interface{
      bus_path: bus_path(device_link_target || device_path),
      device_path: device_path,
      driver: normalize_driver(driver_name),
      driver_name: driver_name,
      groups: [],
      ifindex: ifindex,
      ifname: ifname,
      iftype: resolve_iftype(ifname, ifindex, iftype_resolver),
      mac: interface_path |> Path.join("address") |> read_trimmed() |> normalize_mac(),
      modalias: read_trimmed(Path.join(interface_path, "device/modalias")),
      phy: interface_path |> Path.join("phy80211") |> realpath() |> basename_or_nil()
    }
  end

  defp wireless_interface?(interface_path) do
    File.dir?(interface_path) and
      (File.exists?(Path.join(interface_path, "phy80211")) or
         File.dir?(Path.join(interface_path, "wireless")) or
         uevent_contains_wireless?(Path.join(interface_path, "uevent")))
  end

  defp uevent_contains_wireless?(path) do
    case File.read(path) do
      {:ok, contents} -> String.contains?(contents, "DEVTYPE=wlan")
      {:error, _reason} -> false
    end
  end

  defp resolve_ifindex(ifname, resolver) do
    case resolver.(ifname) do
      {:ok, ifindex} when is_integer(ifindex) and ifindex > 0 -> ifindex
      ifindex when is_integer(ifindex) and ifindex > 0 -> ifindex
      _other -> nil
    end
  end

  defp default_ifindex_resolver(ifname) do
    :net.if_name2index(String.to_charlist(ifname))
  end

  defp default_iftype_resolver(opts) do
    netlink_opts =
      opts
      |> Keyword.take([:recv_size, :socket_module, :timeout])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    fn _ifname, ifindex -> Nl80211.get_iftype(ifindex, netlink_opts) end
  end

  defp resolve_iftype(_ifname, nil, _resolver), do: nil

  defp resolve_iftype(ifname, ifindex, resolver) when is_function(resolver, 2) do
    resolver
    |> apply_iftype_resolver(ifname, ifindex)
    |> normalize_iftype_result()
  end

  defp resolve_iftype(_ifname, ifindex, resolver) when is_function(resolver, 1) do
    resolver
    |> apply_iftype_resolver(ifindex)
    |> normalize_iftype_result()
  end

  defp resolve_iftype(_ifname, _ifindex, nil), do: nil

  defp resolve_iftype(_ifname, _ifindex, resolver) do
    raise ArgumentError,
          "expected iftype_resolver to be a function with arity 1 or 2, got: #{inspect(resolver)}"
  end

  defp apply_iftype_resolver(resolver, ifindex) do
    resolver.(ifindex)
  end

  defp apply_iftype_resolver(resolver, ifname, ifindex) do
    resolver.(ifname, ifindex)
  end

  defp normalize_iftype_result({:ok, iftype}), do: Interface.normalize_iftype!(iftype)
  defp normalize_iftype_result({:error, _reason}), do: nil
  defp normalize_iftype_result(nil), do: nil
  defp normalize_iftype_result(iftype), do: Interface.normalize_iftype!(iftype)

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.trim()
        |> case do
          "" -> nil
          value -> value
        end

      {:error, _reason} ->
        nil
    end
  end

  defp read_link(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, resolved} -> List.to_string(resolved)
      {:error, _reason} -> nil
    end
  end

  defp realpath(path) do
    path = Path.expand(path)

    case read_link(path) do
      nil ->
        if File.exists?(path), do: path, else: nil

      resolved ->
        resolved =
          if Path.type(resolved) == :absolute do
            resolved
          else
            Path.expand(resolved, Path.dirname(path))
          end

        realpath(resolved)
    end
  end

  defp basename_or_nil(nil), do: nil
  defp basename_or_nil(path), do: Path.basename(path)

  defp normalize_driver(nil), do: nil

  defp normalize_driver(driver_name) when is_binary(driver_name) do
    normalized = normalize_case_insensitive_string!(driver_name)

    Map.get(@driver_aliases, normalized) ||
      cond do
        String.contains?(normalized, "8812au") -> :rtl8812au
        String.ends_with?(normalized, "88xxau") -> :rtl8812au
        String.contains?(normalized, "8812eu") -> :rtl8812eu
        String.ends_with?(normalized, "88xxeu") -> :rtl8812eu
        true -> nil
      end
  end

  defp normalize_driver(driver_name) when is_atom(driver_name), do: driver_name

  defp driver_tokens(nil), do: []

  defp driver_tokens(driver_name) when is_binary(driver_name) do
    normalized = normalize_case_insensitive_string!(driver_name)

    case normalize_driver(driver_name) do
      nil -> [normalized]
      driver -> Enum.uniq([normalized, Atom.to_string(driver)])
    end
  end

  defp driver_tokens(driver_name) when is_atom(driver_name), do: [Atom.to_string(driver_name)]

  defp normalize_mac(nil), do: nil
  defp normalize_mac(value), do: normalize_mac!(value)

  defp normalize_mac!(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_mac!(value) do
    raise ArgumentError,
          "expected MAC selector to be a string or list of strings, got: #{inspect(value)}"
  end

  defp normalize_exact_string!(value) when is_binary(value) and byte_size(value) > 0, do: value

  defp normalize_exact_string!(value) do
    raise ArgumentError,
          "expected selector value to be a non-empty string or list of strings, got: #{inspect(value)}"
  end

  defp normalize_case_insensitive_string!(value) when is_binary(value) and byte_size(value) > 0 do
    String.downcase(value)
  end

  defp normalize_case_insensitive_string!(value) do
    raise ArgumentError,
          "expected selector value to be a non-empty string or list of strings, got: #{inspect(value)}"
  end

  defp normalize_group!(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.downcase()

  defp normalize_group!(value) when is_binary(value) and byte_size(value) > 0 do
    String.downcase(value)
  end

  defp normalize_group!(value) do
    raise ArgumentError,
          "expected group selector to be an atom, string, or list, got: #{inspect(value)}"
  end

  defp bus_path(nil), do: nil

  defp bus_path(device_path) do
    basename = Path.basename(device_path)

    cond do
      pci_bus_id?(basename) ->
        basename

      true ->
        case String.split(device_path, "/devices/", parts: 2) do
          [_prefix, suffix] -> suffix
          [_only] -> basename
        end
    end
  end

  defp pci_bus_id?(value) do
    String.match?(value, ~r/^([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$/i)
  end
end
