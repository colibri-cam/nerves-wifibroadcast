defmodule NervesWifibroadcast.Membrane.Radio.Sink do
  @moduledoc """
  Shared WFB radio sink that injects packets from multiple `radio_port` branches.

  The sink owns one packet socket per interface, wraps inner WFB session/data
  payloads with radiotap and 802.11 headers, and drains per-port queues in a
  round-robin order for fairer multi-stream transmission.

  TX sockets bypass qdisc by default for lower latency. Set `use_qdisc?: true`
  together with `fwmark_base` if you want Linux `tc` or policy routing to
  classify packets. The current mark policy is:

  - `fwmark_base` for session packets and source data shards
  - `fwmark_base + 1` for parity shards
  """

  use Membrane.Sink

  alias Membrane.Buffer
  alias Membrane.Pad
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.Radio.AFPacket
  alias NervesWifibroadcast.Radio.Frame
  alias NervesWifibroadcast.Radio.PhyConfig

  @max_interfaces 64

  def_options(
    bandwidth: [spec: pos_integer(), default: 20],
    frame_type: [spec: :data | :rts | non_neg_integer(), default: :data],
    fwmark_base: [spec: non_neg_integer(), default: 0],
    interfaces: [spec: [String.t()], default: []],
    ldpc: [spec: boolean(), default: false],
    max_queue_size: [spec: pos_integer(), default: 256],
    mcs_index: [spec: non_neg_integer(), default: 1],
    open_socket?: [spec: boolean(), default: true],
    short_gi: [spec: boolean() | :short | :long, default: :long],
    socket_backend: [spec: module(), default: AFPacket],
    socket_buffer_size: [spec: pos_integer() | nil, default: nil],
    stbc: [spec: non_neg_integer(), default: 0],
    use_qdisc?: [spec: boolean(), default: false],
    vht_mode: [spec: boolean(), default: false],
    vht_nss: [spec: pos_integer(), default: 1]
  )

  def_input_pad(:input,
    availability: :on_request,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    interfaces = normalize_interfaces!(opts.interfaces)

    phy_config =
      Frame.normalize_phy_config!(%PhyConfig{
        bandwidth: opts.bandwidth,
        ldpc: opts.ldpc,
        mcs_index: opts.mcs_index,
        short_gi: opts.short_gi,
        stbc: opts.stbc,
        vht_mode: opts.vht_mode,
        vht_nss: opts.vht_nss
      })

    state = %{
      counters: %{
        dropped_packets: 0,
        fwmark_updates: 0,
        injected_bytes: 0,
        injected_packets: 0,
        invalid_packet_drops: 0,
        socket_closed: 0,
        socket_errors: 0
      },
      frame_type: opts.frame_type,
      fwmark_base: opts.fwmark_base,
      input_pads: %{},
      interfaces: interfaces,
      max_queue_size: opts.max_queue_size,
      next_drain_index: 0,
      open_socket?: opts.open_socket?,
      phy_config: phy_config,
      playback_started?: false,
      sequence_control: 0,
      socket_backend: opts.socket_backend,
      socket_buffer_size: opts.socket_buffer_size,
      sockets: %{},
      use_qdisc?: opts.use_qdisc?
    }

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, %{open_socket?: false} = state), do: {[], state}

  def handle_setup(_ctx, state) do
    case open_sockets(
           state.interfaces,
           state.socket_backend,
           state.socket_buffer_size,
           state.use_qdisc?
         ) do
      {:ok, sockets} ->
        {[], %{state | sockets: sockets}}

      {:error, interface, reason, sockets} ->
        close_sockets(sockets, state.socket_backend)

        actions = [
          notify_parent: {:radio_sink_socket_open_failed, interface, reason},
          terminate: {:socket_open_failed, reason}
        ]

        {actions, state}
    end
  end

  @impl true
  def handle_playing(_ctx, state) do
    drain_queues(%{state | playback_started?: true})
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, radio_port) = pad, _ctx, state) do
    input = %{pad: pad, queue: :queue.new(), queue_len: 0, stream_format: nil}
    {[], put_input(state, radio_port, input)}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, radio_port), _ctx, state) do
    {[], drop_input(state, radio_port)}
  end

  @impl true
  def handle_stream_format(
        Pad.ref(:input, radio_port),
        %StreamFormat{} = stream_format,
        _ctx,
        state
      ) do
    radio_port = validate_radio_port!(radio_port)

    if stream_format.radio_port != radio_port do
      raise ArgumentError,
            "expected stream format radio_port #{inspect(stream_format.radio_port)} to match sink pad #{inspect(radio_port)}"
    end

    input = Map.fetch!(state.input_pads, radio_port)
    {[], put_input(state, radio_port, %{input | stream_format: stream_format})}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, radio_port), %Buffer{} = buffer, _ctx, state) do
    state = enqueue_buffer(state, radio_port, buffer)

    if state.playback_started? do
      drain_queues(state)
    else
      {[], state}
    end
  end

  @impl true
  def handle_parent_notification({:set_radio_config, %PhyConfig{} = phy_config}, _ctx, state) do
    apply_radio_config(state, phy_config)
  end

  def handle_parent_notification({:set_radio_config, attrs}, _ctx, state) when is_map(attrs) do
    apply_radio_config(state, Frame.merge_phy_config!(state.phy_config, attrs))
  end

  def handle_parent_notification(_notification, _ctx, state), do: {[], state}

  @impl true
  def handle_terminate_request(_ctx, state) do
    _ = close_sockets(state.sockets, state.socket_backend)
    {[terminate: :normal], state}
  end

  defp apply_radio_config(state, %PhyConfig{} = phy_config) do
    next_state = %{state | phy_config: Frame.normalize_phy_config!(phy_config)}

    notification =
      {:radio_sink_config_applied,
       %{
         interfaces: state.interfaces,
         phy: next_state.phy_config
       }}

    {[notify_parent: notification], next_state}
  end

  defp open_sockets(interfaces, socket_backend, socket_buffer_size, use_qdisc?) do
    Enum.reduce_while(Enum.with_index(interfaces), {:ok, %{}}, fn {interface, socket_idx},
                                                                  {:ok, sockets} ->
      case socket_backend.open_tx(
             interface: interface,
             socket_buffer_size: socket_buffer_size,
             use_qdisc?: use_qdisc?
           ) do
        {:ok, socket} ->
          socket_info = %{
            current_mark: nil,
            interface: interface,
            socket: socket,
            socket_idx: socket_idx
          }

          {:cont, {:ok, Map.put(sockets, socket, socket_info)}}

        {:error, reason} ->
          {:halt, {:error, interface, reason, sockets}}
      end
    end)
  end

  defp close_sockets(sockets, socket_backend) do
    Enum.each(sockets, fn {socket, _info} ->
      _ = socket_backend.close(socket)
    end)

    :ok
  end

  defp enqueue_buffer(state, radio_port, buffer) do
    input = Map.fetch!(state.input_pads, radio_port)

    if input.queue_len >= state.max_queue_size do
      increment_counter(state, :dropped_packets)
    else
      updated_input = %{
        input
        | queue: :queue.in(buffer, input.queue),
          queue_len: input.queue_len + 1
      }

      put_input(state, radio_port, updated_input)
    end
  end

  defp drain_queues(state), do: drain_queues(state, [])

  defp drain_queues(state, actions) do
    case pop_next_buffer(state) do
      {:ok, buffer, input, next_state} ->
        {inject_actions, next_state} = inject_buffer(next_state, input, buffer)
        drain_queues(next_state, actions ++ inject_actions)

      :empty ->
        {actions, state}
    end
  end

  defp pop_next_buffer(%{input_pads: input_pads}) when map_size(input_pads) == 0, do: :empty

  defp pop_next_buffer(state) do
    radio_ports = state.input_pads |> Map.keys() |> Enum.sort()
    count = length(radio_ports)
    start_index = rem(state.next_drain_index, count)
    rotated_ports = Enum.drop(radio_ports, start_index) ++ Enum.take(radio_ports, start_index)

    case Enum.find(rotated_ports, &ready_input?(state, &1)) do
      nil ->
        :empty

      radio_port ->
        input = Map.fetch!(state.input_pads, radio_port)
        {{:value, buffer}, queue} = :queue.out(input.queue)

        updated_input = %{input | queue: queue, queue_len: input.queue_len - 1}

        next_state =
          state
          |> put_input(radio_port, updated_input)
          |> Map.put(:next_drain_index, next_drain_index(radio_ports, radio_port))

        {:ok, buffer, updated_input, next_state}
    end
  end

  defp inject_buffer(state, input, %Buffer{} = buffer) do
    case Frame.tx_frame(buffer, state.sequence_control, state.frame_type, %{
           channel_id: input_channel_id(input, buffer),
           phy_config: state.phy_config
         }) do
      {:ok, frame} ->
        {actions, state} = inject_frame(state, frame, fwmark_for(state, buffer))

        {actions,
         %{state | sequence_control: Frame.next_sequence_control(state.sequence_control)}}

      {:error, _reason} ->
        {[], increment_counter(state, :invalid_packet_drops)}
    end
  end

  defp inject_frame(state, frame, fwmark) do
    Enum.reduce(Map.keys(state.sockets), {[], state}, fn socket, {actions, acc_state} ->
      case maybe_apply_fwmark(acc_state, socket, fwmark) do
        {:ok, next_state, mark_actions} ->
          case next_state.socket_backend.send(socket, frame) do
            :ok ->
              final_state =
                next_state
                |> increment_counter(:injected_packets)
                |> add_counter(:injected_bytes, byte_size(frame))

              {actions ++ mark_actions, final_state}

            {:error, :closed} ->
              {socket_actions, final_state} = remove_socket(next_state, socket, :closed)
              {actions ++ mark_actions ++ socket_actions, final_state}

            {:error, reason} ->
              notify =
                {:notify_parent,
                 {:radio_sink_socket_error, next_state.sockets[socket].interface, reason}}

              {actions ++ mark_actions ++ [notify], increment_counter(next_state, :socket_errors)}
          end

        {:error, next_state, mark_actions} ->
          {actions ++ mark_actions, next_state}
      end
    end)
  end

  defp maybe_apply_fwmark(%{use_qdisc?: false} = state, _socket, _fwmark), do: {:ok, state, []}

  defp maybe_apply_fwmark(state, socket, fwmark) do
    socket_info = Map.fetch!(state.sockets, socket)

    if socket_info.current_mark == fwmark do
      {:ok, state, []}
    else
      case state.socket_backend.set_tx_mark(socket, fwmark) do
        :ok ->
          next_state =
            put_socket_info(state, %{socket_info | current_mark: fwmark})
            |> increment_counter(:fwmark_updates)

          {:ok, next_state, []}

        {:error, :closed} ->
          {actions, next_state} = remove_socket(state, socket, :closed)
          {:error, next_state, actions}

        {:error, reason} ->
          notify =
            {:notify_parent,
             {:radio_sink_socket_mark_failed, socket_info.interface, fwmark, reason}}

          {:error, increment_counter(state, :socket_errors), [notify]}
      end
    end
  end

  defp remove_socket(state, socket, reason) do
    case Map.pop(state.sockets, socket) do
      {nil, _sockets} ->
        {[], state}

      {socket_info, sockets} ->
        _ = state.socket_backend.close(socket)

        next_state =
          %{state | sockets: sockets}
          |> increment_counter(:socket_closed)

        actions = [notify_parent: {:radio_sink_socket_closed, socket_info.interface, reason}]

        if map_size(sockets) == 0 do
          {actions ++ [terminate: :normal], next_state}
        else
          {actions, next_state}
        end
    end
  end

  defp input_channel_id(%{stream_format: %StreamFormat{channel_id: channel_id}}, _buffer),
    do: channel_id

  defp input_channel_id(_input, %Buffer{} = buffer),
    do: get_in(buffer.metadata, [:wfb, :channel_id])

  defp ready_input?(state, radio_port) do
    case Map.get(state.input_pads, radio_port) do
      %{queue_len: queue_len} when queue_len > 0 -> true
      _input -> false
    end
  end

  defp next_drain_index(radio_ports, radio_port) do
    case Enum.find_index(radio_ports, &(&1 == radio_port)) do
      nil -> 0
      index -> index + 1
    end
  end

  defp drop_input(state, radio_port) do
    state =
      case Map.get(state.input_pads, radio_port) do
        %{queue_len: queue_len} when queue_len > 0 ->
          add_counter(state, :dropped_packets, queue_len)

        _input ->
          state
      end

    %{state | input_pads: Map.delete(state.input_pads, radio_port)}
  end

  defp put_input(state, radio_port, input) do
    %{state | input_pads: Map.put(state.input_pads, validate_radio_port!(radio_port), input)}
  end

  defp put_socket_info(state, socket_info) do
    %{state | sockets: Map.put(state.sockets, socket_info.socket, socket_info)}
  end

  defp fwmark_for(%{fwmark_base: fwmark_base}, %Buffer{} = buffer) do
    case {get_in(buffer.metadata, [:wfb, :packet_type]),
          get_in(buffer.metadata, [:wfb, :shard_role])} do
      {:data, :parity} -> fwmark_base + 1
      _other -> fwmark_base
    end
  end

  defp validate_radio_port!(radio_port)
       when is_integer(radio_port) and radio_port >= 0 and radio_port <= 0xFF,
       do: radio_port

  defp validate_radio_port!(radio_port) do
    raise ArgumentError,
          "expected radio_port to be a non-negative 8-bit integer, got: #{inspect(radio_port)}"
  end

  defp normalize_interfaces!(interfaces) when is_list(interfaces) do
    cond do
      interfaces == [] ->
        raise ArgumentError, "expected :interfaces to contain at least one interface"

      length(interfaces) > @max_interfaces ->
        raise ArgumentError,
              "expected at most #{@max_interfaces} interfaces, got #{length(interfaces)}"

      Enum.any?(interfaces, &(not is_binary(&1) or &1 == "")) ->
        raise ArgumentError,
              "expected :interfaces to be a list of non-empty strings, got: #{inspect(interfaces)}"

      length(Enum.uniq(interfaces)) != length(interfaces) ->
        raise ArgumentError,
              "expected :interfaces to contain unique entries, got: #{inspect(interfaces)}"

      true ->
        interfaces
    end
  end

  defp normalize_interfaces!(interfaces) do
    raise ArgumentError,
          "expected :interfaces to be a list of non-empty strings, got: #{inspect(interfaces)}"
  end

  defp increment_counter(state, counter), do: add_counter(state, counter, 1)

  defp add_counter(state, counter, amount) do
    update_in(state.counters[counter], &((&1 || 0) + amount))
  end
end
