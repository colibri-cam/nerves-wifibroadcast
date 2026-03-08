defmodule NervesWifibroadcast.WFB.Keys do
  @moduledoc false

  alias NervesWifibroadcast.WFB.CryptoNif

  @publickey_bytes 32
  @secretkey_bytes 32

  @type t :: %__MODULE__{
          box_key: CryptoNif.box_key(),
          rx_secretkey: binary(),
          tx_publickey: binary()
        }

  defstruct [:box_key, :rx_secretkey, :tx_publickey]

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, key_file} <- File.read(path),
         {:ok, keys} <- from_rx_key_file(key_file) do
      {:ok, keys}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path) do
    case load(path) do
      {:ok, keys} ->
        keys

      {:error, reason} ->
        raise ArgumentError, "unable to load key file #{inspect(path)}: #{inspect(reason)}"
    end
  end

  @spec from_rx_key_file(binary()) :: {:ok, t()} | {:error, term()}
  def from_rx_key_file(
        <<rx_secretkey::binary-size(@secretkey_bytes),
          tx_publickey::binary-size(@publickey_bytes)>>
      ) do
    from_parts(rx_secretkey, tx_publickey)
  end

  def from_rx_key_file(_key_file), do: {:error, :invalid_key_file}

  @spec from_parts(binary(), binary()) :: {:ok, t()} | {:error, term()}
  def from_parts(
        <<_::binary-size(@secretkey_bytes)>> = rx_secretkey,
        <<_::binary-size(@publickey_bytes)>> = tx_publickey
      ) do
    case CryptoNif.box_beforenm(tx_publickey, rx_secretkey) do
      box_key when is_reference(box_key) ->
        {:ok,
         %__MODULE__{box_key: box_key, rx_secretkey: rx_secretkey, tx_publickey: tx_publickey}}

      :error ->
        {:error, :crypto_failure}
    end
  end

  def from_parts(_rx_secretkey, _tx_publickey), do: {:error, :invalid_key_lengths}
end
