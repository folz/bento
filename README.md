# Bento

[![Travis](https://img.shields.io/travis/folz/bento.svg?style=flat-square)](https://github.com/folz/bento)
[![Hex.pm](https://img.shields.io/hexpm/v/bento.svg?style=flat-square)](https://hex.pm/packages/bento)

Bento is a new [Bencoding](https://en.wikipedia.org/wiki/Bencode) library for Elixir focusing on incredibly fast **speed**
without sacrificing **simplicity**, **completeness**, or **correctness**.

It takes inspiration from [Poison](https://github.com/devinus/poison), a
pure-Elixir JSON library, and uses several techniques found there to achieve this speed:

* Extensive [sub-binary matching](http://erlang.org/euc/07/papers/1700Gustafsson.pdf)
* A hand-rolled **parser** using several techniques [known to benefit HiPE](http://erlang.org/workshop/2003/paper/p36-sagonas.pdf)
  for native compilation
* [IO list](http://jlouisramblings.blogspot.com/2013/07/problematic-traits-in-erlang.html)
  encoding
* **Single-pass** decoding

Additionally, and unlike some other Elixir bencoding libraries, Bento will also reject all malformed input. This guarantees you're working with a well-formed bencoded file.

Preliminary [benchmarking](#benchmarking) has put Bento's performance as nearly always faster than existing Elixir libraries.

## Installation

Bento is [available in Hex](https://hex.pm/packages/bento). The package can be installed by:

  1. Add bento to your list of dependencies in `mix.exs`:

        def deps do
          [{:bento, "~> 0.9.0"}]
        end

  2. Update your dependencies.

        $ mix deps.get

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

Bento is also metainfo-aware and comes with a .torrent decoder out of the box:

```elixir
iex> File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent") |> Bento.torrent!()
%Bento.Metainfo.Torrent{announce: "http://torrent.ubuntu.com:6969/announce",
 "announce-list": [["http://torrent.ubuntu.com:6969/announce"],
  ["http://ipv6.torrent.ubuntu.com:6969/announce"]],
 comment: "Ubuntu CD releases.ubuntu.com", "created by": nil,
 "creation date": 1455826371, encoding: nil,
 info: %Bento.Metainfo.SingleFile{length: 1069547520, md5sum: nil,
  name: "ubuntu-14.04.4-desktop-amd64.iso", "piece length": 524288,
  pieces: <<109, 235, 143, 234, 36, 25, 142, 36, 20, 3, 227, 227, 134, 136, 205, 130, 176, ...>>,
  private: nil}}

```

Since Bento uses [Poison](https://hex.pm/packages/poison)'s Decoder module for `.torrent()`, this means it also supports decoding bencoded data into any struct you choose, like so:

```elixir
defmodule Name do
  defstruct [:family, :given]
end
iex> Bento.decode!("d6:family4:Folz5:given6:Rodneye", as: %Name{})
%Name{family: "Folz", given: "Rodney"}
```

## Benchmarking

```
$ MIX_ENV=bench mix bench
```

We currently benchmark against: [Bento](https://github.com/folz/bento) (this project), [bencode](https://github.com/gausby/bencode), [Bencodex](https://github.com/patrickgombert/Bencodex), [bencoder](https://github.com/alehander42/bencoder), and [bencoded](https://github.com/galina/bencoded).

We are aware of, but unable to benchmark against: [exbencode](https://github.com/antifuchs/exbencode) (build errors), and [elixir_bencode](https://github.com/AntonFagerberg/elixir_bencode) (module name conflicts with Bencode).

PRs that add libraries to the benchmarks are greatly appreciated!

## License

See [LICENSE](LICENSE).
