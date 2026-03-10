defmodule Wifibroadcast.WFB.Keys do
  @moduledoc false

  alias Wifibroadcast.WFB.CryptoNif

  @drone_key_path "drone.key"
  @gs_key_path "gs.key"
  @publickey_bytes 32
  @secretkey_bytes 32

  @type t :: %__MODULE__{
          box_key: CryptoNif.box_key(),
          rx_secretkey: binary(),
          tx_publickey: binary()
        }

  @type tx_key_t :: %{
          rx_publickey: binary(),
          tx_secretkey: binary()
        }

  @type generated_t :: CryptoNif.key_material()

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

  @spec load_tx(String.t()) :: {:ok, tx_key_t()} | {:error, term()}
  def load_tx(path) when is_binary(path) do
    with {:ok, key_file} <- File.read(path),
         {:ok, keys} <- from_tx_key_file(key_file) do
      {:ok, keys}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec load_tx!(String.t()) :: tx_key_t()
  def load_tx!(path) when is_binary(path) do
    case load_tx(path) do
      {:ok, keys} ->
        keys

      {:error, reason} ->
        raise ArgumentError, "unable to load tx key file #{inspect(path)}: #{inspect(reason)}"
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

  @spec from_tx_key_file(binary()) :: {:ok, tx_key_t()} | {:error, term()}
  def from_tx_key_file(
        <<tx_secretkey::binary-size(@secretkey_bytes),
          rx_publickey::binary-size(@publickey_bytes)>>
      ) do
    {:ok, %{rx_publickey: rx_publickey, tx_secretkey: tx_secretkey}}
  end

  def from_tx_key_file(_key_file), do: {:error, :invalid_key_file}

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

  @spec generate(Keyword.t()) :: {:ok, generated_t()} | {:error, term()}
  def generate(opts \\ []) do
    opts = Keyword.validate!(opts, password: nil)

    case Keyword.fetch!(opts, :password) do
      nil ->
        normalize_generated_result(CryptoNif.generate_keypairs())

      password when is_binary(password) ->
        normalize_generated_result(CryptoNif.derive_keypairs(password))

      password ->
        raise ArgumentError, "expected :password to be nil or a binary, got: #{inspect(password)}"
    end
  end

  @spec generate!(Keyword.t()) :: generated_t()
  def generate!(opts \\ []) do
    case generate(opts) do
      {:ok, keys} ->
        keys

      {:error, reason} ->
        raise ArgumentError, "unable to generate key material: #{inspect(reason)}"
    end
  end

  @spec generate_files(Keyword.t()) ::
          {:ok, %{drone_path: String.t(), gs_path: String.t(), keys: generated_t()}}
          | {:error, term()}
  def generate_files(opts \\ []) do
    opts =
      Keyword.validate!(opts, drone_path: @drone_key_path, gs_path: @gs_key_path, password: nil)

    drone_path = Keyword.fetch!(opts, :drone_path)
    gs_path = Keyword.fetch!(opts, :gs_path)
    password = Keyword.fetch!(opts, :password)

    validate_path!(drone_path, :drone_path)
    validate_path!(gs_path, :gs_path)

    with {:ok, keys} <- generate(password: password),
         :ok <- File.write(drone_path, drone_key_file_content(keys)),
         :ok <- File.write(gs_path, gs_key_file_content(keys)) do
      {:ok, %{drone_path: drone_path, gs_path: gs_path, keys: keys}}
    end
  end

  @spec generate_files!(Keyword.t()) :: %{
          drone_path: String.t(),
          gs_path: String.t(),
          keys: generated_t()
        }
  def generate_files!(opts \\ []) do
    case generate_files(opts) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise ArgumentError, "unable to generate key files: #{inspect(reason)}"
    end
  end

  @spec drone_key_file_content(generated_t()) :: binary()
  def drone_key_file_content(%{drone_secretkey: drone_secretkey, gs_publickey: gs_publickey}) do
    validate_secretkey!(drone_secretkey, :drone_secretkey)
    validate_publickey!(gs_publickey, :gs_publickey)
    drone_secretkey <> gs_publickey
  end

  @spec gs_key_file_content(generated_t()) :: binary()
  def gs_key_file_content(%{drone_publickey: drone_publickey, gs_secretkey: gs_secretkey}) do
    validate_publickey!(drone_publickey, :drone_publickey)
    validate_secretkey!(gs_secretkey, :gs_secretkey)
    gs_secretkey <> drone_publickey
  end

  defp normalize_generated_result({:ok, keys}) do
    case valid_generated_keys?(keys) do
      true -> {:ok, keys}
      false -> {:error, :invalid_generated_keys}
    end
  end

  defp normalize_generated_result(:error), do: {:error, :crypto_failure}

  defp valid_generated_keys?(%{
         drone_publickey: drone_publickey,
         drone_secretkey: drone_secretkey,
         gs_publickey: gs_publickey,
         gs_secretkey: gs_secretkey
       }) do
    valid_publickey?(drone_publickey) and valid_secretkey?(drone_secretkey) and
      valid_publickey?(gs_publickey) and valid_secretkey?(gs_secretkey)
  end

  defp valid_generated_keys?(_other), do: false

  defp validate_publickey!(key, field) do
    if valid_publickey?(key) do
      :ok
    else
      raise ArgumentError,
            "expected #{inspect(field)} to be a #{@publickey_bytes}-byte binary, got: #{inspect(key)}"
    end
  end

  defp validate_secretkey!(key, field) do
    if valid_secretkey?(key) do
      :ok
    else
      raise ArgumentError,
            "expected #{inspect(field)} to be a #{@secretkey_bytes}-byte binary, got: #{inspect(key)}"
    end
  end

  defp valid_publickey?(key), do: is_binary(key) and byte_size(key) == @publickey_bytes
  defp valid_secretkey?(key), do: is_binary(key) and byte_size(key) == @secretkey_bytes

  defp validate_path!(path, _field) when is_binary(path), do: path

  defp validate_path!(path, field) do
    raise ArgumentError, "expected #{inspect(field)} to be a path string, got: #{inspect(path)}"
  end
end
