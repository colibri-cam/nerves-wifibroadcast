defmodule RadiotapDecoder do
  @moduledoc """
  A module to decode Radiotap headers from raw network frames.
  """

  # Define a Struct for parsed Radiotap header fields
  defstruct version: nil,
            pad: nil,
            length: nil,
            present_fields: [],
            fields: %{}

  @type t :: %__MODULE__{
          version: integer(),
          pad: integer(),
          length: integer(),
          present_fields: [atom()],
          fields: map()
        }

  @radiotap_fields %{
    0 => :tsft,
    1 => :flags,
    2 => :rate,
    3 => :channel,
    4 => :fhss,
    5 => :antenna_signal,
    6 => :antenna_noise,
    7 => :lock_quality,
    8 => :tx_attenuation,
    9 => :db_tx_attenuation,
    10 => :dbm_tx_power,
    11 => :antenna,
    12 => :db_antenna_signal,
    13 => :db_antenna_noise,
    14 => :rx_flags,
    15 => :tx_flags,
    19 => :mcs,
    20 => :a_mpdu_status,
    21 => :vht,
    22 => :timestamp,
    23 => :he,
    24 => :he_mu,
    25 => :he_mu_other_user,
    26 => :zero_length_psdu,
    27 => :l_sig,
    28 => :tlv_fields_in_radiotap,
    29 => :radiotap_namespace,
    30 => :vendor_namespace,
    32 => :s1g,
    33 => :u_sig,
    34 => :eht
  }

  @doc """
  Parses a binary frame and extracts the Radiotap header.

  ## Examples

      iex> RadiotapDecoder.parse(<<0,0,12,0,15,0,0,0>> <> rest_of_frame)
      %RadiotapDecoder{version: 0, pad: 0, length: 12, present_flags: 15, fields: %{...}}

  """
  @spec parse(binary()) :: t()
  def parse(<<
        version::unsigned-integer-size(8),
        pad::unsigned-integer-size(8),
        length::unsigned-integer-little-size(16),
        present_flags::binary-size(4),
        rest::binary
      >>) do
    # Radiotap has a dynamic field list based on the present_flags bits.
    {present_fields, rest} = decode_present_flags(present_flags, rest)

    %__MODULE__{
      version: version,
      pad: pad,
      length: length,
      present_fields: present_fields,
      fields: decode_fields(present_fields, rest)
    }
  end

  def parse(_), do: :radiotap_parsing_failed

  defp decode_present_flags(flags, rest, idx_add \\ 0, acc \\ []) do
    {idx, acc, extended?} =
      for(<<b::1 <- flags>>, do: b)
      |> Enum.reduce({0, acc, false}, fn
        1, {31 = idx, acc} ->
          {idx + 1, acc, true}

        0, {idx, acc, extended?} ->
          {idx + 1, acc, extended?}

        1, {idx, acc, extended?} ->
          new_acc =
            case Map.get(@radiotap_fields, idx + idx_add) do
              nil -> acc
              field -> [field | acc]
            end

          {idx + 1, new_acc, extended?}
      end)


    if extended? do
      IO.puts("Radiotapheader is extended")
      <<more_flags::binary-size(4), rest::binary>> = rest
      decode_present_flags(more_flags, rest, idx + idx_add, acc)
    else
      {Enum.reverse(acc), rest}
    end
  end

  defp decode_fields(_present_fields, _rest) do
    # Full decoding would parse fields based on flags here.
    # We'll leave this as a stub for now.
    %{}
  end
end

defmodule Eltx do
  @moduledoc """
  Injects a raw Ethernet frame on a given interface.
  """

  # PF_PACKET
  @af_packet 17
  # ETH_P_ALL
  @eth_p_all 0x0003

  @spec open() :: {:ok, :socket.t()}
  def open do
    # ETH_P_ALL in network byte order
    <<proto_be::big-unsigned-integer-size(16)>> =
      <<@eth_p_all::native-unsigned-integer-size(16)>>

    :socket.open(@af_packet, :raw, proto_be)
  end

  def bind(socket, ifname) do
    # lookup interface index
    {:ok, if_index} = :net.if_name2index(to_charlist(ifname))

    # build the sockaddr_ll struct: proto, ifindex, rest zeroed

    sll_protocol = 0x0003
    sll_ifindex = if_index
    sll_hatype = 0
    sll_pkttype = 0
    sll_halen = 0
    sll_addr = <<0::native-unsigned-size(8)-unit(8)>>

    addr = <<
      sll_protocol::big-unsigned-size(16),
      sll_ifindex::native-unsigned-size(32),
      sll_hatype::native-unsigned-size(16),
      sll_pkttype::native-unsigned-size(8),
      sll_halen::native-unsigned-size(8),
      sll_addr::binary
    >>

    # bind it
    :socket.bind(socket, %{family: @af_packet, addr: addr})
  end

  def inject(socket, frame_binary) do
    :ok = :socket.send(socket, frame_binary)
  end

  def capture(sock, fun, max_len \\ 4096) do
    case :socket.recv(sock, 0, 50000) do
      {:ok, packet} ->
        fun.(packet)
        capture(sock, fun, max_len)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_capture() do
    {:ok, socket} = open()
    bind(socket, "wlp106s0u5")

    capture(socket, fn frame_binary ->
      IO.puts("Got frame: #{byte_size(frame_binary)} bytes")

      case RadiotapDecoder.parse(frame_binary) do
        %RadiotapDecoder{} = header ->
          IO.puts("Got radiotap header: #{inspect(header)} bytes")

        :radiotap_parsing_failed ->
          IO.puts("Failed to parse radiotap header")
      end
    end)
  end
end
