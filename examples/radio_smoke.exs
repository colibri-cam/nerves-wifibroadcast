defmodule NervesWifibroadcast.Examples.RadioSmoke do
  @moduledoc """
  Minimal IEx-friendly smoke test for the pure Elixir radio source.

  Load it with:

      iex -S mix -r examples/radio_smoke.exs

  Then start the pipeline with:

      NervesWifibroadcast.Examples.RadioSmoke.start(interfaces: ["wlan0mon"])
  """

  alias NervesWifibroadcast.Examples.RadioSmoke.Pipeline

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

  @spec pipeline_pid() :: pid() | nil
  def pipeline_pid, do: Process.whereis(@pipeline_name)

  @spec usage() :: String.t()
  def usage do
    """
    Load the example:

        sudo iex -S mix -r examples/radio_smoke.exs

    Start capture:

        NervesWifibroadcast.Examples.RadioSmoke.start(interfaces: [\"wlan0mon\"])

    Optional tuning:

        NervesWifibroadcast.Examples.RadioSmoke.start(
          interfaces: [\"wlan0mon\"],
          frame_buffer_size: 8192,
          max_read_burst: 64,
          max_queue_size: 512,
          print_first: 20,
          summary_every_ms: 1_000,
          max_preview_bytes: 48
        )

    Stop capture:

        NervesWifibroadcast.Examples.RadioSmoke.stop()
    """
  end

  defp normalize_opts(opts) do
    interfaces = Keyword.get(opts, :interfaces)

    if is_list(interfaces) and interfaces != [] and
         Enum.all?(interfaces, &(is_binary(&1) and &1 != "")) do
      Keyword.put(opts, :interfaces, Enum.uniq(interfaces))
    else
      raise ArgumentError,
            "expected :interfaces option, for example start(interfaces: [\"wlan0mon\"])"
    end
  end

  defp print_started_banner(opts) do
    IO.puts("[radio_smoke] started")
    IO.puts("[radio_smoke] interfaces=#{Enum.join(Keyword.fetch!(opts, :interfaces), ",")}")
    IO.puts("[radio_smoke] stop with NervesWifibroadcast.Examples.RadioSmoke.stop()")
  end
end

defmodule NervesWifibroadcast.Examples.RadioSmoke.Pipeline do
  use Membrane.Pipeline

  alias NervesWifibroadcast.Examples.RadioSmoke.Sink
  alias NervesWifibroadcast.Membrane.Radio.Source

  def start_link(opts) do
    Membrane.Pipeline.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def handle_init(_ctx, opts) do
    source_opts =
      Keyword.take(opts, [:interfaces, :frame_buffer_size, :max_read_burst, :max_queue_size])

    sink_opts = Keyword.take(opts, [:print_first, :summary_every_ms, :max_preview_bytes])

    spec =
      child(:source, struct(Source, source_opts))
      |> child(:sink, struct(Sink, sink_opts))

    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification(notification, child, _ctx, state) do
    IO.puts("[radio_smoke] #{inspect(child)} notification: #{inspect(notification)}")
    {[], state}
  end

  @impl true
  def handle_child_playing(child, _ctx, state) do
    IO.puts("[radio_smoke] #{inspect(child)} is playing")
    {[], state}
  end
end

defmodule NervesWifibroadcast.Examples.RadioSmoke.Sink do
  use Membrane.Sink

  alias Membrane.Time
  alias NervesWifibroadcast.Membrane.Radio.StreamFormat
  alias NervesWifibroadcast.Radiotap

  def_options(
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
      ampdu_crc_error_packets: 0,
      bad_fcs_packets: 0,
      bad_plcp_packets: 0,
      last_radiotap: nil,
      last_summary_ampdu_crc_error_packets: 0,
      last_summary_at_ms: now,
      last_summary_bad_fcs_packets: 0,
      last_summary_bad_plcp_packets: 0,
      last_summary_bytes: 0,
      last_summary_packets: 0,
      max_preview_bytes: opts.max_preview_bytes,
      packets: 0,
      payload_bytes: 0,
      preview_left: opts.print_first,
      summary_every_ms: opts.summary_every_ms
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    actions = [start_timer: {@summary_timer, Time.milliseconds(state.summary_every_ms)}]
    {actions, state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state) do
    IO.puts("[radio_smoke] stream started")
    {[], state}
  end

  @impl true
  def handle_stream_format(:input, %StreamFormat{} = format, _ctx, state) do
    IO.puts(
      "[radio_smoke] stream format interfaces=#{Enum.join(format.interfaces, ",")} link=#{format.link_layer} radiotap=#{format.radiotap?}"
    )

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    radiotap = get_in(buffer.metadata, [:radio, :radiotap])

    state = %{
      state
      | ampdu_crc_error_packets:
          state.ampdu_crc_error_packets + if(ampdu_crc_error?(radiotap), do: 1, else: 0),
        bad_fcs_packets: state.bad_fcs_packets + if(bad_fcs?(radiotap), do: 1, else: 0),
        bad_plcp_packets: state.bad_plcp_packets + if(bad_plcp?(radiotap), do: 1, else: 0),
        last_radiotap: radiotap,
        packets: state.packets + 1,
        payload_bytes: state.payload_bytes + byte_size(buffer.payload)
    }

    state = maybe_print_preview(state, buffer)
    {[], state}
  end

  @impl true
  def handle_tick(@summary_timer, _ctx, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = max(now - state.last_summary_at_ms, 1)
    delta_packets = state.packets - state.last_summary_packets
    delta_bytes = state.payload_bytes - state.last_summary_bytes
    delta_bad_fcs = state.bad_fcs_packets - state.last_summary_bad_fcs_packets
    delta_bad_plcp = state.bad_plcp_packets - state.last_summary_bad_plcp_packets

    delta_ampdu_crc_error =
      state.ampdu_crc_error_packets - state.last_summary_ampdu_crc_error_packets

    packets_per_second = delta_packets * 1_000 / elapsed_ms
    bytes_per_second = delta_bytes * 1_000 / elapsed_ms
    bits_per_second = bytes_per_second * 8

    IO.puts(
      "[radio_smoke] summary packets=#{delta_packets} rate=#{format_float(packets_per_second)} pkt/s bytes=#{delta_bytes} rate=#{format_byte_rate(bytes_per_second)} bitrate=#{format_bit_rate(bits_per_second)} bad_fcs=#{delta_bad_fcs} bad_plcp=#{delta_bad_plcp} ampdu_crc_err=#{delta_ampdu_crc_error} #{format_radiotap(state.last_radiotap)}"
    )

    next_state = %{
      state
      | last_summary_ampdu_crc_error_packets: state.ampdu_crc_error_packets,
        last_summary_at_ms: now,
        last_summary_bad_fcs_packets: state.bad_fcs_packets,
        last_summary_bad_plcp_packets: state.bad_plcp_packets,
        last_summary_bytes: state.payload_bytes,
        last_summary_packets: state.packets
    }

    {[], next_state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    IO.puts("[radio_smoke] end of stream")
    {[], state}
  end

  defp maybe_print_preview(%{preview_left: 0} = state, _buffer), do: state

  defp maybe_print_preview(state, buffer) do
    packet_no = state.packets
    preview = hex_preview(buffer.payload, state.max_preview_bytes)
    radiotap = format_radiotap(get_in(buffer.metadata, [:radio, :radiotap]))

    IO.puts(
      "[radio_smoke] packet=#{packet_no} payload_bytes=#{byte_size(buffer.payload)} #{radiotap} preview=#{preview}"
    )

    %{state | preview_left: state.preview_left - 1}
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
      observation && observation.rssi_db != nil && "sig_db=#{observation.rssi_db}",
      observation && observation.noise_db != nil && "noise_db=#{observation.noise_db}",
      rate_fragment(radiotap),
      mcs_fragment(radiotap),
      vht_fragment(radiotap),
      quality_fragment(radiotap),
      ampdu_fragment(radiotap)
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

  defp rate_fragment(%Radiotap{rate: nil}), do: nil
  defp rate_fragment(%Radiotap{rate: %{mbps: mbps}}), do: "rate=#{format_float(mbps)}"

  defp quality_fragment(%Radiotap{} = radiotap) do
    [
      bad_fcs?(radiotap) && "bad_fcs",
      bad_plcp?(radiotap) && "bad_plcp"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      flags -> Enum.join(flags, ",")
    end
  end

  defp ampdu_fragment(%Radiotap{ampdu_status: nil}), do: nil

  defp ampdu_fragment(%Radiotap{ampdu_status: ampdu_status}) do
    status_bits =
      [
        ampdu_status.last? && "last",
        ampdu_status.delimiter_crc_error? && "delim_crc_err"
      ]
      |> Enum.filter(& &1)

    case status_bits do
      [] -> "ampdu"
      bits -> "ampdu=" <> Enum.join(bits, ",")
    end
  end

  defp mcs_fragment(%Radiotap{mcs: nil}), do: nil

  defp mcs_fragment(%Radiotap{mcs: mcs}) do
    [
      mcs.index != nil && "mcs=#{mcs.index}",
      "bw=#{mcs.bandwidth}",
      mcs.short_gi? != nil && "gi=#{if(mcs.short_gi?, do: "short", else: "long")}",
      mcs.fec && "fec=#{mcs.fec}",
      mcs.format && "fmt=#{mcs.format}",
      mcs.stbc_streams not in [nil, 0] && "stbc=#{mcs.stbc_streams}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp vht_fragment(%Radiotap{vht: nil}), do: nil

  defp vht_fragment(%Radiotap{vht: vht}) do
    [
      vht.mcs_index != nil && "vht_mcs=#{vht.mcs_index}",
      vht.nss != nil && "nss=#{vht.nss}",
      "vht_bw=#{vht.bandwidth}",
      vht.short_gi? != nil && "vht_gi=#{if(vht.short_gi?, do: "short", else: "long")}",
      vht.stbc? && "vht_stbc",
      vht.beamformed? && "bf",
      vht.users != [] && vht_ldpc?(vht.users) && "ldpc"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp vht_ldpc?(users), do: Enum.any?(users, & &1.ldpc?)

  defp bad_fcs?(%Radiotap{flags: %{bad_fcs?: true}}), do: true
  defp bad_fcs?(%Radiotap{}), do: false
  defp bad_fcs?(_radiotap), do: false

  defp bad_plcp?(%Radiotap{rx_flags: %{bad_plcp?: true}}), do: true
  defp bad_plcp?(%Radiotap{}), do: false
  defp bad_plcp?(_radiotap), do: false

  defp ampdu_crc_error?(%Radiotap{ampdu_status: %{delimiter_crc_error?: true}}), do: true
  defp ampdu_crc_error?(%Radiotap{}), do: false
  defp ampdu_crc_error?(_radiotap), do: false

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

IO.puts(NervesWifibroadcast.Examples.RadioSmoke.usage())
