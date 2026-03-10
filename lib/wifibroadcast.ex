defmodule Wifibroadcast do
  alias Wifibroadcast.Radio.Control
  alias Wifibroadcast.WFB.Keys

  @moduledoc """
  Top-level helpers for radio control and WFB key generation.
  """

  @doc """
  Sets card into monitor mode.
  """
  def set_card_monitor_mode(card) do
    Control.set_monitor_mode(card)
  end

  @doc """
  Sets channel and bandwidth on a card.
  """
  def set_card_channel(card, channel, width) do
    Control.set_channel(card, channel, width)
  end

  @doc """
  Sets card TX power using explicit wfb-ng driver semantics.

  Supported drivers are `:rtl8812au` and `:rtl8812eu`.
  """
  def set_card_tx_power(card, driver, dbm) when is_integer(dbm) and dbm >= 0 do
    Control.set_card_tx_power(card, driver, dbm)
  end

  @doc """
  Generates `drone.key` and `gs.key` in the current directory.

  When a password is provided, the output matches the password-derived
  `wfb-ng` key generation flow.
  """
  @spec generate_wfb_keys(nil | binary()) ::
          {:ok, %{drone_path: String.t(), gs_path: String.t(), keys: Keys.generated_t()}}
          | {:error, term()}
  def generate_wfb_keys(password \\ nil)

  def generate_wfb_keys(nil) do
    Keys.generate_files()
  end

  def generate_wfb_keys(password) when is_binary(password) do
    Keys.generate_files(password: password)
  end
end
