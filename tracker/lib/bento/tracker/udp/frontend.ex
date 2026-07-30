defmodule Bento.Tracker.UDP.Frontend do
  @moduledoc """
  A BitTorrent tracker frontend over UDP (BEP 15).

  The frontend owns a single UDP socket and a receiver process that reads
  datagrams and dispatches each in its own process: connect requests mint
  an HMAC connection ID, announces and scrapes are parsed, handed to the
  tracker logic, and answered, with post-hooks run asynchronously.

  ## Configuration

    * `:addr` - the listen address `"ip:port"`
    * `:private_key` - the HMAC key for connection IDs; a random 64-byte
      key is generated when empty
    * `:max_clock_skew` - permitted future clock skew for connection IDs,
      in milliseconds (default: 10s)
    * `:enable_request_timing` - whether to record real response
      durations (default: `false`)
    * parse options: `:allow_ip_spoofing`, `:max_numwant`,
      `:default_numwant`, `:max_scrape_info_hashes`
  """

  use GenServer

  require Logger

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.IP
  alias Bento.Tracker.Logic
  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Peer
  alias Bento.Tracker.TimeCache
  alias Bento.Tracker.UDP.ConnectionID
  alias Bento.Tracker.UDP.Parser
  alias Bento.Tracker.UDP.Writer

  @default_max_clock_skew :timer.seconds(10)
  @default_max_numwant 100
  @default_default_numwant 50
  @default_max_scrape_info_hashes 50

  @connect_action 0
  @announce_action 1
  @scrape_action 2
  @announce_v6_action 4

  # The magic initial connection ID specified by BEP 15.
  @initial_connection_id <<0, 0, 0x04, 0x17, 0x27, 0x10, 0x19, 0x80>>

  @private_key_alphabet ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"

  @doc "Starts the UDP frontend."
  @spec start_link({Logic.t(), map()}, keyword()) :: GenServer.on_start()
  def start_link({logic, config}, opts \\ []) do
    GenServer.start_link(__MODULE__, {logic, config}, opts)
  end

  @doc "Returns the `{:ok, {ip, port}}` the socket is bound to."
  @spec listen_address(pid()) :: {:ok, {:inet.ip_address(), :inet.port_number()}}
  def listen_address(pid), do: GenServer.call(pid, :listen_address)

  @impl GenServer
  def init({logic, config}) do
    Process.flag(:trap_exit, true)
    config = validate(config)

    with {:ok, ip, port} <- parse_addr(config.addr),
         {:ok, socket} <- open_socket(ip, port) do
      state = %{logic: logic, config: config, socket: socket}
      receiver = spawn_link(fn -> recv_loop(socket, state) end)
      {:ok, Map.put(state, :receiver, receiver)}
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
    :gen_udp.close(state.socket)
    :ok
  end

  ## Config

  defp validate(config) do
    config = Map.new(config)

    private_key =
      case Map.get(config, :private_key) do
        key when is_binary(key) and key != "" ->
          key

        _empty ->
          key = generate_private_key()
          Logger.warning("UDP private key was not provided, using generated key")
          key
      end

    %{
      addr: Map.get(config, :addr, ""),
      private_key: private_key,
      max_clock_skew: positive(Map.get(config, :max_clock_skew), @default_max_clock_skew),
      enable_request_timing: Map.get(config, :enable_request_timing, false),
      allow_ip_spoofing: Map.get(config, :allow_ip_spoofing, false),
      max_numwant: positive(Map.get(config, :max_numwant), @default_max_numwant),
      default_numwant: positive(Map.get(config, :default_numwant), @default_default_numwant),
      max_scrape_info_hashes:
        positive(Map.get(config, :max_scrape_info_hashes), @default_max_scrape_info_hashes)
    }
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp generate_private_key do
    for _ <- 1..64, into: "", do: <<Enum.random(@private_key_alphabet)>>
  end

  defp parse_addr(addr) do
    with [_ | _] = parts <- String.split(addr, ":"),
         port_str <- List.last(parts),
         host <- Enum.join(Enum.drop(parts, -1), ":"),
         {port, ""} <- Integer.parse(port_str),
         {:ok, ip} <- parse_host(host) do
      {:ok, ip, port}
    else
      _error -> {:error, {:invalid_addr, addr}}
    end
  end

  defp parse_host(host) when host in ["", "*"], do: {:ok, {0, 0, 0, 0}}

  defp parse_host(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp open_socket(ip, port) do
    inet = if tuple_size(ip) == 8, do: :inet6, else: :inet
    :gen_udp.open(port, [:binary, inet, {:ip, ip}, {:active, false}, {:reuseaddr, true}])
  end

  ## Receive loop

  defp recv_loop(socket, state) do
    case :gen_udp.recv(socket, 0) do
      {:ok, {addr, port, packet}} ->
        spawn(fn -> handle_datagram(state, addr, port, packet) end)
        recv_loop(socket, state)

      {:error, reason} when reason in [:closed, :einval] ->
        :ok

      {:error, _reason} ->
        recv_loop(socket, state)
    end
  end

  defp handle_datagram(state, addr, port, packet) do
    start = System.monotonic_time(:microsecond)
    source_ip = normalize_ip(addr)
    write = fn data -> :gen_udp.send(state.socket, addr, port, data) end

    {action, af, error} = handle_request(state, packet, source_ip, write)

    duration_ms =
      if state.config.enable_request_timing do
        (System.monotonic_time(:microsecond) - start) / 1000
      else
        0
      end

    record_response_duration(action, af, error, duration_ms)
  end

  # No client packet is shorter than 16 bytes. We return nothing in case
  # this is a DoS attempt.
  defp handle_request(_state, packet, _source_ip, _write) when byte_size(packet) < 16 do
    {nil, nil, Parser.err_malformed_packet()}
  end

  defp handle_request(state, packet, source_ip, write) do
    <<conn_id::binary-size(8), action_id::32-big, tx_id::binary-size(4), _rest::binary>> = packet

    if action_id != @connect_action and not valid_connection_id?(state, conn_id, source_ip) do
      write.(Writer.write_error(tx_id, ClientError.new("bad connection ID")))
      {action_name(action_id), nil, ClientError.new("bad connection ID")}
    else
      dispatch(state, action_id, packet, tx_id, conn_id, source_ip, write)
    end
  end

  defp dispatch(state, @connect_action, _packet, tx_id, conn_id, source_ip, write) do
    if conn_id == @initial_connection_id do
      connection_id = ConnectionID.new(source_ip, TimeCache.now_unix(), state.config.private_key)
      write.(Writer.write_connection_id(tx_id, connection_id))
      {"connect", address_family(source_ip), nil}
    else
      {"connect", address_family(source_ip), Parser.err_malformed_packet()}
    end
  end

  defp dispatch(state, action_id, packet, tx_id, _conn_id, source_ip, write)
       when action_id in [@announce_action, @announce_v6_action] do
    v6_action? = action_id == @announce_v6_action

    case Parser.parse_announce(packet, source_ip, v6_action?, parse_opts(state)) do
      {:ok, announce} ->
        af = Peer.address_family(announce.peer)

        case Logic.handle_announce(state.logic, %{}, announce) do
          {:ok, ctx, response} ->
            write.(Writer.write_announce(tx_id, response, v6_action?, af == :ipv6))
            spawn(fn -> Logic.after_announce(state.logic, ctx, announce, response) end)
            {"announce", af, nil}

          {:error, error} ->
            write.(Writer.write_error(tx_id, error))
            {"announce", af, error}
        end

      {:error, error} ->
        write.(Writer.write_error(tx_id, error))
        {"announce", nil, error}
    end
  end

  defp dispatch(state, @scrape_action, packet, tx_id, _conn_id, source_ip, write) do
    case Parser.parse_scrape(packet, source_ip, parse_opts(state)) do
      {:ok, scrape} ->
        af = address_family(source_ip)
        scrape = %{scrape | address_family: af}

        case Logic.handle_scrape(state.logic, %{}, scrape) do
          {:ok, ctx, response} ->
            write.(Writer.write_scrape(tx_id, response))
            spawn(fn -> Logic.after_scrape(state.logic, ctx, scrape, response) end)
            {"scrape", af, nil}

          {:error, error} ->
            write.(Writer.write_error(tx_id, error))
            {"scrape", af, error}
        end

      {:error, error} ->
        write.(Writer.write_error(tx_id, error))
        {"scrape", nil, error}
    end
  end

  defp dispatch(_state, _action_id, _packet, tx_id, _conn_id, source_ip, write) do
    error = ClientError.new("unknown action ID")
    write.(Writer.write_error(tx_id, error))
    {"unknown", address_family(source_ip), error}
  end

  defp valid_connection_id?(state, conn_id, source_ip) do
    max_clock_skew_seconds = div(state.config.max_clock_skew, 1000)

    ConnectionID.valid?(
      conn_id,
      source_ip,
      TimeCache.now_unix(),
      max_clock_skew_seconds,
      state.config.private_key
    )
  end

  defp parse_opts(state) do
    %{
      allow_ip_spoofing: state.config.allow_ip_spoofing,
      max_numwant: state.config.max_numwant,
      default_numwant: state.config.default_numwant,
      max_scrape_info_hashes: state.config.max_scrape_info_hashes
    }
  end

  defp action_name(@connect_action), do: "connect"
  defp action_name(@announce_action), do: "announce"
  defp action_name(@announce_v6_action), do: "announce"
  defp action_name(@scrape_action), do: "scrape"
  defp action_name(_other), do: "unknown"

  defp normalize_ip({0, 0, 0, 0, 0, 0xFFFF, _ab, _cd} = ip), do: IP.to4(ip)
  defp normalize_ip(ip), do: ip

  defp address_family(ip) when tuple_size(ip) == 4, do: :ipv4
  defp address_family(ip) when tuple_size(ip) == 8, do: :ipv6

  defp record_response_duration(action, af, error, duration_ms) do
    labels = %{
      "action" => action || "",
      "address_family" => address_family_label(af),
      "error" => error_label(error)
    }

    Metrics.observe("chihaya_udp_response_duration_milliseconds", labels, duration_ms)
  end

  defp address_family_label(nil), do: "Unknown"
  defp address_family_label(:ipv4), do: "IPv4"
  defp address_family_label(:ipv6), do: "IPv6"

  defp error_label(nil), do: ""
  defp error_label(%ClientError{message: message}), do: message
  defp error_label(_internal), do: "internal error"
end
