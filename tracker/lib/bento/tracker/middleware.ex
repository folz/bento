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
      name = get_option(config, :name)
      options = get_option(config, :options) || %{}

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

  @doc """
  Fetches a hook option under either an atom or a string key, the two
  shapes configuration can arrive in.
  """
  @spec get_option(map(), atom()) :: term()
  def get_option(options, key) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key))
  end

  @doc """
  Validates that a whitelist and a blacklist are not both configured.
  """
  @spec check_exclusive(list(), list()) :: :ok | {:error, String.t()}
  def check_exclusive([_ | _], [_ | _]) do
    {:error, "using both whitelist and blacklist is invalid"}
  end

  def check_exclusive(_whitelist, _blacklist), do: :ok

  @doc """
  The shared whitelist/blacklist decision: with a non-empty `approved`
  set the key must be a member; with a non-empty `unapproved` set the key
  must not be.
  """
  @spec approved?(%{approved: MapSet.t(), unapproved: MapSet.t()}, term()) :: boolean()
  def approved?(%{approved: approved, unapproved: unapproved}, key) do
    cond do
      MapSet.size(approved) > 0 -> MapSet.member?(approved, key)
      MapSet.size(unapproved) > 0 -> not MapSet.member?(unapproved, key)
      true -> true
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
end
