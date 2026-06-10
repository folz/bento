# Demonstrates the memory-retention difference between
# `strings: :reference` (the default) and `strings: :copy`.
#
# Run with: mix bench.retention (after mix bench.gen)
#
# With `:reference`, decoded strings longer than 64 bytes are
# sub-binaries into the input, so keeping any one of them alive (here: a
# single ~130-byte name out of an ~8 MB input) keeps the *entire* input
# binary alive. With `strings: :copy`, decoded strings are detached from
# the input. (The runtime copies slices of 64 bytes or less to the
# process heap on its own, so very short strings never retain the
# input in either mode.)

defmodule Bento.Bench.Retention do
  def run(path) do
    size = File.stat!(path).size
    IO.puts("input: #{Path.basename(path)} (#{size} bytes)")

    for opts <- [[], [strings: :copy]] do
      retained = measure(path, opts)

      IO.puts(
        "  decode(input, #{inspect(opts)}): one retained #{string_size(path, opts)}-byte " <>
          "string keeps #{retained} bytes of binary data alive"
      )
    end
  end

  defp string_size(path, opts) do
    path |> File.read!() |> Bento.decode!(opts) |> get_in(["info", "name"]) |> byte_size()
  end

  defp measure(path, opts) do
    # Decode in this process, keep only one string, and drop every other
    # reference before garbage-collecting.
    kept = decode_and_keep_one(path, opts)
    :erlang.garbage_collect()

    {:binary, refs} = Process.info(self(), :binary)
    total = refs |> Enum.map(fn {_id, bytes, _refc} -> bytes end) |> Enum.sum()

    # Keep the reference alive past the measurement.
    true = byte_size(kept) >= 0
    total
  end

  defp decode_and_keep_one(path, opts) do
    path |> File.read!() |> Bento.decode!(opts) |> get_in(["info", "name"])
  end
end

case Path.wildcard(Path.expand("data/big_pieces.bencode", __DIR__)) do
  [] ->
    IO.puts("No benchmark data found. Run `mix bench.gen` first.")
    System.halt(1)

  paths ->
    Enum.each(paths, &Bento.Bench.Retention.run/1)
end
