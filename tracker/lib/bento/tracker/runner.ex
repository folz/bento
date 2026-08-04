defmodule Bento.Tracker.Runner do
  @moduledoc """
  Wires a running tracker together from a configuration: the metrics
  registry and server, the peer store, the middleware hooks, the tracker
  logic, and the HTTP and UDP frontends.

  This is the OTP equivalent of chihaya's `Run`. The runner is a
  `GenServer` that owns every component, links them, and tears them down
  in the correct order on shutdown (frontends, then logic/hooks, then the
  store).
  """

  use GenServer

  require Logger

  alias Bento.Tracker.Logic
  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Middleware
  alias Bento.Tracker.Storage

  @doc """
  Starts a tracker from `config` (a map or a path to an `.exs` config
  file). Accepts a `:name` option for the runner process.
  """
  @spec start_link(map() | String.t(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, config, gen_opts)
  end

  @doc "Returns the running components (store, logic, frontends, metrics server)."
  @spec components(pid()) :: map()
  def components(pid), do: GenServer.call(pid, :components)

  @impl GenServer
  def init(config) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- Bento.Tracker.Config.load(config) do
      start_components(config)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # Starts each component in order, threading the growing state so that a
  # failure at any step can tear down everything already started. Without
  # this, a frontend that fails to bind after the store and hooks are up
  # would orphan those processes (and their sockets, ETS tables and
  # timers). Each step receives the state so far and produces the value
  # stored under its key.
  defp start_components(config) do
    initial = %{config: config, metrics_server: nil, store: nil, logic: nil, http: nil, udp: nil}

    steps = [
      metrics_server: &start_metrics_server/1,
      store: &start_store_component/1,
      logic: &build_logic/1,
      http: &start_http/1,
      udp: &start_udp/1
    ]

    case run_steps(steps, initial) do
      {:ok, state} ->
        Logger.info("bento_tracker started")
        {:ok, state}

      {:error, reason, partial} ->
        cleanup(partial)
        {:stop, reason}
    end
  end

  defp run_steps([], state), do: {:ok, state}

  defp run_steps([{key, step} | rest], state) do
    case step.(state) do
      {:ok, value} -> run_steps(rest, Map.put(state, key, value))
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_metrics_server(state) do
    with :ok <- ensure_metrics() do
      maybe_start_metrics_server(state.config.metrics_addr)
    end
  end

  defp start_store_component(state) do
    with {:ok, store} <- start_store(state.config.storage) do
      link_component(store)
      {:ok, store}
    end
  end

  defp start_http(state) do
    maybe_start_frontend(
      Bento.Tracker.HTTP.Frontend,
      :http_frontend,
      state.logic,
      state.config.http
    )
  end

  defp start_udp(state) do
    maybe_start_frontend(Bento.Tracker.UDP.Frontend, :udp_frontend, state.logic, state.config.udp)
  end

  # Builds the tracker logic, linking each hook GenServer to the runner and
  # stopping the pre-hooks if the post-hooks fail to start.
  defp build_logic(%{config: config, store: store}) do
    with {:ok, pre_hooks} <- Middleware.hooks_from_hook_configs(config.prehooks) do
      case Middleware.hooks_from_hook_configs(config.posthooks) do
        {:ok, post_hooks} ->
          Enum.each(pre_hooks ++ post_hooks, &link_component/1)
          {:ok, Logic.new(config.response_config, store, pre_hooks, post_hooks)}

        {:error, reason} ->
          Enum.each(pre_hooks, &Middleware.stop/1)
          {:error, reason}
      end
    end
  end

  # Links the runner to a component's owning process so a crash in the
  # store or a hook GenServer is surfaced here (the frontends and metrics
  # server are already linked via start_link). Pure, process-less hooks
  # carry no pid and are skipped.
  defp link_component({_module, %{pid: pid}}) when is_pid(pid), do: Process.link(pid)
  defp link_component(_stateless), do: :ok

  @impl GenServer
  def handle_call(:components, _from, state) do
    {:reply, Map.take(state, [:store, :logic, :http, :udp, :metrics_server]), state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, reason}, state) when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.error("bento_tracker component #{inspect(pid)} exited: #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: cleanup(state)

  # Stops every started component in reverse dependency order (frontends,
  # then logic and its hooks, then the store, then the metrics server).
  # Shared by clean shutdown and partial-init rollback; tolerates nil
  # entries so a partially built state is safe to pass.
  defp cleanup(state) do
    stop_pid(state.http)
    stop_pid(state.udp)
    if state.logic, do: Logic.stop(state.logic)
    if state.store, do: Storage.stop(state.store)
    stop_pid(state.metrics_server)
    :ok
  end

  ## Component startup

  defp ensure_metrics do
    case Metrics.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_metrics_server(addr) when addr in [nil, ""], do: {:ok, nil}

  defp maybe_start_metrics_server(addr) do
    case Bento.Tracker.Metrics.Server.start_link(addr) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:metrics_server, reason}}
    end
  end

  defp start_store(%{name: name, config: config}) do
    case Storage.new(name, config) do
      {:ok, store} -> {:ok, store}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp maybe_start_frontend(_module, _tag, _logic, nil), do: {:ok, nil}

  defp maybe_start_frontend(module, tag, logic, config) do
    case module.start_link({logic, config}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {tag, reason}}
    end
  end

  defp stop_pid(nil), do: :ok

  defp stop_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
