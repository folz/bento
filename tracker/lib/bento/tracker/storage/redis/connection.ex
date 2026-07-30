defmodule Bento.Tracker.Storage.Redis.Connection do
  @moduledoc """
  A minimal, dependency-free RESP2 client over `gen_tcp`.

  A single connection process serializes every command, which is exactly
  what the Redis peer store needs: `MULTI`/`EXEC` and `WATCH` blocks must
  run without interleaving from other commands, and Redis itself is
  single-threaded, so one ordered connection loses no throughput that
  matters here.

  Commands are issued as `command/2` (one request, one reply) or
  `pipeline/2` (several requests, replies returned in order). Integer
  arguments are stringified; all replies are decoded to Elixir terms:
  simple strings and bulk strings to binaries, integers to integers,
  nil bulk/array to `nil`, arrays to lists, and Redis errors to
  `{:error, {:redis, message}}`.
  """

  use GenServer

  @type reply :: binary() | integer() | nil | [reply()]

  @doc """
  Starts a connection to `host`/`port`.

  Options: `:password` (sends `AUTH` when non-empty), `:db` (sends
  `SELECT` when non-zero), `:connect_timeout` and `:recv_timeout` in
  milliseconds.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Issues a single command and returns its decoded reply."
  @spec command(pid(), [binary() | integer()]) :: {:ok, reply()} | {:error, term()}
  def command(conn, args) do
    case pipeline(conn, [args]) do
      {:ok, [reply]} -> normalize(reply)
      {:error, _reason} = error -> error
    end
  end

  @doc "Issues several commands and returns their decoded replies in order."
  @spec pipeline(pid(), [[binary() | integer()]]) :: {:ok, [reply()]} | {:error, term()}
  def pipeline(conn, commands) do
    GenServer.call(conn, {:pipeline, commands}, 30_000)
  end

  @doc "Closes the connection."
  @spec close(pid()) :: :ok
  def close(conn) do
    GenServer.stop(conn)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    connect_timeout = Keyword.get(opts, :connect_timeout, 15_000)
    recv_timeout = Keyword.get(opts, :recv_timeout, 15_000)
    send_timeout = Keyword.get(opts, :send_timeout, 15_000)

    case :gen_tcp.connect(
           to_charlist(host),
           port,
           [:binary, active: false, nodelay: true, send_timeout: send_timeout],
           connect_timeout
         ) do
      {:ok, socket} ->
        state = %{socket: socket, recv_timeout: recv_timeout, buffer: <<>>}

        with :ok <- maybe_auth(state, Keyword.get(opts, :password, "")),
             :ok <- maybe_select(state, Keyword.get(opts, :db, 0)) do
          {:ok, state}
        else
          {:error, reason} ->
            :gen_tcp.close(socket)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:pipeline, commands}, _from, state) do
    {result, state} = do_pipeline(state, commands)
    {:reply, result, state}
  end

  defp do_pipeline(state, commands) do
    request = Enum.map(commands, &encode_command/1)

    case :gen_tcp.send(state.socket, request) do
      :ok -> read_replies(state, length(commands))
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  ## Command encoding (RESP arrays of bulk strings)

  defp encode_command(args) do
    parts = Enum.map(args, &to_bulk/1)
    [?*, Integer.to_string(length(args)), "\r\n", parts]
  end

  defp to_bulk(arg) when is_integer(arg), do: to_bulk(Integer.to_string(arg))

  defp to_bulk(arg) when is_binary(arg) do
    [?$, Integer.to_string(byte_size(arg)), "\r\n", arg, "\r\n"]
  end

  ## Reply decoding

  defp read_replies(state, count) do
    case read_array(state, count, []) do
      {:ok, replies, state} -> {{:ok, replies}, state}
      {:error, reason, state} -> {{:error, reason}, state}
    end
  end

  defp read_reply(state) do
    with {:ok, line, state} <- read_line(state) do
      <<type, rest::binary>> = line
      decode(type, rest, state)
    end
  end

  defp decode(?+, rest, state), do: {:ok, rest, state}
  defp decode(?-, rest, state), do: {:ok, {:error, {:redis, rest}}, state}
  defp decode(?:, rest, state), do: {:ok, String.to_integer(rest), state}

  defp decode(?$, rest, state) do
    case String.to_integer(rest) do
      -1 ->
        {:ok, nil, state}

      length ->
        with {:ok, data, state} <- read_bytes(state, length + 2) do
          <<payload::binary-size(length), "\r\n">> = data
          {:ok, payload, state}
        end
    end
  end

  defp decode(?*, rest, state) do
    case String.to_integer(rest) do
      -1 -> {:ok, nil, state}
      count -> read_array(state, count, [])
    end
  end

  defp read_array(state, 0, acc), do: {:ok, Enum.reverse(acc), state}

  defp read_array(state, count, acc) do
    case read_reply(state) do
      {:ok, element, state} -> read_array(state, count - 1, [element | acc])
      {:error, _reason, _state} = error -> error
    end
  end

  # Reads a single CRLF-terminated line, decoding it from any buffered
  # bytes plus the socket.
  defp read_line(%{buffer: buffer} = state) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        {:ok, line, %{state | buffer: rest}}

      [_incomplete] ->
        case recv(state) do
          {:ok, state} -> read_line(state)
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  # Reads exactly `n` bytes (payload + trailing CRLF for bulk strings).
  defp read_bytes(%{buffer: buffer} = state, n) when byte_size(buffer) >= n do
    <<data::binary-size(n), rest::binary>> = buffer
    {:ok, data, %{state | buffer: rest}}
  end

  defp read_bytes(state, n) do
    case recv(state) do
      {:ok, state} -> read_bytes(state, n)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp recv(state) do
    case :gen_tcp.recv(state.socket, 0, state.recv_timeout) do
      {:ok, data} -> {:ok, %{state | buffer: state.buffer <> data}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Bootstrapping

  defp maybe_auth(_state, password) when password in [nil, ""], do: :ok
  defp maybe_auth(state, password), do: bootstrap(state, ["AUTH", password])

  defp maybe_select(_state, 0), do: :ok
  defp maybe_select(state, db), do: bootstrap(state, ["SELECT", db])

  defp bootstrap(state, command) do
    case do_pipeline(state, [command]) do
      {{:ok, [{:error, _reason} = error]}, _state} -> error
      {{:ok, [_reply]}, _state} -> :ok
      {{:error, reason}, _state} -> {:error, reason}
    end
  end

  # Surfaces a Redis-level error embedded in a reply as an {:error, ...}.
  defp normalize({:error, _reason} = error), do: error
  defp normalize(reply), do: {:ok, reply}
end
