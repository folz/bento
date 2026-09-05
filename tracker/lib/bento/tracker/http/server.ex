defmodule Bento.Tracker.HTTP.Server do
  @moduledoc """
  A minimal HTTP/1.1 server over `gen_tcp`/`ssl`, shared by the tracker
  frontend and the metrics endpoint.

  The server owns one listening socket per configured scheme and a pool
  of acceptor processes. Each accepted connection is served in its own
  process, which parses requests with the VM's `:erlang.decode_packet/3`,
  calls the handler, writes the response and, with keep-alive enabled,
  loops for the next request.

  ## Options

    * `:listeners` - `[{:http, "ip:port"} | {:https, "ip:port"}]`
    * `:handler` - a function from `Bento.Tracker.HTTP.Request` to
      `{status, body}` or `{status, body, opts}`, where `opts` may set
      `:content_type` and `:after` (a function run once the response has
      been written, used for the tracker's post-hooks)
    * `:tls` - `[certfile: path, keyfile: path]`, used by `:https`
    * `:read_timeout`, `:write_timeout`, `:idle_timeout` - in
      milliseconds, defaulting to 2s, 2s and 30s like chihaya's
      `http.Server`; non-positive values fall back to the default
    * `:keepalive` - whether to keep connections alive (default `false`)
  """

  use GenServer

  alias Bento.Tracker.HTTP.Request
  alias Bento.Tracker.IP

  @acceptor_count 10
  @default_timeouts %{read_timeout: 2000, write_timeout: 2000, idle_timeout: 30_000}
  @reasons %{200 => "OK", 404 => "Not Found", 405 => "Method Not Allowed"}

  # Caps the request line and header block so a client that never sends
  # the terminating blank line cannot grow the read buffer without bound.
  # Mirrors net/http's default MaxHeaderBytes (1 MiB).
  @max_header_bytes 1_048_576

  @doc "Starts the server."
  @spec start_link(keyword() | map(), keyword()) :: GenServer.on_start()
  def start_link(opts, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, Map.new(opts), gen_opts)
  end

  @doc "Returns the actual `{:ok, {ip, port}}` a listener is bound to."
  @spec listen_address(pid(), :http | :https) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def listen_address(pid, scheme \\ :http), do: GenServer.call(pid, {:listen_address, scheme})

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    timeouts =
      Map.new(@default_timeouts, fn {key, default} ->
        case Map.get(opts, key) do
          value when is_integer(value) and value > 0 -> {key, value}
          _invalid -> {key, default}
        end
      end)

    state =
      Map.merge(opts, timeouts)
      |> Map.put_new(:keepalive, false)
      |> Map.put_new(:tls, [])

    case open_all(state.listeners, state, []) do
      {:ok, sockets} ->
        state = Map.put(state, :sockets, sockets)

        for {scheme, socket} <- sockets, _ <- 1..@acceptor_count do
          spawn_link(fn -> accept_loop(scheme, socket, state) end)
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:listen_address, scheme}, _from, state) do
    reply =
      case Keyword.fetch(state.sockets, scheme) do
        {:ok, socket} -> :inet.sockname(socket)
        :error -> {:error, :not_listening}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    for {scheme, socket} <- state.sockets, do: close(scheme, socket)
    :ok
  end

  ## Listeners

  defp open_all([], _state, opened), do: {:ok, opened}

  defp open_all([{scheme, addr} | rest], state, opened) do
    case listen(scheme, addr, state) do
      {:ok, socket} ->
        open_all(rest, state, [{scheme, socket} | opened])

      {:error, reason} ->
        for {s, socket} <- opened, do: close(s, socket)
        {:error, {scheme, reason}}
    end
  end

  defp listen(scheme, addr, state) do
    with {:ok, ip, port} <- IP.parse_addr(addr) do
      opts = [
        :binary,
        IP.inet_family(ip),
        ip: ip,
        active: false,
        reuseaddr: true,
        packet: :raw,
        backlog: 1024,
        # Bounds a response write against a stuck client, standing in for
        # chihaya's http.Server WriteTimeout. Inherited by accepted sockets.
        send_timeout: state.write_timeout
      ]

      case scheme do
        :http ->
          :gen_tcp.listen(port, opts)

        :https ->
          tls = [
            versions: [:"tlsv1.2", :"tlsv1.3"],
            certfile: String.to_charlist(state.tls[:certfile]),
            keyfile: String.to_charlist(state.tls[:keyfile])
          ]

          :ssl.listen(port, opts ++ tls)
      end
    end
  end

  ## Acceptors and connections

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

  defp await_handoff(scheme, state) do
    receive do
      {:handoff, socket} -> handle_connection(scheme, socket, state)
    after
      5000 -> :ok
    end
  end

  defp handle_connection(:https, socket, state) do
    case :ssl.handshake(socket, 5000) do
      {:ok, socket} -> serve_and_close(:https, socket, state)
      {:error, _reason} -> :ssl.close(socket)
    end
  end

  defp handle_connection(:http, socket, state), do: serve_and_close(:http, socket, state)

  defp serve_and_close(scheme, socket, state) do
    serve(scheme, socket, state, peer_ip(scheme, socket), <<>>, state.read_timeout)
  after
    close(scheme, socket)
  end

  # `buffer` carries bytes already read past the previous request so a
  # pipelined keep-alive request is not dropped. The first request waits
  # `read_timeout`; a kept-alive connection then waits `idle_timeout` for
  # the next one, matching chihaya's http.Server IdleTimeout.
  defp serve(scheme, socket, state, remote_ip, buffer, timeout) do
    case read_request(scheme, socket, timeout, buffer) do
      {:ok, request, rest} ->
        request = %{request | remote_ip: remote_ip}
        keep_alive? = state.keepalive and keep_alive?(request.headers)
        respond(scheme, socket, state, request, keep_alive?)

        if keep_alive? do
          serve(scheme, socket, state, remote_ip, rest, state.idle_timeout)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp respond(scheme, socket, state, request, keep_alive?) do
    {status, body, opts} =
      case state.handler.(request) do
        {status, body} -> {status, body, []}
        {status, body, opts} -> {status, body, opts}
      end

    response = [
      "HTTP/1.1 #{status} #{Map.fetch!(@reasons, status)}\r\n",
      "Content-Type: #{Keyword.get(opts, :content_type, "text/plain; charset=utf-8")}\r\n",
      "Content-Length: #{IO.iodata_length(body)}\r\n",
      "Connection: #{if keep_alive?, do: "keep-alive", else: "close"}\r\n\r\n",
      body
    ]

    send_data(scheme, socket, response)

    # Runs after the response has been delivered, mirroring chihaya's
    # AfterAnnounce/AfterScrape ordering.
    if after_fun = opts[:after], do: after_fun.()
  end

  defp keep_alive?(headers) do
    case Map.get(headers, "connection") do
      nil -> true
      value -> String.downcase(value) != "close"
    end
  end

  ## HTTP/1.1 wire handling via :erlang.decode_packet

  defp read_request(scheme, socket, timeout, buffer) do
    with {:ok, method, target, rest} <- read_request_line(scheme, socket, timeout, buffer),
         {:ok, headers, rest} <- read_headers(scheme, socket, timeout, rest, %{}) do
      {:ok, %Request{method: method, target: target, headers: headers, remote_ip: nil}, rest}
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
        {:ok, to_string(method), path, rest}

      {:ok, {:http_request, method, {:absoluteURI, _s, _h, _p, path}, _v}, rest} ->
        {:ok, to_string(method), path, rest}

      _malformed ->
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
        # Keep the first occurrence of a header, like Go's Header.Get.
        headers = Map.put_new(headers, String.downcase(to_string(field)), value)
        read_headers(scheme, socket, timeout, rest, headers)

      _malformed ->
        {:error, :bad_request}
    end
  end

  ## Transport helpers (plain vs TLS)

  defp accept(:http, listen_socket), do: :gen_tcp.accept(listen_socket, 1000)
  defp accept(:https, listen_socket), do: :ssl.transport_accept(listen_socket, 1000)

  defp controlling_process(:http, socket, pid), do: :gen_tcp.controlling_process(socket, pid)
  defp controlling_process(:https, socket, pid), do: :ssl.controlling_process(socket, pid)

  defp recv(:http, socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)
  defp recv(:https, socket, timeout), do: :ssl.recv(socket, 0, timeout)

  defp send_data(:http, socket, data), do: :gen_tcp.send(socket, data)
  defp send_data(:https, socket, data), do: :ssl.send(socket, data)

  defp close(:http, socket), do: :gen_tcp.close(socket)
  defp close(:https, socket), do: :ssl.close(socket)

  defp peer_ip(scheme, socket) do
    peername = if scheme == :https, do: :ssl.peername(socket), else: :inet.peername(socket)

    case peername do
      {:ok, {ip, _port}} -> IP.normalize(ip)
      {:error, _reason} -> {0, 0, 0, 0}
    end
  end
end
