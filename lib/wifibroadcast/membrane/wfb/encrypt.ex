defmodule Wifibroadcast.Membrane.WFB.Encrypt do
  @moduledoc """
  Encrypts clear WFB session and data packet payloads for TX.

  The element preserves the packet/session contract so clear-text pipelines can
  bypass it and connect `FecEncoder` straight to `Radio.Sink`.
  """

  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias Wifibroadcast.Membrane.WFB.StreamFormat
  alias Wifibroadcast.WFB.CryptoNif
  alias Wifibroadcast.WFB.Keys
  alias Wifibroadcast.WFB.Session

  @max_block_idx (1 <<< 55) - 1
  @session_nonce_size 24

  def_options(
    key_path: [spec: String.t() | nil, default: "drone.key"],
    rx_publickey: [spec: binary() | nil, default: nil],
    tx_secretkey: [spec: binary() | nil, default: nil]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    keys = load_keys!(opts)

    state = %{
      cached_session_packet: nil,
      counters: %{
        data_encrypt_errors: 0,
        data_without_session_drops: 0,
        invalid_block_drops: 0,
        invalid_fec_drops: 0,
        invalid_session_data_drops: 0,
        passed_packets: 0,
        session_encrypt_errors: 0,
        unknown_packet_type_drops: 0,
        wrong_channel_id_drops: 0
      },
      current_session: nil,
      input_stream_format: nil,
      keys: keys
    }

    {[], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state), do: {[], state}

  @impl true
  def handle_event(_pad, event, _ctx, state), do: {[forward: event], state}

  @impl true
  def handle_stream_format(:input, %StreamFormat{} = stream_format, _ctx, state) do
    output_stream_format = %StreamFormat{stream_format | encrypted?: true}

    {[stream_format: {:output, output_stream_format}],
     %{
       state
       | cached_session_packet: nil,
         current_session: nil,
         input_stream_format: output_stream_format
     }}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state), do: {[end_of_stream: :output], state}

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    case get_in(buffer.metadata, [:wfb, :packet_type]) do
      :session -> handle_session_packet(buffer, state)
      :data -> handle_data_packet(buffer, state)
      _other -> {[], increment_counter(state, :unknown_packet_type_drops)}
    end
  end

  defp handle_session_packet(%Buffer{} = buffer, state) do
    with {:ok, session} <- Session.parse(buffer.payload),
         :ok <- validate_session(session, buffer, state) do
      encrypt_session_packet(state, session, buffer)
    else
      {:error, :invalid_session_data} ->
        {[], increment_counter(state, :invalid_session_data_drops)}

      {:error, :wrong_channel_id} ->
        {[], increment_counter(state, :wrong_channel_id_drops)}
    end
  end

  defp handle_data_packet(%Buffer{} = _buffer, %{current_session: nil} = state) do
    {[], increment_counter(state, :data_without_session_drops)}
  end

  defp handle_data_packet(%Buffer{} = buffer, state) do
    fragment_idx = get_in(buffer.metadata, [:wfb, :fragment_idx])
    block_idx = get_in(buffer.metadata, [:wfb, :block_idx])
    data_nonce = get_in(buffer.metadata, [:wfb, :data_nonce])

    cond do
      not is_integer(block_idx) or block_idx < 0 or block_idx > @max_block_idx ->
        {[], increment_counter(state, :invalid_block_drops)}

      not is_integer(fragment_idx) or fragment_idx < 0 or fragment_idx > 0xFF ->
        {[], increment_counter(state, :invalid_fec_drops)}

      not is_integer(data_nonce) or data_nonce < 0 or data_nonce > 0xFFFFFFFFFFFFFFFF ->
        {[], increment_counter(state, :invalid_block_drops)}

      true ->
        case CryptoNif.seal_data(buffer.payload, data_nonce, state.current_session.session_key) do
          {:ok, <<0x01, _nonce::big-64, ciphertext::binary>>} ->
            output_buffer =
              %Buffer{buffer | payload: ciphertext}
              |> put_wfb_session_metadata(state.current_session)

            {[buffer: {:output, output_buffer}], increment_counter(state, :passed_packets)}

          _other ->
            {[], increment_counter(state, :data_encrypt_errors)}
        end
    end
  end

  defp encrypt_session_packet(state, %Session{} = session, %Buffer{} = buffer) do
    case cached_session_packet_for(state, session) do
      {:ok, cached_session_packet} ->
        output_buffer = build_encrypted_session_buffer(buffer, session, cached_session_packet)

        {[buffer: {:output, output_buffer}],
         state
         |> Map.put(:current_session, session)
         |> increment_counter(:passed_packets)}

      :error ->
        session_nonce = :crypto.strong_rand_bytes(@session_nonce_size)

        case CryptoNif.seal_session(
               buffer.payload,
               session_nonce,
               state.keys.rx_publickey,
               state.keys.tx_secretkey
             ) do
          {:ok, <<0x02, _nonce::binary-size(@session_nonce_size), ciphertext::binary>>} ->
            cached_session_packet = %{
              payload: ciphertext,
              session: session,
              session_nonce: session_nonce
            }

            output_buffer = build_encrypted_session_buffer(buffer, session, cached_session_packet)

            {[buffer: {:output, output_buffer}],
             state
             |> Map.put(:cached_session_packet, cached_session_packet)
             |> Map.put(:current_session, session)
             |> increment_counter(:passed_packets)}

          _other ->
            {[], increment_counter(state, :session_encrypt_errors)}
        end
    end
  end

  defp cached_session_packet_for(
         %{cached_session_packet: %{session: session} = cached},
         %Session{} = session
       ),
       do: {:ok, cached}

  defp cached_session_packet_for(_state, _session), do: :error

  defp build_encrypted_session_buffer(
         %Buffer{} = buffer,
         %Session{} = session,
         cached_session_packet
       ) do
    metadata =
      normalize_metadata(buffer.metadata)
      |> Map.update(:wfb, %{}, fn wfb ->
        Map.merge(wfb, %{
          fec_k: session.fec_k,
          fec_n: session.fec_n,
          fec_type: session.fec_type,
          session_epoch: session.epoch,
          session_nonce: cached_session_packet.session_nonce
        })
      end)
      |> Map.put(:wfb_session, session)

    %Buffer{buffer | payload: cached_session_packet.payload, metadata: metadata}
  end

  defp put_wfb_session_metadata(%Buffer{metadata: metadata} = buffer, %Session{} = session)
       when is_map(metadata) do
    wfb_metadata =
      metadata
      |> Map.get(:wfb, %{})
      |> Map.merge(%{
        fec_k: session.fec_k,
        fec_n: session.fec_n,
        fec_type: session.fec_type,
        session_epoch: session.epoch,
        session_nonce: nil
      })

    %Buffer{
      buffer
      | metadata: metadata |> Map.put(:wfb, wfb_metadata) |> Map.put(:wfb_session, session)
    }
  end

  defp put_wfb_session_metadata(%Buffer{} = buffer, %Session{} = session) do
    metadata =
      normalize_metadata(buffer.metadata)
      |> Map.update(:wfb, %{}, fn wfb ->
        Map.merge(wfb, %{
          fec_k: session.fec_k,
          fec_n: session.fec_n,
          fec_type: session.fec_type,
          session_epoch: session.epoch,
          session_nonce: nil
        })
      end)
      |> Map.put(:wfb_session, session)

    %Buffer{buffer | metadata: metadata}
  end

  defp validate_session(%Session{} = session, %Buffer{} = buffer, _state) do
    expected_channel_id = get_in(buffer.metadata, [:wfb, :channel_id])

    cond do
      session.channel_id != expected_channel_id ->
        {:error, :wrong_channel_id}

      session.fec_type != Session.fec_vdm_rs() ->
        {:error, :invalid_session_data}

      session.fec_n < 1 ->
        {:error, :invalid_session_data}

      session.fec_k < 1 or session.fec_k > session.fec_n ->
        {:error, :invalid_session_data}

      true ->
        :ok
    end
  end

  defp load_keys!(%{rx_publickey: nil, tx_secretkey: nil, key_path: key_path})
       when is_binary(key_path) do
    Keys.load_tx!(key_path)
  end

  defp load_keys!(%{rx_publickey: rx_publickey, tx_secretkey: tx_secretkey})
       when is_binary(rx_publickey) and is_binary(tx_secretkey) and byte_size(rx_publickey) == 32 and
              byte_size(tx_secretkey) == 32 do
    %{rx_publickey: rx_publickey, tx_secretkey: tx_secretkey}
  end

  defp load_keys!(opts) do
    raise ArgumentError,
          "expected either :key_path or both :rx_publickey and :tx_secretkey, got: #{inspect(opts)}"
  end

  defp increment_counter(state, counter) do
    update_in(state.counters[counter], &((&1 || 0) + 1))
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
