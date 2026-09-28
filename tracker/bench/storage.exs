# Benchmarks a peer store driver against a single large swarm:
#
#     mix run bench/storage.exs [driver] [swarm_size]
#
# The default is the memory driver with a 50,000-peer swarm. The redis
# driver expects chihaya's default broker (redis://myRedis@127.0.0.1:6379/0).
alias Bento.Tracker.{Peer, Storage}

{driver, swarm_size} =
  case System.argv() do
    [driver, size] -> {driver, String.to_integer(size)}
    [driver] -> {driver, 50_000}
    [] -> {"memory", 50_000}
  end

{:ok, store} = Storage.new(driver, %{})
ih = :crypto.strong_rand_bytes(20)
announcer = %Peer{id: :crypto.strong_rand_bytes(20), ip: {10, 0, 0, 1}, port: 6881}

per_op = fn label, n, fun ->
  {us, _} = :timer.tc(fn -> for i <- 1..n, do: fun.(i) end)
  IO.puts("#{String.pad_trailing(label, 24)} #{Float.round(us / n, 2)} µs/op (n=#{n})")
end

per_op.("put_leecher", swarm_size, fn i ->
  :ok = Storage.put_leecher(store, ih, %Peer{id: <<i::160>>, ip: {10, 0, 0, 2}, port: i})
end)

per_op.("announce_peers/50", 1000, fn _ ->
  {:ok, _peers} = Storage.announce_peers(store, ih, true, 50, announcer)
end)

per_op.("scrape_swarm", 1000, fn _ -> Storage.scrape_swarm(store, ih, :ipv4) end)

Storage.stop(store)
