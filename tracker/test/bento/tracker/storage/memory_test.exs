defmodule Bento.Tracker.Storage.MemoryTest do
  # Ported from chihaya's storage/memory/peer_store_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.Storage
  alias Bento.Tracker.StorageCase

  defp create_new do
    {:ok, store} =
      Storage.new("memory", %{
        shard_count: 1024,
        gc_interval: :timer.minutes(10),
        prometheus_reporting_interval: :timer.minutes(10),
        peer_lifetime: :timer.minutes(30)
      })

    store
  end

  test "conforms to the peer store interface" do
    StorageCase.test_peer_store(create_new())
  end

  test "an unknown driver name is rejected" do
    assert Storage.new("nope", %{}) == {:error, :driver_does_not_exist}
  end

  test "garbage collection removes peers older than the cutoff" do
    alias Bento.Tracker.Peer
    alias Bento.Tracker.Storage.Memory

    {:ok, {_mod, state} = store} =
      Storage.new("memory", %{
        shard_count: 4,
        gc_interval: :timer.minutes(10),
        prometheus_reporting_interval: :timer.minutes(10),
        peer_lifetime: :timer.minutes(30)
      })

    ih = String.duplicate("g", 20)
    peer = %Peer{id: String.duplicate("p", 20), ip: {1, 2, 3, 4}, port: 1}
    assert Storage.put_seeder(store, ih, peer) == :ok

    # A cutoff before the peer's mtime must not remove it.
    assert Memory.collect_garbage(state, System.system_time(:nanosecond) - 1_000_000_000) == :ok
    scrape = Storage.scrape_swarm(store, ih, :ipv4)
    assert scrape.complete == 1

    # A cutoff at-or-after the peer's mtime removes it and its swarm.
    assert Memory.collect_garbage(state, System.system_time(:nanosecond)) == :ok
    scrape = Storage.scrape_swarm(store, ih, :ipv4)
    assert scrape.complete == 0

    assert Storage.announce_peers(store, ih, false, 50, peer) ==
             {:error, Storage.err_resource_does_not_exist()}

    assert Storage.stop(store) == :ok
  end

  test "announce_peers caps results at numwant and excludes the announcer from leechers" do
    alias Bento.Tracker.Peer

    {:ok, store} = Storage.new("memory", %{})

    ih = String.duplicate("n", 20)

    leechers =
      for i <- 1..10 do
        %Peer{id: String.duplicate(<<?a + i>>, 20), ip: {10, 0, 0, i}, port: i}
      end

    for peer <- leechers, do: :ok = Storage.put_leecher(store, ih, peer)

    announcer = hd(leechers)

    # A seeding announcer sees only leechers, capped at numwant.
    assert {:ok, peers} = Storage.announce_peers(store, ih, true, 5, announcer)
    assert length(peers) == 5

    # A leeching announcer never receives itself.
    assert {:ok, peers} = Storage.announce_peers(store, ih, false, 50, announcer)
    refute Enum.any?(peers, &Peer.equal?(&1, announcer))
    assert length(peers) == 9

    assert Storage.stop(store) == :ok
  end

  test "announce returns a varied random subset across repeated calls" do
    alias Bento.Tracker.Peer

    {:ok, store} = Storage.new("memory", %{shard_count: 4})
    ih = String.duplicate("r", 20)

    # Sequential low-valued peer IDs cluster at the low end of the key
    # space, the case that defeated the earlier ordered-scan selection.
    leechers = for i <- 1..40, do: %Peer{id: <<i::160>>, ip: {10, 0, 0, rem(i, 250)}, port: i}
    for peer <- leechers, do: :ok = Storage.put_leecher(store, ih, peer)

    announcer = %Peer{id: <<999::160>>, ip: {10, 0, 1, 1}, port: 999}

    subsets =
      for _ <- 1..20 do
        {:ok, peers} = Storage.announce_peers(store, ih, true, 5, announcer)
        assert length(peers) == 5
        # No duplicates within a single response.
        assert length(Enum.uniq_by(peers, &{&1.ip, &1.port})) == 5
        Enum.map(peers, & &1.port) |> Enum.sort()
      end

    # The subset varies across calls rather than always returning the same
    # (lowest-keyed) peers.
    assert length(Enum.uniq(subsets)) > 1

    assert Storage.stop(store) == :ok
  end
end
