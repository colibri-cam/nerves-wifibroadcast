defmodule NervesWifibroadcast.WFB.Session do
  @moduledoc false

  @fec_vdm_rs 0x01
  @session_key_bytes 32

  @type t :: %__MODULE__{
          channel_id: non_neg_integer(),
          epoch: non_neg_integer(),
          fec_k: non_neg_integer(),
          fec_n: non_neg_integer(),
          fec_type: non_neg_integer(),
          session_key: binary(),
          tags: binary()
        }

  defstruct [:channel_id, :epoch, :fec_k, :fec_n, :fec_type, :session_key, :tags]

  @spec fec_vdm_rs() :: non_neg_integer()
  def fec_vdm_rs, do: @fec_vdm_rs

  @spec parse(binary()) :: {:ok, t()} | {:error, :invalid_session_data}
  def parse(
        <<epoch::big-64, channel_id::big-32, fec_type, fec_k, fec_n,
          session_key::binary-size(@session_key_bytes), tags::binary>>
      ) do
    {:ok,
     %__MODULE__{
       channel_id: channel_id,
       epoch: epoch,
       fec_k: fec_k,
       fec_n: fec_n,
       fec_type: fec_type,
       session_key: session_key,
       tags: tags
     }}
  end

  def parse(_plaintext), do: {:error, :invalid_session_data}
end
