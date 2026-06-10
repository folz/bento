# Encoding benchmarks across libraries and input shapes.
#
# Run with: mix bench.encode
#
# Inputs are the decoded forms of the same corpus used for decoding.
# Each run is saved under output/runs/ and compared against previously
# saved runs. An HTML report is written to output/encode.html.

encode_jobs = %{
  "Bento" => fn input -> Bento.encode_to_iodata!(input) end,
  "Bento (to binary)" => fn input -> Bento.encode!(input) end,
  "bencode" => fn input -> Bencode.encode(input) end,
  "Bencodex" => fn input -> Bencodex.encode(input) end
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
    {Path.basename(path), path |> File.read!() |> Bento.decode!()}
  end

IO.puts("Checking jobs don't crash")

for {input_name, input} <- inputs, {job_name, job} <- encode_jobs do
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

Benchee.run(encode_jobs,
  warmup: warmup,
  time: time,
  memory_time: memory_time,
  inputs: inputs,
  save: %{path: Path.expand("output/runs/encode-#{System.os_time(:second)}.benchee", __DIR__)},
  load: Path.expand("output/runs/encode-*.benchee", __DIR__),
  formatters: [
    {Benchee.Formatters.HTML, file: Path.expand("output/encode.html", __DIR__), auto_open: false},
    Benchee.Formatters.Console
  ]
)
