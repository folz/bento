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
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {config, opts}, gen_opts)
  end

  @doc "Returns the running components (store, logic, frontends, metrics server)."
  @spec components(pid()) :: map()
  def components(pid), do: GenServer.call(pid, :components)

  @impl GenServer
  def init({config, _opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- Bento.Tracker.Config.load(config),
         :ok <- ensure_metrics(),
         {:ok, metrics_server} <- maybe_start_metrics_server(config.metrics_addr),
         {:ok, store} <- start_store(config.storage),
         {:ok, pre_hooks} <- Middleware.hooks_from_hook_configs(config.prehooks),
         {:ok, post_hooks} <- Middleware.hooks_from_hook_configs(config.posthooks),
         logic <- Logic.new(config.response_config, store, pre_hooks, post_hooks),
         {:ok, http} <- maybe_start_http(logic, config.http),
         {:ok, udp} <- maybe_start_udp(logic, config.udp) do
      state = %{
        config: config,
        metrics_server: metrics_server,
        store: store,
        logic: logic,
        http: http,
        udp: udp
      }

      Logger.info("bento_tracker started")
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

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
  def terminate(_reason, state) do
    stop_frontend(state.http)
    stop_frontend(state.udp)
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

  defp maybe_start_http(_logic, nil), do: {:ok, nil}

  defp maybe_start_http(logic, config) do
    case Bento.Tracker.HTTP.Frontend.start_link({logic, config}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:http_frontend, reason}}
    end
  end

  defp maybe_start_udp(_logic, nil), do: {:ok, nil}

  defp maybe_start_udp(logic, config) do
    case Bento.Tracker.UDP.Frontend.start_link({logic, config}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:udp_frontend, reason}}
    end
  end

  defp stop_frontend(nil), do: :ok
  defp stop_frontend(pid), do: stop_pid(pid)

  defp stop_pid(nil), do: :ok

  defp stop_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
