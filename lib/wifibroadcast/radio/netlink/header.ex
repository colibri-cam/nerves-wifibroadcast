defmodule Wifibroadcast.Radio.Netlink.Header do
  @moduledoc false

  @nlmsg_hdrlen 16
  @genl_hdrlen 4
  @ifinfomsg_len 16

  @type message :: %{
          flags: non_neg_integer(),
          payload: binary(),
          pid: non_neg_integer(),
          seq: non_neg_integer(),
          type: non_neg_integer()
        }

  @spec nlmsg(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          iodata()
        ) ::
          binary()
  def nlmsg(type, flags, seq, pid, payload) do
    payload = IO.iodata_to_binary(payload)
    len = @nlmsg_hdrlen + byte_size(payload)

    <<len::native-32, type::native-16, flags::native-16, seq::native-32, pid::native-32,
      payload::binary>>
  end

  @spec genlmsg(non_neg_integer(), non_neg_integer(), iodata()) :: binary()
  def genlmsg(cmd, version, attrs) do
    attrs = IO.iodata_to_binary(attrs)
    <<cmd::8, version::8, 0::native-16, attrs::binary>>
  end

  @spec ifinfomsg(integer(), integer(), integer(), integer(), integer()) :: binary()
  def ifinfomsg(index, flags, change, family \\ 0, type \\ 0) do
    <<family::8, 0::8, type::native-16, index::native-signed-32, flags::native-32,
      change::native-32>>
  end

  @spec decode_messages(binary()) :: [message()]
  def decode_messages(binary), do: decode_messages(binary, [])

  @spec decode_genlmsg(binary()) :: %{
          attrs: binary(),
          cmd: non_neg_integer(),
          version: non_neg_integer()
        }
  def decode_genlmsg(<<cmd::8, version::8, _reserved::native-16, attrs::binary>>) do
    %{cmd: cmd, version: version, attrs: attrs}
  end

  @spec nlmsg_error_code(binary()) :: integer()
  def nlmsg_error_code(<<error::native-signed-32, _rest::binary>>), do: error

  @spec nlmsg_header_length() :: non_neg_integer()
  def nlmsg_header_length, do: @nlmsg_hdrlen

  @spec genl_header_length() :: non_neg_integer()
  def genl_header_length, do: @genl_hdrlen

  @spec ifinfomsg_length() :: non_neg_integer()
  def ifinfomsg_length, do: @ifinfomsg_len

  defp decode_messages(binary, acc) when byte_size(binary) < @nlmsg_hdrlen, do: Enum.reverse(acc)

  defp decode_messages(
         <<len::native-32, type::native-16, flags::native-16, seq::native-32, pid::native-32,
           rest::binary>> = binary,
         acc
       )
       when len >= @nlmsg_hdrlen and byte_size(binary) >= len do
    payload_len = len - @nlmsg_hdrlen
    aligned_len = align(len)

    <<payload::binary-size(payload_len), tail::binary>> = rest
    padding_len = aligned_len - len
    <<_padding::binary-size(padding_len), remaining::binary>> = tail

    message = %{type: type, flags: flags, seq: seq, pid: pid, payload: payload}
    decode_messages(remaining, [message | acc])
  end

  defp decode_messages(_binary, acc), do: Enum.reverse(acc)

  defp align(length), do: Bitwise.band(length + 3, -4)
end
