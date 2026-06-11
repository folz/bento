# Changelog

## 2.0.0 (unreleased)

A ground-up rewrite of the parser and encoder focused on performance,
correctness, and error reporting. The public API surface is unchanged
for common usage (`encode`/`encode!`/`decode`/`decode!`/`torrent`/
`torrent!` and the `Bento.Encoder` protocol), but error values and a few
edge-case behaviors changed, so this is a major release.

### Breaking changes

* `Bento.decode/2`, `Bento.Parser.parse/2` and friends now return
  `{:error, %Bento.SyntaxError{}}` instead of
  `{:error, :invalid | {:invalid, token}}`. The exception carries the
  byte `position` of the offending input, the offending `token` (when
  available), and the input `data`.
* `Bento.encode/2` now returns `{:error, %Bento.EncodeError{}}` instead
  of `{:error, {:invalid, value}}`.
* Maps that mix atom and string keys are now sorted by their *string*
  form, as the canonical (BEP-3) encoding requires. Previously all
  atom keys sorted before all string keys, producing non-canonical
  output. Two keys that normalize to the same string (such as
  `%{:a => 1, "a" => 2}`) now raise `Bento.EncodeError` instead of
  silently emitting an invalid dictionary with duplicate keys.
* Decoding enforces the BEP-3 dictionary key ordering and uniqueness
  requirements by default (continuing the behavior introduced on the
  1.x line after the 1.0 release); the new `dicts: :lenient` option
  restores the old lenient behavior for non-conforming files.
* Decoded integers are limited to 1024 digits by default to avoid
  excessive big-integer conversion cost on adversarial input.
  Configurable via the `:decoding_integer_digit_limit` application
  environment key (compile-time).
* The internal `Bento.Encode.__using__/1` macro (an undocumented
  implementation detail) was removed.

### Performance

* The parser is now a single tail-recursive state machine over the
  input binary. Containers are tracked on an explicit heap stack, the
  input is scanned by byte offset, and strings are extracted with a
  single sub-binary slice, eliminating the per-value tuple and
  sub-binary allocations of the previous recursive-descent design.
  Arbitrarily deep nesting no longer grows the call stack.
* String lengths are accumulated arithmetically with zero allocation;
  integers are converted with a single slice and `String.to_integer/1`.
* Decoding options are resolved into functions once, before parsing
  starts, instead of being consulted in the hot loop.
* Encoding dispatches on the value's type directly and uses the
  `Bento.Encoder` protocol only for structs and custom types.
  Dictionaries are encoded from a single `Map.to_list/1` traversal
  instead of `Map.keys/1` plus one lookup per key.

### Added

* `Bento.Magnet`: a magnet URI codec for BitTorrent (BEP-9), covering
  v2 info-hashes (BEP-52) and select-only (BEP-53). `parse/1` strictly
  decodes magnet links into a struct (raw-binary info-hashes from hex
  or base32, trackers, web seeds, peers, select-only indices, and
  more), `to_string/1` (and `String.Chars`) renders them, and
  `from_torrent/1` (also `Bento.magnet/1`) builds a magnet link
  straight from a `.torrent` file's bytes.
* `Bento.Metainfo.info_hash/1` and `Bento.Metainfo.info_hash_v2/1`
  (plus `!` variants): the v1 (SHA-1) and v2 (SHA-256) info-hashes of
  a metainfo file, computed over the exact bytes of its info
  dictionary - correct even for non-canonical files.
* `:keys` decode option: `:strings` (default), `:atoms`, `:atoms!`, or
  a custom function applied to every dictionary key.
* `:strings` decode option: `:reference` (default) returns
  sub-binaries into the input; `:copy` detaches decoded strings from
  the input binary so retained values don't keep large inputs alive.
* `:dicts` decode option: `:strict` (default; the BEP-3 key ordering
  and uniqueness requirements), `:lenient` (no key checks, for reading
  non-conforming files), or `:ordered` (returns `Bento.OrderedDict`
  structs preserving wire order, enabling byte-faithful re-encoding of
  non-canonical input).
* `Bento.OrderedDict`: an order-preserving dictionary with `Access`
  and `Enumerable` support.
* `Bento.Fragment`: inject already-encoded Bencoding into a larger
  structure without a decode/encode round-trip.
* `Bento.decode_prefix/2` and `Bento.decode_prefix!/2` (and
  `Bento.Parser.parse_prefix/2`): parse a single value off the front
  of the input and return the remaining bytes, for streams carrying
  several consecutive values.
* `@derive Bento.Encoder` for structs, with `:only`, `:except` and
  `:skip_nil` options. Field keys are pre-encoded at compile time and
  emitted in canonical order.
* Syntax errors produce bounded messages that identify the offending
  byte and its position, no matter how large the input is.
* A conformance test suite (`test/bencode_test_suite/`) of
  accept/reject vectors, and property-based round-trip, canonicality,
  mutation and truncation tests.
* A Benchee-based benchmark suite under `bench/` with shape-isolated
  inputs, memory measurements, saved-run comparisons, HTML reports,
  and a memory-retention demonstration (`mix bench.retention`).

### Fixed

* Parse errors no longer embed the entire remaining input in the
  error/exception message (previously a truncated multi-megabyte file
  produced a multi-megabyte message).

## 1.0.0 and earlier

See the [release notes on GitHub](https://github.com/folz/bento/releases).
