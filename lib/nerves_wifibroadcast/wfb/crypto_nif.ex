defmodule NervesWifibroadcast.WFB.CryptoNif do
  @moduledoc false

  use Bundlex.Loader, nif: :wfb_crypto

  @opaque box_key :: reference()
  @type key_material :: %{
          drone_publickey: binary(),
          drone_secretkey: binary(),
          gs_publickey: binary(),
          gs_secretkey: binary()
        }

  @spec box_beforenm(binary(), binary()) :: box_key() | :error
  defnif(box_beforenm(tx_publickey, rx_secretkey))

  @spec generate_keypairs() :: {:ok, key_material()} | :error
  defnif(generate_keypairs())

  @spec derive_keypairs(binary()) :: {:ok, key_material()} | :error
  defnif(derive_keypairs(password))

  @spec open_session(binary(), box_key()) :: {:ok, binary()} | :error
  defnif(open_session(packet, box_key))

  @spec open_data(binary(), binary()) :: {:ok, binary()} | :error
  defnif(open_data(packet, session_key))

  @spec seal_session(binary(), binary(), binary(), binary()) :: {:ok, binary()} | :error
  defnif(seal_session(plaintext, session_nonce, rx_publickey, tx_secretkey))

  @spec seal_data(binary(), non_neg_integer(), binary()) :: {:ok, binary()} | :error
  defnif(seal_data(plaintext, data_nonce, session_key))
end
