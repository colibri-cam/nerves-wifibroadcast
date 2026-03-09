defmodule NervesWifibroadcast.TestSupport.WFBFixtures do
  import Bitwise

  alias Membrane.Buffer
  alias Membrane.RemoteStream
  alias NervesWifibroadcast.Membrane.WFB.DecryptedStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.OrderedShardStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.Membrane.WFB.WrappedPayloadStreamFormat
  alias NervesWifibroadcast.WFB.CryptoNif
  alias NervesWifibroadcast.WFB.FecNif

  @default_link_id 7_669_206
  @default_radio_port 4
  @default_interfaces ["wlan0"]
  @fec_type 0x01

  def key_material do
    {tx_publickey, tx_secretkey} = :crypto.generate_key(:eddh, :x25519)
    {rx_publickey, rx_secretkey} = :crypto.generate_key(:eddh, :x25519)

    %{
      rx_publickey: rx_publickey,
      rx_secretkey: rx_secretkey,
      tx_publickey: tx_publickey,
      tx_secretkey: tx_secretkey
    }
  end

  def ingress_stream_format(opts \\ []) do
    link_id = Keyword.get(opts, :link_id, @default_link_id)
    radio_port = Keyword.get(opts, :radio_port, @default_radio_port)

    %StreamFormat{
      channel_id: channel_id(link_id, radio_port),
      encrypted?: Keyword.get(opts, :encrypted?, true),
      interfaces: Keyword.get(opts, :interfaces, @default_interfaces),
      link_id: link_id,
      radio_port: radio_port
    }
  end

  def remote_stream_format do
    %RemoteStream{type: :packetized, content_format: nil}
  end

  def wrapped_payload_stream_format(opts \\ []) do
    link_id = Keyword.get(opts, :link_id, @default_link_id)
    radio_port = Keyword.get(opts, :radio_port, @default_radio_port)

    %WrappedPayloadStreamFormat{
      channel_id: channel_id(link_id, radio_port),
      interfaces: Keyword.get(opts, :interfaces, []),
      link_id: link_id,
      radio_port: radio_port
    }
  end

  def decrypted_stream_format(opts \\ []) do
    link_id = Keyword.get(opts, :link_id, @default_link_id)
    radio_port = Keyword.get(opts, :radio_port, @default_radio_port)

    %DecryptedStreamFormat{
      channel_id: channel_id(link_id, radio_port),
      epoch: Keyword.get(opts, :epoch, 1),
      fec_k: Keyword.get(opts, :fec_k, 2),
      fec_n: Keyword.get(opts, :fec_n, 3),
      fec_type: Keyword.get(opts, :fec_type, @fec_type),
      interfaces: Keyword.get(opts, :interfaces, @default_interfaces),
      link_id: link_id,
      radio_port: radio_port
    }
  end

  def ordered_shard_stream_format(opts \\ []) do
    link_id = Keyword.get(opts, :link_id, @default_link_id)
    radio_port = Keyword.get(opts, :radio_port, @default_radio_port)

    %OrderedShardStreamFormat{
      channel_id: channel_id(link_id, radio_port),
      epoch: Keyword.get(opts, :epoch, 1),
      fec_k: Keyword.get(opts, :fec_k, 2),
      fec_n: Keyword.get(opts, :fec_n, 3),
      fec_type: Keyword.get(opts, :fec_type, @fec_type),
      interfaces: Keyword.get(opts, :interfaces, @default_interfaces),
      link_id: link_id,
      radio_port: radio_port
    }
  end

  def channel_id(link_id \\ @default_link_id, radio_port \\ @default_radio_port) do
    (link_id <<< 8) + radio_port
  end

  def session_plaintext(opts \\ []) do
    epoch = Keyword.get(opts, :epoch, 1)
    link_id = Keyword.get(opts, :link_id, @default_link_id)
    radio_port = Keyword.get(opts, :radio_port, @default_radio_port)
    fec_k = Keyword.get(opts, :fec_k, 8)
    fec_n = Keyword.get(opts, :fec_n, 12)
    session_key = Keyword.get(opts, :session_key, :crypto.strong_rand_bytes(32))
    tags = Keyword.get(opts, :tags, <<>>)

    plaintext =
      <<epoch::big-64, channel_id(link_id, radio_port)::big-32, @fec_type, fec_k, fec_n,
        session_key::binary, tags::binary>>

    %{
      channel_id: channel_id(link_id, radio_port),
      epoch: epoch,
      fec_k: fec_k,
      fec_n: fec_n,
      fec_type: @fec_type,
      link_id: link_id,
      plaintext: plaintext,
      radio_port: radio_port,
      session_key: session_key,
      tags: tags
    }
  end

  def encrypted_session_packet(keys, opts \\ []) do
    session = session_plaintext(opts)
    session_nonce = Keyword.get(opts, :session_nonce, :crypto.strong_rand_bytes(24))

    {:ok, packet} =
      CryptoNif.seal_session(
        session.plaintext,
        session_nonce,
        keys.rx_publickey,
        keys.tx_secretkey
      )

    {Map.merge(session, %{packet: packet, session_nonce: session_nonce}), packet}
  end

  def session_packet_payload(<<0x02, _session_nonce::binary-size(24), payload::binary>>),
    do: payload

  def session_buffer(session, opts \\ []) do
    session =
      Map.put_new(
        session,
        :session_nonce,
        Keyword.get(opts, :session_nonce, :crypto.strong_rand_bytes(24))
      )

    %Membrane.Buffer{
      payload: Map.fetch!(session, :plaintext),
      metadata: session_metadata(session, opts)
    }
  end

  def fragment_plaintext(opts \\ []) do
    flags = Keyword.get(opts, :flags, 0)
    payload = Keyword.get(opts, :payload, <<1, 2, 3, 4>>)
    <<flags, byte_size(payload)::big-16, payload::binary>>
  end

  def encrypted_data_packet(session_key, opts \\ []) do
    block_idx = Keyword.get(opts, :block_idx, 0x0102)
    fragment_idx = Keyword.get(opts, :fragment_idx, 3)
    plaintext = Keyword.get(opts, :plaintext, fragment_plaintext(opts))
    data_nonce = (block_idx <<< 8) + fragment_idx
    {:ok, packet} = CryptoNif.seal_data(plaintext, data_nonce, session_key)

    {%{
       block_idx: block_idx,
       data_nonce: data_nonce,
       fragment_idx: fragment_idx,
       plaintext: plaintext
     }, packet}
  end

  def data_packet_payload(<<0x01, _data_nonce::big-64, payload::binary>>), do: payload

  def session_metadata(session, opts \\ []) do
    metadata = %{
      wfb: %{
        channel_id: session.channel_id,
        link_id: session.link_id,
        packet_type: :session,
        packet_type_byte: 0x02,
        radio_port: session.radio_port,
        session_nonce: session.session_nonce
      }
    }

    maybe_put_radio_metadata(metadata, opts)
  end

  def data_metadata(data, opts \\ []) do
    link_id = Keyword.get(opts, :link_id, @default_link_id)
    radio_port = Keyword.get(opts, :radio_port, @default_radio_port)

    %{
      wfb: %{
        block_idx: data.block_idx,
        channel_id: channel_id(link_id, radio_port),
        data_nonce: data.data_nonce,
        fragment_idx: data.fragment_idx,
        link_id: link_id,
        packet_type: :data,
        packet_type_byte: 0x01,
        radio_port: radio_port,
        session_nonce: nil
      }
    }
    |> maybe_put_radio_metadata(opts)
  end

  def rx_key_file_content(keys), do: keys.rx_secretkey <> keys.tx_publickey

  def tx_key_file_content(keys), do: keys.tx_secretkey <> keys.rx_publickey

  def remote_packet_buffer(payload, opts \\ []) do
    %Buffer{payload: payload, metadata: Keyword.get(opts, :metadata, %{})}
  end

  def tx_session_buffer(session, opts \\ []) do
    metadata = %{
      wfb: %{
        channel_id: session.channel_id,
        link_id: session.link_id,
        packet_type: :session,
        packet_type_byte: 0x02,
        radio_port: session.radio_port,
        session_nonce: nil
      },
      wfb_session:
        struct(
          NervesWifibroadcast.WFB.Session,
          Map.take(session, [:channel_id, :epoch, :fec_k, :fec_n, :fec_type, :session_key, :tags])
        )
    }

    %Buffer{payload: session.plaintext, metadata: maybe_put_radio_metadata(metadata, opts)}
  end

  def tx_data_buffer(payload, session, block_idx, fragment_idx, opts \\ []) do
    link_id = Keyword.get(opts, :link_id, session.link_id)
    radio_port = Keyword.get(opts, :radio_port, session.radio_port)

    metadata = %{
      wfb: %{
        block_idx: block_idx,
        channel_id: channel_id(link_id, radio_port),
        data_nonce: (block_idx <<< 8) + fragment_idx,
        fec_k: session.fec_k,
        fec_n: session.fec_n,
        fec_type: session.fec_type,
        fragment_idx: fragment_idx,
        link_id: link_id,
        packet_type: :data,
        packet_type_byte: 0x01,
        radio_port: radio_port,
        session_epoch: session.epoch,
        session_nonce: nil,
        shard_role: Keyword.get(opts, :shard_role, :source)
      },
      wfb_session:
        struct(
          NervesWifibroadcast.WFB.Session,
          Map.take(session, [:channel_id, :epoch, :fec_k, :fec_n, :fec_type, :session_key, :tags])
        )
    }

    %Buffer{payload: payload, metadata: maybe_put_radio_metadata(metadata, opts)}
  end

  def source_shard(payload, flags \\ 0) do
    <<flags, byte_size(payload)::big-16, payload::binary>>
  end

  def wrapped_payload_buffer(payload, opts \\ []) do
    flags = Keyword.get(opts, :flags, 0)

    %Buffer{
      payload: source_shard(payload, flags),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def encode_block(source_shards, k, n) do
    shard_size = Enum.max_by(source_shards, &byte_size/1) |> byte_size()
    codec = FecNif.new(k, n)
    {:ok, parity_shards} = FecNif.encode(codec, source_shards, shard_size)
    %{parity_shards: parity_shards, shard_size: shard_size}
  end

  def decrypted_buffer(payload, block_idx, fragment_idx, opts \\ []) do
    link_id = Keyword.get(opts, :link_id, @default_link_id)
    radio_port = Keyword.get(opts, :radio_port, @default_radio_port)
    fec_k = Keyword.get(opts, :fec_k, 2)
    fec_n = Keyword.get(opts, :fec_n, 3)
    session_epoch = Keyword.get(opts, :session_epoch, 1)

    %Membrane.Buffer{
      payload: payload,
      metadata: %{
        radio: radio_metadata(opts, payload),
        wfb: %{
          block_idx: block_idx,
          channel_id: channel_id(link_id, radio_port),
          fec_k: fec_k,
          fec_n: fec_n,
          fragment_idx: fragment_idx,
          link_id: link_id,
          packet_type: :data,
          packet_type_byte: 0x01,
          radio_port: radio_port,
          session_epoch: session_epoch
        },
        wfb_session: %{epoch: session_epoch, fec_k: fec_k, fec_n: fec_n}
      }
    }
  end

  def ordered_shard_buffer(payload, block_idx, fragment_idx, opts \\ []) do
    fec_k = Keyword.get(opts, :fec_k, 2)
    ordered_seq = Keyword.get(opts, :ordered_seq, block_idx * fec_k + fragment_idx)
    emission = Keyword.get(opts, :emission, :live)
    recovered? = Keyword.get(opts, :recovered?, false)

    buffer = decrypted_buffer(payload, block_idx, fragment_idx, opts)

    metadata =
      Map.update(buffer.metadata, :wfb, %{}, fn wfb ->
        Map.merge(wfb, %{
          emission: emission,
          ordered_seq: ordered_seq
        })
      end)

    metadata =
      if recovered? do
        receiver_mask =
          Keyword.get(opts, :receiver_mask, 1 <<< Keyword.get(opts, :receiver_idx, 0))

        Map.put(metadata, :recovery, %{receiver_mask: receiver_mask})
      else
        Map.delete(metadata, :recovery)
      end

    %Membrane.Buffer{buffer | metadata: metadata}
  end

  defp maybe_put_radio_metadata(metadata, opts) do
    Map.put(metadata, :radio, radio_metadata(opts))
  end

  defp radio_metadata(opts, payload \\ <<>>) do
    %{
      capture_ts: Keyword.get(opts, :capture_ts, 0),
      radiotap: Keyword.get(opts, :radiotap),
      raw_length: Keyword.get(opts, :raw_length, byte_size(payload)),
      receiver_idx: Keyword.get(opts, :receiver_idx, 0),
      socket_addr: Keyword.get(opts, :socket_addr),
      socket_flags: Keyword.get(opts, :socket_flags, [])
    }
  end
end
