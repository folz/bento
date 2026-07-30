defmodule Bento.Tracker.StorageCase do
  @moduledoc """
  A shared conformance suite for `Bento.Tracker.Storage` implementations,
  ported from chihaya's storage/storage_tests.go.

  Call `test_peer_store/2` from an implementation's test with a freshly
  created store.
  """

  import ExUnit.Assertions

  alias Bento.Tracker.Peer
  alias Bento.Tracker.Storage

  @v4_peer %Peer{id: "99999999999999999994", ip: {99, 99, 99, 99}, port: 9994}
  @v6_peer %Peer{
    id: "99999999999999999996",
    ip: {0xFC00, 0, 0, 0, 0, 0, 0, 0x0001},
    port: 9996
  }

  @test_data [
    {"00000000000000000001", %Peer{id: "00000000000000000001", ip: {1, 1, 1, 1}, port: 1}},
    {"00000000000000000002",
     %Peer{id: "00000000000000000002", ip: {0xABAB, 0, 0, 0, 0, 0, 0, 0x0001}, port: 2}}
  ]

  @doc """
  Tests a `Bento.Tracker.Storage` implementation against the interface.

  Options:

    * `:equality` - the function used to check two peers for equality.
      Defaults to `Peer.equal?/2`; implementations that discard the peer
      ID can use `Peer.equal_endpoint?/2`.
  """
  def test_peer_store(store, opts \\ []) do
    equal? = Keyword.get(opts, :equality, &Peer.equal?/2)

    for {ih, peer} <- @test_data do
      dummy = if Peer.address_family(peer) == :ipv6, do: @v6_peer, else: @v4_peer

      # Test resource-does-not-exist for non-existent swarms.
      assert Storage.delete_leecher(store, ih, peer) ==
               {:error, Storage.err_resource_does_not_exist()}

      assert Storage.delete_seeder(store, ih, peer) ==
               {:error, Storage.err_resource_does_not_exist()}

      assert Storage.announce_peers(store, ih, false, 50, dummy) ==
               {:error, Storage.err_resource_does_not_exist()}

      # Test empty scrape response for non-existent swarms.
      scrape = Storage.scrape_swarm(store, ih, Peer.address_family(peer))
      assert scrape.complete == 0
      assert scrape.incomplete == 0
      assert scrape.snatches == 0

      # Insert dummy peer to keep swarm active (same address family as peer).
      assert Storage.put_leecher(store, ih, dummy) == :ok

      # Test resource-does-not-exist for non-existent seeder.
      assert Storage.delete_seeder(store, ih, dummy) ==
               {:error, Storage.err_resource_does_not_exist()}

      # Test put_leecher -> announce -> delete_leecher -> announce.

      assert Storage.put_leecher(store, ih, peer) == :ok

      assert {:ok, peers} = Storage.announce_peers(store, ih, true, 50, dummy)
      assert contains_peer?(peers, peer, equal?)

      # A non-seeder announce should still return the leecher.
      assert {:ok, peers} = Storage.announce_peers(store, ih, false, 50, dummy)
      assert contains_peer?(peers, peer, equal?)

      scrape = Storage.scrape_swarm(store, ih, Peer.address_family(peer))
      assert scrape.incomplete == 2
      assert scrape.complete == 0

      assert Storage.delete_leecher(store, ih, peer) == :ok

      assert {:ok, peers} = Storage.announce_peers(store, ih, true, 50, dummy)
      refute contains_peer?(peers, peer, equal?)

      # Test put_seeder -> announce -> delete_seeder -> announce.

      assert Storage.put_seeder(store, ih, peer) == :ok

      # Has to be a leecher to see the seeder.
      assert {:ok, peers} = Storage.announce_peers(store, ih, false, 50, dummy)
      assert contains_peer?(peers, peer, equal?)

      scrape = Storage.scrape_swarm(store, ih, Peer.address_family(peer))
      assert scrape.incomplete == 1
      assert scrape.complete == 1

      assert Storage.delete_seeder(store, ih, peer) == :ok

      assert {:ok, peers} = Storage.announce_peers(store, ih, false, 50, dummy)
      refute contains_peer?(peers, peer, equal?)

      # Test put_leecher -> graduate -> announce -> delete_leecher -> announce.

      assert Storage.put_leecher(store, ih, peer) == :ok
      assert Storage.graduate_leecher(store, ih, peer) == :ok

      # Has to be a leecher to see the graduated seeder.
      assert {:ok, peers} = Storage.announce_peers(store, ih, false, 50, dummy)
      assert contains_peer?(peers, peer, equal?)

      # Deleting the peer as a leecher should have no effect.
      assert Storage.delete_leecher(store, ih, peer) ==
               {:error, Storage.err_resource_does_not_exist()}

      # Verify it's still there.
      assert {:ok, peers} = Storage.announce_peers(store, ih, false, 50, dummy)
      assert contains_peer?(peers, peer, equal?)

      # Clean up.

      assert Storage.delete_leecher(store, ih, dummy) == :ok

      # Test resource-does-not-exist for missing leecher.
      assert Storage.delete_leecher(store, ih, dummy) ==
               {:error, Storage.err_resource_does_not_exist()}

      assert Storage.delete_seeder(store, ih, peer) == :ok

      assert Storage.delete_seeder(store, ih, peer) ==
               {:error, Storage.err_resource_does_not_exist()}
    end

    assert Storage.stop(store) == :ok
  end

  defp contains_peer?(peers, peer, equal?) do
    Enum.any?(peers, &equal?.(&1, peer))
  end
end
