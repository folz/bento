# Bento [![ci](https://img.shields.io/github/actions/workflow/status/folz/bento/build-test.yml?label=CI&logo=github&style=flat-square)](https://github.com/folz/bento/actions/workflows/build-test.yml？style=flat-square) [![hex.pm](https://img.shields.io/hexpm/v/bento.svg?label=Hex&style=flat-square)](https://hex.pm/packages/bento)

Bento is a new [Bencoding](https://en.wikipedia.org/wiki/Bencode) library for Elixir focusing on incredibly fast **speed** without sacrificing **simplicity**, **completeness**, or **correctness**.

It takes inspiration from [Poison](https://github.com/devinus/poison), a pure-Elixir JSON library, and uses several techniques found there to achieve this speed:

- Extensive [sub-binary matching](http://erlang.org/euc/07/papers/1700Gustafsson.pdf).
- A hand-rolled **parser** using several techniques [known to benefit HiPE](http://erlang.org/workshop/2003/paper/p36-sagonas.pdf) for native compilation.
- [IO list](http://jlouisramblings.blogspot.com/2013/07/problematic-traits-in-erlang.html) encoding.
- **Single-pass** decoding.

Additionally, and unlike some other Elixir bencoding libraries, Bento will also reject all malformed input. This guarantees you're working with a well-formed bencoded file.

Preliminary [benchmarking](#benchmarking) shows that Bento performs over 2x faster when encoding, and at least as fast when decoding, compared to other existing Elixir libraries.

## Documentation

Documentation is [available on Hexdocs](https://hexdocs.pm/bento).

## Installation

Bento is [available in Hex](https://hex.pm/packages/bento). The package can be installed by:

1. Add bento to your list of dependencies in `mix.exs`:

```elixir
{:bento, "~> 1.0"}
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
    name: "ubuntu-14.04.4-desktop-amd64.iso"
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

## Benchmarking

```shell
$ MIX_ENV=bench mix bench
```

We currently benchmark against: [Bento](https://github.com/folz/bento) (this project), [bencode](https://github.com/gausby/bencode), [Bencodex](https://github.com/patrickgombert/Bencodex), and [bencoder](https://github.com/alehander42/bencoder).

We are aware of, but unable to benchmark against: [exbencode](https://github.com/antifuchs/exbencode) (build errors), and [elixir_bencode](https://github.com/AntonFagerberg/elixir_bencode) (module name conflicts with Bencode).

PRs that add libraries to the benchmarks are greatly appreciated!

## License

See [LICENSE](./LICENSE).
