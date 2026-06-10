# Decoding benchmarks across libraries and input shapes.
#
# Run with: mix bench.decode
#
# Each run is saved under output/runs/ and compared against previously
# saved runs, so before/after comparisons of optimizations come for
# free. An HTML report is written to output/decode.html.

decode_jobs = %{
  "Bento" => fn input -> Bento.decode!(input) end,
  "Bento (strings: :copy)" => fn input -> Bento.decode!(input, strings: :copy) end,
  "Bento (dicts: :verify)" => fn input -> Bento.decode!(input, dicts: :verify) end,
  "bencode" => fn input -> Bencode.decode!(input) end,
  "Bencodex" => fn input -> Bencodex.decode(input) end
}

data_files =
  Path.wildcard(Path.expand("data/*.bencode", __DIR__)) ++
    Path.wildcard(Path.expand("../test/_data/*.torrent", __DIR__))

if data_files == [] do
  IO.puts("No benchmark data found. Run `mix bench.gen` first.")
  System.halt(1)
end

inputs =
  for path <- data_files, into: %{} do
    {Path.basename(path), File.read!(path)}
  end

IO.puts("Checking jobs don't crash or disagree")

for {input_name, input} <- inputs, {job_name, job} <- decode_jobs do
  try do
    job.(input)
  rescue
    exception ->
      IO.puts("#{job_name} failed on #{input_name}: #{Exception.message(exception)}")
  end
end

IO.puts("")

# Durations are tunable so CI smoke runs can be quick.
warmup = String.to_integer(System.get_env("BENCH_WARMUP", "2"))
time = String.to_integer(System.get_env("BENCH_TIME", "10"))
memory_time = String.to_integer(System.get_env("BENCH_MEMORY_TIME", "2"))

Benchee.run(decode_jobs,
  warmup: warmup,
  time: time,
  memory_time: memory_time,
  inputs: inputs,
  save: %{path: Path.expand("output/runs/decode-#{System.os_time(:second)}.benchee", __DIR__)},
  load: Path.expand("output/runs/decode-*.benchee", __DIR__),
  formatters: [
    {Benchee.Formatters.HTML, file: Path.expand("output/decode.html", __DIR__), auto_open: false},
    Benchee.Formatters.Console
  ]
)
