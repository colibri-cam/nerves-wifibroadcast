# Examples

These examples assume the `beam.smp` capability setup described in `README.md`.
If you have not granted those capabilities, run the same commands with `sudo`
instead.

## Generate Keys

The encrypted examples expect `drone.key` for TX and `gs.key` for RX. Generate
them from IEx:

```bash
iex -S mix
```

```elixir
NervesWifibroadcast.generate_wfb_keys()
```

If you want password-derived keys that match `wfb-ng`, pass the shared password:

```elixir
NervesWifibroadcast.generate_wfb_keys("shared-password")
```

## TX Pipeline Snippet

There is not a full TX smoke script yet, but the current TX Membrane shape is:

```elixir
alias Membrane.Pad
alias NervesWifibroadcast.Membrane.Radio.Sink
alias NervesWifibroadcast.Membrane.WFB.Encrypt
alias NervesWifibroadcast.Membrane.WFB.FecEncoder
alias NervesWifibroadcast.Membrane.WFB.PayloadWrap

children = [
  payload_wrap_4: %PayloadWrap{link_id: 0x7505D6, radio_port: 4},
  fec_encoder_4: %FecEncoder{k: 8, n: 12, fec_timeout_ms: 20},
  encrypt_4: %Encrypt{key_path: "drone.key"},
  radio_sink: %Sink{
    interfaces: ["wlan0mon", "wlan1mon"],
    bandwidth: 20,
    mcs_index: 1,
    short_gi: :long
  }
]

links = [
  link(:payload_wrap_4)
  |> to(:fec_encoder_4)
  |> to(:encrypt_4)
  |> via_in(Pad.ref(:input, 4))
  |> to(:radio_sink)
]
```

By default `Radio.Sink` opens TX sockets with qdisc bypass enabled for the
lowest-latency path.

If you want Linux `tc` / routing rules to classify TX packets, enable qdisc and
set a mark base:

```elixir
%Sink{
  interfaces: ["wlan0mon", "wlan1mon"],
  bandwidth: 20,
  mcs_index: 3,
  short_gi: :short,
  use_qdisc?: true,
  fwmark_base: 100
}
```

Current mark policy in `Radio.Sink`:

- source data packets and session packets use `fwmark_base`
- parity packets use `fwmark_base + 1`

Runtime PHY updates still go through the sink:

```elixir
Membrane.Pipeline.notify_child(pipeline, :radio_sink, {:set_radio_config, %{mcs_index: 5, short_gi: :short}})
```

## Radio Smoke Test

`examples/radio_smoke.exs` provides a tiny Membrane pipeline for smoke-testing
the pure Elixir radio source on one or more real monitor-mode interfaces.

Load it in IEx:

```bash
  iex -S mix -r examples/radio_smoke.exs
```

Start the pipeline:

```elixir
NervesWifibroadcast.Examples.RadioSmoke.start(interfaces: ["wlan0mon"])
```

Stop it:

```elixir
NervesWifibroadcast.Examples.RadioSmoke.stop()
```

The interface must already be up and in monitor mode. If needed, you can switch
an interface first from IEx:

```elixir
NervesWifibroadcast.Radio.Control.set_region("BO")
NervesWifibroadcast.set_card_monitor_mode("wlan0")
NervesWifibroadcast.Radio.Control.set_frequency("wlan0", 5825, 20)
NervesWifibroadcast.set_card_tx_power("wlan0", :rtl8812au, 30)
```

Use `:rtl8812eu` instead of `:rtl8812au` for 8812EU cards. The TX power helper
follows the `wfb-ng` driver quirk described in `master.cfg`.

`Radio.Control` is netlink-only now, so monitor mode, channel/frequency, and
TX power changes work through the BEAM process itself. See `README.md` for the
`setcap` details if you want to run these examples without `sudo`.

The example prints:

- child lifecycle notifications from the pipeline
- the first few captured payload previews
- a periodic summary with packet and byte rates
- selected parsed radiotap metadata such as frequency, antenna, RSSI, noise,
  and MCS/VHT information when present

Useful options:

```elixir
NervesWifibroadcast.Examples.RadioSmoke.start(
  interfaces: ["wlan0mon"],
  frame_buffer_size: 8192,
  max_read_burst: 64,
  max_queue_size: 512,
  print_first: 20,
  summary_every_ms: 1_000,
  max_preview_bytes: 48
)
```

You usually need root or `CAP_NET_RAW` for `AF_PACKET` capture.

## WFB Ingress Smoke Test

`examples/wfb_ingress_smoke.exs` smoke-tests WFB-specific routing directly in the
source:
`Radio.Source -> per-radio-port sinks`.

Load it in IEx:

```bash
  iex -S mix -r examples/wfb_ingress_smoke.exs
```

Start the pipeline:

```elixir
NervesWifibroadcast.Examples.WfbIngressSmoke.start(
  interfaces: ["wlan0mon"],
  radio_port: 4
)
```

Enable only a subset of the already linked radio ports at runtime:

```elixir
NervesWifibroadcast.Examples.WfbIngressSmoke.set_radio_ports([4])
```

Stop it:

```elixir
NervesWifibroadcast.Examples.WfbIngressSmoke.stop()
```

The example prints:

- ingress child notifications from the pipeline
- first packet previews per configured `radio_port`
- periodic summaries per radio port with packet type counts
- parsed WFB metadata like `block_idx`, `fragment_idx`, and session nonce preview
- selected radiotap metadata for the last packet seen on that radio port

Useful options:

```elixir
NervesWifibroadcast.Examples.WfbIngressSmoke.start(
  interfaces: ["wlan0mon"],
  link_id: 0x7505d6,
  radio_ports: [4, 5],
  frame_buffer_size: 8192,
  max_read_burst: 64,
  max_queue_size: 512,
  print_first: 10,
  summary_every_ms: 1_000,
  max_preview_bytes: 48
)
```

Packets for unknown radio ports or the wrong `link_id` are dropped directly by `NervesWifibroadcast.Membrane.Radio.Source`.

## WFB Decrypt Smoke Test

`examples/wfb_decrypt_smoke.exs` smoke-tests the decrypt stage of the pipeline:
`Radio.Source -> WFB.Decrypt -> per-radio-port sinks`.

Load it in IEx:

```bash
  iex -S mix -r examples/wfb_decrypt_smoke.exs
```

Start the pipeline:

```elixir
NervesWifibroadcast.Examples.WfbDecryptSmoke.start(
  interfaces: ["wlan0mon"],
  radio_port: 4
)
```

Enable only a subset of the already linked radio ports at runtime:

```elixir
NervesWifibroadcast.Examples.WfbDecryptSmoke.set_radio_ports([4])
```

Stop it:

```elixir
NervesWifibroadcast.Examples.WfbDecryptSmoke.stop()
```

The example prints:

- decrypt pipeline child notifications from the pipeline
- accepted session updates with `epoch` and `fec_k/fec_n`
- first decrypted fragment previews per configured `radio_port`
- periodic summaries with decrypted fragment counts and plaintext throughput
- selected decrypted fragment metadata like `block_idx`, `fragment_idx`, `flags`, and `packet_size`
- selected radiotap metadata for the last decrypted fragment seen on that radio port

Useful options:

```elixir
NervesWifibroadcast.Examples.WfbDecryptSmoke.start(
  interfaces: ["wlan0mon"],
  link_id: 0x7505d6,
  radio_ports: [4, 5],
  key_path: "gs.key",
  min_epoch: 0,
  frame_buffer_size: 8192,
  max_read_burst: 64,
  max_queue_size: 512,
  print_first: 10,
  summary_every_ms: 1_000,
  max_preview_bytes: 48
)
```

The decrypt stage waits for a valid session announcement before decrypted data
fragments begin to flow.

## WFB Reorder/FEC Smoke Test

`examples/wfb_reorder_fec_smoke.exs` smoke-tests the next stage of the RX
pipeline:
`Radio.Source -> WFB.Decrypt -> WFB.FecDecoder -> per-radio-port sinks`.

Load it in IEx:

```bash
  iex -S mix -r examples/wfb_reorder_fec_smoke.exs
```

Start the pipeline:

```elixir
NervesWifibroadcast.Examples.WfbReorderFecSmoke.start(
  interfaces: ["wlan0mon"],
  radio_port: 4
)
```

Enable only a subset of the already linked radio ports at runtime:

```elixir
NervesWifibroadcast.Examples.WfbReorderFecSmoke.set_radio_ports([4])
```

Stop it:

```elixir
NervesWifibroadcast.Examples.WfbReorderFecSmoke.stop()
```

The example prints:

- reorder/FEC pipeline child notifications from the pipeline
- accepted decrypt session updates before ordered shards start flowing
- first ordered shard previews per configured `radio_port`
- periodic summaries with ordered shard counts, recovered shard counts, and payload throughput
- selected ordered shard metadata like `block_idx`, `fragment_idx`, `ordered_seq`, `flags`, and `packet_size`
- selected radiotap metadata for the last ordered shard seen on that radio port

Useful options:

```elixir
NervesWifibroadcast.Examples.WfbReorderFecSmoke.start(
  interfaces: ["wlan0mon"],
  link_id: 0x7505d6,
  radio_ports: [4, 5],
  key_path: "gs.key",
  min_epoch: 0,
  ring_size: 40,
  print_first: 10,
  summary_every_ms: 1_000,
  max_preview_bytes: 48
)
```

The reorder/FEC stage emits only ordered source shards. FEC-only shards stay
internal unless they are needed to recover missing source shards.
