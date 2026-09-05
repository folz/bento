# Bento.Tracker

Bento.Tracker is an open source [BitTorrent tracker] for the BEAM, a
faithful Elixir port of [chihaya] built on the [Bento](../README.md)
bencoding library.

It is a standalone Mix project living alongside Bento (like `bench/`), so
Bento itself stays a pure, zero-dependency library while the tracker
depends on it via a path dependency. The tracker has **no runtime
dependencies** beyond Bento and the Erlang/OTP standard library — the
HTTP and UDP servers, the Prometheus metrics endpoint, the Redis client
and the JWT/JWK verification are all built directly on OTP.

Differentiating features, matching chihaya:

- HTTP and UDP protocols ([BEP 3], [BEP 15], [BEP 23], [BEP 41])
- IPv4 and IPv6 support
- Pre/Post middleware hooks
- Pluggable peer storage (in-memory and Redis)
- Prometheus-compatible metrics (identical metric names and buckets)

## Architecture

BitTorrent clients send announce and scrape requests to a **frontend**
(`Bento.Tracker.HTTP.Frontend` / `Bento.Tracker.UDP.Frontend`). Frontends
parse and sanitize requests for their protocol and pass them to the
**tracker logic** (`Bento.Tracker.Logic`), which runs a configurable
chain of **pre-hooks** and **post-hooks**:

1. Read the request.
2. Parse and sanitize it (`SanitizeAnnounce`/`SanitizeScrape` become
   `AnnounceRequest.sanitize/3` and `ScrapeRequest.sanitize/2`).
3. `handle_announce`/`handle_scrape` runs the **pre-hooks**. The built-in
   `ResponseHook` runs last, filling the response from the **storage**
   (`Bento.Tracker.Storage`).
4. Write the response to the client.
5. `after_announce`/`after_scrape` runs the **post-hooks**
   asynchronously. The built-in `SwarmInteractionHook` updates storage
   after the client already has its response.

Where chihaya threads a `context.Context` between pre- and post-hooks,
the port threads a plain context map. Where chihaya uses goroutines,
`sync.Pool`, `sync.Mutex` and Go maps, the port uses supervised
processes, stateless functions, and public ETS tables — the observable
behavior is identical.

The module layout mirrors chihaya's packages:

| chihaya (Go) | Bento.Tracker (Elixir) |
|---|---|
| `bittorrent/` | `InfoHash`, `PeerID`, `ClientID`, `Event`, `IP`, `Peer`, `Params`, `AnnounceRequest`, `AnnounceResponse`, `ScrapeRequest`, `Scrape`, `ScrapeResponse`, `ClientError` |
| `storage/` + `storage/memory` + `storage/redis` | `Storage` (behaviour), `Storage.Memory`, `Storage.Redis` (+ `Redis.Connection`) |
| `middleware/` | `Middleware`, `Middleware.Hook`, `Logic`, `Middleware.{ResponseHook,SwarmInteractionHook,ClientApproval,TorrentApproval,VarInterval,JWT}` |
| `frontend/http` + `frontend/http/bencode` (on `net/http` + httprouter) | `HTTP.{Frontend,Parser,Writer,Request}` on `HTTP.Server` (a minimal HTTP/1.1 server over `gen_tcp`/`ssl`) and `HTTP.Route` (httprouter-style patterns); bencode via Bento |
| `frontend/udp` | `UDP.{Frontend,Parser,Writer,ConnectionID}` |
| `pkg/metrics`, `pkg/timecache`, `pkg/stop` | `Metrics`, `Metrics.Server` (also on `HTTP.Server`), `TimeCache`, OTP supervision |
| `cmd/chihaya` | `Runner`, `Config`, `CLI`, `E2E` |

## Running

Build the escript and run the tracker from a config file:

```shell
$ cd tracker
$ mix deps.get
$ mix escript.build
$ ./bento_tracker --config dist/example_config.exs
```

`--debug` enables debug logging, as in chihaya.

Or run it without building an escript:

```shell
$ mix run --no-halt -e 'Bento.Tracker.Runner.start_link("dist/example_config.exs")'
```

### Configuration

Configuration mirrors chihaya's YAML schema, expressed as an Elixir map
so no YAML dependency is needed. It can be an `.exs` file (see
[`dist/example_config.exs`](dist/example_config.exs) and
[`dist/example_config_redis.exs`](dist/example_config_redis.exs)) or an
in-memory map passed to `Bento.Tracker.Runner.start_link/1`. Duration
values accept chihaya-style strings (`"30m"`, `"15s"`, `"10s"`) or plain
integers.

### End-to-end self-test

The `e2e` subcommand announces two peers for a random infohash and
verifies the tracker returns the other, over HTTP and UDP — the port of
chihaya's `chihaya e2e`:

```shell
$ ./bento_tracker e2e --httpaddr http://127.0.0.1:6969/announce \
                      --udpaddr udp://127.0.0.1:6969 --delay 1000
e2e: success
```

### Metrics

When `metrics_addr` is set, `GET /metrics` serves the Prometheus text
format. Metric names, help text, labels and histogram buckets are
identical to chihaya's (`chihaya_http_response_duration_milliseconds`,
`chihaya_udp_response_duration_milliseconds`,
`chihaya_storage_{infohashes,seeders,leechers}_count`,
`chihaya_storage_gc_duration_milliseconds`), so existing dashboards work
unchanged.

## Middleware

The same four middleware ship as chihaya, registered under the same
names and configured with the same option keys:

- **`client approval`** — allow/deny by BitTorrent client ID
  (whitelist/blacklist).
- **`torrent approval`** — allow/deny by infohash (hex whitelist/blacklist).
- **`interval variation`** — randomly increase the announce interval per
  peer so clients don't re-announce in lockstep; the increase is
  deterministic per (infohash, peer id) via XORShift128Plus seeded from
  the request, exactly as in chihaya.
- **`jwt`** — require a valid RS256 JWT with matching `iss`, `aud` and
  `infohash` claims, verifying against a JWK Set fetched and rotated from
  an HTTP endpoint. Implemented with `:public_key` alone — no JOSE
  dependency.

Custom middleware and storage drivers can be registered via the
`:middleware_drivers` and `:storage_drivers` application-environment keys.
As in chihaya, HTTP `announce_routes`/`scrape_routes` are httprouter
patterns (`/announce`, `/:passkey/announce`, `/announce/*rest`), and the
parameters bound by the matched route reach hooks in the request context
under `Bento.Tracker.Middleware.route_params_key/0` — the equivalent of
chihaya's `RouteParams`.

## Storage

Two peer stores ship, both passing the shared conformance suite in
`Bento.Tracker.StorageCase` (ported from chihaya's `storage_tests.go`):

- **`memory`** — `2 * shard_count` public ETS `ordered_set` tables split
  by address family, with atomic upserts, `:counters`-based statistics,
  and a GC/reporting process. Peers are keyed by a hash of their
  serialized form, and announce responses walk forward from a random
  point in that order, wrapping around — O(numwant), mirroring Go's
  randomized map iteration.
- **`redis`** — the exact chihaya key schema
  (`IPv{4,6}_{S,L}_<infohash-hex>`, group hashes, count keys), the same
  `MULTI`/`EXEC` transactions and GC algorithm, over a minimal RESP2
  client (`Bento.Tracker.Storage.Redis.Connection`). The client serializes
  every command over one connection and reconnects transparently after a
  socket error (see the deviations below for how this shapes the GC reap).

## Testing

```shell
$ cd tracker
$ mix test                      # unit, conformance and e2e tests
$ mix format --check-formatted
```

The Go table-driven tests are ported to ExUnit (tests-first for every
module). The Redis tests require a local `redis-server` and skip
automatically when none is reachable; set `BENTO_TEST_REDIS_PORT` to
point at a specific instance.

## Intentional deviations from chihaya

The port aims for observable behavioral parity. A small number of
differences are deliberate — each either fixes a chihaya bug or reflects
a BEAM idiom that preserves behavior:

- **Canonical bencode.** Responses use Bento, so dictionary keys are
  emitted in byte-wise sorted order (BEP 3), where chihaya relies on Go's
  randomized map iteration. Both are valid; ours is deterministic.
- **Announcer exclusion in the Redis store.** chihaya's Redis backend has
  a latent Go type-mismatch bug that never excludes the announcing peer
  from the returned leechers; the port matches the (correct) memory store
  and the documented `PeerStore` contract, excluding it.
- **Redis GC reap uses a Lua script, not `WATCH`.** chihaya reaps an
  emptied swarm with a `WATCH`/`HLEN`/`MULTI`/`EXEC` block on a connection
  drawn fresh from its pool, so the optimistic lock is never disturbed. The
  port serializes all commands over one connection, where an interleaved
  transaction could clear the `WATCH`; it performs the same empty-check,
  infohash-key removal and counter decrement atomically in a single
  server-side `EVAL`, which is strictly stronger and observably identical.
- **Redis connection self-heals.** With one shared connection (rather than
  chihaya's pool), a socket error tears the connection down and the next
  command reconnects and replays `AUTH`/`SELECT`, so a transient Redis blip
  cannot leave a permanently desynced reply stream. Best-effort counter
  updates log and continue on error instead of aborting, as chihaya's do.
- **UDP IP spoofing.** A v4-layout announce carrying a spoofed IP decodes
  to a clean IPv4 address; chihaya can produce a mangled address when such
  a packet arrives over IPv6.
- **Durations.** Integer duration values are milliseconds (seconds for the
  wire announce intervals), not Go's nanoseconds — nanosecond integers
  are meaningless on the BEAM. Duration strings (`"30m"`) work as in
  chihaya.
- **Defaults & validation.** `shard_count` needs no overflow guard
  (BEAM integers are arbitrary-precision); config fallbacks are applied
  silently rather than warning per absent field; an omitted `storage`
  section defaults to `memory`; an empty `metrics_addr` disables the
  metrics server rather than binding `:80`. The JWT refresh interval
  defaults to five minutes instead of chihaya's `0` (which busy-loops).
- **No SIGUSR1 reload.** chihaya reloads its config on SIGUSR1. BEAM
  services are reconfigured by restarting the `Runner` (or the OS
  process); signal-based hot reload is not implemented.
- **No `--json` / `--nocolors` log flags.** Log formatting is left to the
  Elixir `Logger` configuration of the host release; only `--debug` is
  mirrored.
- **No pprof endpoint.** The metrics server exposes only `/metrics`;
  BEAM introspection uses `:observer`/`:recon`/remote shells.
- **HTTP header size cap.** The request line and header block are bounded
  to 1 MiB (net/http's default `MaxHeaderBytes`) so a client that never
  terminates its headers cannot grow the read buffer without bound.

## License

Bento is licensed under [MPL-2.0](../LICENSE); chihaya is BSD-licensed.

[BitTorrent tracker]: https://en.wikipedia.org/wiki/BitTorrent_tracker
[chihaya]: https://github.com/chihaya/chihaya
[BEP 3]: http://bittorrent.org/beps/bep_0003.html
[BEP 15]: http://bittorrent.org/beps/bep_0015.html
[BEP 23]: http://bittorrent.org/beps/bep_0023.html
[BEP 41]: http://bittorrent.org/beps/bep_0041.html
