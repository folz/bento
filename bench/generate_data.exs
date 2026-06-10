# Generates the synthetic benchmark inputs under bench/data/.
#
# Inputs are shape-isolated so individual optimizations can be measured:
# value-dense data, string-heavy data, integer-heavy data, deep nesting,
# and many-small-message workloads behave very differently.
#
# Run with: mix bench.gen

data_dir = Path.expand("data", __DIR__)
File.mkdir_p!(data_dir)

write = fn name, iodata ->
  path = Path.join(data_dir, name)
  File.write!(path, iodata)
  size = path |> File.stat!() |> Map.fetch!(:size)
  IO.puts("#{name}: #{size} bytes")
end

# Deterministic pseudo-random bytes, so runs are comparable.
:rand.seed(:exsss, {100, 101, 102})
rand_bytes = fn count -> :rand.bytes(count) end

# A metainfo-shaped dictionary with a very large file list: dense in
# values, dictionary- and string-heavy. Stresses per-value parser
# overhead.
files =
  for i <- 1..10_000 do
    %{"length" => i * 1024, "path" => ["dir#{rem(i, 100)}", "file#{i}.bin"]}
  end

multi = %{
  "announce" => "http://tracker.example/announce",
  "info" => %{
    "files" => files,
    "name" => "many-files",
    "piece length" => 262_144,
    "pieces" => rand_bytes.(20 * 2_048)
  }
}

write.("file_list_10k.bencode", Bento.encode!(multi))

# One huge string dominates the input. Decode cost is a single slice, so
# this isolates fixed costs and the strings: :copy trade-off. The name is
# longer than 64 bytes so it decodes as a sub-binary (the runtime copies
# shorter slices to the heap), which the retention demo relies on.
big_pieces = %{
  "info" => %{
    "name" => String.duplicate("big-pieces.", 12),
    "piece length" => 16_384,
    "pieces" => rand_bytes.(8 * 1_024 * 1_024)
  }
}

write.("big_pieces.bencode", Bento.encode!(big_pieces))

# A scrape-style response: a dictionary with many 20-byte binary
# (non-UTF-8) keys.
scrape_files =
  for i <- 1..2_000, into: %{} do
    {rand_bytes.(20), %{"complete" => i, "downloaded" => i * 3, "incomplete" => rem(i, 7)}}
  end

write.("scrape_2k.bencode", Bento.encode!(%{"files" => scrape_files}))

# A flat list of integers - isolates integer parsing and encoding.
write.("integers_100k.bencode", Bento.encode!(Enum.to_list(1..100_000)))

# Many short strings - isolates string slicing.
write.("strings_50k.bencode", Bento.encode!(for i <- 1..50_000, do: "string-#{i}"))

# Deep nesting - stresses container bookkeeping.
depth = 10_000
write.("nested_10k.bencode", [String.duplicate("l", depth), String.duplicate("e", depth)])

# A small message in the style of UDP peer-protocol traffic; benchmarked
# per-operation to expose constant overhead.
query = %{
  "a" => %{"id" => rand_bytes.(20), "target" => rand_bytes.(20)},
  "q" => "find_node",
  "t" => "aa",
  "y" => "q"
}

write.("small_message.bencode", Bento.encode!(query))
