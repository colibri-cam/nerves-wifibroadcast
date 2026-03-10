defmodule Wifibroadcast.Radio.Control do
  @moduledoc """
  Out-of-band radio interface control through pure-Elixir rtnetlink and nl80211.

  Public functions accept interface names. Low-level netlink options such as
  `:socket_module`, `:ifindex_resolver`, `:timeout`, and `:recv_size` are kept
  available for testing and advanced control.
  """

  alias Wifibroadcast.Radio.Channel
  alias Wifibroadcast.Radio.Netlink.Nl80211
  alias Wifibroadcast.Radio.Netlink.Rtnetlink

  @type driver_t :: :rtl8812au | :rtl8812eu
  @type tx_power_spec :: nil | :off | {:dbm, non_neg_integer()} | {:raw, integer()}

  @spec set_region(String.t(), Keyword.t()) :: :ok | {:error, term()}
  def set_region(region, opts \\ []) do
    case Nl80211.set_region(normalize_region!(region), opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:set_region_failed, reason}}
    end
  end

  @spec set_monitor_mode(String.t() | [String.t()], Keyword.t()) :: :ok | {:error, term()}
  def set_monitor_mode(cards, opts \\ []) do
    cards
    |> normalize_interfaces!()
    |> Enum.reduce_while(:ok, fn interface, :ok ->
      with {:ok, ifindex} <- resolve_ifindex(interface, opts),
           :ok <- Rtnetlink.set_link_state(ifindex, false, opts),
           :ok <- Nl80211.set_monitor_mode(ifindex, opts),
           :ok <- Rtnetlink.set_link_state(ifindex, true, opts) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:monitor_mode_failed, interface, reason}}}
      end
    end)
  end

  @spec set_card_monitor_mode(String.t() | [String.t()], Keyword.t()) :: :ok | {:error, term()}
  def set_card_monitor_mode(cards, opts \\ []) do
    set_monitor_mode(cards, opts)
  end

  @spec set_link_state(String.t() | [String.t()], boolean(), Keyword.t()) ::
          :ok | {:error, term()}
  def set_link_state(cards, up?, opts \\ []) when is_boolean(up?) do
    target_state = if(up?, do: "up", else: "down")

    cards
    |> normalize_interfaces!()
    |> Enum.reduce_while(:ok, fn interface, :ok ->
      with {:ok, ifindex} <- resolve_ifindex(interface, opts),
           :ok <- Rtnetlink.set_link_state(ifindex, up?, opts) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, {:set_link_state_failed, interface, target_state, reason}}}
      end
    end)
  end

  @spec set_channel(
          String.t() | [String.t()],
          String.t() | pos_integer(),
          String.t() | pos_integer(),
          Keyword.t()
        ) ::
          :ok | {:error, term()}
  def set_channel(cards, channel, width, opts \\ []) do
    width = Channel.normalize_width!(width)
    frequency_mhz = channel |> Channel.normalize_channel!() |> Channel.channel_to_frequency!()

    cards
    |> normalize_interfaces!()
    |> Enum.reduce_while(:ok, fn interface, :ok ->
      with {:ok, ifindex} <- resolve_ifindex(interface, opts),
           :ok <-
             wrap_argument_errors(fn ->
               Nl80211.set_frequency(ifindex, frequency_mhz, width, opts)
             end) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:set_channel_failed, interface, reason}}}
      end
    end)
  end

  @spec set_card_channel(
          String.t() | [String.t()],
          String.t() | pos_integer(),
          String.t() | pos_integer(),
          Keyword.t()
        ) ::
          :ok | {:error, term()}
  def set_card_channel(cards, channel, width, opts \\ []) do
    set_channel(cards, channel, width, opts)
  end

  @spec set_frequency(
          String.t() | [String.t()],
          String.t() | pos_integer(),
          String.t() | pos_integer(),
          Keyword.t()
        ) ::
          :ok | {:error, term()}
  def set_frequency(cards, frequency_mhz, width, opts \\ []) do
    width = Channel.normalize_width!(width)
    frequency_mhz = Channel.normalize_frequency!(frequency_mhz)

    cards
    |> normalize_interfaces!()
    |> Enum.reduce_while(:ok, fn interface, :ok ->
      with {:ok, ifindex} <- resolve_ifindex(interface, opts),
           :ok <-
             wrap_argument_errors(fn ->
               Nl80211.set_frequency(ifindex, frequency_mhz, width, opts)
             end) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:set_frequency_failed, interface, reason}}}
      end
    end)
  end

  @spec set_tx_power(String.t() | [String.t()], tx_power_spec(), Keyword.t()) ::
          :ok | {:error, term()}
  def set_tx_power(cards, tx_power, opts \\ []) do
    cards = normalize_interfaces!(cards)
    driver = Keyword.get(opts, :driver)
    tx_power = normalize_tx_power!(tx_power, driver)
    opts = Keyword.drop(opts, [:driver])

    if tx_power in [nil, :off] do
      :ok
    else
      Enum.reduce_while(cards, :ok, fn interface, :ok ->
        with {:ok, ifindex} <- resolve_ifindex(interface, opts),
             :ok <- Nl80211.set_tx_power(ifindex, tx_power, opts) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:set_tx_power_failed, interface, reason}}}
        end
      end)
    end
  end

  @spec set_card_tx_power(String.t() | [String.t()], driver_t(), non_neg_integer(), Keyword.t()) ::
          :ok | {:error, term()}
  def set_card_tx_power(cards, driver, dbm, opts \\ []) when is_integer(dbm) and dbm >= 0 do
    set_tx_power(cards, {:dbm, dbm}, Keyword.put(opts, :driver, driver))
  end

  defp resolve_ifindex(interface, opts) do
    resolver = Keyword.get(opts, :ifindex_resolver, &default_ifindex_resolver/1)

    case resolver.(interface) do
      {:ok, ifindex} when is_integer(ifindex) and ifindex > 0 -> {:ok, ifindex}
      ifindex when is_integer(ifindex) and ifindex > 0 -> {:ok, ifindex}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_ifindex, interface, other}}
    end
  end

  defp default_ifindex_resolver(interface) do
    case :net.if_name2index(String.to_charlist(interface)) do
      {:ok, ifindex} -> {:ok, ifindex}
      {:error, reason} -> {:error, {:if_name2index_failed, interface, reason}}
    end
  end

  defp wrap_argument_errors(fun) do
    fun.()
  rescue
    error in ArgumentError -> {:error, {:invalid_argument, Exception.message(error)}}
  end

  defp normalize_interfaces!(interface) when is_binary(interface),
    do: [validate_interface!(interface)]

  defp normalize_interfaces!(interfaces) when is_list(interfaces) do
    interfaces = Enum.map(interfaces, &validate_interface!/1)

    if interfaces == [] do
      raise ArgumentError, "expected at least one interface"
    else
      interfaces
    end
  end

  defp normalize_interfaces!(interfaces) do
    raise ArgumentError,
          "expected interfaces to be a binary or non-empty list of binaries, got: #{inspect(interfaces)}"
  end

  defp validate_interface!(interface) when is_binary(interface) and byte_size(interface) > 0,
    do: interface

  defp validate_interface!(interface) do
    raise ArgumentError, "expected interface to be a non-empty binary, got: #{inspect(interface)}"
  end

  defp normalize_region!(region) when is_binary(region) and byte_size(region) > 0,
    do: String.upcase(region)

  defp normalize_region!(region) do
    raise ArgumentError, "expected region to be a non-empty binary, got: #{inspect(region)}"
  end

  defp normalize_tx_power!(nil, _driver), do: nil
  defp normalize_tx_power!(:off, _driver), do: :off
  defp normalize_tx_power!({:raw, value}, _driver) when is_integer(value), do: value

  defp normalize_tx_power!({:dbm, dbm}, driver) when is_integer(dbm) and dbm >= 0 do
    tx_power_mbm(dbm, normalize_driver!(driver))
  end

  defp normalize_tx_power!(tx_power, driver) do
    raise ArgumentError,
          "expected tx_power to be nil, :off, {:raw, integer} or {:dbm, non_neg_integer} with driver #{inspect(driver)}, got: #{inspect(tx_power)}"
  end

  defp normalize_driver!(:rtl8812au), do: :rtl8812au
  defp normalize_driver!(:rtl8812eu), do: :rtl8812eu
  defp normalize_driver!("rtl8812au"), do: :rtl8812au
  defp normalize_driver!("rtl8812eu"), do: :rtl8812eu

  defp normalize_driver!(driver) do
    raise ArgumentError,
          "expected driver to be :rtl8812au or :rtl8812eu, got: #{inspect(driver)}"
  end

  defp tx_power_mbm(dbm, :rtl8812au), do: -dbm * 100
  defp tx_power_mbm(dbm, :rtl8812eu), do: dbm * 100
end
