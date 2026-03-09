defmodule NervesWifibroadcast.Membrane.WFB.ReorderFec do
  @moduledoc """
  Consumes WFB session/data packets, applies FEC recovery, and emits ordered
  source shards.

  The element emits only ordered source shards (`fragment_idx < fec_k`) and keeps
  the shard payload as `wpacket_hdr_t <> payload` for later stages.
  """

  use Membrane.Filter

  import Bitwise

  alias Membrane.Buffer
  alias Membrane.Time
  alias NervesWifibroadcast.Membrane.WFB.OrderedShardStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.WFB.FecNif
  alias NervesWifibroadcast.WFB.Session

  @max_block_idx (1 <<< 55) - 1
  @stats_timer :stats

  def_options(
    min_epoch: [spec: non_neg_integer(), default: 0],
    ring_size: [spec: pos_integer(), default: 40],
    stats_interval_ms: [spec: pos_integer() | nil, default: nil]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :always,
    accepted_format: OrderedShardStreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      accepted_session_payload: nil,
      codec: nil,
      counters: %{
        data_without_session_drops: 0,
        duplicate_fragments: 0,
        duplicate_session_drops: 0,
        emitted_source_shards: 0,
        fec_recovered_fragments: 0,
        invalid_fec_drops: 0,
        invalid_fragment_drops: 0,
        invalid_session_data_drops: 0,
        lost_source_shards: 0,
        old_epoch_drops: 0,
        ring_override_count: 0,
        stale_block_drops: 0,
        wrong_channel_id_drops: 0
      },
      current_format: nil,
      current_session: nil,
      epoch_floor: opts.min_epoch,
      input_stream_format: nil,
      last_emitted_seq: nil,
      last_known_block: nil,
      min_epoch: opts.min_epoch,
      order: [],
      ring_size: opts.ring_size,
      stats_baseline: %{
        data_without_session_drops: 0,
        duplicate_fragments: 0,
        duplicate_session_drops: 0,
        emitted_source_shards: 0,
        fec_recovered_fragments: 0,
        invalid_fec_drops: 0,
        invalid_fragment_drops: 0,
        invalid_session_data_drops: 0,
        lost_source_shards: 0,
        old_epoch_drops: 0,
        ring_override_count: 0,
        stale_block_drops: 0,
        wrong_channel_id_drops: 0
      },
      stats_interval_ms: opts.stats_interval_ms,
      blocks: %{}
    }

    {[], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state), do: {[], state}

  @impl true
  def handle_event(_pad, event, _ctx, state), do: {[forward: event], state}

  @impl true
  def handle_playing(_ctx, %{stats_interval_ms: interval_ms} = state)
      when is_integer(interval_ms) do
    {[start_timer: {@stats_timer, Time.milliseconds(interval_ms)}], state}
  end

  def handle_playing(_ctx, state), do: {[], state}

  @impl true
  def handle_stream_format(:input, %StreamFormat{} = format, _ctx, state) do
    next_state =
      reset_decoder_state(%{state | input_stream_format: format, accepted_session_payload: nil})

    {[], next_state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state), do: {[end_of_stream: :output], state}

  @impl true
  def handle_tick(@stats_timer, _ctx, %{current_format: nil} = state), do: {[], state}

  def handle_tick(@stats_timer, _ctx, state) do
    stats = stats_notification(state)
    {[notify_parent: {:wfb_reorder_fec_stats, stats}], %{state | stats_baseline: state.counters}}
  end

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    case get_in(buffer.metadata, [:wfb, :packet_type]) do
      :session -> handle_session_packet(buffer, state)
      :data -> handle_data_buffer(buffer, state)
      _other -> {[], state}
    end
  end

  defp handle_session_packet(%Buffer{} = _buffer, %{input_stream_format: nil} = state),
    do: {[], state}

  defp handle_session_packet(%Buffer{} = buffer, state) do
    if duplicate_accepted_session_payload?(state, buffer.payload) do
      {[], increment_counter(state, :duplicate_session_drops)}
    else
      with {:ok, session} <- Session.parse(buffer.payload),
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
    end
  end

  defp handle_data_buffer(%Buffer{} = _buffer, %{current_session: nil} = state) do
    {[], increment_counter(state, :data_without_session_drops)}
  end

  defp handle_data_buffer(%Buffer{} = buffer, state) do
    with {:ok, block_idx, fragment_idx} <- fragment_ref(buffer),
         :ok <- validate_fragment(block_idx, fragment_idx, state.current_session),
         {:ok, state, actions, block_idx} <- ensure_block(state, block_idx),
         {:ok, state} <- store_fragment(state, block_idx, fragment_idx, buffer) do
      {contiguous_actions, state} = maybe_emit_contiguous_front(state, block_idx)
      {recovery_actions, state} = maybe_recover_and_flush(state, block_idx)
      actions = actions ++ contiguous_actions ++ recovery_actions

      {actions, state}
    else
      {:error, :stale_block} ->
        {[], increment_counter(state, :stale_block_drops)}

      {:error, :duplicate_fragment, next_state} ->
        {[], increment_counter(next_state, :duplicate_fragments)}

      {:error, :invalid_fragment} ->
        {[], increment_counter(state, :invalid_fragment_drops)}
    end
  end

  defp fragment_ref(%Buffer{metadata: metadata}) do
    block_idx = get_in(metadata, [:wfb, :block_idx])
    fragment_idx = get_in(metadata, [:wfb, :fragment_idx])

    if is_integer(block_idx) and is_integer(fragment_idx) do
      {:ok, block_idx, fragment_idx}
    else
      {:error, :invalid_fragment}
    end
  end

  defp validate_fragment(block_idx, fragment_idx, %Session{fec_n: fec_n})
       when block_idx >= 0 and block_idx <= @max_block_idx and fragment_idx >= 0 and
              fragment_idx < fec_n,
       do: :ok

  defp validate_fragment(_block_idx, _fragment_idx, _format), do: {:error, :invalid_fragment}

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

  defp maybe_install_session(state, %Session{} = session, accepted_session_payload) do
    if session_changed?(state.current_session, session) do
      with codec when is_reference(codec) <- FecNif.new(session.fec_k, session.fec_n) do
        current_format = output_stream_format(state.input_stream_format, session)

        next_state = %{
          state
          | accepted_session_payload: accepted_session_payload,
            codec: codec,
            current_format: current_format,
            current_session: session,
            epoch_floor: session.epoch,
            last_emitted_seq: nil,
            last_known_block: nil,
            order: [],
            stats_baseline: state.counters,
            blocks: %{}
        }

        actions = [
          stream_format: {:output, current_format},
          notify_parent:
            {:wfb_session_accepted, session_notification(session, state.input_stream_format)}
        ]

        {actions, next_state}
      else
        :error ->
          raise ArgumentError,
                "unable to initialize FEC codec for k=#{session.fec_k} n=#{session.fec_n}"
      end
    else
      {[], %{state | accepted_session_payload: accepted_session_payload}}
    end
  end

  defp reset_decoder_state(state) do
    %{
      state
      | codec: nil,
        current_format: nil,
        current_session: nil,
        last_emitted_seq: nil,
        last_known_block: nil,
        order: [],
        stats_baseline: state.counters,
        blocks: %{}
    }
  end

  defp ensure_block(state, block_idx) do
    cond do
      Map.has_key?(state.blocks, block_idx) ->
        {:ok, state, [], block_idx}

      state.last_known_block != nil and block_idx <= state.last_known_block ->
        {:error, :stale_block}

      true ->
        new_blocks = min(new_blocks_count(state.last_known_block, block_idx), state.ring_size)

        {state, actions, created_idx} =
          Enum.reduce(0..(new_blocks - 1), {state, [], nil}, fn offset,
                                                                {acc_state, acc_actions, _acc_idx} ->
            new_block_idx = block_idx + offset + 1 - new_blocks
            {next_state, next_actions} = push_block(acc_state, new_block_idx)
            {next_state, acc_actions ++ next_actions, new_block_idx}
          end)

        {:ok, %{state | last_known_block: block_idx}, actions, created_idx}
    end
  end

  defp new_blocks_count(nil, _block_idx), do: 1
  defp new_blocks_count(last_known_block, block_idx), do: max(block_idx - last_known_block, 1)

  defp push_block(state, block_idx) do
    block = new_block(block_idx)

    if length(state.order) < state.ring_size do
      {
        %{
          state
          | order: state.order ++ [block_idx],
            blocks: Map.put(state.blocks, block_idx, block)
        },
        []
      }
    else
      [oldest_idx | rest] = state.order

      {flush_actions, state} = flush_block(state, oldest_idx, :override)

      next_state = %{
        state
        | order: rest ++ [block_idx],
          blocks: state.blocks |> Map.delete(oldest_idx) |> Map.put(block_idx, block)
      }

      {increment_counter(next_state, :ring_override_count), flush_actions}
    end
  end

  defp store_fragment(state, block_idx, fragment_idx, %Buffer{} = buffer) do
    block = Map.fetch!(state.blocks, block_idx)

    if Map.has_key?(block.received, fragment_idx) do
      {:error, :duplicate_fragment, state}
    else
      updated_block = %{
        block
        | has_fragments: block.has_fragments + 1,
          max_shard_size: max(block.max_shard_size, byte_size(buffer.payload)),
          received: Map.put(block.received, fragment_idx, buffer)
      }

      {:ok, put_block(state, updated_block)}
    end
  end

  defp maybe_emit_contiguous_front(state, block_idx) do
    case state.order do
      [^block_idx | _rest] ->
        emit_contiguous_front(state)

      _other ->
        {[], state}
    end
  end

  defp maybe_recover_and_flush(state, block_idx) do
    if not Map.has_key?(state.blocks, block_idx) do
      {[], state}
    else
      block = Map.fetch!(state.blocks, block_idx)

      cond do
        block.fragment_to_send_idx >= state.current_format.fec_k ->
          {[], state}

        block.has_fragments != state.current_format.fec_k ->
          {[], state}

        true ->
          case state.order do
            [^block_idx | _rest] ->
              recover_and_emit_front(state, block_idx)

            _other ->
              predecode_and_flush_to_front(state, block_idx)
          end
      end
    end
  end

  defp emit_contiguous_front(state) do
    case state.order do
      [front_idx | _rest] ->
        block = Map.fetch!(state.blocks, front_idx)
        emit_contiguous_front(state, block, [])

      [] ->
        {[], state}
    end
  end

  defp emit_contiguous_front(state, block, actions) do
    fec_k = state.current_format.fec_k

    cond do
      block.fragment_to_send_idx >= fec_k ->
        {actions, pop_front_block(state)}

      source_fragment(block, block.fragment_to_send_idx) == nil ->
        {actions, state}

      true ->
        {fragment_actions, next_state} =
          emit_source_fragment(state, block.block_idx, block.fragment_to_send_idx, :live)

        next_block = Map.fetch!(next_state.blocks, block.block_idx)
        emit_contiguous_front(next_state, next_block, actions ++ fragment_actions)
    end
  end

  defp predecode_and_flush_to_front(state, block_idx) do
    {state, recovered_count} = ensure_recovered_sources(state, block_idx)
    state = add_counter(state, :fec_recovered_fragments, recovered_count)

    {flush_actions, state} = flush_older_blocks_until_front(state, block_idx)
    {emit_actions, state} = recover_and_emit_front(state, block_idx)
    {flush_actions ++ emit_actions, state}
  end

  defp recover_and_emit_front(state, block_idx) do
    {state, recovered_count} = ensure_recovered_sources(state, block_idx)
    state = add_counter(state, :fec_recovered_fragments, recovered_count)

    block = Map.fetch!(state.blocks, block_idx)
    emit_all_from_front(state, block, [])
  end

  defp emit_all_from_front(state, block, actions) do
    fec_k = state.current_format.fec_k

    if block.fragment_to_send_idx >= fec_k do
      {actions, pop_front_block(state)}
    else
      {fragment_actions, next_state} =
        emit_source_fragment(
          state,
          block.block_idx,
          block.fragment_to_send_idx,
          if(Map.has_key?(block.recovered, block.fragment_to_send_idx),
            do: :recovered,
            else: :live
          )
        )

      next_block = Map.fetch!(next_state.blocks, block.block_idx)
      emit_all_from_front(next_state, next_block, actions ++ fragment_actions)
    end
  end

  defp flush_older_blocks_until_front(state, block_idx) do
    do_flush_older_blocks_until_front(state, block_idx, [])
  end

  defp do_flush_older_blocks_until_front(
         %{order: [block_idx | _rest]} = state,
         block_idx,
         actions
       ),
       do: {actions, state}

  defp do_flush_older_blocks_until_front(
         %{order: [front_idx | _rest]} = state,
         block_idx,
         actions
       ) do
    {flush_actions, next_state} = flush_block(state, front_idx, :flush)
    do_flush_older_blocks_until_front(next_state, block_idx, actions ++ flush_actions)
  end

  defp flush_block(state, block_idx, emission) do
    block = Map.fetch!(state.blocks, block_idx)
    fec_k = state.current_format.fec_k

    {actions, next_state} =
      if block.fragment_to_send_idx >= fec_k do
        {[], state}
      else
        Enum.reduce(block.fragment_to_send_idx..(fec_k - 1), {[], state}, fn fragment_idx,
                                                                             {acc_actions,
                                                                              acc_state} ->
          case Map.get(block.received, fragment_idx) do
            %Buffer{} ->
              {fragment_actions, updated_state} =
                emit_source_fragment(acc_state, block_idx, fragment_idx, emission)

              {Enum.reverse(fragment_actions) ++ acc_actions, updated_state}

            nil ->
              {acc_actions, acc_state}
          end
        end)
      end

    {Enum.reverse(actions), pop_front_block(next_state)}
  end

  defp emit_source_fragment(state, block_idx, fragment_idx, emission) do
    block = Map.fetch!(state.blocks, block_idx)
    %Buffer{} = buffer = source_fragment(block, fragment_idx)
    buffer = put_wfb_session_metadata(buffer, state.current_session)
    ordered_seq = block_idx * state.current_session.fec_k + fragment_idx
    lost = lost_between(state.last_emitted_seq, ordered_seq)

    metadata =
      normalize_metadata(buffer.metadata)
      |> Map.update(:wfb, %{}, fn wfb ->
        Map.merge(wfb, %{
          emission: emission,
          ordered_seq: ordered_seq
        })
      end)

    updated_buffer = %Buffer{buffer | metadata: metadata}

    updated_block = %{block | fragment_to_send_idx: fragment_idx + 1}

    next_state =
      state
      |> put_block(updated_block)
      |> add_counter(:emitted_source_shards, 1)
      |> add_counter(:lost_source_shards, lost)
      |> Map.put(:last_emitted_seq, ordered_seq)

    actions =
      if lost > 0 do
        [
          {:notify_parent,
           {:wfb_packet_loss,
            packet_loss_notification(state, lost, ordered_seq, block_idx, fragment_idx)}},
          {:buffer, {:output, updated_buffer}}
        ]
      else
        [{:buffer, {:output, updated_buffer}}]
      end

    {actions, next_state}
  end

  defp ensure_recovered_sources(state, block_idx) do
    block = Map.fetch!(state.blocks, block_idx)
    missing = missing_source_indexes(block, state.current_session.fec_k)

    if missing == [] do
      {state, 0}
    else
      shard_size = block.max_shard_size
      {shards, indexes, receiver_mask} = decode_inputs(block, state.current_session)

      case FecNif.decode(state.codec, shards, indexes, missing, shard_size) do
        {:ok, recovered_shards} ->
          recovered =
            Enum.zip(missing, recovered_shards)
            |> Enum.reduce(block.recovered, fn {idx, shard}, acc ->
              Map.put(acc, idx, recovered_buffer(block, idx, shard, receiver_mask))
            end)

          {put_block(state, %{block | recovered: recovered}), length(missing)}

        :error ->
          {state, 0}
      end
    end
  end

  defp decode_inputs(block, %Session{fec_k: fec_k, fec_n: fec_n}) do
    {shards, indexes, _next_parity_idx, receiver_mask} =
      Enum.reduce(0..(fec_k - 1), {[], [], fec_k, 0}, fn idx,
                                                         {acc_shards, acc_indexes,
                                                          next_parity_idx, acc_receiver_mask} ->
        case Map.get(block.received, idx) do
          %Buffer{} = buffer ->
            {[buffer.payload | acc_shards], [idx | acc_indexes], next_parity_idx,
             acc_receiver_mask ||| receiver_mask_for(buffer)}

          nil ->
            parity_idx = next_present_parity_index(block.received, next_parity_idx, fec_n)
            parity_buffer = Map.fetch!(block.received, parity_idx)

            {[parity_buffer.payload | acc_shards], [parity_idx | acc_indexes], parity_idx + 1,
             acc_receiver_mask ||| receiver_mask_for(parity_buffer)}
        end
      end)

    {Enum.reverse(shards), Enum.reverse(indexes), receiver_mask}
  end

  defp next_present_parity_index(received, start_idx, fec_n) do
    Enum.find(start_idx..(fec_n - 1), fn idx -> Map.has_key?(received, idx) end) ||
      raise ArgumentError, "missing parity shard required for FEC decode"
  end

  defp missing_source_indexes(block, fec_k) do
    if block.fragment_to_send_idx >= fec_k do
      []
    else
      Enum.filter(block.fragment_to_send_idx..(fec_k - 1), fn idx ->
        source_fragment(block, idx) == nil
      end)
    end
  end

  defp source_fragment(block, idx) do
    Map.get(block.received, idx) || Map.get(block.recovered, idx)
  end

  defp recovered_buffer(block, fragment_idx, recovered_shard, receiver_mask) do
    trimmed_payload = trim_recovered_shard(recovered_shard)

    template_metadata =
      block.received
      |> Map.values()
      |> List.first()
      |> then(fn buffer ->
        case buffer do
          %Buffer{metadata: metadata} -> metadata
          _other -> %{}
        end
        |> normalize_metadata()
        |> Map.drop([:radio, :recovery])
      end)

    metadata =
      template_metadata
      |> Map.update(:wfb, %{}, fn wfb ->
        wfb
        |> Map.put(:fragment_idx, fragment_idx)
      end)
      |> Map.put(:recovery, %{receiver_mask: receiver_mask})

    %Buffer{payload: trimmed_payload, metadata: metadata}
  end

  defp trim_recovered_shard(<<_flags, packet_size::big-16, _rest::binary>> = shard) do
    total_size = min(byte_size(shard), packet_size + 3)
    binary_part(shard, 0, total_size)
  end

  defp trim_recovered_shard(shard), do: shard

  defp lost_between(nil, _ordered_seq), do: 0

  defp lost_between(last_emitted_seq, ordered_seq) when ordered_seq > last_emitted_seq + 1,
    do: ordered_seq - last_emitted_seq - 1

  defp lost_between(_last_emitted_seq, _ordered_seq), do: 0

  defp pop_front_block(%{order: [front_idx | rest], blocks: blocks} = state) do
    %{state | order: rest, blocks: Map.delete(blocks, front_idx)}
  end

  defp new_block(block_idx) do
    %{
      block_idx: block_idx,
      fragment_to_send_idx: 0,
      has_fragments: 0,
      max_shard_size: 0,
      received: %{},
      recovered: %{}
    }
  end

  defp put_block(state, block) do
    %{state | blocks: Map.put(state.blocks, block.block_idx, block)}
  end

  defp output_stream_format(%StreamFormat{} = input_stream_format, %Session{} = session) do
    %OrderedShardStreamFormat{
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

  defp put_wfb_session_metadata(%Buffer{} = buffer, %Session{} = session) do
    metadata =
      normalize_metadata(buffer.metadata)
      |> Map.update(:wfb, %{}, fn wfb ->
        Map.merge(wfb, %{
          fec_k: session.fec_k,
          fec_n: session.fec_n,
          fec_type: session.fec_type,
          session_epoch: session.epoch
        })
      end)
      |> Map.put(:wfb_session, session)

    %Buffer{buffer | metadata: metadata}
  end

  defp duplicate_accepted_session_payload?(state, payload) do
    is_binary(state.accepted_session_payload) and state.accepted_session_payload == payload
  end

  defp session_changed?(nil, %Session{}), do: true

  defp session_changed?(%Session{} = current_session, %Session{} = session),
    do: current_session != session

  defp notify_session_issue(state, %Buffer{} = buffer, reason) do
    [notify_parent: {:wfb_session_rejected, reason, session_issue_context(state, buffer)}]
  end

  defp session_notification(%Session{} = session, %StreamFormat{} = input_stream_format) do
    %{
      channel_id: session.channel_id,
      epoch: session.epoch,
      fec_k: session.fec_k,
      fec_n: session.fec_n,
      fec_type: session.fec_type,
      interfaces: input_stream_format.interfaces,
      link_id: input_stream_format.link_id,
      radio_port: input_stream_format.radio_port
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

  defp packet_loss_notification(state, lost_count, ordered_seq, block_idx, fragment_idx) do
    format = state.current_format

    %{
      block_idx: block_idx,
      channel_id: format.channel_id,
      epoch: format.epoch,
      fragment_idx: fragment_idx,
      interfaces: format.interfaces,
      last_ordered_seq: state.last_emitted_seq,
      link_id: format.link_id,
      lost_count: lost_count,
      ordered_seq: ordered_seq,
      radio_port: format.radio_port
    }
  end

  defp stats_notification(state) do
    format = state.current_format

    %{
      blocks_in_ring: length(state.order),
      channel_id: format.channel_id,
      counters: counters_delta(state.counters, state.stats_baseline),
      epoch: format.epoch,
      interfaces: format.interfaces,
      last_emitted_seq: state.last_emitted_seq,
      last_known_block: state.last_known_block,
      link_id: format.link_id,
      radio_port: format.radio_port,
      stats_interval_ms: state.stats_interval_ms
    }
  end

  defp counters_delta(counters, baseline) do
    Map.new(counters, fn {counter, value} ->
      {counter, value - Map.get(baseline, counter, 0)}
    end)
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp receiver_mask_for(%Buffer{} = buffer) do
    case get_in(buffer.metadata, [:radio, :receiver_idx]) do
      receiver_idx when is_integer(receiver_idx) and receiver_idx >= 0 and receiver_idx < 64 ->
        1 <<< receiver_idx

      _receiver_idx ->
        0
    end
  end

  defp increment_counter(state, counter), do: add_counter(state, counter, 1)

  defp add_counter(state, counter, amount) do
    update_in(state.counters[counter], &((&1 || 0) + amount))
  end
end
