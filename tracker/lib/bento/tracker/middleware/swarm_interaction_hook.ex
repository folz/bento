defmodule Bento.Tracker.Middleware.SwarmInteractionHook do
  @moduledoc """
  The built-in post-hook that updates the peer store according to the
  announce. It always runs last in the post-hook chain.
  """

  @behaviour Bento.Tracker.Middleware.Hook

  alias Bento.Tracker.Middleware
  alias Bento.Tracker.Storage

  @impl true
  def handle_announce(store, ctx, request, response) do
    if Map.get(ctx, Middleware.skip_swarm_interaction_key()) do
      {:ok, ctx, response}
    else
      with :ok <- interact(store, request) do
        {:ok, ctx, response}
      end
    end
  end

  defp interact(store, %{event: :stopped} = request) do
    with :ok <-
           ignore_does_not_exist(Storage.delete_seeder(store, request.info_hash, request.peer)) do
      ignore_does_not_exist(Storage.delete_leecher(store, request.info_hash, request.peer))
    end
  end

  defp interact(store, %{event: :completed} = request) do
    Storage.graduate_leecher(store, request.info_hash, request.peer)
  end

  # Completed events will also have left == 0, but by making this an
  # extra case we can treat "old" seeders differently from graduating
  # leechers. (Calling put_seeder is probably faster than calling
  # graduate_leecher.)
  defp interact(store, %{left: 0} = request) do
    Storage.put_seeder(store, request.info_hash, request.peer)
  end

  defp interact(store, request) do
    Storage.put_leecher(store, request.info_hash, request.peer)
  end

  defp ignore_does_not_exist(:ok), do: :ok

  defp ignore_does_not_exist({:error, error}) do
    if error == Storage.err_resource_does_not_exist() do
      :ok
    else
      {:error, error}
    end
  end

  @impl true
  def handle_scrape(_store, ctx, _request, response) do
    # Scrapes have no effect on the swarm.
    {:ok, ctx, response}
  end
end
