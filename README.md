# NervesWfbNg

Elixir-first work on the `wifibroadcast` RX/TX stack for Nerves, with the RX
pipeline being rebuilt as Membrane elements and native code kept focused on the
hot crypto and FEC paths.

## Current RX pipeline work

The RX side is being implemented incrementally and smoke-tested on real monitor
mode hardware:

- `NervesWifibroadcast.Membrane.Radio.Source` captures monitor-mode traffic in pure Elixir via `AF_PACKET`, applies WFB ingress filtering, and routes packets by `link_id` and `radio_port`
- `NervesWifibroadcast.Radiotap.Parser` decodes radiotap metadata into `buffer.metadata`
- `NervesWifibroadcast.Membrane.WFB.Ingress` remains available as a compatibility filter/router for pre-routed 802.11 frames
- `NervesWifibroadcast.Membrane.WFB.Decrypt` accepts session announcements and decrypts WFB shards
- `NervesWifibroadcast.Membrane.WFB.ReorderFec` reorders fragments, performs FEC recovery, and emits ordered source shards

## Smoke examples

Runnable smoke examples live in `examples/README.md`:

- `examples/radio_smoke.exs`
- `examples/wfb_ingress_smoke.exs`
- `examples/wfb_decrypt_smoke.exs`
- `examples/wfb_reorder_fec_smoke.exs`

These are intended for step-by-step validation on real hardware while the RX
pipeline is being built out.
