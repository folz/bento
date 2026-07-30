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
| `frontend/http` + `frontend/http/bencode` | `HTTP.{Frontend,Parser,Writer,Request}` (bencode via Bento) |
| `frontend/udp` | `UDP.{Frontend,Parser,Writer,ConnectionID}` |
| `pkg/metrics`, `pkg/timecache`, `pkg/stop` | `Metrics`, `Metrics.Server`, `TimeCache`, OTP supervision |
| `cmd/chihaya` | `Runner`, `Config`, `CLI`, `E2E` |

## Running

Build the escript and run the tracker from a config file:

```shell
$ cd tracker
$ mix deps.get
$ mix escript.build
$ ./bento_tracker --config dist/example_config.exs
```

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

## Storage

Two peer stores ship, both passing the shared conformance suite in
`Bento.Tracker.StorageCase` (ported from chihaya's `storage_tests.go`):

- **`memory`** — `2 * shard_count` public ETS `ordered_set` tables split
  by address family, with atomic upserts, `:counters`-based statistics,
  and a GC/reporting process. Announce responses start from a random
  position and wrap around, mirroring Go's randomized map iteration.
- **`redis`** — the exact chihaya key schema
  (`IPv{4,6}_{S,L}_<infohash-hex>`, group hashes, count keys), the same
  `MULTI`/`EXEC` and `WATCH` sequences and GC algorithm, over a minimal
  RESP2 client (`Bento.Tracker.Storage.Redis.Connection`).

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

## License

Bento is licensed under [MPL-2.0](../LICENSE); chihaya is BSD-licensed.

[BitTorrent tracker]: https://en.wikipedia.org/wiki/BitTorrent_tracker
[chihaya]: https://github.com/chihaya/chihaya
[BEP 3]: http://bittorrent.org/beps/bep_0003.html
[BEP 15]: http://bittorrent.org/beps/bep_0015.html
[BEP 23]: http://bittorrent.org/beps/bep_0023.html
[BEP 41]: http://bittorrent.org/beps/bep_0041.html
