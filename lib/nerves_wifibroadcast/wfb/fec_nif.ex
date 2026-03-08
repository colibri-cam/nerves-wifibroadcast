defmodule NervesWifibroadcast.WFB.FecNif do
  @moduledoc false

  use Bundlex.Loader, nif: :wfb_fec

  @opaque codec :: reference()

  @spec new(pos_integer(), pos_integer()) :: codec() | :error
  defnif(new(k, n))

  @spec encode(codec(), [binary()], pos_integer()) :: {:ok, [binary()]} | :error
  defnif(encode(codec, source_shards, shard_size))

  @spec decode(codec(), [binary()], [non_neg_integer()], [non_neg_integer()], pos_integer()) ::
          {:ok, [binary()]} | :error
  defnif(decode(codec, shards, indexes, missing_indexes, shard_size))
end
