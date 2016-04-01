# Bento

[![Travis](https://img.shields.io/travis/folz/bento.svg?style=flat-square)](https://github.com/folz/bento)
[![Hex.pm](https://img.shields.io/hexpm/v/bento.svg?style=flat-square)](https://hex.pm/packages/bento)

Bento is a new [Bencoding](https://en.wikipedia.org/wiki/Bencode) library for Elixir focusing on wicked-fast **speed**
without sacrificing **simplicity**, **completeness**, or **correctness**.

It takes inspiration from [Poison](https://github.com/devinus/poison), a
pure-Elixir JSON library, and uses several of the techniques found there:

* Extensive [sub-binary matching](http://erlang.org/euc/07/papers/1700Gustafsson.pdf)
* A hand-rolled **parser** using several techniques [known to benefit HiPE](http://erlang.org/workshop/2003/paper/p36-sagonas.pdf)
  for native compilation
* [IO list](http://jlouisramblings.blogspot.com/2013/07/problematic-traits-in-erlang.html)
  encoding
* **Single-pass** decoding

Unlike other Elixir bencoding libraries, Bento will also reject all invalid bencoded input, so you're guaranteed to work with a well-formed bencoded file.

Preliminary benchmarking has put Bento's performance as nearly always faster than existing Elixir libraries.

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
iex> File.read!("path/to/file.torrent") |> Bento.torrent!()
%Bento.Metainfo.Torrent{announce: "https://announce.url",
 "announce-list": nil,
 comment: "Comment",
 "created by": "Bento/0.9.0", "creation date": 1234567890, encoding: "UTF-8",
 info: %Bento.Metainfo.SingleFile{length: 9001, md5sum: nil,
  name: "file.torrent", "piece length": 42,
  pieces: << ... >>,
  private: nil}}
```

Since Bento uses [Poison](https://hex.pm/packages/poison)'s Decoder module for `.torrent()`, this means it also supports decoding bencoded data into whatever struct you like, like so:

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
