defmodule Bento.Tracker.Metrics.Server do
  @moduledoc """
  A standalone HTTP server exposing the Prometheus metrics endpoint.

  Serves `GET /metrics` in the Prometheus text exposition format rendered
  by `Bento.Tracker.Metrics`. chihaya's server also serves pprof
  profiles; on the BEAM live introspection is done with `:observer`,
  `:recon` and remote shells instead, so only `/metrics` is exposed here.
  """

  use GenServer

  require Logger

  alias Bento.Tracker.IP
  alias Bento.Tracker.Metrics

  @acceptor_count 2

  # Bounds the request-line read like the tracker frontend's header cap
  # (net/http's default MaxHeaderBytes), so a client that never finishes
  # its request line cannot grow the buffer without bound.
  @max_request_line_bytes 1_048_576

  @doc "Starts the metrics server listening on `addr` (\"ip:port\")."
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(addr, opts \\ []) do
    GenServer.start_link(__MODULE__, addr, opts)
  end

  @doc "Returns the `{:ok, {ip, port}}` the server is bound to."
  @spec listen_address(pid()) :: {:ok, {:inet.ip_address(), :inet.port_number()}}
  def listen_address(pid), do: GenServer.call(pid, :listen_address)

  @impl GenServer
  def init(addr) do
    Process.flag(:trap_exit, true)

    with {:ok, ip, port} <- IP.parse_addr(addr),
         {:ok, socket} <-
           :gen_tcp.listen(port, [
             :binary,
             IP.inet_family(ip),
             ip: ip,
             active: false,
             reuseaddr: true,
             backlog: 128
           ]) do
      state = %{socket: socket}
      for _ <- 1..@acceptor_count, do: spawn_link(fn -> accept_loop(socket) end)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:listen_address, _from, state) do
    {:reply, :inet.sockname(state.socket), state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket, 1000) do
      {:ok, conn} ->
        serve(conn)
        accept_loop(socket)

      {:error, reason} when reason in [:closed, :einval] ->
        :ok

      {:error, _reason} ->
        accept_loop(socket)
    end
  end

  defp serve(conn) do
    case read_request_line(conn, <<>>) do
      # Like chihaya's promhttp handler, /metrics answers any method.
      {:ok, _method, "/metrics"} ->
        send_response(conn, 200, "text/plain; version=0.0.4; charset=utf-8", Metrics.render())

      {:ok, _method, _other} ->
        send_response(conn, 404, "text/plain; charset=utf-8", "not found\n")

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(conn)
  end

  defp read_request_line(_conn, buffer) when byte_size(buffer) > @max_request_line_bytes do
    {:error, :request_line_too_large}
  end

  defp read_request_line(conn, buffer) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:more, _length} ->
        case :gen_tcp.recv(conn, 0, 2000) do
          {:ok, data} -> read_request_line(conn, buffer <> data)
          {:error, reason} -> {:error, reason}
        end

      {:ok, {:http_request, method, {:abs_path, path}, _version}, _rest} ->
        {:ok, to_string(method), path}

      {:ok, _other, _rest} ->
        {:error, :bad_request}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_response(conn, status, content_type, body) do
    body = IO.iodata_to_binary(body)
    reason = status_reason(status)

    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason,
      "\r\n",
      "Content-Type: ",
      content_type,
      "\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(conn, response)
  end

  defp status_reason(200), do: "OK"
  defp status_reason(404), do: "Not Found"
end
