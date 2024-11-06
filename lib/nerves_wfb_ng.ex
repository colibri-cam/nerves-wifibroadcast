defmodule NervesWfbNg do
  require Bundlex.Port

  @moduledoc """
  Documentation for `NervesWfbNg`.
  """

  @doc """
  Sets card into monitor mode.
  """
  def set_card_monitor_mode(card) do
    with {:ok, _} <- cmd("ip", ["link", "set", card, "down"]),
         {:ok, _} <- cmd("iw", ["dev", card, "set", "monitor", "otherbss"]),
         {:ok, _} <- cmd("ip", ["link", "set", card, "up"]),
         do: :ok
  end

  @doc """
  Sets channel and band width on a card
  """
  def set_card_channel(card, channel, width) do
    channel = to_string(channel)
    width = to_string(width)

    with {:ok, _} <- cmd("iw", ["dev", card, "set", channel, width]),
         do: :ok
  end

  @doc """
  Sets power index on card
  """
  def set_card_tx_power(card, mode \\ "fixed", power_index) do
    with true <- power_index >= 0 and power_index <= 63,
         power_index = to_string(-power_index * 100),
         {:ok, _} <- cmd("iw", ["dev", card, "set", "txpower", mode, power_index]),
         do: :ok
  end

  @doc """
  Generates pair of keys(drone.key, gs.key) using wfb_keygen to be
  used on drone and groundstation side.
  """
  def generate_wfb_keys, do: cmd(bundlex_path(:wfb_keygen))

  @doc """
  Starts wfb_tx or wfb_rx and creates StringIO device where output is stored
  """
  def start_wfb(card, mode, port, radio_id \\ 0, key \\ nil)

  def start_wfb(card, :tx, port, radio_id, key) do
    key_args = ["-K", key || "drone.key"]
    port_args = ["-u", to_string(port)]
    radio_id_args = ["-p", to_string(radio_id)]
    args = Enum.concat([key_args, port_args, radio_id_args, [card]])

    cmd_path = bundlex_path(:wfb_tx)
    {:ok, log_device_pid} = StringIO.open("")
    log_io_stream = IO.stream(log_device_pid, :line)

    pid = spawn(fn -> cmd(cmd_path, args, into: log_io_stream) end)

    {pid, log_device_pid}
  end

  def start_wfb(card, :rx, port, radio_id, key) do
    key_args = ["-K", key || "gs.key"]
    port_args = ["-u", to_string(port)]
    radio_id_args = ["-p", to_string(radio_id)]
    args = Enum.concat([key_args, port_args, radio_id_args, [card]])

    cmd_path = bundlex_path(:wfb_rx)
    {:ok, log_device_pid} = StringIO.open("")
    log_io_stream = IO.stream(log_device_pid, :line)

    pid = spawn(fn -> cmd(cmd_path, args, into: log_io_stream) end)

    {pid, log_device_pid}
  end

  defp bundlex_path(native_name) do
    app = Application.get_application(__MODULE__)

    Bundlex.build_path(app, native_name, :port)
  end

  defp cmd(cmd, args \\ [], options \\ []) do
    case MuonTrap.cmd(cmd, args, options) do
      {output, 0} -> {:ok, output}
      {output, err_code} -> {:error, "Error code: #{err_code} \n #{output}"}
    end
  end
end
