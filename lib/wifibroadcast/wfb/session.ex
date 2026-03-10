defmodule Wifibroadcast.WFB.Session do
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

  @spec serialize(t()) :: {:ok, binary()} | {:error, :invalid_session_data}
  def serialize(%__MODULE__{} = session) do
    with true <- valid_epoch?(session.epoch),
         true <- valid_channel_id?(session.channel_id),
         true <- valid_fec_byte?(session.fec_type),
         true <- valid_fec_byte?(session.fec_k),
         true <- valid_fec_byte?(session.fec_n),
         true <- session.fec_k >= 1 and session.fec_k <= session.fec_n,
         true <-
           is_binary(session.session_key) and byte_size(session.session_key) == @session_key_bytes,
         true <- is_binary(session.tags) do
      {:ok,
       <<session.epoch::big-64, session.channel_id::big-32, session.fec_type, session.fec_k,
         session.fec_n, session.session_key::binary, session.tags::binary>>}
    else
      _other -> {:error, :invalid_session_data}
    end
  end

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

  defp valid_epoch?(epoch), do: is_integer(epoch) and epoch >= 0 and epoch <= 0xFFFFFFFFFFFFFFFF

  defp valid_channel_id?(channel_id),
    do: is_integer(channel_id) and channel_id >= 0 and channel_id <= 0xFFFFFFFF

  defp valid_fec_byte?(value), do: is_integer(value) and value >= 0 and value <= 0xFF
end
