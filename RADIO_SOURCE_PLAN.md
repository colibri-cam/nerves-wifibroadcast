# Radio Source Plan

## Goal

Build a pure Elixir Membrane source element that captures monitor-mode radio packets over `AF_PACKET`, parses radiotap headers, and exposes parsed radiotap data in buffer metadata.

This is intentionally not a replica of `c_src/nerves_wifibroadcast/rx.cpp`.

## First Milestone

Create `NervesWifibroadcast.Membrane.Radio.Source` as a Membrane `Source` that:

- owns the Linux `AF_PACKET` socket itself
- receives raw monitor-mode packets in pure Elixir
- parses radiotap in pure Elixir
- emits one `Membrane.Buffer` per captured packet
- keeps parsed radiotap in `buffer.metadata`
- places the post-radiotap 802.11 frame in `buffer.payload`

The first version should not be WFB-specific.

## Element Shape

### `NervesWifibroadcast.Membrane.Radio.Source`

Responsibilities:

- open, bind, and close the `AF_PACKET` socket
- own packet ingress lifecycle
- receive packets directly from the socket
- call the radiotap parser
- queue and emit `Membrane.Buffer`s according to downstream demand
- drop malformed radiotap packets without crashing

### `NervesWifibroadcast.Radio.AFPacket`

Pure helper module, not a process.

Responsibilities:

- open socket
- bind socket to interface
- apply socket options needed by the source
- close socket

### `NervesWifibroadcast.Radiotap.Parser`

Pure Elixir parser.

API shape:

```elixir
parse(packet) :: {:ok, radiotap, ieee80211_frame} | {:error, reason}
```

Responsibilities:

- parse fixed radiotap header
- parse little-endian present bitmaps
- apply radiotap alignment rules
- decode selected radiotap fields
- return the remaining 802.11 frame

## Output Contract

Each output packet should be emitted as a `Membrane.Buffer` with:

- `payload`: 802.11 frame with the radiotap header removed
- `metadata.radio.radiotap`: parsed `%Radiotap{}` struct
- `metadata.radio.receiver_idx`: stable ingress interface index
- `metadata.radio.capture_ts`: capture timestamp from `System.monotonic_time/0`
- `metadata.radio.raw_length`: original packet length

## Source Ownership Model

`Radio.Source` should own the socket.

Reasons:

- fewer processes and fewer message hops
- ingress lifecycle stays inside the Membrane element
- easier demand, queue, drop, and shutdown handling
- helper modules stay testable without owning runtime state

If active socket delivery is awkward with `AF_PACKET`, the source should still own the socket and fall back to nonblocking drains rather than introducing a separate capture owner process.

## Membrane Behavior

Recommended behavior for the source:

- use a manual-demand output pad
- keep a bounded internal queue
- drop on overflow with counters/telemetry
- emit stream format in `handle_playing/2`
- parse packets in `handle_info/3` or equivalent socket-triggered callback path
- drain queued buffers in `handle_demand/5`

State should include at least:

- socket
- interfaces
- queue
- available demand
- counters for malformed packets and dropped packets
- parser/backend options

## Radiotap V1 Scope

The first parser version should decode the fields needed for real-world packet inspection:

- `flags`
- `tx_flags`
- `channel`
- `dbm_antsignal`
- `dbm_antnoise`
- `antenna`
- `mcs`
- `vht`

It should also expose:

- radiotap `length`
- raw `present_words`

## Radiotap Data Model

Use a struct that preserves the packet's radiotap information without forcing WFB-specific normalization.

Suggested shape:

```elixir
%Radiotap{
  version: 0,
  length: 0,
  present_words: [],
  flags: nil,
  tx_flags: nil,
  channel_freq: nil,
  channel_flags: nil,
  mcs: nil,
  vht: nil,
  observations: []
}
```

Where `observations` is an ordered list of entries like:

```elixir
%Observation{
  antenna: nil,
  rssi_dbm: nil,
  noise_dbm: nil
}
```

## Failure Handling

Malformed packets should not crash the source.

The parser should return structured errors such as:

- `:short_header`
- `:unsupported_version`
- `:invalid_length`
- `{:truncated_field, field}`
- `:invalid_alignment_walk`

The source should drop bad packets and increment counters instead of failing the pipeline.

## Explicit Non-Goals For V1

The first milestone does not need to do the following:

- WFB-specific filtering
- self-injected frame filtering
- bad-FCS dropping policy
- FCS trimming policy
- FEC, crypto, session handling, or block reorder logic
- pcap parity or kernel BPF support

## Testing Plan

### Parser Tests

Add ExUnit coverage for:

- fixed header parsing
- extended present bitmaps
- alignment behavior
- each supported v1 field
- multiple antenna/signal/noise observations
- malformed and truncated packets

### Source Tests

Use Membrane testing tools to verify:

- stream format emission
- buffer emission only when there is demand
- payload contains the 802.11 frame without radiotap
- metadata contains parsed radiotap
- malformed packets are dropped safely
- queue overflow policy works as expected

### Live Smoke Tests

On real hardware in monitor mode, verify:

- the source captures real packets
- radiotap metadata is populated
- 802.11 payload is emitted downstream

These tests should be tagged so they do not run by default.

## Incremental Delivery

Recommended implementation order:

1. `NervesWifibroadcast.Radiotap.Parser`
2. `NervesWifibroadcast.Radio.AFPacket`
3. `NervesWifibroadcast.Membrane.Radio.Source`
4. `Radio.Source -> Testing.Sink` smoke pipeline
5. WFB-specific downstream filters later
