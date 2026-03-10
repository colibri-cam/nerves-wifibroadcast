defmodule Wifibroadcast.Radiotap.ParserTest do
  use ExUnit.Case

  import Bitwise

  alias Wifibroadcast.Radiotap.Observation
  alias Wifibroadcast.Radiotap.Parser

  test "parses header and payload with no fields" do
    packet = <<0, 0, 8::little-16, 0::little-32, 1, 2, 3>>

    assert {:ok, radiotap, payload} = Parser.parse(packet)
    assert radiotap.version == 0
    assert radiotap.length == 8
    assert radiotap.present_words == [0]
    assert radiotap.present_indexes == []
    assert payload == <<1, 2, 3>>
  end

  test "parses flags and channel fields" do
    packet = <<
      0,
      0,
      14::little-16,
      0x0A::little-32,
      0x50,
      0,
      2462::little-16,
      0x0140::little-16,
      0x08,
      0x01
    >>

    assert {:ok, radiotap, payload} = Parser.parse(packet)
    assert radiotap.flags == %{raw: 0x50, fcs?: true, bad_fcs?: true, datapad?: false}
    assert radiotap.channel_freq == 2462
    assert radiotap.channel_flags == 0x0140
    assert payload == <<0x08, 0x01>>
  end

  test "parses antenna observations" do
    packet = <<
      0,
      0,
      11::little-16,
      0x860::little-32,
      -42::signed-8,
      -92::signed-8,
      3,
      0x08
    >>

    assert {:ok, radiotap, payload} = Parser.parse(packet)
    assert radiotap.observations == [%Observation{antenna: 3, rssi_dbm: -42, noise_dbm: -92}]
    assert payload == <<0x08>>
  end

  test "parses link-quality fields like tsft rate rx flags and rich mcs" do
    packet =
      radiotap_packet(
        [0, 2, 12, 13, 14, 19],
        <<
          0x08,
          0x07,
          0x06,
          0x05,
          0x04,
          0x03,
          0x02,
          0x01,
          108,
          42,
          9,
          0,
          0x02,
          0x00,
          0x3F,
          0x5D,
          7
        >>,
        <<0x08, 0x01>>
      )

    assert {:ok, radiotap, payload} = Parser.parse(packet)
    assert radiotap.tsft == 0x0102030405060708
    assert radiotap.rate == %{raw: 108, mbps: 54.0}
    assert radiotap.rx_flags == %{raw: 0x0002, bad_plcp?: true}

    assert radiotap.observations == [
             %Observation{antenna: nil, rssi_dbm: nil, noise_dbm: nil, rssi_db: 42, noise_db: 9}
           ]

    assert radiotap.mcs == %{
             known: 0x3F,
             flags: 0x5D,
             index: 7,
             bandwidth_code: 1,
             bandwidth: 40,
             bandwidth_detail: :mhz40,
             short_gi?: true,
             format: :greenfield,
             fec: :ldpc,
             stbc_streams: 2
           }

    assert payload == <<0x08, 0x01>>
  end

  test "parses ampdu and rich vht fields" do
    packet =
      radiotap_packet(
        [20, 21],
        <<
          0x44,
          0x33,
          0x22,
          0x11,
          0x3C,
          0x00,
          0xAA,
          0x00,
          0xF5,
          0x01,
          0x35,
          0x04,
          0x82,
          0x00,
          0x00,
          0x00,
          0x01,
          63,
          0x34,
          0x12
        >>,
        <<0x08>>
      )

    assert {:ok, radiotap, payload} = Parser.parse(packet)

    assert radiotap.ampdu_status == %{
             reference: 0x11223344,
             flags: 0x003C,
             report_zero_length?: false,
             zero_length?: false,
             last_known?: true,
             last?: true,
             delimiter_crc_error?: true,
             delimiter_crc_known?: true,
             delimiter_crc: 0xAA
           }

    assert radiotap.vht == %{
             known: 0x01F5,
             flags: 0x35,
             bandwidth_code: 4,
             bandwidth: 80,
             short_gi?: true,
             stbc?: true,
             beamformed?: true,
             ldpc_extra_ofdm_symbol?: true,
             group_id: 63,
             partial_aid: 0x1234,
             users: [%{user_index: 0, nss: 2, mcs_index: 8, ldpc?: true}],
             nss: 2,
             mcs_index: 8
           }

    assert payload == <<0x08>>
  end

  test "returns error when radiotap length exceeds packet size" do
    assert {:error, :invalid_length} = Parser.parse(<<0, 0, 10::little-16, 0::little-32, 1>>)
  end

  defp radiotap_packet(field_indexes, body, payload) do
    present = Enum.reduce(field_indexes, 0, fn index, acc -> acc ||| 1 <<< index end)
    length = 8 + byte_size(body)

    <<0, 0, length::little-16, present::little-32, body::binary, payload::binary>>
  end
end
