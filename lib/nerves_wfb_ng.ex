defmodule NervesWfbNg do
  require Bundlex.Port

  @moduledoc """
  Documentation for `NervesWfbNg`.
  """

  @doc """
  Sets card into monitor mode.
  """
  def set_card_montitor_mode(card) do
    with {:ok, _} <- cmd("ip", ["link", "set", card, "down"]),
         {:ok, _} <- cmd("iw", ["dev", card, "set", "monitor", "otherbss"]),
         {:ok, _} <- cmd("ip", ["link", "set", card, "up"]) do
      :ok
    end
  end

  @doc """
  Sets channel and band width on a card
  """
  def set_card_channel(card, channel, width) do
    channel = to_string(channel)
    width = to_string(width)
    with {:ok, _} <- cmd("iw", ["dev", card, "set", channel, width]), do: :ok
  end

  @doc """
  Generates pair of keys(drone.key, gs.key) using wfb_keygen to be
  used on drone and groundstation side.
  """
  def generate_wfb_keys do
    port = Bundlex.Port.open(:wfb_keygen)

    Port.monitor(port)

    receive do
      {:DOWN, _, :port, ^port, :normal} -> :ok
    end
  end

  def start_wfb(card, mode, port, radio_id \\ 0, key \\ nil)

  def start_wfb(card, :tx, port, radio_id, key) do
    key_args = ["-K", key || "drone.key"]
    port_args = ["-u", to_string(port)]
    radio_id_args = ["-p", to_string(radio_id)]
    args = Enum.concat([key_args, port_args, radio_id_args, [card]])

    spawn(fn _ -> cmd(bundlex_path(:wfb_tx), args) end)
  end

  def start_wfb(card, :rx, port, radio_id, key) do
    key_args = ["-K", key || "gs.key"]
    port_args = ["-u", to_string(port)]
    radio_id_args = ["-p", to_string(radio_id)]
    args = Enum.concat([key_args, port_args, radio_id_args, [card]])

    spawn(fn _ -> cmd(bundlex_path(:wfb_rx), args) end)
  end

  defp bundlex_path(native_name) do
    app = Application.get_application(__MODULE__)

    Bundlex.build_path(app, native_name, :port)
  end

  defp cmd(cmd, args) do
    case MuonTrap.cmd(cmd, args) do
      {output, 0} -> {:ok, output}
      {output, err_code} -> {:error, "Error code: #{err_code} \n #{output}"}
    end
  end
end
