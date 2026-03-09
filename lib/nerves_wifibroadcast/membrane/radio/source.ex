defmodule NervesWifibroadcast.Membrane.Radio.Source do
  @moduledoc """
  Membrane source for WFB monitor-mode capture over `AF_PACKET`.

  The source owns one Linux packet socket per interface, parses radiotap, applies
  WFB-specific ingress filtering, and routes packets to dynamic output pads keyed
  by `radio_port`.
  """

  use Membrane.Source

  alias Membrane.Buffer
  alias Membrane.Pad
  alias NervesWifibroadcast.Membrane.WFB.Router
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.Radio.AFPacket
  alias NervesWifibroadcast.Radiotap.Parser

  @max_interfaces 64
  @default_frame_buffer_size 4301
  @default_link_id Router.default_link_id()

  def_options(
    interfaces: [spec: [String.t()], default: []],
    link_id: [spec: non_neg_integer(), default: @default_link_id],
    radio_port: [spec: non_neg_integer() | nil, default: nil],
    radio_ports: [spec: [non_neg_integer()], default: []],
    drop_bad_fcs?: [spec: boolean(), default: true],
    drop_self_injected?: [spec: boolean(), default: true],
    trim_fcs?: [spec: boolean(), default: true],
    capture_ts_fun: [spec: (-> integer()), default: &System.monotonic_time/0],
    frame_buffer_size: [spec: pos_integer(), default: @default_frame_buffer_size],
    max_read_burst: [spec: pos_integer(), default: 32],
    max_queue_size: [spec: pos_integer(), default: 256],
    open_socket?: [spec: boolean(), default: true],
    parser: [spec: module(), default: Parser],
    socket_backend: [spec: module(), default: AFPacket],
    socket_buffer_size: [spec: pos_integer() | nil, default: nil]
  )

  def_output_pad(:output,
    accepted_format: StreamFormat,
    availability: :on_request,
    flow_control: :manual,
    demand_unit: :buffers
  )

  @impl true
  def handle_init(_ctx, opts) do
    interfaces = normalize_interfaces!(opts.interfaces)

    state = %{
      capture_ts_fun: opts.capture_ts_fun,
      counters: %{
        bad_fcs_drops: 0,
        dropped_packets: 0,
        invalid_wfb_header_drops: 0,
        malformed_packets: 0,
        passed_packets: 0,
        self_injected_drops: 0,
        short_frame_drops: 0,
        short_wfb_packet_drops: 0,
        truncated_packets: 0,
        unknown_packet_type_drops: 0,
        unknown_radio_port_drops: 0,
        unlinked_radio_port_drops: 0,
        wrong_link_id_drops: 0
      },
      drop_bad_fcs?: opts.drop_bad_fcs?,
      drop_self_injected?: opts.drop_self_injected?,
      enabled_radio_ports:
        Router.normalize_initial_radio_ports!(opts.radio_ports, opts.radio_port),
      frame_buffer_size: opts.frame_buffer_size,
      interfaces: interfaces,
      link_id: Router.validate_link_id!(opts.link_id),
      max_read_burst: opts.max_read_burst,
      max_queue_size: opts.max_queue_size,
      next_drain_index: 0,
      open_socket?: opts.open_socket?,
      output_pads: %{},
      parser: opts.parser,
      playback_started?: false,
      receivers: %{},
      socket_backend: opts.socket_backend,
      socket_buffer_size: opts.socket_buffer_size,
      trim_fcs?: opts.trim_fcs?
    }

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, %{open_socket?: false} = state), do: {[], state}

  def handle_setup(_ctx, state) do
    case open_receivers(state.interfaces, state.socket_backend, state.socket_buffer_size) do
      {:ok, receivers} ->
        {[], %{state | receivers: receivers}}

      {:error, interface, reason, receivers} ->
        close_receivers(receivers, state.socket_backend)

        actions = [
          {:notify_parent, {:radio_source_socket_open_failed, interface, reason}},
          {:terminate, {:socket_open_failed, reason}}
        ]

        {actions, state}
    end
  end

  @impl true
  def handle_playing(_ctx, state) do
    state = %{state | playback_started?: true}
    {read_actions, state} = maybe_start_reads(state)
    {buffer_actions, state} = drain_queues(state)

    actions = output_stream_format_actions(state) ++ read_actions ++ buffer_actions

    {actions, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, radio_port) = pad, _ctx, state) do
    radio_port = Router.validate_radio_port!(radio_port)

    output = %{
      demand: 0,
      pad: pad,
      queue: :queue.new(),
      queue_len: 0
    }

    next_state = put_output(state, radio_port, output)

    actions =
      if state.playback_started? do
        [stream_format: {pad, output_stream_format(state, radio_port)}]
      else
        []
      end

    {actions, next_state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, radio_port), _ctx, state) do
    {[], drop_output(state, radio_port)}
  end

  @impl true
  def handle_demand(Pad.ref(:output, radio_port), size, :buffers, _ctx, state) do
    case Map.get(state.output_pads, radio_port) do
      %{demand: demand} = output ->
        state = put_output(state, radio_port, %{output | demand: demand + size})
        drain_queues(state)

      nil ->
        {[], state}
    end
  end

  @impl true
  def handle_parent_notification({:set_radio_ports, radio_ports}, _ctx, state) do
    radio_ports = Router.normalize_radio_ports!(radio_ports)
    state = %{state | enabled_radio_ports: radio_ports}
    {[], drop_disabled_queues(state)}
  end

  def handle_parent_notification({:add_radio_port, radio_port}, _ctx, state) do
    radio_port = Router.validate_radio_port!(radio_port)
    {[], %{state | enabled_radio_ports: MapSet.put(state.enabled_radio_ports, radio_port)}}
  end

  def handle_parent_notification({:remove_radio_port, radio_port}, _ctx, state) do
    radio_port = Router.validate_radio_port!(radio_port)

    state = %{state | enabled_radio_ports: MapSet.delete(state.enabled_radio_ports, radio_port)}
    {[], clear_output_queue(state, radio_port)}
  end

  def handle_parent_notification({:set_link_id, link_id}, _ctx, state) do
    link_id = Router.validate_link_id!(link_id)

    state =
      state
      |> Map.put(:link_id, link_id)
      |> clear_all_output_queues()

    actions =
      if state.playback_started? do
        output_stream_format_actions(state)
      else
        []
      end

    {actions, state}
  end

  @impl true
  def handle_info({:radio_packet, packet}, _ctx, state) do
    case first_receiver(state) do
      nil -> {[], state}
      receiver -> state |> ingest_packet(packet, receiver, %{}) |> drain_queues()
    end
  end

  def handle_info({:radio_packet, receiver_idx, packet}, _ctx, state)
      when is_integer(receiver_idx) do
    case receiver_by_idx(state, receiver_idx) do
      nil -> {[], state}
      receiver -> state |> ingest_packet(packet, receiver, %{}) |> drain_queues()
    end
  end

  def handle_info({:"$socket", socket, :select, handle}, _ctx, state) do
    case Map.get(state.receivers, socket) do
      %{read_state: {:waiting, ^handle}} = receiver ->
        state
        |> put_receiver(%{receiver | read_state: :idle})
        |> read_and_drain(socket)

      _receiver ->
        {[], state}
    end
  end

  def handle_info({:"$socket", socket, :abort, {handle, reason}}, _ctx, state) do
    case Map.get(state.receivers, socket) do
      %{read_state: {:waiting, ^handle}, interface: interface} = receiver ->
        next_state = put_receiver(state, %{receiver | read_state: :idle})

        remove_receiver(
          next_state,
          socket,
          {:notify_parent, {:radio_source_socket_abort, interface, reason}}
        )

      _receiver ->
        {[], state}
    end
  end

  def handle_info({:continue_read, socket}, _ctx, state) do
    read_and_drain(state, socket)
  end

  def handle_info(_message, _ctx, state), do: {[], state}

  @impl true
  def handle_terminate_request(_ctx, state) do
    _ = cancel_pending_reads(state)
    _ = close_receivers(state.receivers, state.socket_backend)
    {[{:terminate, :normal}], state}
  end

  defp open_receivers(interfaces, socket_backend, socket_buffer_size) do
    Enum.reduce_while(Enum.with_index(interfaces), {:ok, %{}}, fn {interface, receiver_idx},
                                                                  {:ok, receivers} ->
      case socket_backend.open(interface: interface, socket_buffer_size: socket_buffer_size) do
        {:ok, socket} ->
          receiver = %{
            interface: interface,
            read_state: :idle,
            receiver_idx: receiver_idx,
            socket: socket
          }

          {:cont, {:ok, Map.put(receivers, socket, receiver)}}

        {:error, reason} ->
          {:halt, {:error, interface, reason, receivers}}
      end
    end)
  end

  defp close_receivers(receivers, socket_backend) do
    Enum.each(receivers, fn {socket, _receiver} ->
      _ = socket_backend.close(socket)
    end)

    :ok
  end

  defp maybe_start_reads(state) do
    Enum.reduce(Map.keys(state.receivers), {[], state}, fn socket, {actions, acc_state} ->
      {socket_actions, next_state} = maybe_start_read(acc_state, socket)
      {actions ++ socket_actions, next_state}
    end)
  end

  defp read_and_drain(state, socket) do
    {read_actions, state} = maybe_start_read(state, socket)
    {buffer_actions, state} = drain_queues(state)
    {read_actions ++ buffer_actions, state}
  end

  defp maybe_start_read(state, socket) do
    case Map.get(state.receivers, socket) do
      nil ->
        {[], state}

      %{read_state: {:waiting, _handle}} ->
        {[], state}

      _receiver ->
        recvmsg_loop(state, socket, state.max_read_burst, [])
    end
  end

  defp recvmsg_loop(state, socket, 0, actions) do
    send(self(), {:continue_read, socket})
    {actions, state}
  end

  defp recvmsg_loop(state, socket, burst_left, actions) do
    with %{socket: ^socket} = receiver <- Map.get(state.receivers, socket) do
      handle = make_ref()

      case state.socket_backend.recvmsg(socket, state.frame_buffer_size, 0, handle) do
        {:ok, msg} ->
          recvmsg_loop(ingest_recvmsg(state, receiver, msg), socket, burst_left - 1, actions)

        {:select, select_info} ->
          waiting_receiver = %{
            receiver
            | read_state: {:waiting, select_handle(select_info, handle)}
          }

          {actions, put_receiver(state, waiting_receiver)}

        {:select_read, {select_info, msg}} ->
          next_state = ingest_recvmsg(state, receiver, msg)

          case Map.get(next_state.receivers, socket) do
            nil ->
              {actions, next_state}

            updated_receiver ->
              waiting_receiver = %{
                updated_receiver
                | read_state: {:waiting, select_handle(select_info, handle)}
              }

              {actions, put_receiver(next_state, waiting_receiver)}
          end

        {:error, :closed} ->
          remove_receiver(
            state,
            socket,
            {:notify_parent, {:radio_source_socket_closed, receiver.interface}}
          )
          |> prepend_actions(actions)

        {:error, reason} ->
          remove_receiver(
            state,
            socket,
            {:notify_parent, {:radio_source_socket_error, receiver.interface, reason}}
          )
          |> prepend_actions(actions)
      end
    else
      nil ->
        {actions, state}
    end
  end

  defp ingest_recvmsg(state, receiver, msg) do
    case packet_from_recvmsg(msg) do
      {:ok, packet, metadata} ->
        ingest_packet(state, packet, receiver, metadata)

      {:error, :truncated} ->
        increment_counter(state, :truncated_packets)

      {:error, :invalid_recvmsg} ->
        increment_counter(state, :malformed_packets)
    end
  end

  defp packet_from_recvmsg(%{iov: iov} = msg) do
    flags = Map.get(msg, :flags, [])

    if Enum.member?(flags, :trunc) do
      {:error, :truncated}
    else
      packet = IO.iodata_to_binary(iov)

      metadata = %{
        socket_addr: Map.get(msg, :addr),
        socket_flags: flags
      }

      {:ok, packet, metadata}
    end
  end

  defp packet_from_recvmsg(_msg), do: {:error, :invalid_recvmsg}

  defp ingest_packet(state, packet, receiver, extra_radio_metadata) do
    case state.parser.parse(packet) do
      {:ok, radiotap, payload} ->
        radio_metadata =
          Map.merge(extra_radio_metadata, %{
            capture_ts: state.capture_ts_fun.(),
            radiotap: radiotap,
            raw_length: byte_size(packet),
            receiver_idx: receiver.receiver_idx
          })

        buffer = %Buffer{payload: payload, metadata: %{radio: radio_metadata}}
        route_packet(state, buffer)

      {:error, _reason} ->
        increment_counter(state, :malformed_packets)
    end
  end

  defp route_packet(state, %Buffer{} = buffer) do
    case Router.route_buffer(buffer, state) do
      {:ok, radio_port, routed_buffer} ->
        if Map.has_key?(state.output_pads, radio_port) do
          enqueue_buffer(state, radio_port, routed_buffer)
          |> increment_counter(:passed_packets)
        else
          increment_counter(state, :unlinked_radio_port_drops)
        end

      {:drop, counter} ->
        increment_counter(state, counter)
    end
  end

  defp enqueue_buffer(state, radio_port, buffer) do
    output = Map.fetch!(state.output_pads, radio_port)

    if output.queue_len >= state.max_queue_size do
      increment_counter(state, :dropped_packets)
    else
      updated_output = %{
        output
        | queue: :queue.in(buffer, output.queue),
          queue_len: output.queue_len + 1
      }

      put_output(state, radio_port, updated_output)
    end
  end

  defp drain_queues(state), do: drain_queues(state, [])

  defp drain_queues(state, actions) do
    case pop_next_buffer(state) do
      {:ok, action, next_state} ->
        drain_queues(next_state, [action | actions])

      :empty ->
        {Enum.reverse(actions), state}
    end
  end

  defp pop_next_buffer(%{output_pads: output_pads}) when map_size(output_pads) == 0,
    do: :empty

  defp pop_next_buffer(state) do
    radio_ports = state.output_pads |> Map.keys() |> Enum.sort()
    count = length(radio_ports)
    start_index = rem(state.next_drain_index, count)
    rotated_ports = Enum.drop(radio_ports, start_index) ++ Enum.take(radio_ports, start_index)

    case Enum.find(rotated_ports, &ready_output?(state, &1)) do
      nil ->
        :empty

      radio_port ->
        output = Map.fetch!(state.output_pads, radio_port)
        {{:value, buffer}, queue} = :queue.out(output.queue)

        updated_output = %{
          output
          | demand: output.demand - 1,
            queue: queue,
            queue_len: output.queue_len - 1
        }

        next_state =
          state
          |> put_output(radio_port, updated_output)
          |> Map.put(:next_drain_index, next_drain_index(radio_ports, radio_port))

        {:ok, {:buffer, {output.pad, buffer}}, next_state}
    end
  end

  defp ready_output?(state, radio_port) do
    case Map.get(state.output_pads, radio_port) do
      %{demand: demand, queue_len: queue_len} when demand > 0 and queue_len > 0 -> true
      _output -> false
    end
  end

  defp next_drain_index(radio_ports, radio_port) do
    case Enum.find_index(radio_ports, &(&1 == radio_port)) do
      nil -> 0
      index -> index + 1
    end
  end

  defp output_stream_format_actions(state) do
    state.output_pads
    |> Enum.sort_by(fn {radio_port, _output} -> radio_port end)
    |> Enum.map(fn {radio_port, %{pad: pad}} ->
      {:stream_format, {pad, output_stream_format(state, radio_port)}}
    end)
  end

  defp output_stream_format(state, radio_port) do
    Router.output_stream_format(state.link_id, radio_port, state.interfaces)
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

  defp select_handle({:select_info, _op, handle}, _default), do: handle
  defp select_handle({:select_info, handle}, _default), do: handle
  defp select_handle(_other, default), do: default

  defp put_receiver(state, receiver) do
    %{state | receivers: Map.put(state.receivers, receiver.socket, receiver)}
  end

  defp remove_receiver(state, socket, notify_action) do
    case Map.pop(state.receivers, socket) do
      {nil, _receivers} ->
        {[], state}

      {_receiver, receivers} ->
        _ = state.socket_backend.close(socket)

        next_state = %{state | receivers: receivers}
        actions = [notify_action]

        if map_size(receivers) == 0 do
          {actions ++ [{:terminate, :normal}], next_state}
        else
          {actions, next_state}
        end
    end
  end

  defp prepend_actions({receiver_actions, state}, actions),
    do: {actions ++ receiver_actions, state}

  defp cancel_pending_reads(state) do
    Enum.each(state.receivers, fn {socket, receiver} ->
      case receiver.read_state do
        {:waiting, handle} ->
          _ = state.socket_backend.cancel(socket, handle)

        :idle ->
          :ok
      end
    end)

    :ok
  end

  defp clear_all_output_queues(state) do
    Enum.reduce(Map.keys(state.output_pads), state, fn radio_port, acc_state ->
      clear_output_queue(acc_state, radio_port)
    end)
  end

  defp drop_disabled_queues(state) do
    Enum.reduce(Map.keys(state.output_pads), state, fn radio_port, acc_state ->
      if MapSet.member?(acc_state.enabled_radio_ports, radio_port) do
        acc_state
      else
        clear_output_queue(acc_state, radio_port)
      end
    end)
  end

  defp clear_output_queue(state, radio_port) do
    case Map.get(state.output_pads, radio_port) do
      %{queue_len: queue_len} = output when queue_len > 0 ->
        state
        |> put_output(radio_port, %{output | queue: :queue.new(), queue_len: 0})
        |> add_counter(:dropped_packets, queue_len)

      _output ->
        state
    end
  end

  defp drop_output(state, radio_port) do
    state = clear_output_queue(state, radio_port)
    %{state | output_pads: Map.delete(state.output_pads, radio_port)}
  end

  defp put_output(state, radio_port, output) do
    %{state | output_pads: Map.put(state.output_pads, radio_port, output)}
  end

  defp first_receiver(state) do
    state.receivers
    |> Map.values()
    |> Enum.min_by(& &1.receiver_idx, fn -> nil end)
  end

  defp receiver_by_idx(state, receiver_idx) do
    Enum.find_value(state.receivers, fn {_socket, receiver} ->
      if receiver.receiver_idx == receiver_idx, do: receiver
    end)
  end

  defp increment_counter(state, counter), do: add_counter(state, counter, 1)

  defp add_counter(state, counter, amount) do
    update_in(state.counters[counter], &((&1 || 0) + amount))
  end
end
