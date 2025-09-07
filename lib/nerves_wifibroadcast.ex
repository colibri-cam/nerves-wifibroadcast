defmodule NervesWifibroadcast do
  require Bundlex.Port

  @moduledoc """
  Documentation for `NervesWfbNg`.
  """

  @doc """
  Sets card into monitor mode.
  """
  def set_card_monitor_mode(card) do
    with {:ok, _} <- mt_cmd("ip", ["link", "set", card, "down"]),
         {:ok, _} <- mt_cmd("iw", ["dev", card, "set", "monitor", "otherbss"]),
         {:ok, _} <- mt_cmd("ip", ["link", "set", card, "up"]),
         do: :ok
  end

  @doc """
  Sets channel and band width on a card
  """
  def set_card_channel(card, channel, width) do
    channel = to_string(channel)
    width = to_string(width)

    with {:ok, _} <- mt_cmd("iw", ["dev", card, "set", "channel", channel, width]),
         do: :ok
  end

  @doc """
  Sets power index on card
  """
  def set_card_tx_power(card, mode \\ "fixed", power_index) do
    with true <- power_index >= 0 and power_index <= 63,
         power_index = to_string(-power_index * 100),
         {:ok, _} <- mt_cmd("iw", ["dev", card, "set", "txpower", mode, power_index]),
         do: :ok
  end

  @doc """
  Generates pair of keys(drone.key, gs.key) using wfb_keygen to be
  used on drone and groundstation side.
  """
  def generate_wfb_keys, do: mt_cmd(bundlex_path(:wfb_keygen))

  @doc """
  Starts wfb_tx and creates StringIO device where output is stored
  """
  def start_wfb_tx(card, opts \\ []) do
    defaults = [port: 5001, radio_id: 0, key: "drone.key", mcs_i: 0, bandwidth: 20]
    args = defaults |> Keyword.merge(opts) |> Enum.flat_map(&prepare_args(&1)) |> Enum.concat([card])

    cmd_path = bundlex_path(:wfb_tx)
    {:ok, log_device_pid} = StringIO.open("")
    log_io_stream = IO.stream(log_device_pid, :line)

    pid = spawn(fn -> mt_cmd(cmd_path, args, into: log_io_stream) end)

    {pid, log_device_pid}
  end

  @doc """
  Starts wfb_rx and creates StringIO device where output is stored
  """
  def start_wfb_rx(card, opts \\ [])
  def start_wfb_rx(card, opts) when is_binary(card), do: start_wfb_rx([card], opts)
  def start_wfb_rx(cards, opts) do
    defaults = [port: 5001, radio_id: 0, key: "gs.key", link_id: 7669206]
    args = defaults |> Keyword.merge(opts) |> Enum.flat_map(&prepare_args(&1)) |> Enum.concat(cards)

    cmd_path = bundlex_path(:wfb_rx)
    {:ok, log_device_pid} = StringIO.open("")
    log_io_stream = IO.stream(log_device_pid, :line)

    pid = spawn(fn -> mt_cmd(cmd_path, args, into: log_io_stream) end)

    {pid, log_device_pid}
  end

  defp prepare_args({:port, port}), do: ["-u", to_string(port)]
  defp prepare_args({:key, key}), do: ["-K", key]
  defp prepare_args({:radio_id, radio_id}), do: ["-p", to_string(radio_id)]
  defp prepare_args({:link_id, link_id}), do: ["-i", to_string(link_id)]
  defp prepare_args({:mcs_i, mcs_i}), do: ["-M", to_string(mcs_i)]
  defp prepare_args({:bandwidth, bandwidth}), do: ["-B", to_string(bandwidth)]


  defp bundlex_path(native_name) do
    app = Application.get_application(__MODULE__)

    Bundlex.build_path(app, native_name, :port)
  end

  defp mt_cmd(cmd, args \\ [], options \\ []) do
    case MuonTrap.cmd(cmd, args, options) do
      {output, 0} -> {:ok, output}
      {output, err_code} -> {:error, "Error code: #{err_code} \n #{inspect output}"}
    end
  end
end
