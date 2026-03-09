defmodule NervesWifibroadcast.Radio.AFPacket do
  @moduledoc """
  Pure Elixir helper for Linux `AF_PACKET` sockets.
  """

  @af_packet 17
  @eth_p_all 0x0003

  @type socket :: term()

  @spec open(keyword()) :: {:ok, socket()} | {:error, term()}
  def open(opts) do
    interface = Keyword.fetch!(opts, :interface)
    protocol = Keyword.get(opts, :protocol, @eth_p_all)
    socket_buffer_size = Keyword.get(opts, :socket_buffer_size)

    case :socket.open(@af_packet, :raw, htons(protocol)) do
      {:ok, socket} ->
        with :ok <- maybe_set_socket_buffer(socket, socket_buffer_size),
             :ok <- bind(socket, interface, protocol) do
          {:ok, socket}
        else
          {:error, _reason} = error ->
            maybe_close_socket(socket)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec recvmsg(socket(), non_neg_integer(), non_neg_integer(), term()) ::
          {:ok, map()}
          | {:select, term()}
          | {:select_read, term()}
          | {:error, term()}
  def recvmsg(socket, buffer_size, control_size \\ 0, timeout_or_handle \\ :nowait) do
    :socket.recvmsg(socket, buffer_size, control_size, timeout_or_handle)
  end

  @spec cancel(socket(), term()) :: :ok | {:error, term()}
  def cancel(socket, handle) do
    :socket.cancel(socket, handle)
  end

  @spec close(socket()) :: :ok | {:error, term()}
  def close(socket) do
    :socket.close(socket)
  end

  @spec bind(socket(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def bind(socket, interface, protocol \\ @eth_p_all) do
    with {:ok, if_index} <- :net.if_name2index(String.to_charlist(interface)) do
      addr = sockaddr_ll(protocol, if_index)
      :socket.bind(socket, %{family: @af_packet, addr: addr})
    end
  end

  defp sockaddr_ll(protocol, if_index) do
    <<
      protocol::big-unsigned-size(16),
      if_index::native-unsigned-size(32),
      0::native-unsigned-size(16),
      0::native-unsigned-size(8),
      0::native-unsigned-size(8),
      0::native-size(64)
    >>
  end

  defp htons(value) do
    <<big_endian::big-unsigned-integer-size(16)>> = <<value::native-unsigned-integer-size(16)>>
    big_endian
  end

  defp maybe_set_socket_buffer(_socket, nil), do: :ok
  defp maybe_set_socket_buffer(_socket, 0), do: :ok

  defp maybe_set_socket_buffer(socket, socket_buffer_size)
       when is_integer(socket_buffer_size) and socket_buffer_size > 0 do
    :socket.setopt(socket, :socket, :rcvbuf, socket_buffer_size)
  end

  defp maybe_set_socket_buffer(_socket, socket_buffer_size) do
    {:error, {:invalid_socket_buffer_size, socket_buffer_size}}
  end

  defp maybe_close_socket(nil), do: :ok
  defp maybe_close_socket(socket), do: :socket.close(socket)
end
