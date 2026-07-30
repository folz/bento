defmodule Bento.Tracker.Middleware do
  @moduledoc """
  The middleware framework: hooks that interact with a BitTorrent
  client's request and response, and a driver registry to construct them
  from configuration.

  A hook instance is an opaque `{module, state}` pair; pre-hooks and
  post-hooks share the same `Bento.Tracker.Middleware.Hook` behaviour.
  Requests thread a context map through every hook, replacing Go's
  `context.Context`; well-known keys are exposed as functions below.
  """

  alias Bento.Tracker.Middleware.Hook

  @typedoc "An opaque handle to a hook instance."
  @type hook :: {module(), term()}

  @typedoc "The per-request context threaded through hooks."
  @type ctx :: map()

  @doc """
  The context key controlling whether the swarm interaction middleware
  should run. Any value other than `nil` set for this key will cause the
  swarm interaction middleware to skip.
  """
  @spec skip_swarm_interaction_key() :: atom()
  def skip_swarm_interaction_key, do: :skip_swarm_interaction

  @doc """
  The context key controlling whether the response middleware should run.
  Any value other than `nil` set for this key will cause the response
  middleware to skip.
  """
  @spec skip_response_hook_key() :: atom()
  def skip_response_hook_key, do: :skip_response_hook

  @doc """
  The context key under which to store whether the address used to
  request a scrape was an IPv6 address. The value is expected to be a
  boolean; a missing or non-boolean value is equivalent to `false`.
  """
  @spec scrape_is_ipv6_key() :: atom()
  def scrape_is_ipv6_key, do: :scrape_is_ipv6

  @doc """
  The context key under which frontends store the named parameters
  matched on the announce route.
  """
  @spec route_params_key() :: atom()
  def route_params_key, do: :route_params

  @builtin_drivers %{
    "client approval" => Bento.Tracker.Middleware.ClientApproval,
    "torrent approval" => Bento.Tracker.Middleware.TorrentApproval,
    "interval variation" => Bento.Tracker.Middleware.VarInterval,
    "jwt" => Bento.Tracker.Middleware.JWT
  }

  @doc """
  The map of available middleware driver names: the built-in drivers
  merged with any drivers configured under the `:middleware_drivers` key
  of the `:bento_tracker` application environment.
  """
  @spec drivers() :: %{optional(String.t()) => module()}
  def drivers do
    Map.merge(@builtin_drivers, Application.get_env(:bento_tracker, :middleware_drivers, %{}))
  end

  @doc """
  Initializes a new hook instance from the list of registered drivers.

  If the driver does not exist, returns `{:error, :driver_does_not_exist}`.
  """
  @spec new(String.t(), map()) :: {:ok, hook()} | {:error, term()}
  def new(name, options) do
    case Map.fetch(drivers(), name) do
      {:ok, module} ->
        with {:ok, state} <- module.new(options), do: {:ok, {module, state}}

      :error ->
        {:error, :driver_does_not_exist}
    end
  end

  @doc """
  Initializes hooks in bulk from a list of `%{name: ..., options: ...}`
  configurations.
  """
  @spec hooks_from_hook_configs([map()]) :: {:ok, [hook()]} | {:error, term()}
  def hooks_from_hook_configs(configs) do
    configs
    |> Enum.reduce_while([], fn config, hooks ->
      name = Map.get(config, :name) || Map.get(config, "name")
      options = Map.get(config, :options) || Map.get(config, "options") || %{}

      case new(name, options) do
        {:ok, hook} -> {:cont, [hook | hooks]}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      hooks -> {:ok, Enum.reverse(hooks)}
    end
  end

  @doc "Runs a hook's announce handler."
  @spec handle_announce(hook(), ctx(), term(), term()) ::
          {:ok, ctx(), term()} | {:error, term()}
  def handle_announce({module, state}, ctx, request, response) do
    module.handle_announce(state, ctx, request, response)
  end

  @doc "Runs a hook's scrape handler."
  @spec handle_scrape(hook(), ctx(), term(), term()) ::
          {:ok, ctx(), term()} | {:error, term()}
  def handle_scrape({module, state}, ctx, request, response) do
    module.handle_scrape(state, ctx, request, response)
  end

  @doc "Stops a hook if its module implements the optional `stop/1`."
  @spec stop(hook()) :: :ok
  def stop({module, state}) do
    if function_exported?(module, :stop, 1) do
      module.stop(state)
    end

    :ok
  end

  defmodule Hook do
    @moduledoc """
    Anything that needs to interact with a BitTorrent client's request
    and response to a BitTorrent tracker. Pre-hooks and post-hooks both
    use the same behaviour.

    `new/1` builds the hook's state from its configuration options; the
    optional `stop/1` is invoked on shutdown for hooks that need clean
    teardown.
    """

    alias Bento.Tracker.AnnounceRequest
    alias Bento.Tracker.AnnounceResponse
    alias Bento.Tracker.Middleware
    alias Bento.Tracker.ScrapeRequest
    alias Bento.Tracker.ScrapeResponse

    @callback new(options :: map()) :: {:ok, term()} | {:error, term()}

    @callback handle_announce(
                state :: term(),
                Middleware.ctx(),
                AnnounceRequest.t(),
                AnnounceResponse.t()
              ) :: {:ok, Middleware.ctx(), AnnounceResponse.t()} | {:error, term()}

    @callback handle_scrape(
                state :: term(),
                Middleware.ctx(),
                ScrapeRequest.t(),
                ScrapeResponse.t()
              ) :: {:ok, Middleware.ctx(), ScrapeResponse.t()} | {:error, term()}

    @callback stop(state :: term()) :: :ok

    @optional_callbacks new: 1, stop: 1
  end
end
