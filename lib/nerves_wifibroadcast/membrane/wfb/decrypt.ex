defmodule NervesWifibroadcast.Membrane.WFB.Decrypt do
  @moduledoc """
  Decrypts WFB session and data packets for a single ingress branch.
  """

  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias NervesWifibroadcast.Membrane.WFB.DecryptedStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.WFB.CryptoNif
  alias NervesWifibroadcast.WFB.Keys
  alias NervesWifibroadcast.WFB.Session

  @aead_abytes 16
  @max_block_idx (1 <<< 55) - 1
  @min_data_packet_size 9 + @aead_abytes + 3

  def_options(
    key_path: [spec: String.t() | nil, default: "gs.key"],
    min_epoch: [spec: non_neg_integer(), default: 0],
    rx_secretkey: [spec: binary() | nil, default: nil],
    tx_publickey: [spec: binary() | nil, default: nil]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: DecryptedStreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    keys = load_keys!(opts)

    state = %{
      accepted_session_packet: nil,
      counters: %{
        data_decrypt_errors: 0,
        data_without_session_drops: 0,
        duplicate_session_drops: 0,
        invalid_block_drops: 0,
        invalid_fec_drops: 0,
        invalid_session_data_drops: 0,
        old_epoch_drops: 0,
        passed_packets: 0,
        session_decrypt_errors: 0,
        short_data_packet_drops: 0,
        short_plaintext_drops: 0,
        unknown_packet_type_drops: 0,
        wrong_channel_id_drops: 0
      },
      current_session: nil,
      epoch_floor: opts.min_epoch,
      input_stream_format: nil,
      keys: keys,
      min_epoch: opts.min_epoch
    }

    {[], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state), do: {[], state}

  @impl true
  def handle_event(_pad, event, _ctx, state), do: {[forward: event], state}

  @impl true
  def handle_stream_format(:input, %StreamFormat{} = stream_format, _ctx, state) do
    actions = maybe_stream_format_action(stream_format, state.current_session)
    {actions, %{state | accepted_session_packet: nil, input_stream_format: stream_format}}
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
    if duplicate_accepted_session_packet?(state, buffer.payload) do
      {[], increment_counter(state, :duplicate_session_drops)}
    else
      case CryptoNif.open_session(buffer.payload, state.keys.box_key) do
        {:ok, plaintext} ->
          with {:ok, session} <- Session.parse(plaintext),
               :ok <- validate_session(session, buffer, state) do
            maybe_install_session(state, session, buffer.payload)
          else
            {:error, :invalid_session_data} ->
              {notify_session_issue(state, buffer, :invalid_session_data),
               increment_counter(state, :invalid_session_data_drops)}

            {:error, :old_epoch} ->
              {notify_session_issue(state, buffer, :old_epoch),
               increment_counter(state, :old_epoch_drops)}

            {:error, :wrong_channel_id} ->
              {notify_session_issue(state, buffer, :wrong_channel_id),
               increment_counter(state, :wrong_channel_id_drops)}

            {:error, :invalid_fec} ->
              {notify_session_issue(state, buffer, :invalid_fec),
               increment_counter(state, :invalid_fec_drops)}
          end

        :error ->
          {notify_session_issue(state, buffer, :decrypt_error),
           increment_counter(state, :session_decrypt_errors)}
      end
    end
  end

  defp handle_data_packet(%Buffer{} = buffer, %{current_session: nil} = state) do
    _buffer = buffer
    {[], increment_counter(state, :data_without_session_drops)}
  end

  defp handle_data_packet(%Buffer{} = buffer, state) do
    fragment_idx = get_in(buffer.metadata, [:wfb, :fragment_idx])
    block_idx = get_in(buffer.metadata, [:wfb, :block_idx])

    cond do
      byte_size(buffer.payload) < @min_data_packet_size ->
        {[], increment_counter(state, :short_data_packet_drops)}

      not is_integer(block_idx) or block_idx < 0 or block_idx > @max_block_idx ->
        {[], increment_counter(state, :invalid_block_drops)}

      not is_integer(fragment_idx) or fragment_idx < 0 or
          fragment_idx >= state.current_session.fec_n ->
        {[], increment_counter(state, :invalid_fec_drops)}

      true ->
        decrypt_data_packet(buffer, state)
    end
  end

  defp decrypt_data_packet(%Buffer{} = buffer, state) do
    case CryptoNif.open_data(buffer.payload, state.current_session.session_key) do
      {:ok, plaintext} when byte_size(plaintext) >= 3 ->
        routed_buffer =
          %Buffer{buffer | payload: plaintext}
          |> put_wfb_session_metadata(state.current_session)

        {[buffer: {:output, routed_buffer}], increment_counter(state, :passed_packets)}

      {:ok, _plaintext} ->
        {[], increment_counter(state, :short_plaintext_drops)}

      :error ->
        {[], increment_counter(state, :data_decrypt_errors)}
    end
  end

  defp maybe_install_session(state, %Session{} = session, accepted_session_packet) do
    if session_key_changed?(state.current_session, session) do
      next_state = %{
        state
        | current_session: session,
          accepted_session_packet: accepted_session_packet,
          epoch_floor: session.epoch
      }

      actions =
        maybe_stream_format_action(state.input_stream_format, session) ++
          [
            notify_parent:
              {:wfb_session_accepted, session_notification(session, state.input_stream_format)}
          ]

      {actions, next_state}
    else
      {[], %{state | accepted_session_packet: accepted_session_packet}}
    end
  end

  defp maybe_stream_format_action(%StreamFormat{} = input_stream_format, %Session{} = session) do
    [stream_format: {:output, output_stream_format(input_stream_format, session)}]
  end

  defp maybe_stream_format_action(_input_stream_format, _session), do: []

  defp output_stream_format(%StreamFormat{} = input_stream_format, %Session{} = session) do
    %DecryptedStreamFormat{
      channel_id: input_stream_format.channel_id,
      epoch: session.epoch,
      fec_k: session.fec_k,
      fec_n: session.fec_n,
      fec_type: session.fec_type,
      interfaces: input_stream_format.interfaces,
      link_id: input_stream_format.link_id,
      radio_port: input_stream_format.radio_port
    }
  end

  defp validate_session(%Session{} = session, %Buffer{} = buffer, state) do
    expected_channel_id = get_in(buffer.metadata, [:wfb, :channel_id])

    cond do
      session.epoch < max(state.min_epoch, state.epoch_floor) ->
        {:error, :old_epoch}

      session.channel_id != expected_channel_id ->
        {:error, :wrong_channel_id}

      session.fec_type != Session.fec_vdm_rs() ->
        {:error, :invalid_fec}

      session.fec_n < 1 ->
        {:error, :invalid_fec}

      session.fec_k < 1 or session.fec_k > session.fec_n ->
        {:error, :invalid_fec}

      true ->
        :ok
    end
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
        session_epoch: session.epoch
      })

    %Buffer{
      buffer
      | metadata: metadata |> Map.put(:wfb, wfb_metadata) |> Map.put(:wfb_session, session)
    }
  end

  defp session_key_changed?(nil, %Session{}), do: true

  defp session_key_changed?(%Session{session_key: session_key}, %Session{session_key: session_key}),
       do: false

  defp session_key_changed?(%Session{}, %Session{}), do: true

  defp load_keys!(%{rx_secretkey: nil, tx_publickey: nil, key_path: key_path})
       when is_binary(key_path) do
    Keys.load!(key_path)
  end

  defp load_keys!(%{rx_secretkey: rx_secretkey, tx_publickey: tx_publickey})
       when is_binary(rx_secretkey) and is_binary(tx_publickey) do
    case Keys.from_parts(rx_secretkey, tx_publickey) do
      {:ok, keys} ->
        keys

      {:error, reason} ->
        raise ArgumentError, "unable to initialize decrypt keys: #{inspect(reason)}"
    end
  end

  defp load_keys!(opts) do
    raise ArgumentError,
          "expected either :key_path or both :rx_secretkey and :tx_publickey, got: #{inspect(opts)}"
  end

  defp increment_counter(state, counter) do
    update_in(state.counters[counter], &((&1 || 0) + 1))
  end

  defp notify_session_issue(state, buffer, reason) do
    [notify_parent: {:wfb_session_rejected, reason, session_issue_context(state, buffer)}]
  end

  defp duplicate_accepted_session_packet?(state, packet) do
    is_binary(state.accepted_session_packet) and state.accepted_session_packet == packet
  end

  defp session_notification(%Session{} = session, input_stream_format) do
    %{
      channel_id: session.channel_id,
      epoch: session.epoch,
      fec_k: session.fec_k,
      fec_n: session.fec_n,
      fec_type: session.fec_type,
      interfaces: input_stream_format && input_stream_format.interfaces,
      link_id: input_stream_format && input_stream_format.link_id,
      radio_port: input_stream_format && input_stream_format.radio_port
    }
  end

  defp session_issue_context(state, %Buffer{} = buffer) do
    %{
      channel_id: get_in(buffer.metadata, [:wfb, :channel_id]),
      interfaces: state.input_stream_format && state.input_stream_format.interfaces,
      link_id: state.input_stream_format && state.input_stream_format.link_id,
      radio_port: state.input_stream_format && state.input_stream_format.radio_port
    }
  end
end
