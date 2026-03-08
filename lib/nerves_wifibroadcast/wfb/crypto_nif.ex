defmodule NervesWifibroadcast.WFB.CryptoNif do
  @moduledoc false

  use Bundlex.Loader, nif: :wfb_crypto

  @opaque box_key :: reference()

  @spec box_beforenm(binary(), binary()) :: box_key() | :error
  defnif(box_beforenm(tx_publickey, rx_secretkey))

  @spec open_session(binary(), box_key()) :: {:ok, binary()} | :error
  defnif(open_session(packet, box_key))

  @spec open_data(binary(), binary()) :: {:ok, binary()} | :error
  defnif(open_data(packet, session_key))

  @spec seal_session(binary(), binary(), binary(), binary()) :: {:ok, binary()} | :error
  defnif(seal_session(plaintext, session_nonce, rx_publickey, tx_secretkey))

  @spec seal_data(binary(), non_neg_integer(), binary()) :: {:ok, binary()} | :error
  defnif(seal_data(plaintext, data_nonce, session_key))
end
