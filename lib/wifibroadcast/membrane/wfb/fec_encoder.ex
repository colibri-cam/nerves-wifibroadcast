defmodule Wifibroadcast.Membrane.WFB.FecEncoder do
  @moduledoc """
  Groups wrapped TX payloads into FEC blocks and emits WFB session/data packets.
  """

  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.Time
  alias Wifibroadcast.Membrane.WFB.StreamFormat
  alias Wifibroadcast.Membrane.WFB.WrappedPayloadStreamFormat
  alias Wifibroadcast.WFB.FecNif
  alias Wifibroadcast.WFB.Session

  @fec_only_flag 0x01
  @max_block_idx (1 <<< 55) - 1
  @packet_type_data 0x01
  @packet_type_session 0x02
  @timeout_timer :fec_timeout

  def_options(
    epoch: [spec: non_neg_integer(), default: 0],
    fec_timeout_ms: [spec: pos_integer() | nil, default: nil],
    fec_type: [spec: non_neg_integer(), default: Session.fec_vdm_rs()],
    k: [spec: pos_integer(), default: 8],
    n: [spec: pos_integer(), default: 12],
    session_repeat_count: [spec: pos_integer() | :auto, default: :auto],
    tags: [spec: binary(), default: <<>>]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: WrappedPayloadStreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    validate_fec!(opts.k, opts.n)

    state = %{
      block: %{},
      block_idx: 0,
      codec: new_codec!(opts.k, opts.n),
      counters: %{
        emitted_fec_only_fragments: 0,
        emitted_parity_fragments: 0,
        emitted_session_packets: 0,
        emitted_source_fragments: 0,
        fec_timeouts: 0,
        fec_updates: 0
      },
      current_session: nil,
      epoch: opts.epoch,
      fec_close_at_ms: nil,
      fec_timeout_ms: opts.fec_timeout_ms,
      fec_type: opts.fec_type,
      input_stream_format: nil,
      k: opts.k,
      max_shard_size: 0,
      n: opts.n,
      next_fragment_idx: 0,
      output_stream_format: nil,
      session_pending: false,
      session_repeat_count: opts.session_repeat_count,
      tags: opts.tags
    }

    {[], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state), do: {[], state}

  @impl true
  def handle_event(_pad, event, _ctx, state), do: {[forward: event], state}

  @impl true
  def handle_playing(_ctx, %{fec_timeout_ms: interval_ms} = state) when is_integer(interval_ms) do
    {[start_timer: {@timeout_timer, Time.milliseconds(interval_ms)}], state}
  end

  def handle_playing(_ctx, state), do: {[], state}

  @impl true
  def handle_stream_format(:input, %WrappedPayloadStreamFormat{} = format, _ctx, state) do
    next_state = prepare_stream(state, format)
    {[stream_format: {:output, next_state.output_stream_format}], next_state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {actions, state} = flush_open_block(state, :end_of_stream)
    {actions ++ [end_of_stream: :output], state}
  end

  @impl true
  def handle_tick(@timeout_timer, _ctx, state) do
    if timeout_expired?(state) do
      {actions, state} = flush_open_block(state, :timeout)
      {actions, increment_counter(state, :fec_timeouts)}
    else
      {[], state}
    end
  end

  @impl true
  def handle_parent_notification({:set_fec, %{k: k, n: n}}, _ctx, state) do
    if valid_fec?(k, n) do
      {flush_actions, flushed_state} = flush_open_block(state, :set_fec)
      next_state = reconfigure_fec(flushed_state, k, n)
      {session_actions, next_state} = emit_session_packets(next_state)

      notification =
        {:wfb_fec_config_applied,
         %{
           epoch: next_state.current_session && next_state.current_session.epoch,
           fec_k: next_state.k,
           fec_n: next_state.n,
           link_id: next_state.output_stream_format && next_state.output_stream_format.link_id,
           radio_port:
             next_state.output_stream_format && next_state.output_stream_format.radio_port
         }}

      {flush_actions ++ session_actions ++ [notify_parent: notification],
       increment_counter(next_state, :fec_updates)}
    else
      rejected = {:wfb_fec_config_rejected, %{reason: :invalid_fec, requested: %{k: k, n: n}}}
      {[notify_parent: rejected], state}
    end
  end

  def handle_parent_notification(_notification, _ctx, state), do: {[], state}

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, %{output_stream_format: nil} = state) do
    _buffer = buffer
    {[], state}
  end

  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    {session_actions, state} = emit_session_packets(state)
    {source_actions, state} = emit_source_fragment(state, buffer)
    {parity_actions, state} = maybe_close_full_block(state)
    {session_actions ++ source_actions ++ parity_actions, state}
  end

  defp prepare_stream(state, %WrappedPayloadStreamFormat{} = format) do
    output_stream_format = %StreamFormat{
      channel_id: format.channel_id,
      encrypted?: false,
      interfaces: format.interfaces,
      link_id: format.link_id,
      radio_port: format.radio_port
    }

    state
    |> Map.put(:input_stream_format, format)
    |> Map.put(:output_stream_format, output_stream_format)
    |> start_new_session()
  end

  defp start_new_session(state) do
    if is_nil(state.output_stream_format) do
      %{
        state
        | block: %{},
          block_idx: 0,
          current_session: nil,
          fec_close_at_ms: nil,
          max_shard_size: 0,
          next_fragment_idx: 0,
          session_pending: false
      }
    else
      current_session = %Session{
        channel_id: state.output_stream_format.channel_id,
        epoch: state.epoch,
        fec_k: state.k,
        fec_n: state.n,
        fec_type: state.fec_type,
        session_key: :crypto.strong_rand_bytes(32),
        tags: state.tags
      }

      %{
        state
        | block: %{},
          block_idx: 0,
          current_session: current_session,
          fec_close_at_ms: nil,
          max_shard_size: 0,
          next_fragment_idx: 0,
          session_pending: true
      }
    end
  end

  defp emit_session_packets(%{session_pending: false} = state), do: {[], state}
  defp emit_session_packets(%{current_session: nil} = state), do: {[], state}
  defp emit_session_packets(%{output_stream_format: nil} = state), do: {[], state}

  defp emit_session_packets(state) do
    {:ok, payload} = Session.serialize(state.current_session)
    repeat_count = session_repeat_count(state)

    actions =
      for _index <- 1..repeat_count do
        buffer = build_session_buffer(state, payload)
        {:buffer, {:output, buffer}}
      end

    next_state = %{state | session_pending: false}

    {actions, add_to_counter(next_state, :emitted_session_packets, repeat_count)}
  end

  defp emit_source_fragment(state, %Buffer{} = buffer) do
    fragment_idx = state.next_fragment_idx
    payload = buffer.payload

    output_buffer = build_data_buffer(buffer.metadata, payload, state, fragment_idx, :source)

    next_state = %{
      state
      | block: Map.put(state.block, fragment_idx, payload),
        fec_close_at_ms: next_fec_close_at_ms(state),
        max_shard_size: max(state.max_shard_size, byte_size(payload)),
        next_fragment_idx: fragment_idx + 1
    }

    {[buffer: {:output, output_buffer}], increment_counter(next_state, :emitted_source_fragments)}
  end

  defp maybe_close_full_block(%{next_fragment_idx: next_fragment_idx, k: k} = state)
       when next_fragment_idx < k,
       do: {[], state}

  defp maybe_close_full_block(state), do: close_current_block(state)

  defp flush_open_block(%{next_fragment_idx: 0} = state, _reason),
    do: {[], %{state | fec_close_at_ms: nil}}

  defp flush_open_block(state, _reason) do
    {fill_actions, state} = fill_missing_source_fragments(state)
    {parity_actions, state} = close_current_block(state)
    {fill_actions ++ parity_actions, state}
  end

  defp fill_missing_source_fragments(%{next_fragment_idx: next_fragment_idx, k: k} = state)
       when next_fragment_idx >= k,
       do: {[], state}

  defp fill_missing_source_fragments(state) do
    Enum.reduce(state.next_fragment_idx..(state.k - 1), {[], state}, fn fragment_idx,
                                                                        {actions, acc} ->
      payload = <<@fec_only_flag, 0::big-16>>
      buffer = build_data_buffer(%{}, payload, acc, fragment_idx, :source)

      next_state = %{
        acc
        | block: Map.put(acc.block, fragment_idx, payload),
          max_shard_size: max(acc.max_shard_size, byte_size(payload)),
          next_fragment_idx: fragment_idx + 1
      }

      next_state =
        next_state
        |> increment_counter(:emitted_source_fragments)
        |> increment_counter(:emitted_fec_only_fragments)

      {actions ++ [buffer: {:output, buffer}], next_state}
    end)
  end

  defp close_current_block(state) do
    source_shards =
      for fragment_idx <- 0..(state.k - 1), do: Map.fetch!(state.block, fragment_idx)

    {:ok, parity_shards} = FecNif.encode(state.codec, source_shards, state.max_shard_size)

    actions =
      parity_shards
      |> Enum.with_index(state.k)
      |> Enum.map(fn {payload, fragment_idx} ->
        buffer = build_data_buffer(%{}, payload, state, fragment_idx, :parity)
        {:buffer, {:output, buffer}}
      end)

    next_state =
      state
      |> add_to_counter(:emitted_parity_fragments, length(parity_shards))
      |> advance_block()

    {actions, next_state}
  end

  defp advance_block(%{block_idx: block_idx, k: k, n: n} = state) do
    next_block_idx = block_idx + 1

    base_state = %{
      state
      | block: %{},
        block_idx: next_block_idx,
        fec_close_at_ms: nil,
        max_shard_size: 0,
        next_fragment_idx: 0
    }

    if next_block_idx > @max_block_idx do
      base_state
      |> Map.put(:block_idx, 0)
      |> Map.put(:codec, new_codec!(k, n))
      |> start_new_session()
    else
      base_state
    end
  end

  defp reconfigure_fec(state, k, n) do
    state
    |> Map.put(:codec, new_codec!(k, n))
    |> Map.put(:k, k)
    |> Map.put(:n, n)
    |> start_new_session()
  end

  defp build_session_buffer(state, payload) do
    metadata = %{
      wfb: %{
        block_idx: nil,
        channel_id: state.current_session.channel_id,
        data_nonce: nil,
        fec_k: state.current_session.fec_k,
        fec_n: state.current_session.fec_n,
        fec_type: state.current_session.fec_type,
        fragment_idx: nil,
        link_id: state.output_stream_format.link_id,
        packet_type: :session,
        packet_type_byte: @packet_type_session,
        radio_port: state.output_stream_format.radio_port,
        session_epoch: state.current_session.epoch,
        session_nonce: nil,
        shard_role: nil
      },
      wfb_session: state.current_session
    }

    %Buffer{payload: payload, metadata: metadata}
  end

  defp build_data_buffer(metadata, payload, state, fragment_idx, shard_role) do
    data_nonce = make_data_nonce(state.block_idx, fragment_idx)

    wfb_fields = %{
      block_idx: state.block_idx,
      channel_id: state.current_session.channel_id,
      data_nonce: data_nonce,
      fec_k: state.current_session.fec_k,
      fec_n: state.current_session.fec_n,
      fec_type: state.current_session.fec_type,
      fragment_idx: fragment_idx,
      link_id: state.output_stream_format.link_id,
      packet_type: :data,
      packet_type_byte: @packet_type_data,
      radio_port: state.output_stream_format.radio_port,
      session_epoch: state.current_session.epoch,
      session_nonce: nil,
      shard_role: shard_role
    }

    metadata =
      normalize_metadata(metadata)
      |> Map.update(:wfb, wfb_fields, fn wfb ->
        Map.merge(wfb, wfb_fields)
      end)
      |> Map.put(:wfb_session, state.current_session)

    %Buffer{payload: payload, metadata: metadata}
  end

  defp next_fec_close_at_ms(%{fec_timeout_ms: nil}), do: nil

  defp next_fec_close_at_ms(%{fec_timeout_ms: fec_timeout_ms}) do
    System.monotonic_time(:millisecond) + fec_timeout_ms
  end

  defp timeout_expired?(%{fec_close_at_ms: nil}), do: false
  defp timeout_expired?(%{next_fragment_idx: 0}), do: false

  defp timeout_expired?(%{fec_close_at_ms: fec_close_at_ms}) do
    System.monotonic_time(:millisecond) >= fec_close_at_ms
  end

  defp session_repeat_count(%{session_repeat_count: :auto, k: k, n: n}), do: max(1, n - k + 1)
  defp session_repeat_count(%{session_repeat_count: count}), do: count

  defp make_data_nonce(block_idx, fragment_idx), do: (block_idx <<< 8) + fragment_idx

  defp new_codec!(k, n) do
    case FecNif.new(k, n) do
      codec when is_reference(codec) -> codec
      :error -> raise ArgumentError, "unable to initialize FEC codec for k=#{k} n=#{n}"
    end
  end

  defp validate_fec!(k, n) do
    if valid_fec?(k, n) do
      :ok
    else
      raise ArgumentError,
            "expected valid FEC settings with 1 <= k <= n < 256, got: #{inspect(%{k: k, n: n})}"
    end
  end

  defp valid_fec?(k, n) do
    is_integer(k) and is_integer(n) and k >= 1 and k <= n and n >= 1 and n < 256
  end

  defp increment_counter(state, counter), do: add_to_counter(state, counter, 1)

  defp add_to_counter(state, counter, value) do
    update_in(state.counters[counter], &((&1 || 0) + value))
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
