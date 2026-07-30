defmodule Bento.Tracker.Storage do
  @moduledoc """
  Abstractions for storing and retrieving peers from their announced
  infohashes.

  A store is created from a named driver with `new/2` and handled as an
  opaque `{module, state}` pair. Implementations must, in addition to
  implementing the callbacks as documented:

    * Implement a garbage-collection strategy that ensures stale data is
      removed. For example, a timestamp on each infohash/peer combination
      can be used to track the last activity for that peer. The entire
      database can then be scanned periodically and too-old peers
      removed. The intervals and durations involved should be
      configurable.

    * Isolate IPv4 and IPv6 swarms from each other. A store must be able
      to transparently handle IPv4 and IPv6 peers, but must separate
      them. `announce_peers/5` and `scrape_swarm/3` must return
      information about the swarm matching the given address family only.

  Implementations can be tested against this interface using
  `Bento.Tracker.StorageCase` and benchmarked using `bench/storage.exs`.
  """

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.InfoHash
  alias Bento.Tracker.IP
  alias Bento.Tracker.Peer
  alias Bento.Tracker.Scrape

  @typedoc "An opaque handle to a peer store instance."
  @type t :: {module(), term()}

  @err_resource_does_not_exist ClientError.new("resource does not exist")

  @doc """
  The client error returned by all delete functions and `announce_peers/5`
  if the requested resource does not exist.
  """
  @spec err_resource_does_not_exist() :: ClientError.t()
  def err_resource_does_not_exist, do: @err_resource_does_not_exist

  @doc "Creates the store state from a driver-specific configuration map."
  @callback new(config :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Adds a seeder to the swarm identified by the provided infohash."
  @callback put_seeder(state :: term(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}

  @doc """
  Removes a seeder from the swarm identified by the provided infohash.

  If the swarm or peer does not exist, this function returns
  `{:error, err_resource_does_not_exist()}`.
  """
  @callback delete_seeder(state :: term(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}

  @doc """
  Adds a leecher to the swarm identified by the provided infohash. If the
  swarm does not exist already, it is created.
  """
  @callback put_leecher(state :: term(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}

  @doc """
  Removes a leecher from the swarm identified by the provided infohash.

  If the swarm or peer does not exist, this function returns
  `{:error, err_resource_does_not_exist()}`.
  """
  @callback delete_leecher(state :: term(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}

  @doc """
  Promotes a leecher to a seeder in the swarm identified by the provided
  infohash.

  If the given peer is not present as a leecher or the swarm does not
  exist already, the peer is added as a seeder and no error is returned.
  """
  @callback graduate_leecher(state :: term(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}

  @doc """
  A best-effort attempt to return peers from the swarm identified by the
  provided infohash.

  The `num_want` parameter indicates the number of peers requested by the
  announcing peer. The `seeder?` flag determines whether the peer
  announced as a seeder. The returned peers are required to be either all
  IPv4 or all IPv6.

  The returned peers should strive to be:

    * as close to length equal to `num_want` as possible without going over
    * all IPv4 or all IPv6 depending on the provided peer
    * if `seeder?` is true, should ideally return more leechers than seeders
    * if `seeder?` is false, should ideally return more seeders than leechers

  Returns `{:error, err_resource_does_not_exist()}` if the provided
  infohash is not tracked.
  """
  @callback announce_peers(
              state :: term(),
              InfoHash.t(),
              seeder? :: boolean(),
              num_want :: non_neg_integer(),
              Peer.t()
            ) :: {:ok, [Peer.t()]} | {:error, term()}

  @doc """
  Returns information required to answer a scrape request about the swarm
  identified by the given infohash.

  The address family indicates whether the IPv4 or IPv6 swarm should be
  scraped. The `complete` and `incomplete` fields of the scrape must be
  filled; filling the `snatches` field is optional.

  If the swarm does not exist, an empty scrape is returned.
  """
  @callback scrape_swarm(state :: term(), InfoHash.t(), IP.address_family()) :: Scrape.t()

  @doc "Cleanly shuts the store down, releasing its resources."
  @callback stop(state :: term()) :: :ok

  @doc "Returns a loggable version of the store's configuration."
  @callback log_value(state :: term()) :: map()

  @builtin_drivers %{
    "memory" => Bento.Tracker.Storage.Memory,
    "redis" => Bento.Tracker.Storage.Redis
  }

  @doc """
  The map of available driver names, the built-in `"memory"` and
  `"redis"` drivers merged with any drivers configured under the
  `:storage_drivers` key of the `:bento_tracker` application environment.
  """
  @spec drivers() :: %{optional(String.t()) => module()}
  def drivers do
    Map.merge(@builtin_drivers, Application.get_env(:bento_tracker, :storage_drivers, %{}))
  end

  @doc """
  Initializes a new store instance from the list of registered drivers.

  If the driver does not exist, returns `{:error, :driver_does_not_exist}`.
  """
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def new(name, config \\ %{}) do
    case Map.fetch(drivers(), name) do
      {:ok, module} ->
        with {:ok, state} <- module.new(config), do: {:ok, {module, state}}

      :error ->
        {:error, :driver_does_not_exist}
    end
  end

  @doc "See `c:put_seeder/3`."
  @spec put_seeder(t(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}
  def put_seeder({module, state}, info_hash, peer), do: module.put_seeder(state, info_hash, peer)

  @doc "See `c:delete_seeder/3`."
  @spec delete_seeder(t(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}
  def delete_seeder({module, state}, info_hash, peer) do
    module.delete_seeder(state, info_hash, peer)
  end

  @doc "See `c:put_leecher/3`."
  @spec put_leecher(t(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}
  def put_leecher({module, state}, info_hash, peer) do
    module.put_leecher(state, info_hash, peer)
  end

  @doc "See `c:delete_leecher/3`."
  @spec delete_leecher(t(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}
  def delete_leecher({module, state}, info_hash, peer) do
    module.delete_leecher(state, info_hash, peer)
  end

  @doc "See `c:graduate_leecher/3`."
  @spec graduate_leecher(t(), InfoHash.t(), Peer.t()) :: :ok | {:error, term()}
  def graduate_leecher({module, state}, info_hash, peer) do
    module.graduate_leecher(state, info_hash, peer)
  end

  @doc "See `c:announce_peers/5`."
  @spec announce_peers(t(), InfoHash.t(), boolean(), non_neg_integer(), Peer.t()) ::
          {:ok, [Peer.t()]} | {:error, term()}
  def announce_peers({module, state}, info_hash, seeder?, num_want, peer) do
    module.announce_peers(state, info_hash, seeder?, num_want, peer)
  end

  @doc "See `c:scrape_swarm/3`."
  @spec scrape_swarm(t(), InfoHash.t(), IP.address_family()) :: Scrape.t()
  def scrape_swarm({module, state}, info_hash, address_family) do
    module.scrape_swarm(state, info_hash, address_family)
  end

  @doc "See `c:stop/1`."
  @spec stop(t()) :: :ok
  def stop({module, state}), do: module.stop(state)

  @doc "See `c:log_value/1`."
  @spec log_value(t()) :: map()
  def log_value({module, state}), do: module.log_value(state)
end
