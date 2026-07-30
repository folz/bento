defmodule Bento.Tracker.Logic do
  @moduledoc """
  The tracker logic: generates responses for announces and scrapes by
  executing a series of middleware hooks.

  Frontends call `handle_announce/3` / `handle_scrape/3` to produce a
  response (running the pre-hook chain, which ends with the built-in
  `Bento.Tracker.Middleware.ResponseHook`), write the response to the
  client, and then call `after_announce/4` / `after_scrape/4` (running
  the post-hook chain, which ends with the built-in
  `Bento.Tracker.Middleware.SwarmInteractionHook`).
  """

  require Logger

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.Middleware
  alias Bento.Tracker.Middleware.ResponseHook
  alias Bento.Tracker.Middleware.SwarmInteractionHook
  alias Bento.Tracker.ScrapeRequest
  alias Bento.Tracker.ScrapeResponse
  alias Bento.Tracker.Storage

  @enforce_keys [:announce_interval, :min_announce_interval, :store]
  defstruct announce_interval: 0,
            min_announce_interval: 0,
            store: nil,
            pre_hooks: [],
            post_hooks: []

  @type t :: %__MODULE__{
          announce_interval: non_neg_integer(),
          min_announce_interval: non_neg_integer(),
          store: Storage.t(),
          pre_hooks: [Middleware.hook()],
          post_hooks: [Middleware.hook()]
        }

  @doc """
  Creates a new tracker logic that executes the provided middleware
  hooks.

  The response configuration provides `:announce_interval` and
  `:min_announce_interval`, both in seconds.
  """
  @spec new(map(), Storage.t(), [Middleware.hook()], [Middleware.hook()]) :: t()
  def new(response_config, store, pre_hooks \\ [], post_hooks \\ []) do
    %__MODULE__{
      announce_interval: Map.fetch!(response_config, :announce_interval),
      min_announce_interval: Map.fetch!(response_config, :min_announce_interval),
      store: store,
      pre_hooks: pre_hooks ++ [{ResponseHook, store}],
      post_hooks: post_hooks ++ [{SwarmInteractionHook, store}]
    }
  end

  @doc "Generates a response for an announce."
  @spec handle_announce(t(), Middleware.ctx(), AnnounceRequest.t()) ::
          {:ok, Middleware.ctx(), AnnounceResponse.t()} | {:error, term()}
  def handle_announce(%__MODULE__{} = logic, ctx, request) do
    response = %AnnounceResponse{
      interval: logic.announce_interval,
      min_interval: logic.min_announce_interval,
      compact?: request.compact?
    }

    with {:ok, ctx, response} <- run_hooks(logic.pre_hooks, :announce, ctx, request, response) do
      Logger.debug(fn -> "generated announce response: #{inspect(response)}" end)
      {:ok, ctx, response}
    end
  end

  @doc """
  Does something with the results of an announce after it has been
  completed. Post-hook failures are logged, never raised.
  """
  @spec after_announce(t(), Middleware.ctx(), AnnounceRequest.t(), AnnounceResponse.t()) :: :ok
  def after_announce(%__MODULE__{} = logic, ctx, request, response) do
    case run_hooks(logic.post_hooks, :announce, ctx, request, response) do
      {:ok, _ctx, _response} ->
        :ok

      {:error, reason} ->
        Logger.error("post-announce hooks failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Generates a response for a scrape."
  @spec handle_scrape(t(), Middleware.ctx(), ScrapeRequest.t()) ::
          {:ok, Middleware.ctx(), ScrapeResponse.t()} | {:error, term()}
  def handle_scrape(%__MODULE__{} = logic, ctx, request) do
    with {:ok, ctx, response} <-
           run_hooks(logic.pre_hooks, :scrape, ctx, request, %ScrapeResponse{}) do
      Logger.debug(fn -> "generated scrape response: #{inspect(response)}" end)
      {:ok, ctx, response}
    end
  end

  @doc """
  Does something with the results of a scrape after it has been
  completed. Post-hook failures are logged, never raised.
  """
  @spec after_scrape(t(), Middleware.ctx(), ScrapeRequest.t(), ScrapeResponse.t()) :: :ok
  def after_scrape(%__MODULE__{} = logic, ctx, request, response) do
    case run_hooks(logic.post_hooks, :scrape, ctx, request, response) do
      {:ok, _ctx, _response} ->
        :ok

      {:error, reason} ->
        Logger.error("post-scrape hooks failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Stops the logic, stopping any hooks that require clean shutdown."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = logic) do
    Enum.each(logic.pre_hooks ++ logic.post_hooks, &Middleware.stop/1)
    :ok
  end

  defp run_hooks(hooks, kind, ctx, request, response) do
    Enum.reduce_while(hooks, {:ok, ctx, response}, fn hook, {:ok, ctx, response} ->
      result =
        case kind do
          :announce -> Middleware.handle_announce(hook, ctx, request, response)
          :scrape -> Middleware.handle_scrape(hook, ctx, request, response)
        end

      case result do
        {:ok, _ctx, _response} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
