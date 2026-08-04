defmodule Bento.Tracker.HTTP.Frontend do
  @moduledoc """
  A BitTorrent frontend over HTTP (BEP 3, BEP 23).

  The frontend owns one or two listening sockets (plain and/or TLS) and a
  pool of acceptor processes. Each accepted connection is handled in its
  own process that parses HTTP/1.1 GET requests with the VM's built-in
  `:erlang.decode_packet/3`, routes announce and scrape paths to the
  tracker logic, writes the bencoded response, and then runs the
  post-hooks.

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
    * `:announce_routes` / `:scrape_routes` - lists of request paths
    * `:enable_request_timing` - whether to record real response
      durations (default: `false`)
    * parse options: `:allow_ip_spoofing`, `:real_ip_header`,
      `:max_numwant`, `:default_numwant`, `:max_scrape_infohashes`

  At least one of `:addr` / `:https_addr` and both route lists are
  required.
  """

  use GenServer

  require Logger

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.HTTP.Parser
  alias Bento.Tracker.HTTP.Request
  alias Bento.Tracker.HTTP.Writer
  alias Bento.Tracker.IP
  alias Bento.Tracker.Logic
  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Peer

  @default_read_timeout :timer.seconds(2)
  @default_write_timeout :timer.seconds(2)
  @default_idle_timeout :timer.seconds(30)
  @acceptor_count 10

  # Caps the request line and header block so a client that never sends the
  # terminating blank line cannot grow the read buffer without bound. Mirrors
  # net/http's default MaxHeaderBytes (1 MiB).
  @max_header_bytes 1_048_576

  @doc "Starts the HTTP frontend."
  @spec start_link({Logic.t(), map()}, keyword()) :: GenServer.on_start()
  def start_link({logic, config}, opts \\ []) do
    GenServer.start_link(__MODULE__, {logic, config}, opts)
  end

  @doc "Returns the actual `{:ok, {ip, port}}` a listener is bound to."
  @spec listen_address(pid(), :http | :https) :: {:ok, {:inet.ip_address(), :inet.port_number()}}
  def listen_address(pid, scheme \\ :http) do
    GenServer.call(pid, {:listen_address, scheme})
  end

  @impl GenServer
  def init({logic, config}) do
    Process.flag(:trap_exit, true)
    config = validate(config)

    with :ok <- check_config(config),
         {:ok, listeners} <- open_listeners(config) do
      state = %{logic: logic, config: config, listeners: listeners}

      for {scheme, listen_socket} <- listeners do
        for _ <- 1..@acceptor_count do
          start_acceptor(scheme, listen_socket, state)
        end
      end

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:listen_address, scheme}, _from, state) do
    reply =
      case Keyword.fetch(state.listeners, scheme) do
        {:ok, socket} -> :inet.sockname(socket)
        :error -> {:error, :not_listening}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    for {_scheme, socket} <- state.listeners, do: close_listener(socket)
    :ok
  end

  ## Config validation

  defp validate(config) do
    config
    |> Map.put_new(:addr, "")
    |> Map.put_new(:https_addr, "")
    |> Map.put_new(:announce_routes, [])
    |> Map.put_new(:scrape_routes, [])
    |> Map.put_new(:enable_keepalive, false)
    |> Map.put_new(:enable_request_timing, false)
    |> Map.put_new(:tls_cert_path, "")
    |> Map.put_new(:tls_key_path, "")
    |> default_positive(:read_timeout, @default_read_timeout)
    |> default_positive(:write_timeout, @default_write_timeout)
    |> default_positive(:idle_timeout, @default_idle_timeout)
    |> default_parse_options()
    |> Map.put_new(:allow_ip_spoofing, false)
    |> Map.put_new(:real_ip_header, "")
  end

  # The parse-option defaults have a single owner: the parser.
  defp default_parse_options(config) do
    Parser.default_options()
    |> Map.take([:max_numwant, :default_numwant, :max_scrape_infohashes])
    |> Enum.reduce(config, fn {key, default}, acc -> default_positive(acc, key, default) end)
  end

  defp default_positive(config, key, default) do
    case Map.get(config, key) do
      value when is_integer(value) and value > 0 -> config
      _invalid -> Map.put(config, key, default)
    end
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

  ## Listeners

  defp open_listeners(config) do
    listeners =
      []
      |> maybe_listener(:http, config.addr)
      |> maybe_listener(:https, config.https_addr)

    open_all(listeners, config, [])
  end

  defp maybe_listener(acc, _scheme, ""), do: acc
  defp maybe_listener(acc, scheme, addr), do: [{scheme, addr} | acc]

  defp open_all([], _config, opened), do: {:ok, opened}

  defp open_all([{scheme, addr} | rest], config, opened) do
    case listen(scheme, addr, config) do
      {:ok, socket} ->
        open_all(rest, config, [{scheme, socket} | opened])

      {:error, reason} ->
        for {_s, s} <- opened, do: close_listener(s)
        {:error, {scheme, reason}}
    end
  end

  defp listen(:http, addr, config) do
    with {:ok, ip, port} <- IP.parse_addr(addr) do
      :gen_tcp.listen(port, [
        :binary,
        IP.inet_family(ip),
        ip: ip,
        active: false,
        reuseaddr: true,
        packet: :raw,
        backlog: 1024,
        # Bounds a single response write against a stuck client, standing
        # in for chihaya's http.Server WriteTimeout. Inherited by every
        # accepted socket.
        send_timeout: config.write_timeout
      ])
    end
  end

  defp listen(:https, addr, config) do
    with {:ok, ip, port} <- IP.parse_addr(addr) do
      :ssl.listen(port, [
        :binary,
        IP.inet_family(ip),
        ip: ip,
        active: false,
        reuseaddr: true,
        packet: :raw,
        backlog: 1024,
        send_timeout: config.write_timeout,
        versions: [:"tlsv1.2", :"tlsv1.3"],
        certfile: String.to_charlist(config.tls_cert_path),
        keyfile: String.to_charlist(config.tls_key_path)
      ])
    end
  end

  defp close_listener({:sslsocket, _, _} = socket), do: :ssl.close(socket)
  defp close_listener(socket), do: :gen_tcp.close(socket)

  ## Acceptors and connection handling

  defp start_acceptor(scheme, listen_socket, state) do
    spawn_link(fn -> accept_loop(scheme, listen_socket, state) end)
  end

  # Each accepted connection is handed off to its own process so a slow
  # client or TLS handshake never blocks the acceptor.
  defp accept_loop(scheme, listen_socket, state) do
    case accept(scheme, listen_socket) do
      {:ok, socket} ->
        handler = spawn(fn -> await_handoff(scheme, state) end)
        controlling_process(scheme, socket, handler)
        send(handler, {:handoff, socket})
        accept_loop(scheme, listen_socket, state)

      {:error, reason} when reason in [:closed, :einval] ->
        :ok

      {:error, _reason} ->
        accept_loop(scheme, listen_socket, state)
    end
  end

  defp accept(:http, listen_socket), do: :gen_tcp.accept(listen_socket, 1000)
  defp accept(:https, listen_socket), do: :ssl.transport_accept(listen_socket, 1000)

  defp controlling_process(:http, socket, pid), do: :gen_tcp.controlling_process(socket, pid)
  defp controlling_process(:https, socket, pid), do: :ssl.controlling_process(socket, pid)

  defp await_handoff(scheme, state) do
    receive do
      {:handoff, socket} -> handle_connection(scheme, socket, state)
    after
      5000 -> :ok
    end
  end

  defp handle_connection(:https, socket, state) do
    case :ssl.handshake(socket, 5000) do
      {:ok, socket} ->
        serve_and_close(:https, socket, state)

      {:error, _reason} ->
        :ssl.close(socket)
    end
  end

  defp handle_connection(:http, socket, state) do
    serve_and_close(:http, socket, state)
  end

  defp serve_and_close(scheme, socket, state) do
    remote_ip = peer_ip(scheme, socket)
    serve(scheme, socket, state, remote_ip)
  after
    close(scheme, socket)
  end

  defp serve(scheme, socket, state, remote_ip) do
    serve(scheme, socket, state, remote_ip, <<>>, state.config.read_timeout)
  end

  # `buffer` carries bytes already read past the previous request so a
  # pipelined keep-alive request is not dropped. The first request waits
  # `read_timeout`; a kept-alive connection then waits `idle_timeout` for
  # the next one, matching chihaya's http.Server IdleTimeout.
  defp serve(scheme, socket, state, remote_ip, buffer, timeout) do
    case read_request(scheme, socket, timeout, buffer) do
      {:ok, method, target, headers, rest} ->
        keep_alive? = state.config.enable_keepalive and keep_alive?(headers)
        respond(scheme, socket, state, remote_ip, method, target, headers, keep_alive?)

        if keep_alive? do
          serve(scheme, socket, state, remote_ip, rest, state.config.idle_timeout)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp respond(scheme, socket, state, remote_ip, method, target, headers, keep_alive?) do
    request = %Request{target: target, headers: headers, remote_ip: remote_ip}

    {status, body, after_fun} =
      case route(state, method, target, request) do
        {:ok, body, after_fun} -> {200, body, after_fun}
        :not_found -> {404, "404 page not found\n", nil}
        :method_not_allowed -> {405, "Method Not Allowed\n", nil}
      end

    send_response(scheme, socket, status, body, keep_alive?)

    # Post-hooks run after the response has been delivered, mirroring
    # chihaya's AfterAnnounce/AfterScrape ordering.
    if after_fun, do: after_fun.()
  end

  # Routes a request to announce/scrape, or signals 404/405 like chihaya's
  # httprouter (which answers unmatched paths and methods with plain-text
  # 404/405, not a bencoded failure).
  defp route(state, "GET", target, request) do
    path = request_path(target)

    cond do
      path in state.config.announce_routes -> handle_announce(state, request)
      path in state.config.scrape_routes -> handle_scrape(state, request)
      true -> :not_found
    end
  end

  defp route(state, _method, target, _request) do
    path = request_path(target)

    if path in state.config.announce_routes or path in state.config.scrape_routes do
      :method_not_allowed
    else
      :not_found
    end
  end

  defp handle_announce(state, request) do
    start = System.monotonic_time(:microsecond)

    result =
      with {:ok, announce} <- Parser.parse_announce(request, state.config) do
        af = Peer.address_family(announce.peer)

        case Logic.handle_announce(state.logic, %{}, announce) do
          {:ok, ctx, response} ->
            body = Writer.write_announce_response(response)
            after_fun = fn -> Logic.after_announce(state.logic, ctx, announce, response) end
            {:ok, af, body, after_fun}

          {:error, error} ->
            {:error, af, error}
        end
      end

    finish("announce", state, start, result)
  end

  defp handle_scrape(state, request) do
    start = System.monotonic_time(:microsecond)

    result =
      with {:ok, scrape} <- Parser.parse_scrape(request, state.config),
           {:ok, scrape} <- resolve_scrape_af(scrape, request) do
        case Logic.handle_scrape(state.logic, %{}, scrape) do
          {:ok, ctx, response} ->
            body = Writer.write_scrape_response(response)
            after_fun = fn -> Logic.after_scrape(state.logic, ctx, scrape, response) end
            {:ok, scrape.address_family, body, after_fun}

          {:error, error} ->
            {:error, scrape.address_family, error}
        end
      end

    finish("scrape", state, start, result)
  end

  defp resolve_scrape_af(scrape, request) do
    case request.remote_ip do
      ip when tuple_size(ip) == 4 -> {:ok, %{scrape | address_family: :ipv4}}
      ip when tuple_size(ip) == 8 -> {:ok, %{scrape | address_family: :ipv6}}
      _other -> {:error, ClientError.new("invalid IP")}
    end
  end

  defp finish(action, state, start, result) do
    {af, error, body, after_fun} =
      case result do
        {:ok, af, body, after_fun} -> {af, nil, body, after_fun}
        {:error, af, error} -> {af, error, Writer.write_error(error), nil}
        {:error, error} -> {nil, error, Writer.write_error(error), nil}
      end

    duration_ms =
      if state.config.enable_request_timing do
        (System.monotonic_time(:microsecond) - start) / 1000
      else
        0
      end

    Metrics.record_response_duration(
      "chihaya_http_response_duration_milliseconds",
      action,
      af,
      error,
      duration_ms
    )

    {:ok, body, after_fun}
  end

  ## HTTP/1.1 wire handling via :erlang.decode_packet

  defp read_request(scheme, socket, timeout, buffer) do
    with {:ok, method, target, rest} <- read_request_line(scheme, socket, timeout, buffer),
         {:ok, headers, rest} <- read_headers(scheme, socket, timeout, rest, %{}) do
      {:ok, method, target, headers, rest}
    end
  end

  defp read_request_line(_scheme, _socket, _timeout, buffer)
       when byte_size(buffer) > @max_header_bytes do
    {:error, :headers_too_large}
  end

  defp read_request_line(scheme, socket, timeout, buffer) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:more, _length} ->
        with {:ok, data} <- recv(scheme, socket, timeout) do
          read_request_line(scheme, socket, timeout, buffer <> data)
        end

      {:ok, {:http_request, method, {:abs_path, path}, _version}, rest} ->
        {:ok, method_string(method), path, rest}

      {:ok, {:http_request, method, {:absoluteURI, _s, _h, _p, path}, _v}, rest} ->
        {:ok, method_string(method), path, rest}

      {:ok, {:http_error, _line}, _rest} ->
        {:error, :bad_request}

      {:error, _reason} ->
        {:error, :bad_request}
    end
  end

  defp read_headers(_scheme, _socket, _timeout, buffer, _headers)
       when byte_size(buffer) > @max_header_bytes do
    {:error, :headers_too_large}
  end

  defp read_headers(scheme, socket, timeout, buffer, headers) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:more, _length} ->
        with {:ok, data} <- recv(scheme, socket, timeout) do
          read_headers(scheme, socket, timeout, buffer <> data, headers)
        end

      {:ok, :http_eoh, rest} ->
        {:ok, headers, rest}

      {:ok, {:http_header, _, field, _reserved, value}, rest} ->
        key = field |> header_name() |> String.downcase()
        # Keep the first occurrence of a header, like Go's Header.Get.
        headers = Map.put_new(headers, key, value)
        read_headers(scheme, socket, timeout, rest, headers)

      {:ok, {:http_error, _line}, _rest} ->
        {:error, :bad_request}

      {:error, _reason} ->
        {:error, :bad_request}
    end
  end

  defp method_string(method) when is_atom(method), do: Atom.to_string(method)
  defp method_string(method) when is_binary(method), do: method

  defp header_name(field) when is_atom(field), do: Atom.to_string(field)
  defp header_name(field) when is_binary(field), do: field

  defp keep_alive?(headers) do
    case Map.get(headers, "connection") do
      nil -> true
      value -> String.downcase(value) != "close"
    end
  end

  defp request_path(target), do: target |> :binary.split("?") |> hd()

  defp send_response(scheme, socket, status, body, keep_alive?) do
    connection_header = if keep_alive?, do: "keep-alive", else: "close"

    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      status_reason(status),
      "\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "Content-Length: ",
      Integer.to_string(IO.iodata_length(body)),
      "\r\n",
      "Connection: ",
      connection_header,
      "\r\n",
      "\r\n",
      body
    ]

    send_data(scheme, socket, response)
  end

  defp status_reason(200), do: "OK"
  defp status_reason(404), do: "Not Found"
  defp status_reason(405), do: "Method Not Allowed"

  ## Transport helpers (plain vs TLS)

  defp recv(:http, socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)
  defp recv(:https, socket, timeout), do: :ssl.recv(socket, 0, timeout)

  defp send_data(:http, socket, data), do: :gen_tcp.send(socket, data)
  defp send_data(:https, socket, data), do: :ssl.send(socket, data)

  defp close(:http, socket), do: :gen_tcp.close(socket)
  defp close(:https, socket), do: :ssl.close(socket)

  defp peer_ip(:http, socket) do
    case :inet.peername(socket) do
      {:ok, {ip, _port}} -> IP.normalize(ip)
      {:error, _reason} -> {0, 0, 0, 0}
    end
  end

  defp peer_ip(:https, socket) do
    case :ssl.peername(socket) do
      {:ok, {ip, _port}} -> IP.normalize(ip)
      {:error, _reason} -> {0, 0, 0, 0}
    end
  end
end
