# Wifibroadcast

`wifibroadcast` is a Linux/Nerves-only Elixir rewrite of
[`wfb-ng`](https://github.com/svpcom/wfb-ng).

It keeps the WFB link packet-oriented and low-latency, but expresses the data
path as a [Membrane](https://membraneframework.org/) pipeline so the individual
stages are explicit and easier to reason about, inspect, test, compose, and
extend.

This project is intended to interoperate with `wfb-ng` where compatibility
matters, while moving the RX/TX path, radio control, and key handling into
Elixir.

## Relationship to wfb-ng

[`wfb-ng`](https://github.com/svpcom/wfb-ng) is a long-range packet radio link
built on raw WiFi monitor-mode transport. This project follows the same core
ideas and keeps compatibility with the upstream ecosystem in the places that
matter for packet exchange.

Important upstream ideas that this project keeps:

- packet-oriented transport instead of byte-stream framing, for lower latency
- raw IEEE 802.11 monitor-mode RX/TX
- forward error correction (FEC)
- SIMD-accelerated native FEC where available
- libsodium-based stream encryption and authentication
- Linux traffic shaping / packet marking support
- `drone.key` / `gs.key` compatibility with existing `wfb-ng` setups

This project is not a full clone of the entire `wfb-ng` operational stack. It
focuses on the core RX/TX data path, packet processing, key handling, and radio
control in Elixir.

For the broader `wfb-ng` ecosystem, upstream docs are still the best reference:

- Upstream repository: <https://github.com/svpcom/wfb-ng>
- Upstream wiki: <https://github.com/svpcom/wfb-ng/wiki>

## Why rewrite it as a Membrane pipeline?

One of the main goals of this project is to make the WFB link easier to reason
about.

Instead of treating RX and TX as opaque binaries, `wifibroadcast` models the
link as explicit pipeline stages. That makes it easier to see, test, and modify
what happens at each step:

- radio capture / injection
- radiotap parsing
- WFB packet routing
- decrypt / encrypt
- FEC decode / encode
- payload unwrap / wrap

In practice, that means the RX/TX path is easier to debug, easier to compose
with other Elixir components, and easier to swap or extend parts of the chain.

## Requirements

- Linux / Nerves only
- monitor-mode capable WiFi hardware
- `libsodium` development headers and library available at build time
- a working C toolchain for Bundlex native compilation
- `cap_net_admin` and `cap_net_raw` on `beam.smp`, or `sudo`, for raw radio
  control and `AF_PACKET` RX/TX

Install native build dependencies:

### Arch Linux

```bash
sudo pacman -S --needed base-devel libsodium
```

### Fedora

```bash
sudo dnf install -y gcc make libsodium-devel
```

### Debian / Ubuntu

```bash
sudo apt-get update
sudo apt-get install -y build-essential libsodium-dev
```

## Hardware and Drivers

This package targets the same raw WiFi monitor-mode world as `wfb-ng`, so
hardware and driver quality matter a lot.

Current radio control behavior is aligned with the `wfb-ng` ecosystem,
especially for:

- `rtl8812au`
- `rtl8812eu`

If you are using those chipsets, follow the upstream driver guidance:

- <https://github.com/svpcom/rtl8812au>
- <https://github.com/svpcom/rtl8812eu>

If you only need RX, any monitor-mode capable card may work for capture, but TX
behavior depends heavily on driver support and monitor-mode injection quality.

## Installation

Add `wifibroadcast` to your dependencies:

```elixir
defp deps do
  [
    {:wifibroadcast, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Compatibility with wfb-ng

`wifibroadcast` is intended to receive traffic sent by `wfb-ng` and to transmit
traffic that `wfb-ng` can receive.

Current compatibility-related behavior includes:

- `drone.key` / `gs.key` file layout compatible with `wfb-ng`
- password-derived key generation compatible with `wfb-ng`
- driver-specific TX power handling aligned with `wfb-ng` conventions for
  `rtl8812au` and `rtl8812eu`
- raw monitor-mode packet handling built around the same WFB packet model

This package intentionally does not claim to replace every higher-level
`wfb-ng` operational feature such as system images, service layout, telemetry
tooling, IP tunnel management, or OSD components.

## RX Pipeline

The RX side is built from Membrane elements and runs on real monitor-mode
hardware:

- `Wifibroadcast.Membrane.Radio.Source` captures monitor-mode traffic in pure
  Elixir via `AF_PACKET`, applies WFB ingress filtering, and routes packets by
  `link_id` and `radio_port`
- `Wifibroadcast.Radiotap.Parser` decodes radiotap metadata into
  `buffer.metadata`
- `Wifibroadcast.Membrane.WFB.Decrypt` decrypts WFB session/data packet
  payloads while preserving the packet contract
- `Wifibroadcast.Membrane.WFB.FecDecoder` accepts session/data packets,
  performs FEC recovery, and emits ordered source shards

## TX Pipeline

The TX side has the matching Membrane stages needed to build a WFB transmit
path:

- `Wifibroadcast.Membrane.WFB.PayloadWrap` wraps packetized payloads into
  `wpacket_hdr_t <> payload`
- `Wifibroadcast.Membrane.WFB.FecEncoder` groups wrapped payloads into
  source/parity shards and emits session/data packets
- `Wifibroadcast.Membrane.WFB.Encrypt` optionally encrypts the session/data
  packet payloads without changing the packet contract
- `Wifibroadcast.Membrane.Radio.Sink` fans in multiple `radio_port` branches,
  adds radiotap + 802.11 + outer WFB headers, and injects frames through
  `AF_PACKET`

`Radio.Sink` defaults to low-latency injection with qdisc bypass enabled. If
you want Linux traffic control to classify TX packets, set `use_qdisc?: true`
and a `fwmark_base`. In that mode:

- source data packets and session packets use `fwmark_base`
- parity packets use `fwmark_base + 1`

See `examples/README.md` for a TX pipeline snippet.

## WFB Keys

`Wifibroadcast.generate_wfb_keys/1` writes the standard `drone.key` and
`gs.key` files in the current working directory.

Generate random keys:

```bash
iex -S mix
```

```elixir
Wifibroadcast.generate_wfb_keys()
```

Generate password-derived keys that stay compatible with `wfb-ng`:

```elixir
Wifibroadcast.generate_wfb_keys("shared-password")
```

The resulting files use the same layout expected by the `Encrypt` and `Decrypt`
stages.

## Radio Control

`Wifibroadcast.Radio.Control` uses pure-Elixir rtnetlink and `nl80211` calls.

That includes:

- interface up/down changes
- monitor-mode changes
- regulatory region changes
- channel and frequency changes
- TX power changes

Example:

```elixir
Wifibroadcast.Radio.Control.set_region("BO")
Wifibroadcast.set_card_monitor_mode("wlan0")
Wifibroadcast.Radio.Control.set_frequency("wlan0", 5825, 20)
Wifibroadcast.set_card_tx_power("wlan0", :rtl8812au, 30)
```

## Run Without `sudo`

If you want to switch monitor mode, change channel or frequency, set TX power,
and use raw packet RX/TX without starting the whole VM as root, grant Linux
file capabilities to the actual Erlang VM executable: `beam.smp`.

What the capabilities do:

- `cap_net_admin` lets the BEAM perform the network-admin operations used here,
  including link up/down, monitor mode, regulatory changes, channel or
  frequency changes, TX power changes, and socket options such as `SO_MARK`
- `cap_net_raw` lets the BEAM open raw and `AF_PACKET` sockets for radio RX/TX

What `setcap` changes:

- `setcap` writes file capabilities onto the `beam.smp` executable itself; it
  does not modify this project
- every `iex`, `mix`, release, or Erlang node started from that exact
  `beam.smp` path gets those capabilities when it starts
- any code running inside those VMs can use them; the capabilities are not
  scoped to `wifibroadcast`
- if you use the same Erlang installation for unrelated work, those BEAM
  workloads also get the same network privileges
- other Erlang installations are unaffected unless you run `setcap` on their
  `beam.smp` too

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

- rerun `setcap` after upgrading Erlang/OTP, because a new `beam.smp` binary
  replaces the old one
- the capability change applies only to the resolved `beam.smp`; if you have
  multiple Erlang installs, other installs are unaffected
- if you do not want to grant capabilities to `beam.smp`, running the examples
  with `sudo` still works as a fallback

## Examples

Runnable smoke examples live in `examples/README.md`:

- `examples/radio_smoke.exs`
- `examples/wfb_decrypt_smoke.exs`
- `examples/wfb_fec_decoder_smoke.exs`

These are intended for step-by-step validation on real Linux / Nerves hardware.

## Attribution

This project is directly inspired by and intentionally interoperates with
[`wfb-ng`](https://github.com/svpcom/wfb-ng). Credit goes to the upstream
authors and maintainers for the original WFB tooling, protocol conventions,
hardware knowledge, and ecosystem documentation that this rewrite builds on.
