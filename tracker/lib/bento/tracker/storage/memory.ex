defmodule Bento.Tracker.Storage.Memory do
  @moduledoc """
  A `Bento.Tracker.Storage` implementation keeping peer data in memory.

  Peers are stored in `2 * shard_count` ETS tables: the first half is
  dedicated to IPv4 swarms and the second half to IPv6 swarms, with
  infohashes distributed across shards by their leading 32 bits, exactly
  like chihaya's memory store. Data operations run in the calling process
  directly against ETS; a supervising process owns the tables and runs
  garbage collection and statistics reporting on timers.

  ## Configuration

    * `:shard_count` - the number of shards per address family
      (default: `1024`)
    * `:gc_interval` - interval between garbage collections, in
      milliseconds (default: 3 minutes)
    * `:peer_lifetime` - time after the last announce at which a peer is
      considered stale, in milliseconds (default: 30 minutes)
    * `:prometheus_reporting_interval` - interval between statistics
      updates, in milliseconds (default: 1 second)

  Invalid values fall back to their defaults with a logged warning.
  """

  @behaviour Bento.Tracker.Storage

  use GenServer

  require Logger

  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Peer
  alias Bento.Tracker.Scrape
  alias Bento.Tracker.Storage
  alias Bento.Tracker.TimeCache

  @name "memory"

  @default_shard_count 1024
  @default_prometheus_reporting_interval :timer.seconds(1)
  @default_gc_interval :timer.minutes(3)
  @default_peer_lifetime :timer.minutes(30)

  # Kinds are ordered integers so both kinds of one swarm are adjacent in
  # the shard's ordered_set.
  @seeder 0
  @leecher 1

  defmodule State do
    @moduledoc false
    defstruct [:pid, :shards, :counters, :config]
  end

  ## Lifecycle

  @impl Storage
  def new(config) do
    with {:ok, pid} <- GenServer.start(__MODULE__, config) do
      {:ok, handle(pid)}
    end
  end

  @doc "Starts a memory store linked to the calling process."
  def start_link(config \\ %{}, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @doc "Returns the store handle used for data operations."
  @spec handle(pid()) :: %State{}
  def handle(pid), do: GenServer.call(pid, :handle)

  @impl Storage
  def stop(%State{pid: pid}) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl Storage
  def log_value(%State{config: config}), do: Map.put(config, :name, @name)

  ## Storage operations (run in the calling process)

  @impl Storage
  def put_seeder(%State{} = state, info_hash, peer) do
    upsert(state, info_hash, @seeder, peer)
  end

  @impl Storage
  def put_leecher(%State{} = state, info_hash, peer) do
    upsert(state, info_hash, @leecher, peer)
  end

  @impl Storage
  def delete_seeder(%State{} = state, info_hash, peer) do
    delete(state, info_hash, @seeder, peer)
  end

  @impl Storage
  def delete_leecher(%State{} = state, info_hash, peer) do
    delete(state, info_hash, @leecher, peer)
  end

  @impl Storage
  def graduate_leecher(%State{} = state, info_hash, peer) do
    {shard, index} = shard_for(state, info_hash, Peer.address_family(peer))
    key = Peer.to_key(peer)

    case :ets.take(shard, {info_hash, @leecher, key}) do
      [_object] -> :counters.sub(state.counters, counter_index(index, @leecher), 1)
      [] -> :ok
    end

    upsert(state, info_hash, @seeder, peer)
  end

  @impl Storage
  def announce_peers(%State{} = state, info_hash, seeder?, num_want, announcer) do
    {shard, _index} = shard_for(state, info_hash, Peer.address_family(announcer))

    if swarm_exists?(shard, info_hash) do
      peers =
        if seeder? do
          # Return as many leechers as possible.
          sample(shard, info_hash, @leecher, num_want, nil)
        else
          # Return as many seeders as possible, then fill up with
          # leechers, excluding the announcing peer itself.
          seeders = sample(shard, info_hash, @seeder, num_want, nil)
          remaining = num_want - length(seeders)

          if remaining > 0 do
            seeders ++ sample(shard, info_hash, @leecher, remaining, Peer.to_key(announcer))
          else
            seeders
          end
        end

      {:ok, peers}
    else
      {:error, Storage.err_resource_does_not_exist()}
    end
  end

  @impl Storage
  def scrape_swarm(%State{} = state, info_hash, address_family) do
    {shard, _index} = shard_for(state, info_hash, address_family)

    %Scrape{
      info_hash: info_hash,
      complete: count_peers(shard, info_hash, @seeder),
      incomplete: count_peers(shard, info_hash, @leecher)
    }
  end

  @doc """
  Deletes all peers from the store which have not announced since the
  cutoff (in nanoseconds since the Unix epoch).

  This function executes safely while other operations run in parallel.
  """
  @spec collect_garbage(%State{}, integer()) :: :ok
  def collect_garbage(%State{} = state, cutoff_ns) do
    started_at = System.monotonic_time(:microsecond)

    for index <- 0..(state.config.shard_count * 2 - 1) do
      shard = elem(state.shards, index)

      expired =
        :ets.select(shard, [{{:"$1", :"$2"}, [{:"=<", :"$2", cutoff_ns}], [{{:"$1", :"$2"}}]}])

      for {{_ih, kind, _pk} = key, mtime} <- expired do
        # Delete only if the entry has not been refreshed since we
        # selected it, then account for it.
        case :ets.select_delete(shard, [{{key, mtime}, [], [true]}]) do
          1 -> :counters.sub(state.counters, counter_index(index, kind), 1)
          0 -> :ok
        end
      end
    end

    duration_ms = (System.monotonic_time(:microsecond) - started_at) / 1000
    Metrics.observe("chihaya_storage_gc_duration_milliseconds", %{}, duration_ms)
    :ok
  end

  @doc """
  Aggregates infohash, seeder and leecher counts over all shards and
  publishes them to `Bento.Tracker.Metrics`.
  """
  @spec populate_prom(%State{}) :: :ok
  def populate_prom(%State{} = state) do
    num_infohashes =
      state.shards
      |> Tuple.to_list()
      |> Enum.map(&count_infohashes/1)
      |> Enum.sum()

    {num_seeders, num_leechers} =
      Enum.reduce(0..(state.config.shard_count * 2 - 1), {0, 0}, fn index, {seeders, leechers} ->
        {seeders + :counters.get(state.counters, counter_index(index, @seeder)),
         leechers + :counters.get(state.counters, counter_index(index, @leecher))}
      end)

    Metrics.set_gauge("chihaya_storage_infohashes_count", num_infohashes)
    Metrics.set_gauge("chihaya_storage_seeders_count", num_seeders)
    Metrics.set_gauge("chihaya_storage_leechers_count", num_leechers)
    :ok
  end

  ## GenServer callbacks (table ownership, GC and reporting timers)

  @impl GenServer
  def init(config) do
    config = validate_config(config)

    shards =
      for _ <- 1..(config.shard_count * 2) do
        :ets.new(__MODULE__, [
          :ordered_set,
          :public,
          {:write_concurrency, true},
          {:read_concurrency, true}
        ])
      end

    state = %State{
      pid: self(),
      shards: List.to_tuple(shards),
      counters: :counters.new(config.shard_count * 2 * 2, [:write_concurrency]),
      config: config
    }

    Process.send_after(self(), :collect_garbage, config.gc_interval)
    Process.send_after(self(), :populate_prom, config.prometheus_reporting_interval)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:handle, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info(:collect_garbage, state) do
    cutoff_ns = TimeCache.now_unix_nano() - state.config.peer_lifetime * 1_000_000

    Logger.debug(fn ->
      "storage: purging peers with no announces since #{cutoff_ns}"
    end)

    collect_garbage(state, cutoff_ns)
    Process.send_after(self(), :collect_garbage, state.config.gc_interval)
    {:noreply, state}
  end

  def handle_info(:populate_prom, state) do
    populate_prom(state)
    Process.send_after(self(), :populate_prom, state.config.prometheus_reporting_interval)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug(fn -> "memory store received unexpected message: #{inspect(msg)}" end)
    {:noreply, state}
  end

  ## Internals

  defp validate_config(config) do
    defaults = %{
      shard_count: @default_shard_count,
      gc_interval: @default_gc_interval,
      peer_lifetime: @default_peer_lifetime,
      prometheus_reporting_interval: @default_prometheus_reporting_interval
    }

    Enum.reduce(defaults, %{}, fn {key, default}, acc ->
      provided = Map.get(config, key)

      if is_integer(provided) and provided > 0 do
        Map.put(acc, key, provided)
      else
        unless is_nil(provided) do
          Logger.warning(
            "falling back to default configuration: #{@name}.#{key} " <>
              "provided=#{inspect(provided)} default=#{default}"
          )
        end

        Map.put(acc, key, default)
      end
    end)
  end

  # There are twice the amount of shards specified by the user; the first
  # half is dedicated to IPv4 swarms and the second half to IPv6 swarms.
  defp shard_for(%State{} = state, info_hash, address_family) do
    <<prefix::32-big, _rest::binary>> = info_hash
    index = rem(prefix, state.config.shard_count)
    index = if address_family == :ipv6, do: index + state.config.shard_count, else: index
    {elem(state.shards, index), index}
  end

  defp counter_index(shard_index, kind), do: shard_index * 2 + kind + 1

  defp upsert(%State{} = state, info_hash, kind, peer) do
    {shard, index} = shard_for(state, info_hash, Peer.address_family(peer))
    key = {info_hash, kind, Peer.to_key(peer)}
    now = TimeCache.now_unix_nano()

    unless :ets.update_element(shard, key, {2, now}) do
      if :ets.insert_new(shard, {key, now}) do
        :counters.add(state.counters, counter_index(index, kind), 1)
      else
        # Lost a race against a concurrent insert; refresh the mtime.
        :ets.update_element(shard, key, {2, now})
      end
    end

    :ok
  end

  defp delete(%State{} = state, info_hash, kind, peer) do
    {shard, index} = shard_for(state, info_hash, Peer.address_family(peer))

    case :ets.take(shard, {info_hash, kind, Peer.to_key(peer)}) do
      [_object] ->
        :counters.sub(state.counters, counter_index(index, kind), 1)
        :ok

      [] ->
        {:error, Storage.err_resource_does_not_exist()}
    end
  end

  defp swarm_exists?(shard, info_hash) do
    case :ets.next(shard, {info_hash, -1, 0}) do
      {^info_hash, _kind, _pk} -> true
      _other -> false
    end
  end

  defp count_peers(shard, info_hash, kind) do
    :ets.select_count(shard, [{{{info_hash, kind, :_}, :_}, [], [true]}])
  end

  defp count_infohashes(shard) do
    count_infohashes(shard, :ets.first(shard), 0)
  end

  defp count_infohashes(_shard, :"$end_of_table", count), do: count

  defp count_infohashes(shard, {info_hash, _kind, _pk}, count) do
    count_infohashes(shard, :ets.next(shard, {info_hash, 2, 0}), count + 1)
  end

  # Returns up to num_want peers of the given kind for the swarm, chosen
  # as a uniform random subset. chihaya achieves varied announce
  # responses by relying on Go's randomized map iteration order; an ETS
  # ordered_set is deterministic in key order, so we sample explicitly to
  # avoid biasing toward any region of the (clustered) peer-id key space.
  defp sample(_shard, _info_hash, _kind, num_want, _exclude) when num_want <= 0, do: []

  defp sample(shard, info_hash, kind, num_want, exclude) do
    guards = if exclude, do: [{:"=/=", :"$1", {:const, exclude}}], else: []
    keys = :ets.select(shard, [{{{info_hash, kind, :"$1"}, :_}, guards, [:"$1"]}])
    keys = if length(keys) > num_want, do: Enum.take_random(keys, num_want), else: keys
    Enum.map(keys, &Peer.from_key/1)
  end
end
