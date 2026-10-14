# folval-gw — hermetic-lab mock gateway

The host-side interception point for the `folly-n-valor` RE lab. The Windows
guest (192.168.100.10) lives on an isolated libvirt network
(`re-isolated-net`, bridge `virbr1`) whose only neighbor is this gateway at
192.168.100.1. The guest has **no internet** — every DNS query and HTTP
request hits folval-gw and is logged as evidence.

Licensed under **AGPL-3.0-or-later** (see `LICENSE`). The repository root
carries its own project-level license; this one governs the gateway code.

## Design

- **Unprivileged by construction.** folval-gw binds only high ports
  (`:1053` DNS, `:8080` HTTP). The nftables boundary
  (`../host/firewall/folval.nft`) DNATs guest traffic `53 → 1053` and
  `80 → 8080`, so the guest sees standard ports while the gateway needs no
  root and no `CAP_NET_BIND_SERVICE`.
- **DNS sinkhole.** Every A query is answered with the sinkhole IP
  (192.168.100.1) unless a hosts-style override pins it elsewhere. Both UDP
  and TCP (length-prefixed, RFC 1035 §4.2.2) are served. Hand-rolled wire
  format — zero external dependencies.
- **HTTP echo/logger.** Any request gets a 200 whose body self-identifies as
  folval-gw, so accidental client hits are self-evidencing in guest logs too.
- **Everything is evidence.** One JSONL line per event (`ts`, `proto`, `src`,
  `type`, `name`, `detail`) — the first hermetic dataset for protocol RE.
- Port **443 is deliberately not served** (project decision D3): HTTPS
  endpoints are mapped from pcaps before any TLS-termination choice.

## Layout

    cmd/folval-gw/       thin entrypoint
    internal/config/     flags → Config
    internal/dnswire/    minimal DNS wire format (parse/build)
    internal/overrides/  hosts-style name → pinned IP map
    internal/evidence/   JSONL event logger
    internal/gateway/    UDP/TCP DNS + HTTP loops, lookup policy

## Usage

    go build -o folval-gw ./cmd/folval-gw
    ./folval-gw \
      -dns 192.168.100.1:1053 \
      -http 192.168.100.1:8080 \
      -sinkhole 192.168.100.1 \
      -overrides hosts.overrides \
      -out ../logs/gateway.jsonl

With the nftables ruleset applied on the host, the guest resolves any name to
the sinkhole and reaches the echo server on port 80.
