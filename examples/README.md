# Examples

## Radio Smoke Test

`examples/radio_smoke.exs` provides a tiny Membrane pipeline for smoke-testing
the pure Elixir radio source on one or more real monitor-mode interfaces.

Load it in IEx:

```bash
sudo iex -S mix -r examples/radio_smoke.exs
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
NervesWifibroadcast.set_card_monitor_mode("wlan0")
```

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

`examples/wfb_ingress_smoke.exs` smoke-tests the next stage of the pipeline:
`Radio.Source -> WFB.Ingress -> per-radio-port sinks`.

Load it in IEx:

```bash
sudo iex -S mix -r examples/wfb_ingress_smoke.exs
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

Packets for unknown radio ports or the wrong `link_id` are dropped by `NervesWifibroadcast.Membrane.WFB.Ingress`.

## WFB Decrypt Smoke Test

`examples/wfb_decrypt_smoke.exs` smoke-tests the decrypt stage of the pipeline:
`Radio.Source -> WFB.Ingress -> WFB.Decrypt -> per-radio-port sinks`.

Load it in IEx:

```bash
sudo iex -S mix -r examples/wfb_decrypt_smoke.exs
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
`Radio.Source -> WFB.Ingress -> WFB.Decrypt -> WFB.ReorderFec -> per-radio-port sinks`.

Load it in IEx:

```bash
sudo iex -S mix -r examples/wfb_reorder_fec_smoke.exs
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
