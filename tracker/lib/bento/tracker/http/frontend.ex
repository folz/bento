defmodule Bento.Tracker.HTTP.Frontend do
  @moduledoc """
  A BitTorrent frontend over HTTP (BEP 3, BEP 23).

  The frontend validates its configuration and runs a
  `Bento.Tracker.HTTP.Server` whose handler routes announce and scrape
  requests to the tracker logic, writes the bencoded response, and then
  runs the post-hooks.

  ## Configuration

    * `:addr` - the plain-HTTP listen address `"ip:port"` (optional)
    * `:https_addr` - the TLS listen address `"ip:port"` (optional)
    * `:read_timeout` / `:write_timeout` - socket timeouts in
      milliseconds (default: 2000)
    * `:idle_timeout` - keep-alive idle timeout in milliseconds
      (default: 30000)
    * `:enable_keepalive` - whether to keep connections alive (default:
      `false`)
    * `:tls_cert_path` / `:tls_key_path` - PEM paths for TLS
    * `:announce_routes` / `:scrape_routes` - lists of
      `Bento.Tracker.HTTP.Route` patterns
    * `:enable_request_timing` - whether to record real response
      durations (default: `false`)
    * parse options: `:allow_ip_spoofing`, `:real_ip_header`,
      `:max_numwant`, `:default_numwant`, `:max_scrape_infohashes`

  At least one of `:addr` / `:https_addr` and both route lists are
  required.
  """

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.HTTP.Parser
  alias Bento.Tracker.HTTP.Request
  alias Bento.Tracker.HTTP.Route
  alias Bento.Tracker.HTTP.Server
  alias Bento.Tracker.HTTP.Writer
  alias Bento.Tracker.Logic
  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Middleware
  alias Bento.Tracker.Peer

  @defaults %{
    addr: "",
    https_addr: "",
    announce_routes: [],
    scrape_routes: [],
    enable_keepalive: false,
    enable_request_timing: false,
    tls_cert_path: "",
    tls_key_path: "",
    allow_ip_spoofing: false,
    real_ip_header: ""
  }

  @doc "Starts the HTTP frontend, returning the pid of its server."
  @spec start_link({Logic.t(), map()}, keyword()) :: GenServer.on_start()
  def start_link({logic, config}, opts \\ []) do
    config = validate(config)

    with :ok <- check_config(config) do
      Server.start_link(
        [
          listeners:
            for(
              {s, addr} <- [http: config.addr, https: config.https_addr],
              addr != "",
              do: {s, addr}
            ),
          tls: [certfile: config.tls_cert_path, keyfile: config.tls_key_path],
          read_timeout: config[:read_timeout],
          write_timeout: config[:write_timeout],
          idle_timeout: config[:idle_timeout],
          keepalive: config.enable_keepalive,
          handler: &handle(logic, config, &1)
        ],
        opts
      )
    end
  end

  @doc "Returns the actual `{:ok, {ip, port}}` a listener is bound to."
  defdelegate listen_address(pid, scheme \\ :http), to: Server

  ## Config validation

  # The parse-option defaults have a single owner: the parser.
  defp validate(config) do
    Parser.default_options()
    |> Map.take([:max_numwant, :default_numwant, :max_scrape_infohashes])
    |> Enum.reduce(Map.merge(@defaults, config), fn {key, default}, acc ->
      case Map.get(acc, key) do
        value when is_integer(value) and value > 0 -> acc
        _invalid -> Map.put(acc, key, default)
      end
    end)
  end

  defp check_config(config) do
    cond do
      config.addr == "" and config.https_addr == "" ->
        {:error, "must specify addr or https_addr or both"}

      config.announce_routes == [] or config.scrape_routes == [] ->
        {:error, "must specify routes"}

      config.https_addr != "" and (config.tls_cert_path == "" or config.tls_key_path == "") ->
        {:error, "must specify tls_cert_path and tls_key_path when using https_addr"}

      config.https_addr == "" and (config.tls_cert_path != "" and config.tls_key_path != "") ->
        {:error, "must specify https_addr when using tls_cert_path and tls_key_path"}

      true ->
        :ok
    end
  end

  ## Request handling

  # Unmatched paths and methods get httprouter's plain-text 404/405, not a
  # bencoded failure, like chihaya.
  defp handle(logic, config, %Request{} = request) do
    case {request.method, route(config, Request.path(request))} do
      {"GET", {:ok, action, params}} ->
        respond(action, logic, config, request, %{Middleware.route_params_key() => params})

      {_method, {:ok, _action, _params}} ->
        {405, "Method Not Allowed\n"}

      {_method, :error} ->
        {404, "404 page not found\n"}
    end
  end

  defp route(config, path) do
    with :error <- tag(:announce, Route.match(config.announce_routes, path)),
         :error <- tag(:scrape, Route.match(config.scrape_routes, path)) do
      :error
    end
  end

  defp tag(action, {:ok, params}), do: {:ok, action, params}
  defp tag(_action, :error), do: :error

  defp respond(:announce, logic, config, request, ctx) do
    time("announce", config, fn ->
      with {:ok, announce} <- Parser.parse_announce(request, config) do
        af = Peer.address_family(announce.peer)

        case Logic.handle_announce(logic, ctx, announce) do
          {:ok, ctx, response} ->
            after_fun = fn -> Logic.after_announce(logic, ctx, announce, response) end
            {:ok, af, Writer.write_announce_response(response), after_fun}

          {:error, error} ->
            {:error, af, error}
        end
      end
    end)
  end

  defp respond(:scrape, logic, config, request, ctx) do
    time("scrape", config, fn ->
      with {:ok, scrape} <- Parser.parse_scrape(request, config),
           {:ok, scrape} <- resolve_scrape_af(scrape, request) do
        case Logic.handle_scrape(logic, ctx, scrape) do
          {:ok, ctx, response} ->
            after_fun = fn -> Logic.after_scrape(logic, ctx, scrape, response) end
            {:ok, scrape.address_family, Writer.write_scrape_response(response), after_fun}

          {:error, error} ->
            {:error, scrape.address_family, error}
        end
      end
    end)
  end

  # Like chihaya, the scrape's address family comes from the connection's
  # remote address, never from a spoofed or forwarded IP.
  defp resolve_scrape_af(scrape, request) do
    case request.remote_ip do
      ip when tuple_size(ip) == 4 -> {:ok, %{scrape | address_family: :ipv4}}
      ip when tuple_size(ip) == 8 -> {:ok, %{scrape | address_family: :ipv6}}
      _other -> {:error, ClientError.new("invalid IP")}
    end
  end

  # Runs an announce/scrape, records its response-duration metric, and
  # builds the server response: errors are bencoded failures with a 200
  # status, as chihaya writes them.
  defp time(action, config, fun) do
    start = System.monotonic_time(:microsecond)

    {af, error, body, after_fun} =
      case fun.() do
        {:ok, af, body, after_fun} -> {af, nil, body, after_fun}
        {:error, af, error} -> {af, error, Writer.write_error(error), nil}
        {:error, error} -> {nil, error, Writer.write_error(error), nil}
      end

    duration_ms =
      if config.enable_request_timing,
        do: (System.monotonic_time(:microsecond) - start) / 1000,
        else: 0

    Metrics.record_response_duration(
      "chihaya_http_response_duration_milliseconds",
      action,
      af,
      error,
      duration_ms
    )

    {200, body, after: after_fun}
  end
end
