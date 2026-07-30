defmodule Bento.Tracker.Storage.Redis do
  @moduledoc """
  A `Bento.Tracker.Storage` implementation keeping peer data in Redis,
  ported from chihaya's Redis peer store.

  ## Key schema

  Two categories of hash hold peers, keyed by address family group
  (`"IPv4"` / `"IPv6"`):

    * `IPv{4,6}_{S,L}_<infohash-hex>` maps a serialized peer to its last
      announce time (nanoseconds). `S` holds seeders, `L` holds leechers.
    * `IPv{4,6}` maps every `S`/`L` infohash key to a time, used for
      garbage collection and metrics.

  Plain integer keys track counts per group: `IPv{4,6}_infohash_count`,
  `IPv{4,6}_S_count`, `IPv{4,6}_L_count`. As in chihaya, the infohash
  count follows *seeder* infohash keys only, and delete operations never
  remove infohash keys from the group hash or decrement the infohash
  counter - that cleanup is left to garbage collection.

  ## Configuration

    * `:redis_broker` - a `redis://[password@]host:port/db` URL
      (default: `"redis://127.0.0.1:6379/0"`)
    * `:redis_connect_timeout` / `:redis_read_timeout` /
      `:redis_write_timeout` - timeouts in milliseconds (default: 15s)
    * `:gc_interval`, `:peer_lifetime`, `:prometheus_reporting_interval` -
      as in the memory store, in milliseconds

  Data is not cleared from Redis on shutdown; all keys are prefixed
  `IPv{4,6}_`.
  """

  @behaviour Bento.Tracker.Storage

  use GenServer

  require Logger

  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Peer
  alias Bento.Tracker.Scrape
  alias Bento.Tracker.Storage
  alias Bento.Tracker.Storage.Redis.Connection
  alias Bento.Tracker.TimeCache

  @name "redis"

  # Matches chihaya's defaultRedisBroker, password included.
  @default_redis_broker "redis://myRedis@127.0.0.1:6379/0"
  @default_redis_timeout :timer.seconds(15)
  @default_gc_interval :timer.minutes(3)
  @default_peer_lifetime :timer.minutes(30)
  @default_prometheus_reporting_interval :timer.seconds(1)

  @groups ["IPv4", "IPv6"]

  defmodule State do
    @moduledoc false
    defstruct [:pid, :conn, :config]
  end

  ## Lifecycle

  @impl Storage
  def new(config) do
    with {:ok, pid} <- GenServer.start(__MODULE__, config),
         %State{} = state <- GenServer.call(pid, :handle) do
      {:ok, state}
    end
  end

  @doc "Starts a Redis store linked to the calling process."
  def start_link(config \\ %{}, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @impl Storage
  def stop(%State{pid: pid}) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl Storage
  def log_value(%State{config: config}), do: Map.put(config, :name, @name)

  ## Storage operations

  @impl Storage
  def put_seeder(%State{conn: conn}, info_hash, peer) do
    af = af_string(peer)
    pk = Peer.to_key(peer)
    seeder_key = seeder_ih_key(af, info_hash)
    ct = TimeCache.now_unix_nano()

    with {:ok, [new_peer?, new_ih?]} <-
           transaction(conn, [
             ["HSET", seeder_key, pk, ct],
             ["HSET", af, seeder_key, ct]
           ]) do
      if new_peer? == 1, do: command!(conn, ["INCR", seeder_count_key(af)])
      if new_ih? == 1, do: command!(conn, ["INCR", infohash_count_key(af)])
      :ok
    end
  end

  @impl Storage
  def delete_seeder(%State{conn: conn}, info_hash, peer) do
    af = af_string(peer)
    delete_peer(conn, seeder_ih_key(af, info_hash), seeder_count_key(af), peer)
  end

  @impl Storage
  def put_leecher(%State{conn: conn}, info_hash, peer) do
    af = af_string(peer)
    pk = Peer.to_key(peer)
    leecher_key = leecher_ih_key(af, info_hash)
    ct = TimeCache.now_unix_nano()

    with {:ok, [new_peer?, _new_ih?]} <-
           transaction(conn, [
             ["HSET", leecher_key, pk, ct],
             ["HSET", af, leecher_key, ct]
           ]) do
      if new_peer? == 1, do: command!(conn, ["INCR", leecher_count_key(af)])
      :ok
    end
  end

  @impl Storage
  def delete_leecher(%State{conn: conn}, info_hash, peer) do
    af = af_string(peer)
    delete_peer(conn, leecher_ih_key(af, info_hash), leecher_count_key(af), peer)
  end

  # Removes a peer field from a swarm hash, adjusting the kind's counter;
  # a missing field means the resource does not exist.
  defp delete_peer(conn, ih_key, count_key, peer) do
    with {:ok, del} <- Connection.command(conn, ["HDEL", ih_key, Peer.to_key(peer)]) do
      if del == 0 do
        {:error, Storage.err_resource_does_not_exist()}
      else
        command!(conn, ["DECR", count_key])
        :ok
      end
    end
  end

  @impl Storage
  def graduate_leecher(%State{conn: conn}, info_hash, peer) do
    af = af_string(peer)
    pk = Peer.to_key(peer)
    leecher_key = leecher_ih_key(af, info_hash)
    seeder_key = seeder_ih_key(af, info_hash)
    ct = TimeCache.now_unix_nano()

    with {:ok, [deleted, new_seeder?, new_ih?]} <-
           transaction(conn, [
             ["HDEL", leecher_key, pk],
             ["HSET", seeder_key, pk, ct],
             ["HSET", af, seeder_key, ct]
           ]) do
      if deleted == 1, do: command!(conn, ["DECR", leecher_count_key(af)])
      if new_seeder? == 1, do: command!(conn, ["INCR", seeder_count_key(af)])
      if new_ih? == 1, do: command!(conn, ["INCR", infohash_count_key(af)])
      :ok
    end
  end

  @impl Storage
  def announce_peers(%State{conn: conn}, info_hash, seeder?, num_want, announcer) do
    af = af_string(announcer)
    leecher_key = leecher_ih_key(af, info_hash)
    seeder_key = seeder_ih_key(af, info_hash)

    with {:ok, [leecher_pks, seeder_pks]} <-
           pipeline_ok(conn, [["HKEYS", leecher_key], ["HKEYS", seeder_key]]) do
      leecher_pks = leecher_pks || []
      seeder_pks = seeder_pks || []

      if leecher_pks == [] and seeder_pks == [] do
        {:error, Storage.err_resource_does_not_exist()}
      else
        {:ok, select_peers(seeder?, num_want, announcer, seeder_pks, leecher_pks)}
      end
    end
  end

  @impl Storage
  def scrape_swarm(%State{conn: conn}, info_hash, address_family) do
    af = af_string(address_family)
    commands = [["HLEN", leecher_ih_key(af, info_hash)], ["HLEN", seeder_ih_key(af, info_hash)]]

    case Connection.pipeline(conn, commands) do
      {:ok, [incomplete, complete]} when is_integer(incomplete) and is_integer(complete) ->
        %Scrape{info_hash: info_hash, incomplete: incomplete, complete: complete}

      _error ->
        %Scrape{info_hash: info_hash}
    end
  end

  defp select_peers(true, num_want, _announcer, _seeder_pks, leecher_pks) do
    leecher_pks |> Enum.take(num_want) |> Enum.map(&Peer.from_key/1)
  end

  defp select_peers(false, num_want, announcer, seeder_pks, leecher_pks) do
    seeders = Enum.take(seeder_pks, num_want)
    remaining = num_want - length(seeders)

    # Exclude the announcing peer from the leechers, matching chihaya's
    # memory store and the documented PeerStore contract. (chihaya's Redis
    # store has a latent type-mismatch bug -- it compares an `interface{}`
    # holding `[]byte` against a `serializedPeer`, which is never equal --
    # so it never actually excludes the announcer. We match the correct,
    # documented behavior rather than reproduce that bug.)
    leechers =
      if remaining > 0 do
        announcer_pk = Peer.to_key(announcer)

        leecher_pks
        |> Stream.reject(&(&1 == announcer_pk))
        |> Enum.take(remaining)
      else
        []
      end

    Enum.map(seeders ++ leechers, &Peer.from_key/1)
  end

  ## Garbage collection

  @doc """
  Deletes all peers that have not announced since `cutoff_ns` (nanoseconds
  since the Unix epoch), removing emptied swarms and adjusting counters.
  """
  @spec collect_garbage(%State{}, integer()) :: :ok | {:error, term()}
  def collect_garbage(%State{conn: conn}, cutoff_ns) do
    started_at = System.monotonic_time(:microsecond)

    result =
      Enum.reduce_while(@groups, :ok, fn group, :ok ->
        case collect_group(conn, group, cutoff_ns) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    duration_ms = (System.monotonic_time(:microsecond) - started_at) / 1000
    Metrics.observe("chihaya_storage_gc_duration_milliseconds", %{}, duration_ms)
    result
  end

  defp collect_group(conn, group, cutoff_ns) do
    with {:ok, ih_keys} <- Connection.command(conn, ["HKEYS", group]) do
      Enum.reduce_while(ih_keys || [], :ok, fn ih_key, :ok ->
        case collect_swarm(conn, group, ih_key, cutoff_ns) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp collect_swarm(conn, group, ih_key, cutoff_ns) do
    seeder? = binary_part(ih_key, 5, 1) == "S"

    with {:ok, pairs} <- Connection.command(conn, ["HGETALL", ih_key]) do
      removed = delete_expired(conn, ih_key, pairs || [], cutoff_ns)

      if removed > 0 do
        counter = if seeder?, do: seeder_count_key(group), else: leecher_count_key(group)
        command!(conn, ["DECRBY", counter, removed])
      end

      reap_empty_swarm(conn, group, ih_key, seeder?)
    end
  end

  defp delete_expired(conn, ih_key, pairs, cutoff_ns) do
    expired =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        [pk, mtime] -> if String.to_integer(mtime) <= cutoff_ns, do: [pk], else: []
        _incomplete -> []
      end)

    # One multi-field HDEL per swarm instead of a round trip per peer.
    case expired do
      [] ->
        0

      fields ->
        case Connection.command(conn, ["HDEL", ih_key | fields]) do
          {:ok, n} when is_integer(n) -> n
          _error -> 0
        end
    end
  end

  defp reap_empty_swarm(conn, group, ih_key, seeder?) do
    with {:ok, _watch} <- Connection.command(conn, ["WATCH", ih_key]),
         {:ok, len} <- Connection.command(conn, ["HLEN", ih_key]) do
      if len == 0 do
        commands = [["HDEL", group, ih_key]]

        commands =
          if seeder?, do: commands ++ [["DECR", infohash_count_key(group)]], else: commands

        with {:ok, _exec} <- transaction(conn, commands), do: :ok
      else
        with {:ok, _unwatch} <- Connection.command(conn, ["UNWATCH"]), do: :ok
      end
    end
  end

  ## Metrics

  @doc "Aggregates per-group counters and publishes them to `Bento.Tracker.Metrics`."
  @spec populate_prom(%State{}) :: :ok
  def populate_prom(%State{conn: conn}) do
    {infohashes, seeders, leechers} =
      Enum.reduce(@groups, {0, 0, 0}, fn group, {ih, s, l} ->
        {ih + get_count(conn, infohash_count_key(group)),
         s + get_count(conn, seeder_count_key(group)),
         l + get_count(conn, leecher_count_key(group))}
      end)

    Metrics.set_gauge("chihaya_storage_infohashes_count", infohashes)
    Metrics.set_gauge("chihaya_storage_seeders_count", seeders)
    Metrics.set_gauge("chihaya_storage_leechers_count", leechers)
    :ok
  end

  defp get_count(conn, key) do
    case Connection.command(conn, ["GET", key]) do
      {:ok, nil} -> 0
      {:ok, value} when is_binary(value) -> String.to_integer(value)
      _error -> 0
    end
  end

  ## GenServer callbacks

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)
    config = validate(config)

    conn_opts = [
      host: config.redis_host,
      port: config.redis_port,
      password: config.redis_password,
      db: config.redis_db,
      connect_timeout: config.redis_connect_timeout,
      recv_timeout: config.redis_read_timeout,
      send_timeout: config.redis_write_timeout
    ]

    case Connection.start_link(conn_opts) do
      {:ok, conn} ->
        state = %State{pid: self(), conn: conn, config: config}
        Process.send_after(self(), :collect_garbage, config.gc_interval)
        Process.send_after(self(), :populate_prom, config.prometheus_reporting_interval)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:handle, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_info(:collect_garbage, state) do
    cutoff_ns = TimeCache.now_unix_nano() - state.config.peer_lifetime * 1_000_000
    collect_garbage(state, cutoff_ns)
    Process.send_after(self(), :collect_garbage, state.config.gc_interval)
    {:noreply, state}
  end

  def handle_info(:populate_prom, state) do
    populate_prom(state)
    Process.send_after(self(), :populate_prom, state.config.prometheus_reporting_interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Logger.info(
      "storage: exiting. bento_tracker does not clear data in redis when exiting. " <>
        "keys have prefix 'IPv{4,6}_'."
    )

    if state.conn, do: Connection.close(state.conn)
    :ok
  end

  ## Config and helpers

  defp validate(config) do
    config = Map.new(config)
    broker = broker_or_default(Map.get(config, :redis_broker))
    {host, port, password, db} = parse_redis_url(broker)

    %{
      redis_broker: broker,
      redis_host: host,
      redis_port: port,
      redis_password: password,
      redis_db: db,
      redis_connect_timeout:
        positive(Map.get(config, :redis_connect_timeout), @default_redis_timeout),
      redis_read_timeout: positive(Map.get(config, :redis_read_timeout), @default_redis_timeout),
      redis_write_timeout:
        positive(Map.get(config, :redis_write_timeout), @default_redis_timeout),
      gc_interval: positive(Map.get(config, :gc_interval), @default_gc_interval),
      peer_lifetime: positive(Map.get(config, :peer_lifetime), @default_peer_lifetime),
      prometheus_reporting_interval:
        positive(
          Map.get(config, :prometheus_reporting_interval),
          @default_prometheus_reporting_interval
        )
    }
  end

  defp broker_or_default(broker) when is_binary(broker) and broker != "", do: broker
  defp broker_or_default(_empty), do: @default_redis_broker

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  # Parses "redis://[password@]host:port/db". Raises with chihaya's
  # "no redis scheme found" message for any non-redis URL.
  defp parse_redis_url(url) do
    case URI.parse(url) do
      %URI{scheme: "redis"} = uri ->
        db =
          case uri.path do
            path when path in [nil, "", "/"] -> 0
            path -> String.to_integer(String.trim_leading(path, "/"))
          end

        password = if uri.userinfo in [nil, ""], do: "", else: uri.userinfo
        {uri.host || "127.0.0.1", uri.port || 6379, password, db}

      _other ->
        raise ArgumentError, "no redis scheme found"
    end
  end

  defp af_string(%Peer{} = peer), do: af_string(Peer.address_family(peer))
  defp af_string(:ipv4), do: "IPv4"
  defp af_string(:ipv6), do: "IPv6"

  defp leecher_ih_key(af, info_hash), do: af <> "_L_" <> ih_hex(info_hash)
  defp seeder_ih_key(af, info_hash), do: af <> "_S_" <> ih_hex(info_hash)
  defp infohash_count_key(af), do: af <> "_infohash_count"
  defp seeder_count_key(af), do: af <> "_S_count"
  defp leecher_count_key(af), do: af <> "_L_count"

  defp ih_hex(info_hash), do: Base.encode16(info_hash, case: :lower)

  # Runs commands inside MULTI/EXEC and returns the EXEC result array.
  defp transaction(conn, commands) do
    wrapped = [["MULTI"]] ++ commands ++ [["EXEC"]]

    with {:ok, replies} <- Connection.pipeline(conn, wrapped) do
      case List.last(replies) do
        {:error, _reason} = error -> error
        exec -> {:ok, exec}
      end
    end
  end

  defp pipeline_ok(conn, commands) do
    with {:ok, replies} <- Connection.pipeline(conn, commands) do
      case Enum.find(replies, &match?({:error, _reason}, &1)) do
        nil -> {:ok, replies}
        error -> error
      end
    end
  end

  defp command!(conn, args) do
    case Connection.command(conn, args) do
      {:ok, reply} -> reply
      {:error, reason} -> raise "redis command #{inspect(args)} failed: #{inspect(reason)}"
    end
  end
end
