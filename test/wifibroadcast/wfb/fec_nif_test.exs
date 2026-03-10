defmodule Wifibroadcast.WFB.FecNifTest do
  use ExUnit.Case, async: true

  alias Wifibroadcast.WFB.FecNif

  test "encodes parity and recovers a missing source shard" do
    codec = FecNif.new(2, 3)
    source_shards = [<<1, 2, 3, 4>>, <<5, 6, 7, 8>>]

    assert is_reference(codec)
    assert {:ok, [parity]} = FecNif.encode(codec, source_shards, 4)

    assert {:ok, [recovered]} =
             FecNif.decode(codec, [source_shards |> hd(), parity], [0, 2], [1], 4)

    assert recovered == Enum.at(source_shards, 1)
  end

  test "handles odd-sized shards with zero padding" do
    codec = FecNif.new(3, 5)

    source_shards = [
      <<1, 2, 3, 4, 5>>,
      <<6, 7, 8>>,
      <<9, 10, 11, 12>>
    ]

    assert is_reference(codec)
    assert {:ok, [parity_a, _parity_b]} = FecNif.encode(codec, source_shards, 5)

    assert {:ok, [recovered]} =
             FecNif.decode(
               codec,
               [Enum.at(source_shards, 0), parity_a, Enum.at(source_shards, 2)],
               [0, 3, 2],
               [1],
               5
             )

    assert recovered == <<6, 7, 8, 0, 0>>
  end
end
