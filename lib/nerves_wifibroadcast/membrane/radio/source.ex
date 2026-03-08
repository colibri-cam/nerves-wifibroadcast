defmodule NervesWifibroadcast.Membrane.Radio.Source do
  @moduledoc """
  Membrane source for monitor-mode radio capture over `AF_PACKET`.

  The source owns one Linux packet socket per interface and drives them through
  OTP `:socket` async readiness notifications on Linux.
  """

  use Membrane.Source

  alias Membrane.Buffer
  alias NervesWifibroadcast.Membrane.Radio.StreamFormat
  alias NervesWifibroadcast.Radio.AFPacket
  alias NervesWifibroadcast.Radiotap.Parser

  @max_interfaces 64

  def_options(
    interfaces: [spec: [String.t()], default: []],
    capture_ts_fun: [spec: (-> integer()), default: &System.monotonic_time/0],
    frame_buffer_size: [spec: pos_integer(), default: 4096],
    max_read_burst: [spec: pos_integer(), default: 32],
    max_queue_size: [spec: pos_integer(), default: 256],
    open_socket?: [spec: boolean(), default: true],
    parser: [spec: module(), default: Parser],
    socket_backend: [spec: module(), default: AFPacket]
  )

  def_output_pad(:output,
    accepted_format: StreamFormat,
    availability: :always,
    flow_control: :manual,
    demand_unit: :buffers
  )

  @impl true
  def handle_init(_ctx, opts) do
    interfaces = normalize_interfaces!(opts.interfaces)

    state = %{
      available_demand: 0,
      capture_ts_fun: opts.capture_ts_fun,
      dropped_packets: 0,
      frame_buffer_size: opts.frame_buffer_size,
      interfaces: interfaces,
      malformed_packets: 0,
      max_read_burst: opts.max_read_burst,
      max_queue_size: opts.max_queue_size,
      open_socket?: opts.open_socket?,
      parser: opts.parser,
      queue: :queue.new(),
      receivers: %{},
      socket_backend: opts.socket_backend,
      truncated_packets: 0
    }

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, %{open_socket?: false} = state), do: {[], state}

  def handle_setup(_ctx, state) do
    case open_receivers(state.interfaces, state.socket_backend) do
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
    {read_actions, state} = maybe_start_reads(state)
    {buffer_actions, state} = drain_queue(state)

    actions = [
      {:stream_format, {:output, %StreamFormat{interfaces: state.interfaces}}}
      | read_actions ++ buffer_actions
    ]

    {actions, state}
  end

  @impl true
  def handle_demand(_pad, size, :buffers, _ctx, state) do
    state = %{state | available_demand: state.available_demand + size}
    drain_queue(state)
  end

  @impl true
  def handle_info({:radio_packet, packet}, _ctx, state) do
    case first_receiver(state) do
      nil -> {[], state}
      receiver -> state |> ingest_packet(packet, receiver, %{}) |> drain_queue()
    end
  end

  def handle_info({:radio_packet, receiver_idx, packet}, _ctx, state)
      when is_integer(receiver_idx) do
    case receiver_by_idx(state, receiver_idx) do
      nil -> {[], state}
      receiver -> state |> ingest_packet(packet, receiver, %{}) |> drain_queue()
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

  defp open_receivers(interfaces, socket_backend) do
    Enum.reduce_while(Enum.with_index(interfaces), {:ok, %{}}, fn {interface, receiver_idx},
                                                                  {:ok, receivers} ->
      case socket_backend.open(interface: interface) do
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
    {buffer_actions, state} = drain_queue(state)
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
        %{state | truncated_packets: state.truncated_packets + 1}

      {:error, :invalid_recvmsg} ->
        %{state | malformed_packets: state.malformed_packets + 1}
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
        enqueue_buffer(state, buffer)

      {:error, _reason} ->
        %{state | malformed_packets: state.malformed_packets + 1}
    end
  end

  defp enqueue_buffer(state, buffer) do
    if :queue.len(state.queue) >= state.max_queue_size do
      %{state | dropped_packets: state.dropped_packets + 1}
    else
      %{state | queue: :queue.in(buffer, state.queue)}
    end
  end

  defp drain_queue(state), do: drain_queue(state, [])

  defp drain_queue(%{available_demand: 0} = state, actions), do: {Enum.reverse(actions), state}

  defp drain_queue(state, actions) do
    case :queue.out(state.queue) do
      {{:value, buffer}, queue} ->
        next_state = %{state | available_demand: state.available_demand - 1, queue: queue}
        drain_queue(next_state, [{:buffer, {:output, buffer}} | actions])

      {:empty, _queue} ->
        {Enum.reverse(actions), state}
    end
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
end
