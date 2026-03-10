defmodule NervesWifibroadcast.Radio.Netlink.Socket do
  @moduledoc false

  @af_netlink 16
  @netlink_generic 16
  @pid_kernel 0
  @sock_raw 3

  @type socket :: term()

  @spec open(non_neg_integer(), Keyword.t()) :: {:ok, socket()} | {:error, term()}
  def open(protocol, opts \\ []) do
    socket_module = socket_module(opts)

    case socket_module.open(@af_netlink, @sock_raw, protocol) do
      {:ok, socket} ->
        with :ok <- socket_module.bind(socket, %{family: @af_netlink, addr: sockaddr_nl(0, 0)}),
             :ok <-
               socket_module.connect(socket, %{
                 family: @af_netlink,
                 addr: sockaddr_nl(@pid_kernel, 0)
               }) do
          {:ok, socket}
        else
          {:error, _reason} = error ->
            _ = maybe_close(socket_module, socket)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec recv(socket(), non_neg_integer(), timeout(), Keyword.t()) ::
          {:ok, binary()} | {:error, term()}
  def recv(socket, length, timeout, opts \\ []) do
    socket_module(opts).recv(socket, length, timeout)
  end

  @spec send(socket(), iodata(), Keyword.t()) :: :ok | {:error, term()}
  def send(socket, payload, opts \\ []) do
    socket_module(opts).send(socket, payload)
  end

  @spec close(socket(), Keyword.t()) :: :ok | {:error, term()}
  def close(socket, opts \\ []) do
    socket_module(opts).close(socket)
  end

  @spec netlink_generic() :: non_neg_integer()
  def netlink_generic, do: @netlink_generic

  @spec sockaddr_nl(non_neg_integer(), non_neg_integer()) :: binary()
  def sockaddr_nl(pid, groups) do
    <<0::native-16, pid::native-32, groups::native-32>>
  end

  defp socket_module(opts), do: Keyword.get(opts, :socket_module, :socket)

  defp maybe_close(_socket_module, nil), do: :ok
  defp maybe_close(socket_module, socket), do: socket_module.close(socket)
end
