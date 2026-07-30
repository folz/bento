defmodule Bento.Tracker.Middleware.ResponseHook do
  @moduledoc """
  The built-in pre-hook that fills announce and scrape responses from the
  peer store. It always runs last in the pre-hook chain.
  """

  @behaviour Bento.Tracker.Middleware.Hook

  alias Bento.Tracker.Middleware
  alias Bento.Tracker.Peer
  alias Bento.Tracker.Storage

  @impl true
  def handle_announce(store, ctx, request, response) do
    if Map.get(ctx, Middleware.skip_response_hook_key()) do
      {:ok, ctx, response}
    else
      # Add the scrape data to the response.
      scrape = Storage.scrape_swarm(store, request.info_hash, Peer.address_family(request.peer))
      response = %{response | incomplete: scrape.incomplete, complete: scrape.complete}

      with {:ok, response} <- append_peers(store, request, response) do
        {:ok, ctx, response}
      end
    end
  end

  defp append_peers(store, request, response) do
    seeding? = request.left == 0

    case Storage.announce_peers(store, request.info_hash, seeding?, request.numwant, request.peer) do
      {:ok, peers} ->
        {:ok, assign_peers(request, response, seeding?, peers)}

      {:error, error} ->
        if error == Storage.err_resource_does_not_exist() do
          {:ok, assign_peers(request, response, seeding?, [])}
        else
          {:error, error}
        end
    end
  end

  # Some clients expect a minimum of their own peer representation
  # returned to them if they are the only peer in a swarm.
  defp assign_peers(request, response, seeding?, []) do
    response =
      if seeding? do
        %{response | complete: response.complete + 1}
      else
        %{response | incomplete: response.incomplete + 1}
      end

    put_peers(request, response, [request.peer])
  end

  defp assign_peers(request, response, _seeding?, peers) do
    put_peers(request, response, peers)
  end

  defp put_peers(request, response, peers) do
    case Peer.address_family(request.peer) do
      :ipv4 -> %{response | ipv4_peers: peers}
      :ipv6 -> %{response | ipv6_peers: peers}
    end
  end

  @impl true
  def handle_scrape(store, ctx, request, response) do
    if Map.get(ctx, Middleware.skip_response_hook_key()) do
      {:ok, ctx, response}
    else
      files =
        Enum.map(request.info_hashes, fn info_hash ->
          Storage.scrape_swarm(store, info_hash, request.address_family)
        end)

      {:ok, ctx, %{response | files: response.files ++ files}}
    end
  end
end
