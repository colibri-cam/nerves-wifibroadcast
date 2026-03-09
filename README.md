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
- `NervesWifibroadcast.Membrane.WFB.Decrypt` decrypts WFB session/data packet payloads while preserving the packet contract
- `NervesWifibroadcast.Membrane.WFB.FecDecoder` is the preferred RX FEC stage name; it accepts session/data packets, performs FEC recovery, and emits ordered source shards

## Current TX pipeline work

The TX side now has the matching Membrane stages needed to build a working WFB
transmit path:

- `NervesWifibroadcast.Membrane.WFB.PayloadWrap` wraps packetized payloads into `wpacket_hdr_t <> payload`
- `NervesWifibroadcast.Membrane.WFB.FecEncoder` groups wrapped payloads into source/parity shards and emits session/data packets
- `NervesWifibroadcast.Membrane.WFB.Encrypt` optionally encrypts the session/data packet payloads without changing the packet contract
- `NervesWifibroadcast.Membrane.Radio.Sink` fans in multiple `radio_port` branches, adds radiotap + 802.11 + outer WFB headers, and injects frames through `AF_PACKET`

`Radio.Sink` defaults to low-latency injection with qdisc bypass enabled. If you
want Linux traffic control to classify TX packets, set `use_qdisc?: true` and a
`fwmark_base`. In that mode:

- source data packets and session packets use `fwmark_base`
- parity packets use `fwmark_base + 1`

See `examples/README.md` for a TX pipeline snippet.

## Smoke examples

Runnable smoke examples live in `examples/README.md`:

- `examples/radio_smoke.exs`
- `examples/wfb_ingress_smoke.exs`
- `examples/wfb_decrypt_smoke.exs`
- `examples/wfb_reorder_fec_smoke.exs`

These are intended for step-by-step validation on real hardware while the RX
pipeline is being built out.
