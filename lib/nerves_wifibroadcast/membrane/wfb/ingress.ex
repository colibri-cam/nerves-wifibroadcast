defmodule NervesWifibroadcast.Membrane.WFB.Ingress do
  @moduledoc """
  WFB-specific ingress filter and channel router.

  It consumes 802.11 frames emitted by `Radio.Source`, applies the fixed ingress
  rules used by WFB, extracts `channel_id` from the synthetic MAC header, and
  routes packets to dynamic output pads keyed by `radio_port` for a single
  configured `link_id`.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.Pad
  alias NervesWifibroadcast.Membrane.Radio.StreamFormat, as: RadioStreamFormat
  alias NervesWifibroadcast.Membrane.WFB.Router
  alias NervesWifibroadcast.Membrane.WFB.StreamFormat

  @default_link_id Router.default_link_id()

  def_options(
    link_id: [spec: non_neg_integer(), default: @default_link_id],
    radio_port: [spec: non_neg_integer() | nil, default: nil],
    radio_ports: [spec: [non_neg_integer()], default: []],
    drop_bad_fcs?: [spec: boolean(), default: true],
    drop_self_injected?: [spec: boolean(), default: true],
    trim_fcs?: [spec: boolean(), default: true]
  )

  def_input_pad(:input,
    availability: :always,
    accepted_format: RadioStreamFormat,
    flow_control: :auto
  )

  def_output_pad(:output,
    availability: :on_request,
    accepted_format: StreamFormat,
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      counters: %{
        bad_fcs_drops: 0,
        invalid_wfb_header_drops: 0,
        passed_packets: 0,
        self_injected_drops: 0,
        short_frame_drops: 0,
        short_wfb_packet_drops: 0,
        unknown_packet_type_drops: 0,
        unknown_radio_port_drops: 0,
        unlinked_radio_port_drops: 0,
        wrong_link_id_drops: 0
      },
      drop_bad_fcs?: opts.drop_bad_fcs?,
      drop_self_injected?: opts.drop_self_injected?,
      enabled_radio_ports:
        Router.normalize_initial_radio_ports!(opts.radio_ports, opts.radio_port),
      input_end_of_stream?: false,
      input_stream_format: nil,
      link_id: Router.validate_link_id!(opts.link_id),
      output_pads: %{},
      trim_fcs?: opts.trim_fcs?
    }

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, radio_port) = pad, _ctx, state) do
    Router.validate_radio_port!(radio_port)

    next_state = put_in(state.output_pads[radio_port], pad)

    actions =
      maybe_output_stream_format(next_state.input_stream_format, pad, state.link_id, radio_port) ++
        maybe_end_of_stream(next_state.input_end_of_stream?, pad)

    {actions, next_state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, radio_port), _ctx, state) do
    {[], %{state | output_pads: Map.delete(state.output_pads, radio_port)}}
  end

  @impl true
  def handle_stream_format(:input, %RadioStreamFormat{} = stream_format, _ctx, state) do
    actions =
      Enum.map(state.output_pads, fn {radio_port, pad} ->
        {:stream_format, {pad, output_stream_format(state.link_id, radio_port, stream_format)}}
      end)

    {actions, %{state | input_stream_format: stream_format}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    actions = Enum.map(state.output_pads, fn {_channel_id, pad} -> {:end_of_stream, pad} end)
    {actions, %{state | input_end_of_stream?: true}}
  end

  @impl true
  def handle_parent_notification({:set_radio_ports, radio_ports}, _ctx, state) do
    {[], %{state | enabled_radio_ports: Router.normalize_radio_ports!(radio_ports)}}
  end

  def handle_parent_notification({:add_radio_port, radio_port}, _ctx, state) do
    radio_port = Router.validate_radio_port!(radio_port)
    {[], %{state | enabled_radio_ports: MapSet.put(state.enabled_radio_ports, radio_port)}}
  end

  def handle_parent_notification({:remove_radio_port, radio_port}, _ctx, state) do
    radio_port = Router.validate_radio_port!(radio_port)
    {[], %{state | enabled_radio_ports: MapSet.delete(state.enabled_radio_ports, radio_port)}}
  end

  def handle_parent_notification({:set_link_id, link_id}, _ctx, state) do
    link_id = Router.validate_link_id!(link_id)

    actions =
      Enum.map(state.output_pads, fn {radio_port, pad} ->
        case state.input_stream_format do
          %RadioStreamFormat{} = input_stream_format ->
            {:stream_format,
             {pad, output_stream_format(link_id, radio_port, input_stream_format)}}

          nil ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {actions, %{state | link_id: link_id}}
  end

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    case Router.route_buffer(buffer, state) do
      {:ok, radio_port, routed_buffer} ->
        case Map.fetch(state.output_pads, radio_port) do
          {:ok, pad} ->
            {[buffer: {pad, routed_buffer}], increment_counter(state, :passed_packets)}

          :error ->
            {[], increment_counter(state, :unlinked_radio_port_drops)}
        end

      {:drop, counter} ->
        {[], increment_counter(state, counter)}
    end
  end

  defp maybe_output_stream_format(nil, _pad, _link_id, _radio_port), do: []

  defp maybe_output_stream_format(
         %RadioStreamFormat{} = input_stream_format,
         pad,
         link_id,
         radio_port
       ) do
    [{:stream_format, {pad, output_stream_format(link_id, radio_port, input_stream_format)}}]
  end

  defp maybe_end_of_stream(false, _pad), do: []
  defp maybe_end_of_stream(true, pad), do: [{:end_of_stream, pad}]

  defp output_stream_format(link_id, radio_port, %RadioStreamFormat{interfaces: interfaces}) do
    Router.output_stream_format(link_id, radio_port, interfaces)
  end

  defp increment_counter(state, counter) do
    update_in(state.counters[counter], &((&1 || 0) + 1))
  end
end
