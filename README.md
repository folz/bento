# Bento

Bento is a new Bencoding library for Elixir focusing on wicked-fast **speed**
without sacrificing **simplicity**, **completeness**, or **correctness**.

It takes inspiration from [Poison](https://github.com/devinus/poison), a
pure-Elixir JSON library, and uses several of the techniques found there:

* Extensive [sub-binary matching](http://erlang.org/euc/07/papers/1700Gustafsson.pdf)
* A hand-rolled **parser** using several techniques [known to benefit HiPE](http://erlang.org/workshop/2003/paper/p36-sagonas.pdf)
  for native compilation
* [IO list](http://jlouisramblings.blogspot.com/2013/07/problematic-traits-in-erlang.html)
  encoding
* **Single-pass** decoding

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

TODO: Document usage.

## License

See [LICENSE](LICENSE).
