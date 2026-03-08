defmodule NervesWifibroadcast.WFB.FecNifTest do
  use ExUnit.Case, async: true

  alias NervesWifibroadcast.WFB.FecNif

  test "encodes parity and recovers a missing source shard" do
    codec = FecNif.new(2, 3)
    source_shards = [<<1, 2, 3, 4>>, <<5, 6, 7, 8>>]

    assert is_reference(codec)
    assert {:ok, [parity]} = FecNif.encode(codec, source_shards, 4)

    assert {:ok, [recovered]} =
             FecNif.decode(codec, [source_shards |> hd(), parity], [0, 2], [1], 4)

    assert recovered == Enum.at(source_shards, 1)
  end
end
