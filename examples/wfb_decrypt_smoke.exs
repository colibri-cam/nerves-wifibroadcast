defmodule NervesWifibroadcast.Examples.WfbDecryptSmoke do
  @moduledoc """
  IEx-friendly smoke test for the WFB decrypt stage.

  Load it with:

      iex -S mix -r examples/wfb_decrypt_smoke.exs

  Then start the pipeline with:

      NervesWifibroadcast.Examples.WfbDecryptSmoke.start(
        interfaces: ["wlan0mon"],
        radio_port: 4
      )
  """

  import Bitwise

  alias NervesWifibroadcast.Examples.WfbDecryptSmoke.Pipeline

  @pipeline_name Pipeline

  @spec start(keyword()) :: {:ok, pid(), pid()} | {:error, term()}
  def start(opts) when is_list(opts) do
    case Process.whereis(@pipeline_name) do
      nil ->
        opts = normalize_opts(opts)

        case Pipeline.start_link(opts) do
          {:ok, _supervisor, _pipeline} = ok ->
            print_started_banner(opts)
            ok

          {:error, _reason} = error ->
            error
        end

      pid ->
        {:error, {:already_started, pid}}
    end
  end

  @spec stop() :: :ok | {:error, :not_running} | {:error, :timeout}
  def stop do
    case Process.whereis(@pipeline_name) do
      nil ->
        {:error, :not_running}

      pid ->
        Membrane.Pipeline.terminate(pid, force?: true)
    end
  end

  @spec restart(keyword()) :: {:ok, pid(), pid()} | {:error, term()}
  def restart(opts) do
    _ = stop()
    start(opts)
  end

  @spec set_radio_ports([non_neg_integer()]) :: :ok | {:error, term()}
  def set_radio_ports(radio_ports) do
    case Process.whereis(@pipeline_name) do
      nil ->
        {:error, :not_running}

      pid ->
        radio_ports = normalize_runtime_radio_ports(radio_ports)
        Membrane.Pipeline.call(pid, {:set_radio_ports, radio_ports})
    end
  end

  @spec pipeline_pid() :: pid() | nil
  def pipeline_pid, do: Process.whereis(@pipeline_name)

  @spec usage() :: String.t()
  def usage do
    """
    Load the example:

        iex -S mix -r examples/wfb_decrypt_smoke.exs

    Start capture:

        NervesWifibroadcast.Examples.WfbDecryptSmoke.start(
          interfaces: [\"wlan0mon\"],
          radio_port: 4
        )

    Start capture for multiple linked radio ports:

        NervesWifibroadcast.Examples.WfbDecryptSmoke.start(
          interfaces: [\"wlan0mon\"],
          link_id: 0x7505d6,
          radio_ports: [4, 5],
          key_path: \"gs.key\",
          min_epoch: 0,
          print_first: 10,
          summary_every_ms: 1_000,
          max_preview_bytes: 48
        )

    Update enabled radio ports among the already linked outputs:

        NervesWifibroadcast.Examples.WfbDecryptSmoke.set_radio_ports([4])

    Stop capture:

        NervesWifibroadcast.Examples.WfbDecryptSmoke.stop()
    """
  end

  defp normalize_opts(opts) do
    interfaces = normalize_interfaces(opts)
    link_id = opts |> Keyword.get(:link_id, 7_669_206) |> normalize_link_id()
    key_path = Keyword.get(opts, :key_path, "gs.key")
    min_epoch = Keyword.get(opts, :min_epoch, 0)

    radio_ports =
      normalize_initial_radio_ports(
        Keyword.get(opts, :radio_ports, []),
        Keyword.get(opts, :radio_port)
      )

    cond do
      interfaces == [] ->
        raise ArgumentError,
              "expected :interfaces option, for example start(interfaces: [\"wlan0mon\"], radio_port: 4)"

      not is_binary(key_path) or key_path == "" ->
        raise ArgumentError, "expected :key_path to be a non-empty string"

      not is_integer(min_epoch) or min_epoch < 0 ->
        raise ArgumentError, "expected :min_epoch to be a non-negative integer"

      true ->
        opts
        |> Keyword.put(:interfaces, interfaces)
        |> Keyword.put(:link_id, link_id)
        |> Keyword.put(:key_path, key_path)
        |> Keyword.put(:min_epoch, min_epoch)
        |> Keyword.delete(:radio_port)
        |> Keyword.put(:radio_ports, radio_ports)
    end
  end

  defp normalize_runtime_radio_ports(radio_ports) when is_list(radio_ports) do
    radio_ports
    |> Enum.map(fn radio_port ->
      if is_integer(radio_port) and radio_port >= 0 and radio_port <= 0xFF do
        radio_port
      else
        raise ArgumentError,
              "expected radio_ports to be a list of non-negative 8-bit integers, got: #{inspect(radio_port)}"
      end
    end)
    |> Enum.uniq()
  end

  defp normalize_runtime_radio_ports(radio_ports) do
    raise ArgumentError,
          "expected :radio_ports to be a list, got: #{inspect(radio_ports)}"
  end

  defp normalize_interfaces(opts) do
    case Keyword.get(opts, :interfaces) do
      interfaces when is_list(interfaces) and interfaces != [] ->
        interfaces
        |> Enum.map(fn interface ->
          if is_binary(interface) and interface != "" do
            interface
          else
            raise ArgumentError,
                  "expected :interfaces to be a list of non-empty strings, got: #{inspect(interfaces)}"
          end
        end)
        |> Enum.uniq()

      _interfaces ->
        []
    end
  end

  defp normalize_initial_radio_ports(radio_ports, radio_port)
       when is_list(radio_ports) and (is_integer(radio_port) or is_nil(radio_port)) do
    radio_ports =
      case {radio_ports, radio_port} do
        {[], nil} -> [0]
        {[], port} -> [port]
        {ports, nil} -> ports
        {ports, port} -> [port | ports]
      end

    radio_ports
    |> normalize_runtime_radio_ports()
    |> case do
      [] ->
        raise ArgumentError,
              "expected at least one radio_port, for example radio_ports: [4]"

      ports ->
        ports
    end
  end

  defp normalize_initial_radio_ports(radio_ports, radio_port) do
    raise ArgumentError,
          "expected :radio_ports to be a list and :radio_port to be an integer or nil, got: #{inspect(radio_ports)} and #{inspect(radio_port)}"
  end

  defp normalize_link_id(link_id)
       when is_integer(link_id) and link_id >= 0 and link_id <= 0xFF_FFFF,
       do: link_id

  defp normalize_link_id(link_id) do
    raise ArgumentError,
          "expected link_id to be a non-negative 24-bit integer, got: #{inspect(link_id)}"
  end

  defp print_started_banner(opts) do
    radio_ports =
      opts |> Keyword.fetch!(:radio_ports) |> Enum.map_join(", ", &Integer.to_string/1)

    link_id = Keyword.fetch!(opts, :link_id)

    channel_ids =
      opts
      |> Keyword.fetch!(:radio_ports)
      |> Enum.map_join(", ", fn radio_port ->
        format_channel_id(make_channel_id(link_id, radio_port))
      end)

    IO.puts("[wfb_decrypt_smoke] started")
    IO.puts("[wfb_decrypt_smoke] interfaces=#{Enum.join(Keyword.fetch!(opts, :interfaces), ",")}")
    IO.puts("[wfb_decrypt_smoke] link_id=#{format_link_id(link_id)}")
    IO.puts("[wfb_decrypt_smoke] radio_ports=[#{radio_ports}]")
    IO.puts("[wfb_decrypt_smoke] channel_ids=[#{channel_ids}]")

    IO.puts(
      "[wfb_decrypt_smoke] key_path=#{Keyword.fetch!(opts, :key_path)} min_epoch=#{Keyword.fetch!(opts, :min_epoch)}"
    )

    IO.puts(
      "[wfb_decrypt_smoke] waiting for a valid session announcement before decrypted fragments appear"
    )

    IO.puts("[wfb_decrypt_smoke] stop with NervesWifibroadcast.Examples.WfbDecryptSmoke.stop()")
  end

  defp format_channel_id(channel_id) do
    "0x" <> String.pad_leading(Integer.to_string(channel_id, 16), 8, "0")
  end

  defp format_link_id(link_id) do
    "0x" <> String.pad_leading(Integer.to_string(link_id, 16), 6, "0")
  end

  defp make_channel_id(link_id, radio_port) do
    (link_id <<< 8) + radio_port
  end
end

defmodule NervesWifibroadcast.Examples.WfbDecryptSmoke.Pipeline do
  use Membrane.Pipeline

  require Membrane.Pad

  alias NervesWifibroadcast.Examples.WfbDecryptSmoke.ChannelSink
  alias NervesWifibroadcast.Membrane.Radio.Source
  alias NervesWifibroadcast.Membrane.WFB.Decrypt

  def start_link(opts) do
    Membrane.Pipeline.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def handle_init(_ctx, opts) do
    link_id = Keyword.fetch!(opts, :link_id)
    radio_ports = Keyword.fetch!(opts, :radio_ports)

    source_opts =
      Keyword.take(opts, [
        :interfaces,
        :frame_buffer_size,
        :max_read_burst,
        :max_queue_size,
        :link_id,
        :radio_port,
        :radio_ports
      ])

    decrypt_opts = Keyword.take(opts, [:key_path, :min_epoch])
    sink_opts = Keyword.take(opts, [:print_first, :summary_every_ms, :max_preview_bytes])

    spec =
      [child(:source, struct(Source, source_opts))] ++
        Enum.map(radio_ports, fn radio_port ->
          get_child(:source)
          |> via_out(Membrane.Pad.ref(:output, radio_port))
          |> child({:decrypt, radio_port}, struct(Decrypt, decrypt_opts))
          |> child(
            {:sink, radio_port},
            struct(
              ChannelSink,
              Keyword.merge(sink_opts, link_id: link_id, radio_port: radio_port)
            )
          )
        end)

    {[spec: spec], %{linked_radio_ports: MapSet.new(radio_ports)}}
  end

  @impl true
  def handle_call({:set_radio_ports, radio_ports}, _ctx, state) do
    requested = MapSet.new(radio_ports)

    unknown =
      MapSet.difference(requested, state.linked_radio_ports) |> MapSet.to_list() |> Enum.sort()

    if unknown == [] do
      {[notify_child: {:source, {:set_radio_ports, radio_ports}}, reply: :ok], state}
    else
      {[reply: {:error, {:unlinked_radio_ports, unknown}}], state}
    end
  end

  @impl true
  def handle_child_notification(notification, child, _ctx, state) do
    IO.puts("[wfb_decrypt_smoke] #{inspect(child)} notification: #{inspect(notification)}")
    {[], state}
  end

  @impl true
  def handle_child_playing(child, _ctx, state) do
    IO.puts("[wfb_decrypt_smoke] #{inspect(child)} is playing")
    {[], state}
  end
end

defmodule NervesWifibroadcast.Examples.WfbDecryptSmoke.ChannelSink do
  use Membrane.Sink

  import Bitwise

  alias Membrane.Time
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat
  alias NervesWifibroadcast.Radiotap
  alias NervesWifibroadcast.WFB.Session

  @fec_only_flag 0x01

  def_options(
    link_id: [spec: non_neg_integer(), default: 7_669_206],
    radio_port: [spec: non_neg_integer(), default: nil],
    print_first: [spec: non_neg_integer(), default: 10],
    summary_every_ms: [spec: pos_integer(), default: 1_000],
    max_preview_bytes: [spec: pos_integer(), default: 32]
  )

  def_input_pad(:input,
    accepted_format: StreamFormat,
    availability: :always,
    flow_control: :auto
  )

  @summary_timer :summary

  @impl true
  def handle_init(_ctx, opts) do
    now = System.monotonic_time(:millisecond)

    state = %{
      data_fragments: 0,
      fec_only_fragments: 0,
      last_fragment: nil,
      last_radiotap: nil,
      last_summary_at_ms: now,
      last_summary_bytes: 0,
      last_summary_data_fragments: 0,
      last_summary_fec_only_fragments: 0,
      last_summary_fragments: 0,
      link_id: opts.link_id,
      max_preview_bytes: opts.max_preview_bytes,
      plaintext_bytes: 0,
      preview_left: opts.print_first,
      radio_port: opts.radio_port,
      session_format: nil,
      total_fragments: 0,
      summary_every_ms: opts.summary_every_ms
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[start_timer: {@summary_timer, Time.milliseconds(state.summary_every_ms)}], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state) do
    IO.puts("[wfb_decrypt_smoke #{scope_label(state)}] stream started")
    {[], state}
  end

  @impl true
  def handle_stream_format(:input, %StreamFormat{} = format, _ctx, state) do
    IO.puts(
      "[wfb_decrypt_smoke #{scope_label(state)}] packet stream channel_id=#{format_channel_id(format.channel_id)}"
    )

    {[], %{state | link_id: format.link_id, radio_port: format.radio_port}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case get_in(buffer.metadata, [:wfb, :packet_type]) do
      :session -> handle_session_buffer(buffer, state)
      :data -> handle_data_buffer(buffer, state)
      _other -> {[], state}
    end
  end

  @impl true
  def handle_tick(@summary_timer, _ctx, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = max(now - state.last_summary_at_ms, 1)
    delta_fragments = state.total_fragments - state.last_summary_fragments
    delta_data_fragments = state.data_fragments - state.last_summary_data_fragments

    delta_fec_only_fragments =
      state.fec_only_fragments - state.last_summary_fec_only_fragments

    delta_bytes = state.plaintext_bytes - state.last_summary_bytes
    fragments_per_second = delta_fragments * 1_000 / elapsed_ms
    bytes_per_second = delta_bytes * 1_000 / elapsed_ms
    bits_per_second = bytes_per_second * 8

    IO.puts(
      "[wfb_decrypt_smoke #{scope_label(state)}] summary fragments=#{delta_fragments} data=#{delta_data_fragments} fec_only=#{delta_fec_only_fragments} rate=#{format_float(fragments_per_second)} frag/s bytes=#{delta_bytes} rate=#{format_byte_rate(bytes_per_second)} bitrate=#{format_bit_rate(bits_per_second)} #{format_session(state.session_format)} #{format_fragment(state.last_fragment)} #{format_radiotap(state.last_radiotap)}"
    )

    next_state = %{
      state
      | last_summary_at_ms: now,
        last_summary_bytes: state.plaintext_bytes,
        last_summary_data_fragments: state.data_fragments,
        last_summary_fec_only_fragments: state.fec_only_fragments,
        last_summary_fragments: state.total_fragments
    }

    {[], next_state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    IO.puts("[wfb_decrypt_smoke #{scope_label(state)}] end of stream")
    {[], state}
  end

  defp maybe_print_preview(%{preview_left: 0} = state, _buffer, _fragment), do: state

  defp maybe_print_preview(state, buffer, fragment) do
    IO.puts(
      "[wfb_decrypt_smoke #{scope_label(state)}] fragment=#{state.total_fragments} plaintext_bytes=#{byte_size(buffer.payload)} #{format_fragment(Map.put(fragment, :wfb, buffer.metadata.wfb))} #{format_radiotap(get_in(buffer.metadata, [:radio, :radiotap]))} preview=#{preview_fragment(fragment, state.max_preview_bytes)}"
    )

    %{state | preview_left: state.preview_left - 1}
  end

  defp handle_session_buffer(buffer, state) do
    case Session.parse(buffer.payload) do
      {:ok, session} ->
        IO.puts(
          "[wfb_decrypt_smoke #{scope_label(state)}] session epoch=#{session.epoch} fec=#{session.fec_type}:#{session.fec_k}/#{session.fec_n} channel_id=#{format_channel_id(session.channel_id)}"
        )

        next_state = %{
          state
          | last_radiotap: get_in(buffer.metadata, [:radio, :radiotap]),
            plaintext_bytes: state.plaintext_bytes + byte_size(buffer.payload),
            session_format: session
        }

        {[], next_state}

      {:error, :invalid_session_data} ->
        IO.puts("[wfb_decrypt_smoke #{scope_label(state)}] invalid session payload")
        {[], state}
    end
  end

  defp handle_data_buffer(buffer, state) do
    fragment = parse_fragment(buffer.payload, buffer.metadata.wfb, state.session_format)
    radiotap = get_in(buffer.metadata, [:radio, :radiotap])

    next_state = %{
      state
      | data_fragments: state.data_fragments + if(fragment.kind == :data, do: 1, else: 0),
        fec_only_fragments:
          state.fec_only_fragments + if(fragment.kind == :fec_only, do: 1, else: 0),
        last_fragment: Map.put(fragment, :wfb, buffer.metadata.wfb),
        last_radiotap: radiotap,
        plaintext_bytes: state.plaintext_bytes + byte_size(buffer.payload),
        total_fragments: state.total_fragments + 1
    }

    {[], maybe_print_preview(next_state, buffer, fragment)}
  end

  defp parse_fragment(payload, %{fragment_idx: fragment_idx}, %Session{fec_k: fec_k})
       when is_integer(fec_k) and is_integer(fragment_idx) do
    base = %{kind: :parity, packet_size: nil, payload: payload, flags: nil, truncated?: false}

    case payload do
      <<flags, packet_size::big-16, rest::binary>>
      when byte_size(rest) >= packet_size and fec_k > 0 ->
        if fragment_is_source?(fragment_idx, fec_k) do
          %{
            kind: if((flags &&& @fec_only_flag) != 0, do: :fec_only, else: :data),
            flags: flags,
            packet_size: packet_size,
            payload: binary_part(rest, 0, packet_size),
            truncated?: false
          }
        else
          base
        end

      <<flags, packet_size::big-16, rest::binary>> ->
        %{kind: :unknown, flags: flags, packet_size: packet_size, payload: rest, truncated?: true}

      _other ->
        %{kind: :unknown, packet_size: nil, payload: payload, flags: nil, truncated?: true}
    end
  end

  defp parse_fragment(payload, _wfb, _session_format) do
    %{kind: :unknown, packet_size: nil, payload: payload, flags: nil, truncated?: true}
  end

  defp fragment_is_source?(fragment_idx, fec_k), do: fragment_idx < fec_k

  defp preview_fragment(%{kind: kind, payload: payload}, max_preview_bytes)
       when kind in [:data, :fec_only] do
    hex_preview(payload, max_preview_bytes)
  end

  defp preview_fragment(%{payload: payload}, max_preview_bytes) do
    hex_preview(payload, max_preview_bytes)
  end

  defp format_session(nil), do: "session=waiting"

  defp format_session(%Session{} = session_format) do
    "session_epoch=#{session_format.epoch} fec=#{session_format.fec_type}:#{session_format.fec_k}/#{session_format.fec_n}"
  end

  defp format_fragment(nil), do: "fragment=unavailable"

  defp format_fragment(
         %{kind: kind, wfb: %{block_idx: block_idx, fragment_idx: fragment_idx}} = fragment
       ) do
    parts = ["block=#{block_idx}", "frag=#{fragment_idx}", "kind=#{kind}"]

    parts =
      case fragment do
        %{flags: flags, packet_size: packet_size}
        when is_integer(flags) and is_integer(packet_size) ->
          parts ++
            [
              "flags=0x" <> String.pad_leading(Integer.to_string(flags, 16), 2, "0"),
              "packet_size=#{packet_size}"
            ]

        _other ->
          parts
      end

    parts = if Map.get(fragment, :truncated?, false), do: parts ++ ["truncated"], else: parts
    Enum.join(parts, " ")
  end

  defp scope_label(%{link_id: link_id, radio_port: radio_port}) do
    "#{format_link_id(link_id)}/#{radio_port} (#{format_channel_id(make_channel_id(link_id, radio_port))})"
  end

  defp format_radiotap(nil), do: "radiotap=unavailable"

  defp format_radiotap(%Radiotap{} = radiotap) do
    observation = List.first(radiotap.observations)

    [
      radiotap.channel_freq && "freq=#{radiotap.channel_freq}",
      observation && observation.antenna != nil && "ant=#{observation.antenna}",
      observation && observation.rssi_dbm != nil && "rssi=#{observation.rssi_dbm}",
      observation && observation.noise_dbm != nil && "noise=#{observation.noise_dbm}",
      snr_fragment(observation),
      mcs_fragment(radiotap),
      vht_fragment(radiotap)
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "radiotap=empty"
      fields -> Enum.join(fields, " ")
    end
  end

  defp snr_fragment(%{rssi_dbm: rssi, noise_dbm: noise})
       when is_integer(rssi) and is_integer(noise),
       do: "snr=#{rssi - noise}"

  defp snr_fragment(_observation), do: nil

  defp mcs_fragment(%Radiotap{mcs: nil}), do: nil

  defp mcs_fragment(%Radiotap{mcs: mcs}) do
    [
      mcs.index != nil && "mcs=#{mcs.index}",
      "bw=#{mcs.bandwidth}",
      mcs.short_gi? != nil && "gi=#{if(mcs.short_gi?, do: "short", else: "long")}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp vht_fragment(%Radiotap{vht: nil}), do: nil

  defp vht_fragment(%Radiotap{vht: vht}) do
    [
      vht.mcs_index != nil && "vht_mcs=#{vht.mcs_index}",
      vht.nss != nil && "nss=#{vht.nss}",
      "vht_bw=#{vht.bandwidth}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp hex_preview(payload, max_bytes) do
    payload
    |> binary_part(0, min(byte_size(payload), max_bytes))
    |> :binary.bin_to_list()
    |> Enum.map_join(" ", fn byte -> Base.encode16(<<byte>>, case: :lower) end)
    |> maybe_append_ellipsis(payload, max_bytes)
  end

  defp maybe_append_ellipsis(preview, payload, max_bytes) when byte_size(payload) > max_bytes,
    do: preview <> " ..."

  defp maybe_append_ellipsis(preview, _payload, _max_bytes), do: preview

  defp format_channel_id(channel_id) do
    "0x" <> String.pad_leading(Integer.to_string(channel_id, 16), 8, "0")
  end

  defp format_link_id(link_id) do
    "0x" <> String.pad_leading(Integer.to_string(link_id, 16), 6, "0")
  end

  defp make_channel_id(link_id, radio_port) do
    (link_id <<< 8) + radio_port
  end

  defp format_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_byte_rate(bytes_per_second) when bytes_per_second < 1024 do
    format_float(bytes_per_second) <> " B/s"
  end

  defp format_byte_rate(bytes_per_second) when bytes_per_second < 1024 * 1024 do
    format_float(bytes_per_second / 1024) <> " KiB/s"
  end

  defp format_byte_rate(bytes_per_second) when bytes_per_second < 1024 * 1024 * 1024 do
    format_float(bytes_per_second / (1024 * 1024)) <> " MiB/s"
  end

  defp format_byte_rate(bytes_per_second) do
    format_float(bytes_per_second / (1024 * 1024 * 1024)) <> " GiB/s"
  end

  defp format_bit_rate(bits_per_second) when bits_per_second < 1000 do
    format_float(bits_per_second) <> " b/s"
  end

  defp format_bit_rate(bits_per_second) when bits_per_second < 1000 * 1000 do
    format_float(bits_per_second / 1000) <> " kb/s"
  end

  defp format_bit_rate(bits_per_second) when bits_per_second < 1000 * 1000 * 1000 do
    format_float(bits_per_second / (1000 * 1000)) <> " Mb/s"
  end

  defp format_bit_rate(bits_per_second) do
    format_float(bits_per_second / (1000 * 1000 * 1000)) <> " Gb/s"
  end
end

IO.puts(NervesWifibroadcast.Examples.WfbDecryptSmoke.usage())
