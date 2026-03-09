defmodule NervesWifibroadcast.Radio.Control do
  @moduledoc """
  Out-of-band radio interface control through OS tooling.
  """

  @type command_runner :: (String.t(), [String.t()], Keyword.t() ->
                             {:ok, binary()} | {:error, term()})
  @type driver_t :: :rtl8812au | :rtl8812eu
  @type tx_power_spec :: nil | :off | {:dbm, non_neg_integer()} | {:raw, integer()}

  @spec set_region(String.t(), command_runner()) :: :ok | {:error, term()}
  def set_region(region, command_runner \\ &default_command_runner/3) do
    region = normalize_region!(region)

    case run_command(command_runner, "iw", ["reg", "set", region]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:set_region_failed, reason}}
    end
  end

  @spec set_monitor_mode(String.t() | [String.t()], command_runner()) :: :ok | {:error, term()}
  def set_monitor_mode(cards, command_runner \\ &default_command_runner/3) do
    cards
    |> normalize_interfaces!()
    |> apply_monitor_mode(command_runner)
  end

  @spec set_card_monitor_mode(String.t() | [String.t()], command_runner()) ::
          :ok | {:error, term()}
  def set_card_monitor_mode(cards, command_runner \\ &default_command_runner/3) do
    set_monitor_mode(cards, command_runner)
  end

  @spec set_link_state(String.t() | [String.t()], boolean(), command_runner()) ::
          :ok | {:error, term()}
  def set_link_state(cards, up?, command_runner \\ &default_command_runner/3)
      when is_boolean(up?) do
    cards
    |> normalize_interfaces!()
    |> apply_link_state(up?, command_runner)
  end

  @spec set_channel(
          String.t() | [String.t()],
          String.t() | pos_integer(),
          String.t() | pos_integer(),
          command_runner()
        ) ::
          :ok | {:error, term()}
  def set_channel(cards, channel, width, command_runner \\ &default_command_runner/3) do
    cards
    |> normalize_interfaces!()
    |> apply_channel(channel, normalize_width!(width), command_runner)
  end

  @spec set_card_channel(
          String.t() | [String.t()],
          String.t() | pos_integer(),
          String.t() | pos_integer(),
          command_runner()
        ) ::
          :ok | {:error, term()}
  def set_card_channel(cards, channel, width, command_runner \\ &default_command_runner/3) do
    set_channel(cards, channel, width, command_runner)
  end

  @spec set_frequency(
          String.t() | [String.t()],
          String.t() | pos_integer(),
          String.t() | pos_integer(),
          command_runner()
        ) ::
          :ok | {:error, term()}
  def set_frequency(cards, frequency_mhz, width, command_runner \\ &default_command_runner/3) do
    cards
    |> normalize_interfaces!()
    |> apply_frequency(frequency_mhz, normalize_width!(width), command_runner)
  end

  @spec set_tx_power(String.t() | [String.t()], tx_power_spec(), Keyword.t()) ::
          :ok | {:error, term()}
  def set_tx_power(cards, tx_power, opts \\ []) do
    command_runner = Keyword.get(opts, :command_runner, &default_command_runner/3)

    cards
    |> normalize_interfaces!()
    |> apply_tx_power(normalize_tx_power!(tx_power, Keyword.get(opts, :driver)), command_runner)
  end

  @spec set_card_tx_power(
          String.t() | [String.t()],
          driver_t(),
          non_neg_integer(),
          command_runner()
        ) ::
          :ok | {:error, term()}
  def set_card_tx_power(cards, driver, dbm, command_runner \\ &default_command_runner/3)

  def set_card_tx_power(cards, driver, dbm, command_runner) when is_integer(dbm) and dbm >= 0 do
    set_tx_power(cards, {:dbm, dbm}, driver: driver, command_runner: command_runner)
  end

  @spec default_command_runner(String.t(), [String.t()], Keyword.t()) ::
          {:ok, binary()} | {:error, term()}
  def default_command_runner(cmd, args, options \\ []) do
    case MuonTrap.cmd(cmd, args, options) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, cmd, args, status, output}}
    end
  end

  defp apply_monitor_mode(interfaces, command_runner) do
    Enum.reduce_while(interfaces, :ok, fn interface, :ok ->
      with :ok <- run_command(command_runner, "ip", ["link", "set", interface, "down"]),
           :ok <-
             run_command(command_runner, "iw", ["dev", interface, "set", "monitor", "otherbss"]),
           :ok <- run_command(command_runner, "ip", ["link", "set", interface, "up"]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:monitor_mode_failed, interface, reason}}}
      end
    end)
  end

  defp apply_link_state(interfaces, up?, command_runner) do
    target_state = if(up?, do: "up", else: "down")

    Enum.reduce_while(interfaces, :ok, fn interface, :ok ->
      case run_command(command_runner, "ip", ["link", "set", interface, target_state]) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:set_link_state_failed, interface, target_state, reason}}}
      end
    end)
  end

  defp apply_channel(interfaces, channel, width, command_runner) do
    channel = normalize_numeric_arg!(channel, "channel")

    Enum.reduce_while(interfaces, :ok, fn interface, :ok ->
      case run_command(command_runner, "iw", ["dev", interface, "set", "channel", channel, width]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:set_channel_failed, interface, reason}}}
      end
    end)
  end

  defp apply_frequency(interfaces, frequency_mhz, width, command_runner) do
    frequency_mhz = normalize_numeric_arg!(frequency_mhz, "frequency")

    Enum.reduce_while(interfaces, :ok, fn interface, :ok ->
      case run_command(command_runner, "iw", [
             "dev",
             interface,
             "set",
             "freq",
             frequency_mhz,
             width
           ]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:set_frequency_failed, interface, reason}}}
      end
    end)
  end

  defp apply_tx_power(_interfaces, nil, _command_runner), do: :ok
  defp apply_tx_power(_interfaces, :off, _command_runner), do: :ok

  defp apply_tx_power(interfaces, value, command_runner) do
    Enum.reduce_while(interfaces, :ok, fn interface, :ok ->
      case run_command(command_runner, "iw", ["dev", interface, "set", "txpower", "fixed", value]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:set_tx_power_failed, interface, reason}}}
      end
    end)
  end

  defp run_command(command_runner, cmd, args) do
    case command_runner.(cmd, args, []) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
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

  defp normalize_region!(region) when is_binary(region) and byte_size(region) > 0, do: region

  defp normalize_region!(region) do
    raise ArgumentError, "expected region to be a non-empty binary, got: #{inspect(region)}"
  end

  defp normalize_numeric_arg!(value, _name) when is_integer(value) and value > 0,
    do: Integer.to_string(value)

  defp normalize_numeric_arg!(value, _name) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp normalize_numeric_arg!(value, name) do
    raise ArgumentError,
          "expected #{name} to be a positive integer or non-empty binary, got: #{inspect(value)}"
  end

  defp normalize_width!(5), do: "5MHz"
  defp normalize_width!("5"), do: "5MHz"
  defp normalize_width!(10), do: "10MHz"
  defp normalize_width!("10"), do: "10MHz"
  defp normalize_width!(20), do: "HT20"
  defp normalize_width!("20"), do: "HT20"
  defp normalize_width!(40), do: "HT40+"
  defp normalize_width!("40"), do: "HT40+"
  defp normalize_width!(80), do: "80MHz"
  defp normalize_width!("80"), do: "80MHz"
  defp normalize_width!(160), do: "160MHz"
  defp normalize_width!("160"), do: "160MHz"
  defp normalize_width!(width) when is_binary(width) and byte_size(width) > 0, do: width

  defp normalize_width!(width) do
    raise ArgumentError,
          "expected width to be one of 5, 10, 20, 40, 80, 160 or a non-empty binary, got: #{inspect(width)}"
  end

  defp normalize_tx_power!(nil, _driver), do: nil
  defp normalize_tx_power!(:off, _driver), do: :off

  defp normalize_tx_power!({:raw, value}, _driver) when is_integer(value),
    do: Integer.to_string(value)

  defp normalize_tx_power!({:dbm, dbm}, driver) when is_integer(dbm) and dbm >= 0 do
    dbm
    |> tx_power_mbm(normalize_driver!(driver))
    |> Integer.to_string()
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
