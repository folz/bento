defmodule Bento.Tracker.LogicTest do
  # chihaya's middleware/logic_test.go contains only hook-overhead
  # benchmarks; these tests cover the documented behavior of the logic
  # and its built-in response and swarm-interaction hooks.
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.Logic
  alias Bento.Tracker.Peer
  alias Bento.Tracker.ScrapeRequest
  alias Bento.Tracker.Storage

  defmodule FailingHook do
    @behaviour Bento.Tracker.Middleware.Hook

    @impl true
    def handle_announce(reason, _ctx, _req, _resp), do: {:error, reason}

    @impl true
    def handle_scrape(reason, _ctx, _req, _resp), do: {:error, reason}
  end

  defmodule ContextHook do
    @behaviour Bento.Tracker.Middleware.Hook

    @impl true
    def handle_announce(key, ctx, _req, resp), do: {:ok, Map.put(ctx, key, true), resp}

    @impl true
    def handle_scrape(key, ctx, _req, resp), do: {:ok, Map.put(ctx, key, true), resp}
  end

  defp new_logic(pre_hooks \\ [], post_hooks \\ []) do
    {:ok, store} = Storage.new("memory", %{shard_count: 4})

    logic =
      Logic.new(
        %{announce_interval: 1800, min_announce_interval: 900},
        store,
        pre_hooks,
        post_hooks
      )

    {logic, store}
  end

  defp announce_request(overrides) do
    peer = %Peer{id: String.duplicate("p", 20), ip: {1, 2, 3, 4}, port: 6881}

    struct!(
      %AnnounceRequest{info_hash: String.duplicate("i", 20), peer: peer, numwant: 50},
      overrides
    )
  end

  test "handle_announce builds a response with the configured intervals" do
    {logic, _store} = new_logic()
    request = announce_request(compact?: true)

    assert {:ok, _ctx, %AnnounceResponse{} = response} =
             Logic.handle_announce(logic, %{}, request)

    assert response.interval == 1800
    assert response.min_interval == 900
    assert response.compact?
  end

  test "an announce for an empty swarm returns the announcing peer itself" do
    {logic, _store} = new_logic()
    request = announce_request([])

    assert {:ok, _ctx, response} = Logic.handle_announce(logic, %{}, request)

    # The announcer is a leecher (left > 0 is not required; left defaults
    # to 0 here, making it a seeder), so it is counted as complete.
    assert response.complete == 1
    assert response.incomplete == 0
    assert [peer] = response.ipv4_peers
    assert Peer.equal?(peer, request.peer)
    assert response.ipv6_peers == []
  end

  test "an IPv6 announce populates ipv6_peers" do
    {logic, _store} = new_logic()
    peer = %Peer{id: String.duplicate("p", 20), ip: {0xFC00, 0, 0, 0, 0, 0, 0, 1}, port: 6881}
    request = announce_request(peer: peer, left: 1)

    assert {:ok, _ctx, response} = Logic.handle_announce(logic, %{}, request)
    assert response.incomplete == 1
    assert [returned] = response.ipv6_peers
    assert Peer.equal?(returned, peer)
    assert response.ipv4_peers == []
  end

  test "after_announce with a normal announce adds the peer as a leecher" do
    {logic, store} = new_logic()
    request = announce_request(left: 100)

    assert {:ok, ctx, response} = Logic.handle_announce(logic, %{}, request)
    assert Logic.after_announce(logic, ctx, request, response) == :ok

    scrape = Storage.scrape_swarm(store, request.info_hash, :ipv4)
    assert scrape.incomplete == 1
    assert scrape.complete == 0
  end

  test "after_announce with left == 0 adds the peer as a seeder" do
    {logic, store} = new_logic()
    request = announce_request(left: 0)

    assert {:ok, ctx, response} = Logic.handle_announce(logic, %{}, request)
    assert Logic.after_announce(logic, ctx, request, response) == :ok

    scrape = Storage.scrape_swarm(store, request.info_hash, :ipv4)
    assert scrape.complete == 1
  end

  test "after_announce with a completed event graduates the leecher" do
    {logic, store} = new_logic()
    request = announce_request(left: 100)

    {:ok, ctx, response} = Logic.handle_announce(logic, %{}, request)
    :ok = Logic.after_announce(logic, ctx, request, response)
    assert Storage.scrape_swarm(store, request.info_hash, :ipv4).incomplete == 1

    request = announce_request(left: 0, event: :completed, event_provided?: true)
    {:ok, ctx, response} = Logic.handle_announce(logic, %{}, request)
    :ok = Logic.after_announce(logic, ctx, request, response)

    scrape = Storage.scrape_swarm(store, request.info_hash, :ipv4)
    assert scrape.complete == 1
    assert scrape.incomplete == 0
  end

  test "after_announce with a stopped event removes the peer" do
    {logic, store} = new_logic()
    request = announce_request(left: 100)

    {:ok, ctx, response} = Logic.handle_announce(logic, %{}, request)
    :ok = Logic.after_announce(logic, ctx, request, response)
    assert Storage.scrape_swarm(store, request.info_hash, :ipv4).incomplete == 1

    request = announce_request(left: 100, event: :stopped, event_provided?: true)
    {:ok, ctx, response} = Logic.handle_announce(logic, %{}, request)
    :ok = Logic.after_announce(logic, ctx, request, response)

    scrape = Storage.scrape_swarm(store, request.info_hash, :ipv4)
    assert scrape.incomplete == 0
    assert scrape.complete == 0
  end

  test "a failing pre-hook aborts the announce" do
    {logic, _store} = new_logic([{FailingHook, :boom}])
    request = announce_request([])

    assert Logic.handle_announce(logic, %{}, request) == {:error, :boom}
  end

  test "pre-hooks can thread values through the context" do
    {logic, _store} = new_logic([{ContextHook, :seen}])
    request = announce_request([])

    assert {:ok, ctx, _response} = Logic.handle_announce(logic, %{}, request)
    assert ctx.seen
  end

  test "skip_response_hook leaves the response untouched" do
    {logic, _store} = new_logic()
    request = announce_request([])

    ctx = %{Bento.Tracker.Middleware.skip_response_hook_key() => true}
    assert {:ok, _ctx, response} = Logic.handle_announce(logic, ctx, request)
    assert response.ipv4_peers == []
    assert response.complete == 0
  end

  test "skip_swarm_interaction leaves the store untouched" do
    {logic, store} = new_logic()
    request = announce_request(left: 100)

    ctx = %{Bento.Tracker.Middleware.skip_swarm_interaction_key() => true}
    {:ok, ctx, response} = Logic.handle_announce(logic, ctx, request)
    :ok = Logic.after_announce(logic, ctx, request, response)

    assert Storage.scrape_swarm(store, request.info_hash, :ipv4).incomplete == 0
  end

  test "handle_scrape returns files in request order" do
    {logic, store} = new_logic()

    ih_a = String.duplicate("a", 20)
    ih_b = String.duplicate("b", 20)

    seeder = %Peer{id: String.duplicate("s", 20), ip: {1, 1, 1, 1}, port: 1}
    :ok = Storage.put_seeder(store, ih_b, seeder)

    request = %ScrapeRequest{address_family: :ipv4, info_hashes: [ih_a, ih_b]}

    assert {:ok, _ctx, response} = Logic.handle_scrape(logic, %{}, request)
    assert [scrape_a, scrape_b] = response.files
    assert scrape_a.info_hash == ih_a
    assert scrape_a.complete == 0
    assert scrape_b.info_hash == ih_b
    assert scrape_b.complete == 1
  end

  test "a failing post-hook is logged, not raised" do
    {logic, _store} = new_logic([], [{FailingHook, :post_boom}])
    request = announce_request([])

    {:ok, ctx, response} = Logic.handle_announce(logic, %{}, request)
    assert Logic.after_announce(logic, ctx, request, response) == :ok
  end

  test "middleware driver registry rejects unknown names" do
    assert Bento.Tracker.Middleware.new("nope", %{}) == {:error, :driver_does_not_exist}
  end
end
