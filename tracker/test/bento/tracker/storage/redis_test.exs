defmodule Bento.Tracker.Storage.RedisTest do
  # Ported from chihaya's storage/redis/peer_store_test.go. Requires a
  # local redis-server; skipped automatically when none is reachable.
  use ExUnit.Case, async: false

  alias Bento.Tracker.Peer
  alias Bento.Tracker.Storage
  alias Bento.Tracker.Storage.Redis.Connection
  alias Bento.Tracker.StorageCase

  @port String.to_integer(System.get_env("BENTO_TEST_REDIS_PORT", "6399"))
  @db 15

  setup_all do
    case Connection.start_link(host: "127.0.0.1", port: @port, db: @db) do
      {:ok, conn} ->
        Connection.close(conn)
        :ok

      {:error, reason} ->
        {:skip, "redis not reachable on 127.0.0.1:#{@port}: #{inspect(reason)}"}
    end
  end

  setup do
    {:ok, conn} = Connection.start_link(host: "127.0.0.1", port: @port, db: @db)
    {:ok, _} = Connection.command(conn, ["FLUSHDB"])
    Connection.close(conn)
    :ok
  end

  defp create_new do
    {:ok, store} =
      Storage.new("redis", %{
        redis_broker: "redis://127.0.0.1:#{@port}/#{@db}",
        gc_interval: :timer.minutes(10),
        prometheus_reporting_interval: :timer.minutes(10),
        peer_lifetime: :timer.minutes(30)
      })

    store
  end

  test "conforms to the peer store interface" do
    StorageCase.test_peer_store(create_new())
  end

  test "garbage collection removes peers older than the cutoff and empties swarms" do
    alias Bento.Tracker.Storage.Redis

    {:ok, {Redis, state} = store} =
      Storage.new("redis", %{
        redis_broker: "redis://127.0.0.1:#{@port}/#{@db}",
        gc_interval: :timer.minutes(10),
        prometheus_reporting_interval: :timer.minutes(10)
      })

    ih = String.duplicate("g", 20)
    peer = %Peer{id: String.duplicate("p", 20), ip: {1, 2, 3, 4}, port: 1}
    assert Storage.put_seeder(store, ih, peer) == :ok

    # A cutoff before the peer's mtime leaves it in place.
    assert Redis.collect_garbage(state, System.system_time(:nanosecond) - 1_000_000_000) == :ok
    assert Storage.scrape_swarm(store, ih, :ipv4).complete == 1

    # A cutoff at-or-after the peer's mtime removes it and its swarm.
    assert Redis.collect_garbage(state, System.system_time(:nanosecond)) == :ok
    assert Storage.scrape_swarm(store, ih, :ipv4).complete == 0

    assert Storage.announce_peers(store, ih, false, 50, peer) ==
             {:error, Storage.err_resource_does_not_exist()}

    assert Storage.stop(store) == :ok
  end

  test "populate_prom aggregates counters without error" do
    alias Bento.Tracker.Storage.Redis

    {:ok, {Redis, state} = store} =
      Storage.new("redis", %{redis_broker: "redis://127.0.0.1:#{@port}/#{@db}"})

    peer = %Peer{id: String.duplicate("p", 20), ip: {1, 2, 3, 4}, port: 1}
    :ok = Storage.put_seeder(store, String.duplicate("h", 20), peer)
    assert Redis.populate_prom(state) == :ok

    assert Storage.stop(store) == :ok
  end
end
