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

## WFB Keys

`NervesWifibroadcast.generate_wfb_keys/1` writes the standard `drone.key` and
`gs.key` files in the current working directory.

Generate random keys:

```bash
iex -S mix
```

```elixir
NervesWifibroadcast.generate_wfb_keys()
```

Generate password-derived keys that stay compatible with `wfb-ng`:

```elixir
NervesWifibroadcast.generate_wfb_keys("shared-password")
```

The resulting files use the same layout expected by the `Encrypt` and `Decrypt`
stages.

## Run Without `sudo`

`NervesWifibroadcast.Radio.Control` uses pure-Elixir rtnetlink and `nl80211`
calls.

If you want to switch monitor mode, change channel or frequency, set TX power,
and use raw packet RX/TX without starting the whole VM as root, grant Linux
file capabilities to the actual Erlang VM executable: `beam.smp`.

What the capabilities do:

- `cap_net_admin` lets the BEAM perform the network-admin operations used here, including link up/down, monitor mode, regulatory changes, channel or frequency changes, TX power changes, and socket options such as `SO_MARK`
- `cap_net_raw` lets the BEAM open raw and `AF_PACKET` sockets for radio RX/TX

What `setcap` changes:

- `setcap` writes file capabilities onto the `beam.smp` executable itself; it does not modify this project
- every `iex`, `mix`, release, or Erlang node started from that exact `beam.smp` path gets those capabilities when it starts
- any code running inside those VMs can use them; the capabilities are not scoped to `nerves-wifibroadcast`
- if you use the same Erlang installation for unrelated work, those BEAM workloads also get the same network privileges
- other Erlang installations are unaffected unless you run `setcap` on their `beam.smp` too

For the smallest blast radius, prefer a dedicated Erlang installation or
runtime for radio work.

Grant the capabilities once per Erlang installation:

### Bash

```bash
erl_path="$(realpath "$(which erl)")"
beam_path="$(realpath "$(dirname "$erl_path")"/../erts-*/bin/beam.smp)"
sudo setcap 'cap_net_admin,cap_net_raw+ep' "$beam_path"
getcap "$beam_path"
```

### Zsh

```zsh
erl_path="$(realpath "$(which erl)")"
beam_path="$(realpath "$(dirname "$erl_path")"/../erts-*/bin/beam.smp)"
sudo setcap 'cap_net_admin,cap_net_raw+ep' "$beam_path"
getcap "$beam_path"
```

### Fish

```fish
set erl_path (realpath (which erl))
set beam_path (realpath (dirname $erl_path)/../erts-*/bin/beam.smp)
sudo setcap 'cap_net_admin,cap_net_raw+ep' $beam_path
getcap $beam_path
```

To remove the capabilities later, rerun the matching `beam_path` snippet above
and then:

```bash
sudo setcap -r "$beam_path"
```

Notes:

- rerun `setcap` after upgrading Erlang/OTP, because a new `beam.smp` binary replaces the old one
- the capability change applies only to the resolved `beam.smp`; if you have multiple Erlang installs, other installs are unaffected
- if you do not want to grant capabilities to `beam.smp`, running the examples with `sudo` still works as a fallback

## Smoke examples

Runnable smoke examples live in `examples/README.md`:

- `examples/radio_smoke.exs`
- `examples/wfb_ingress_smoke.exs`
- `examples/wfb_decrypt_smoke.exs`
- `examples/wfb_reorder_fec_smoke.exs`

These are intended for step-by-step validation on real hardware while the RX
pipeline is being built out.
