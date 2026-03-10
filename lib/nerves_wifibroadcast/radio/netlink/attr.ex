defmodule NervesWifibroadcast.Radio.Netlink.Attr do
  @moduledoc false

  import Bitwise

  @header_len 4
  @nla_f_nested 1 <<< 15
  @nla_type_mask bnot(@nla_f_nested ||| 1 <<< 14)

  @type decoded_attr :: %{
          nested?: boolean(),
          payload: binary(),
          raw_type: non_neg_integer(),
          type: non_neg_integer()
        }

  @spec u8(non_neg_integer(), non_neg_integer()) :: binary()
  def u8(type, value), do: encode(type, <<value::8>>)

  @spec u16(non_neg_integer(), non_neg_integer()) :: binary()
  def u16(type, value), do: encode(type, <<value::native-16>>)

  @spec u32(non_neg_integer(), non_neg_integer()) :: binary()
  def u32(type, value), do: encode(type, <<value::native-32>>)

  @spec s32(non_neg_integer(), integer()) :: binary()
  def s32(type, value), do: encode(type, <<value::native-signed-32>>)

  @spec string(non_neg_integer(), String.t(), boolean()) :: binary()
  def string(type, value, null_terminated? \\ true) when is_binary(value) do
    payload = if null_terminated?, do: value <> <<0>>, else: value
    encode(type, payload)
  end

  @spec flag(non_neg_integer()) :: binary()
  def flag(type), do: encode(type, <<>>)

  @spec raw(non_neg_integer(), iodata()) :: binary()
  def raw(type, payload), do: encode(type, IO.iodata_to_binary(payload))

  @spec nested(non_neg_integer(), iodata()) :: binary()
  def nested(type, payload), do: encode(type ||| @nla_f_nested, IO.iodata_to_binary(payload))

  @spec decode(binary()) :: [decoded_attr()]
  def decode(binary), do: decode(binary, [])

  @spec find([decoded_attr()], non_neg_integer()) :: decoded_attr() | nil
  def find(attrs, type), do: Enum.find(attrs, &(&1.type == type))

  @spec get_u16([decoded_attr()], non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def get_u16(attrs, type) do
    case find(attrs, type) do
      %{payload: <<value::native-16>>} -> {:ok, value}
      _other -> :error
    end
  end

  @spec get_u32([decoded_attr()], non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def get_u32(attrs, type) do
    case find(attrs, type) do
      %{payload: <<value::native-32>>} -> {:ok, value}
      _other -> :error
    end
  end

  @spec get_binary([decoded_attr()], non_neg_integer()) :: {:ok, binary()} | :error
  def get_binary(attrs, type) do
    case find(attrs, type) do
      %{payload: payload} -> {:ok, payload}
      _other -> :error
    end
  end

  defp encode(type, payload) do
    len = @header_len + byte_size(payload)
    padding_len = align(len) - len
    padding = :binary.copy(<<0>>, padding_len)
    <<len::native-16, type::native-16, payload::binary, padding::binary>>
  end

  defp decode(binary, acc) when byte_size(binary) < @header_len, do: Enum.reverse(acc)

  defp decode(<<len::native-16, raw_type::native-16, rest::binary>> = binary, acc)
       when len >= @header_len and byte_size(binary) >= len do
    payload_len = len - @header_len
    aligned_len = align(len)
    padding_len = aligned_len - len

    <<payload::binary-size(payload_len), _padding::binary-size(padding_len), remaining::binary>> =
      rest

    decoded = %{
      nested?: (raw_type &&& @nla_f_nested) != 0,
      payload: payload,
      raw_type: raw_type,
      type: raw_type &&& @nla_type_mask
    }

    decode(remaining, [decoded | acc])
  end

  defp decode(_binary, acc), do: Enum.reverse(acc)

  defp align(length), do: band(length + 3, -4)
end
