# Bento [![ci](https://img.shields.io/github/actions/workflow/status/folz/bento/build-test.yml?label=CI&logo=github&style=flat-square)](https://github.com/folz/bento/actions/workflows/build-test.yml？style=flat-square) [![hex.pm](https://img.shields.io/hexpm/v/bento.svg?label=Hex&style=flat-square)](https://hex.pm/packages/bento)

Bento is a [Bencoding](https://en.wikipedia.org/wiki/Bencode) library for Elixir focusing on incredibly fast **speed** without sacrificing **simplicity**, **completeness**, or **correctness**.

The parser is a single tail-recursive state machine over the input binary, using several techniques to get the most out of the BEAM:

- A **single pass** over the input, scanned by byte offset, with strings extracted as zero-copy [sub-binaries](http://erlang.org/euc/07/papers/1700Gustafsson.pdf) in one slice.
- Containers tracked on an **explicit stack** rather than the call stack, so values return without per-value tuple allocations and arbitrarily deep nesting is safe.
- Decoding options resolved **once, up front** into functions, keeping the hot loop free of conditionals.
- [IO list](http://jlouisramblings.blogspot.com/2013/07/problematic-traits-in-erlang.html) encoding, with encoder dispatch on the value's type directly and the `Bento.Encoder` protocol reserved for structs and custom types.

Bento rejects all malformed input - including the out-of-order and duplicate dictionary keys that BEP-3 forbids - with errors that report the **byte position** and the offending byte - never a multi-megabyte error message. This guarantees you're working with a well-formed bencoded file.

Encoding always produces **canonical** Bencoding: dictionary keys are normalized to strings, emitted in byte-wise sorted order, and key collisions (like `%{:a => 1, "a" => 2}`) are rejected rather than silently emitting an invalid dictionary - so hashes computed over Bento's output (like torrent info-hashes) are correct.

## Documentation

Documentation is [available on Hexdocs](https://hexdocs.pm/bento).

## Installation

Bento is [available in Hex](https://hex.pm/packages/bento). The package can be installed by:

1. Add bento to your list of dependencies in `mix.exs`:

```elixir
{:bento, "~> 2.0"}
```

2. Then, update your dependencies.

```shell
$ mix do deps.get + deps.compile
```

## Usage

Encoding an Elixir data type:

```elixir
iex> Bento.encode([1, "two", [3]])
{:ok, "li1e3:twoli3eee"}
iex> Bento.encode!(%{"foo" => ["bar", "baz"], "qux" => "norf"})
"d3:fool3:bar3:baze3:qux4:norfe"
```

Decoding a bencoded string:

```elixir
iex> Bento.decode("li1e3:twoli3eee")
{:ok, [1, "two", [3]]}
iex> Bento.decode!("d3:fool3:bar3:baze3:qux4:norfe")
%{"foo" => ["bar", "baz"], "qux" => "norf"}
```

Decoding errors tell you where and what went wrong:

```elixir
iex> Bento.decode("d3:foo")
{:error, %Bento.SyntaxError{position: 6, ...}}
iex> Bento.decode!("i4x2e")
** (Bento.SyntaxError) unexpected byte at position 2: 0x78 ("x")
```

### Decoding options

- `keys: :strings | :atoms | :atoms! | (key -> term)` - how dictionary keys are decoded.
- `strings: :reference | :copy` - `:reference` (default) returns zero-copy sub-binaries into the input; use `:copy` when decoded values outlive the input (e.g. stored in ETS), so a small retained string doesn't keep a large input binary alive.
- `dicts: :strict | :lenient | :ordered` - `:strict` (default) requires unique, canonically sorted keys as BEP-3 mandates; `:lenient` skips those checks for non-conforming files; `:ordered` returns `Bento.OrderedDict` structs preserving wire order, so even non-canonical input re-encodes byte-for-byte.

```elixir
iex> Bento.decode!("d1:bi1e1:ai2ee", dicts: :ordered) |> Bento.encode!()
"d1:bi1e1:ai2ee"
```

For streams carrying several consecutive values, `Bento.decode_prefix/2` parses one value off the front and returns the rest:

```elixir
iex> Bento.decode_prefix("i1ei2e")
{:ok, 1, "i2e"}
```

### Structs

Structs can derive `Bento.Encoder`, optionally restricting fields and skipping `nil`s; keys are pre-encoded at compile time:

```elixir
defmodule MyMeta do
  @derive {Bento.Encoder, skip_nil: true}
  defstruct [:announce, :info, :comment]
end
```

Already-encoded parts (like a cached info dictionary) can be spliced in without re-encoding via `Bento.Fragment`:

```elixir
iex> Bento.encode!(%{"info" => Bento.Fragment.new(cached_info)})
```

### Torrents

Bento is also metainfo-aware and comes with a `*.torrent` decoder out of the box:

```elixir
iex> File.read!("./test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent") |> Bento.torrent!()
%Bento.Metainfo.Torrent{
  info: %Bento.Metainfo.SingleFile{
    length: 1069547520,
    md5sum: nil,
    "piece length": 524288,
    pieces: <<109, 235, 143, 234, 36, 25, 142, 36, 20, 3, 227, 227, 134, 136,
      205, 130, 176, 104, 192, 33, 45, 230, 152, 2, 239, 131, 240, 217, 180,
      251, 153, 170, 31, 127, 175, 166, 9, 254, 133, 8, 42, 229, 43, 139, 86,
      ...>>,
    private: 0,
    name: "ubuntu-14.04.4-desktop-amd64.iso",
    "name.utf-8": nil
  },
  announce: "http://torrent.ubuntu.com:6969/announce",
  "announce-list": [
    ["http://torrent.ubuntu.com:6969/announce"],
    ["http://ipv6.torrent.ubuntu.com:6969/announce"]
  ],
  "creation date": ~U[2016-02-18 20:12:51Z],
  comment: "Ubuntu CD releases.ubuntu.com",
  "created by": nil,
  encoding: nil
}
```

In addition to parsing torrents via `Bento.torrent!/1`, It's also available decoding any bencoded data into any struct you choose, like so:

```elixir
defmodule Name do
  defstruct [:family, :given]
end

iex> Bento.decode!("d6:family4:Folz5:given6:Rodneye", as: %Name{})
%Name{family: "Folz", given: "Rodney"}
```

### Magnet links

`Bento.Magnet` is a magnet URI codec for BitTorrent (BEP-9), covering v2 info-hashes (BEP-52) and select-only (BEP-53). `Bento.magnet!/1` builds a magnet link from a `.torrent` file:

```elixir
iex> File.read!("./test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent") |> Bento.magnet!() |> to_string()
"magnet:?xt=urn:btih:33395da120c9a4758e896ded4dec5f2495c9973f&dn=ubuntu-14.04.4-desktop-amd64.iso&xl=1069547520&tr=http%3A%2F%2Ftorrent.ubuntu.com%3A6969%2Fannounce&tr=http%3A%2F%2Fipv6.torrent.ubuntu.com%3A6969%2Fannounce"
```

The info-hash is computed over the **exact bytes** of the file's info dictionary (via `dicts: :ordered`), so it is correct even for non-canonical files; `Bento.Metainfo.info_hash/1` and `Bento.Metainfo.info_hash_v2/1` expose the hashes directly. Parsing is as strict as the rest of Bento - malformed hashes, percent-encoding, ports, and repeated single-valued parameters are rejected with descriptive errors:

```elixir
iex> Bento.Magnet.parse!("magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=Example&so=0,2,4-6")
%Bento.Magnet{
  info_hash: <<193, 47, 225, 192, 107, 186, 37, 74, 157, 201, 245, 25, 179,
    53, 170, 124, 19, 103, 168, 138>>,
  display_name: "Example",
  select_only: [0, 2, 4..6],
  ...
}
```

## Testing

Beyond unit tests, Bento is tested against:

- A **conformance suite** of accept/reject vectors in `test/bencode_test_suite/`, covering the BEP-3 grammar and its edge cases (leading zeros, unterminated values, length overruns, non-string keys, duplicate and unsorted keys, and so on).
- **Property-based tests**: encode/decode round-trips over arbitrary (including non-UTF-8) data, canonical-encoding invariants, and fuzzing via random mutation and truncation of valid input - decoding must always return a positioned error and never crash.

```shell
$ mix test
```

## Benchmarking

The benchmark suite lives in `bench/` as a standalone project and measures both throughput and memory across shape-isolated inputs (large file lists, huge piece strings, many small messages, deep nesting, real torrents):

```shell
$ cd bench
$ mix deps.get
$ mix bench.gen      # generate the synthetic corpus
$ mix bench.decode
$ mix bench.encode
$ mix bench.retention  # demonstrate strings: :reference vs :copy retention
```

Runs are saved under `bench/output/runs/` and automatically compared against previous runs, so before/after numbers for a change come for free. HTML reports are written to `bench/output/`.

We currently benchmark against: [Bento](https://github.com/folz/bento) (this project), [bencode](https://github.com/gausby/bencode), and [Bencodex](https://github.com/patrickgombert/Bencodex).

We are aware of, but unable to benchmark against: [exbencode](https://github.com/antifuchs/exbencode) (build errors), [elixir_bencode](https://github.com/AntonFagerberg/elixir_bencode) (module name conflicts with Bencode), and [bencoder](https://github.com/alehander42/bencoder) (does not compile on Elixir 1.17+).

PRs that add libraries to the benchmarks are greatly appreciated!

## License

See [LICENSE](./LICENSE).
