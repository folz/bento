defmodule Bento.Tracker.HTTP.Frontend do
  @moduledoc """
  A BitTorrent frontend over HTTP (BEP 3, BEP 23).

  The frontend owns one or two listening sockets (plain and/or TLS) and a
  pool of acceptor processes. Each accepted connection is handled in its
  own process that parses HTTP/1.1 GET requests with the VM's built-in
  `:erlang.decode_packet/3`, routes announce and scrape paths to the
  tracker logic, writes the bencoded response, and runs the post-hooks
  asynchronously.

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
      `:max_numwant`, `:default_numwant`, `:max_scrape_info_hashes`

  At least one of `:addr` / `:https_addr` and both route lists are
  required.
  """

  use GenServer

  require Logger

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.HTTP.Parser
  alias Bento.Tracker.HTTP.Request
  alias Bento.Tracker.HTTP.Writer
  alias Bento.Tracker.Logic
  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Peer

  @default_read_timeout :timer.seconds(2)
  @default_write_timeout :timer.seconds(2)
  @default_idle_timeout :timer.seconds(30)
  @default_max_numwant 100
  @default_default_numwant 50
  @default_max_scrape_info_hashes 50
  @acceptor_count 10

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
        {:ok, socket} -> :inet.sockname(socket_for_name(socket))
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
    |> default_positive(:max_numwant, @default_max_numwant)
    |> default_positive(:default_numwant, @default_default_numwant)
    |> default_positive(:max_scrape_info_hashes, @default_max_scrape_info_hashes)
    |> Map.put_new(:allow_ip_spoofing, false)
    |> Map.put_new(:real_ip_header, "")
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

  defp listen(:http, addr, _config) do
    with {:ok, ip, port} <- parse_addr(addr) do
      :gen_tcp.listen(port, [
        :binary,
        ip: ip,
        active: false,
        reuseaddr: true,
        packet: :raw,
        backlog: 1024
      ])
    end
  end

  defp listen(:https, addr, config) do
    with {:ok, ip, port} <- parse_addr(addr) do
      :ssl.listen(port, [
        :binary,
        ip: ip,
        active: false,
        reuseaddr: true,
        packet: :raw,
        backlog: 1024,
        versions: [:"tlsv1.2", :"tlsv1.3"],
        certfile: String.to_charlist(config.tls_cert_path),
        keyfile: String.to_charlist(config.tls_key_path)
      ])
    end
  end

  defp parse_addr(addr) do
    with {host, port_str} <- split_host_port(addr),
         {port, ""} <- Integer.parse(port_str),
         {:ok, ip} <- parse_host(host) do
      {:ok, ip, port}
    else
      _error -> {:error, {:invalid_addr, addr}}
    end
  end

  defp split_host_port(addr) do
    case String.split(addr, ":") do
      [port_str] -> {"", port_str}
      parts -> {Enum.join(Enum.drop(parts, -1), ":"), List.last(parts)}
    end
  end

  defp parse_host(""), do: {:ok, {0, 0, 0, 0}}
  defp parse_host("*"), do: {:ok, {0, 0, 0, 0}}

  defp parse_host(host) do
    host = String.trim_leading(host, "[") |> String.trim_trailing("]")
    :inet.parse_address(String.to_charlist(host))
  end

  defp close_listener({:sslsocket, _, _} = socket), do: :ssl.close(socket)
  defp close_listener(socket), do: :gen_tcp.close(socket)

  defp socket_for_name({:sslsocket, _, _} = socket), do: socket
  defp socket_for_name(socket), do: socket

  ## Acceptors and connection handling

  defp start_acceptor(scheme, listen_socket, state) do
    parent = self()
    spawn_link(fn -> accept_loop(scheme, listen_socket, state, parent) end)
  end

  defp accept_loop(scheme, listen_socket, state, parent) do
    case accept(scheme, listen_socket) do
      {:ok, socket} ->
        handle_connection(scheme, socket, state)
        accept_loop(scheme, listen_socket, state, parent)

      {:error, reason} when reason in [:closed, :einval] ->
        :ok

      {:error, _reason} ->
        accept_loop(scheme, listen_socket, state, parent)
    end
  end

  defp accept(:http, listen_socket), do: :gen_tcp.accept(listen_socket, 1000)

  defp accept(:https, listen_socket) do
    with {:ok, socket} <- :ssl.transport_accept(listen_socket, 1000),
         {:ok, socket} <- ssl_handshake(socket) do
      {:ok, socket}
    end
  end

  defp ssl_handshake(socket) do
    if function_exported?(:ssl, :handshake, 2) do
      :ssl.handshake(socket, 5000)
    else
      apply(:ssl, :ssl_accept, [socket, 5000])
    end
  end

  defp handle_connection(scheme, socket, state) do
    remote_ip = peer_ip(scheme, socket)
    serve(scheme, socket, state, remote_ip)
  after
    close(scheme, socket)
  end

  defp serve(scheme, socket, state, remote_ip) do
    timeout = state.config.read_timeout

    case read_request(scheme, socket, timeout) do
      {:ok, method, target, headers} ->
        keep_alive? = state.config.enable_keepalive and keep_alive?(headers)
        respond(scheme, socket, state, remote_ip, method, target, headers, keep_alive?)

        if keep_alive? do
          serve(scheme, socket, state, remote_ip)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp respond(scheme, socket, state, remote_ip, method, target, headers, keep_alive?) do
    request = %Request{target: target, headers: headers, remote_ip: remote_ip}
    {action, body} = route(state, method, target, request)

    send_response(scheme, socket, body, keep_alive?, state.config.write_timeout)
    _ = action
  end

  defp route(state, "GET", target, request) do
    path = request_path(target)

    cond do
      path in state.config.announce_routes ->
        {"announce", handle_announce(state, request)}

      path in state.config.scrape_routes ->
        {"scrape", handle_scrape(state, request)}

      true ->
        {"unknown", Writer.write_error(ClientError.new("not found"))}
    end
  end

  defp route(_state, _method, _target, _request) do
    {"unknown", Writer.write_error(ClientError.new("method not allowed"))}
  end

  defp handle_announce(state, request) do
    start = System.monotonic_time(:microsecond)

    result =
      with {:ok, announce} <- Parser.parse_announce(request, state.config) do
        af = Peer.address_family(announce.peer)

        case Logic.handle_announce(state.logic, %{}, announce) do
          {:ok, ctx, response} ->
            body = Writer.write_announce_response(response)
            spawn(fn -> Logic.after_announce(state.logic, ctx, announce, response) end)
            {:ok, af, body}

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
            spawn(fn -> Logic.after_scrape(state.logic, ctx, scrape, response) end)
            {:ok, scrape.address_family, body}

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
    {af, error, body} =
      case result do
        {:ok, af, body} -> {af, nil, body}
        {:error, af, error} -> {af, error, Writer.write_error(error)}
        {:error, error} -> {nil, error, Writer.write_error(error)}
      end

    duration_ms =
      if state.config.enable_request_timing do
        (System.monotonic_time(:microsecond) - start) / 1000
      else
        0
      end

    record_response_duration(action, af, error, duration_ms)
    body
  end

  defp record_response_duration(action, af, error, duration_ms) do
    labels = %{
      "action" => action,
      "address_family" => address_family_label(af),
      "error" => error_label(error)
    }

    Metrics.observe("chihaya_http_response_duration_milliseconds", labels, duration_ms)
  end

  defp address_family_label(nil), do: "Unknown"
  defp address_family_label(:ipv4), do: "IPv4"
  defp address_family_label(:ipv6), do: "IPv6"

  defp error_label(nil), do: ""
  defp error_label(%ClientError{message: message}), do: message
  defp error_label(_internal), do: "internal error"

  ## HTTP/1.1 wire handling via :erlang.decode_packet

  defp read_request(scheme, socket, timeout) do
    with {:ok, method, target} <- read_request_line(scheme, socket, timeout, <<>>),
         {:ok, headers} <- read_headers(scheme, socket, timeout, <<>>, %{}) do
      {:ok, method, target, headers}
    end
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

  defp read_headers(scheme, socket, timeout, buffer, headers) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:more, _length} ->
        with {:ok, data} <- recv(scheme, socket, timeout) do
          read_headers(scheme, socket, timeout, buffer <> data, headers)
        end

      {:ok, :http_eoh, _rest} ->
        {:ok, headers}

      {:ok, {:http_header, _, field, _reserved, value}, rest} ->
        key = field |> header_name() |> String.downcase()
        read_headers(scheme, socket, timeout, rest, Map.put(headers, key, value))

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

  defp request_path(target) do
    case :binary.split(target, "?") do
      [path | _rest] -> path
      [] -> target
    end
  end

  defp send_response(scheme, socket, body, keep_alive?, timeout) do
    body = IO.iodata_to_binary(body)

    connection_header = if keep_alive?, do: "keep-alive", else: "close"

    response = [
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: ",
      connection_header,
      "\r\n",
      "\r\n",
      body
    ]

    send_data(scheme, socket, response, timeout)
  end

  ## Transport helpers (plain vs TLS)

  defp recv(:http, socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)
  defp recv(:https, socket, timeout), do: :ssl.recv(socket, 0, timeout)

  defp send_data(:http, socket, data, _timeout), do: :gen_tcp.send(socket, data)
  defp send_data(:https, socket, data, _timeout), do: :ssl.send(socket, data)

  defp close(:http, socket), do: :gen_tcp.close(socket)
  defp close(:https, socket), do: :ssl.close(socket)

  defp peer_ip(:http, socket) do
    case :inet.peername(socket) do
      {:ok, {ip, _port}} -> normalize_ip(ip)
      {:error, _reason} -> {0, 0, 0, 0}
    end
  end

  defp peer_ip(:https, socket) do
    case :ssl.peername(socket) do
      {:ok, {ip, _port}} -> normalize_ip(ip)
      {:error, _reason} -> {0, 0, 0, 0}
    end
  end

  defp normalize_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    import Bitwise
    {ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF}
  end

  defp normalize_ip(ip), do: ip
end
