defmodule NervesWifibroadcast.Radio.Netlink.Client do
  @moduledoc false

  alias NervesWifibroadcast.Radio.Netlink.Header
  alias NervesWifibroadcast.Radio.Netlink.Socket

  import Bitwise

  @netlink_route 0
  @nlmsg_error 0x02
  @nlmsg_done 0x03
  @nlm_f_request 0x01
  @nlm_f_ack 0x04
  @default_recv_size 65_535
  @default_timeout 1_000

  @spec request(non_neg_integer(), non_neg_integer(), iodata(), Keyword.t()) ::
          {:ok, [Header.message()]} | {:error, term()}
  def request(protocol, type, payload, opts \\ []) do
    with {:ok, socket} <- Socket.open(protocol, opts) do
      try do
        seq = Keyword.get(opts, :seq, System.unique_integer([:positive]))
        flags = Keyword.get(opts, :flags, @nlm_f_request ||| @nlm_f_ack)
        message = Header.nlmsg(type, flags, seq, 0, payload)

        with :ok <- Socket.send(socket, message, opts) do
          recv_replies(socket, seq, opts, [])
        end
      after
        _ = Socket.close(socket, opts)
      end
    end
  end

  @spec netlink_route() :: non_neg_integer()
  def netlink_route, do: @netlink_route

  defp recv_replies(socket, seq, opts, replies) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    recv_size = Keyword.get(opts, :recv_size, @default_recv_size)

    case Socket.recv(socket, recv_size, timeout, opts) do
      {:ok, binary} ->
        case process_messages(Header.decode_messages(binary), seq, replies) do
          {:continue, replies} ->
            recv_replies(socket, seq, opts, replies)

          {:ok, replies} ->
            {:ok, replies}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :timeout} when replies != [] ->
        {:ok, replies}

      {:error, reason} ->
        {:error, {:netlink_recv_failed, reason}}
    end
  end

  defp process_messages(messages, seq, replies) do
    Enum.reduce_while(messages, {:continue, replies}, fn message, {:continue, acc_replies} ->
      cond do
        message.seq != 0 and message.seq != seq ->
          {:cont, {:continue, acc_replies}}

        message.type == @nlmsg_error ->
          case Header.nlmsg_error_code(message.payload) do
            0 -> {:cont, {:ok, acc_replies}}
            error -> {:halt, {:error, {:netlink_error, error}}}
          end

        message.type == @nlmsg_done ->
          {:halt, {:ok, acc_replies}}

        true ->
          {:cont, {:continue, acc_replies ++ [message]}}
      end
    end)
  end
end
