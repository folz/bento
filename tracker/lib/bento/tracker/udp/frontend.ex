defmodule Bento.Tracker.UDP.Frontend do
  @moduledoc """
  A BitTorrent tracker frontend over UDP (BEP 15).

  The frontend owns a single UDP socket and a receiver process that reads
  datagrams and dispatches each in its own process: connect requests mint
  an HMAC connection ID, announces and scrapes are parsed, handed to the
  tracker logic, and answered; post-hooks run after the response is sent.

  ## Configuration

    * `:addr` - the listen address `"ip:port"`
    * `:private_key` - the HMAC key for connection IDs; a random 64-byte
      key is generated when empty
    * `:max_clock_skew` - permitted future clock skew for connection IDs,
      in milliseconds (default: 10s)
    * `:enable_request_timing` - whether to record real response
      durations (default: `false`)
    * parse options: `:allow_ip_spoofing`, `:max_numwant`,
      `:default_numwant`, `:max_scrape_infohashes`
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

    with {:ok, ip, port} <- IP.parse_addr(config.addr),
         {:ok, socket} <- open_socket(ip, port) do
      state = %{logic: logic, config: config, socket: socket}
      spawn_link(fn -> recv_loop(socket, state) end)
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

    defaults = Parser.default_options()

    parse_opts = %{
      allow_ip_spoofing: Map.get(config, :allow_ip_spoofing, false),
      max_numwant: positive(Map.get(config, :max_numwant), defaults.max_numwant),
      default_numwant: positive(Map.get(config, :default_numwant), defaults.default_numwant),
      max_scrape_infohashes:
        positive(Map.get(config, :max_scrape_infohashes), defaults.max_scrape_infohashes)
    }

    %{
      addr: Map.get(config, :addr, ""),
      private_key: private_key,
      # chihaya does not validate or default MaxClockSkew: an omitted value
      # is 0 (no future skew tolerated), so we mirror that rather than
      # inventing a default. Resolved to whole seconds once, the unit the
      # connection-ID validator uses.
      max_clock_skew_seconds: div(non_negative(Map.get(config, :max_clock_skew), 0), 1000),
      enable_request_timing: Map.get(config, :enable_request_timing, false),
      parse_opts: parse_opts
    }
  end

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, default), do: default

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp generate_private_key do
    for _ <- 1..64, into: "", do: <<Enum.random(@private_key_alphabet)>>
  end

  defp open_socket(ip, port) do
    opts = [:binary, IP.inet_family(ip), {:ip, ip}, {:active, false}, {:reuseaddr, true}]
    :gen_udp.open(port, opts)
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
    source_ip = IP.normalize(addr)
    write = fn data -> :gen_udp.send(state.socket, addr, port, data) end

    {action, af, error, after_fun} = handle_request(state, packet, source_ip, write)

    duration_ms =
      if state.config.enable_request_timing do
        (System.monotonic_time(:microsecond) - start) / 1000
      else
        0
      end

    Metrics.record_response_duration(
      "chihaya_udp_response_duration_milliseconds",
      action,
      af,
      error,
      duration_ms
    )

    # Post-hooks run after the response has been delivered and timed,
    # mirroring chihaya's detached AfterAnnounce/AfterScrape.
    if after_fun, do: after_fun.()
  end

  # No client packet is shorter than 16 bytes. We return nothing in case
  # this is a DoS attempt.
  defp handle_request(_state, packet, _source_ip, _write) when byte_size(packet) < 16 do
    {nil, nil, Parser.err_malformed_packet(), nil}
  end

  defp handle_request(state, packet, source_ip, write) do
    <<conn_id::binary-size(8), action_id::32-big, tx_id::binary-size(4), _rest::binary>> = packet

    if action_id != @connect_action and not valid_connection_id?(state, conn_id, source_ip) do
      write.(Writer.write_error(tx_id, ClientError.new("bad connection ID")))
      # chihaya returns before setting the action name, so the metric's
      # action label is empty and the address family is Unknown.
      {"", nil, ClientError.new("bad connection ID"), nil}
    else
      dispatch(state, action_id, packet, tx_id, conn_id, source_ip, write)
    end
  end

  defp dispatch(state, @connect_action, _packet, tx_id, conn_id, source_ip, write) do
    if conn_id == @initial_connection_id do
      connection_id = ConnectionID.new(source_ip, TimeCache.now_unix(), state.config.private_key)
      write.(Writer.write_connection_id(tx_id, connection_id))
      {"connect", IP.address_family(source_ip), nil, nil}
    else
      # chihaya sets the address family only after the magic check passes,
      # so a wrong-magic connect records an Unknown address family.
      {"connect", nil, Parser.err_malformed_packet(), nil}
    end
  end

  defp dispatch(state, action_id, packet, tx_id, _conn_id, source_ip, write)
       when action_id in [@announce_action, @announce_v6_action] do
    v6_action? = action_id == @announce_v6_action

    case Parser.parse_announce(packet, source_ip, v6_action?, state.config.parse_opts) do
      {:ok, announce} ->
        af = Peer.address_family(announce.peer)

        case Logic.handle_announce(state.logic, %{}, announce) do
          {:ok, ctx, response} ->
            write.(Writer.write_announce(tx_id, response, v6_action?, af == :ipv6))
            after_fun = fn -> Logic.after_announce(state.logic, ctx, announce, response) end
            {"announce", af, nil, after_fun}

          {:error, error} ->
            write.(Writer.write_error(tx_id, error))
            {"announce", af, error, nil}
        end

      {:error, error} ->
        write.(Writer.write_error(tx_id, error))
        {"announce", nil, error, nil}
    end
  end

  defp dispatch(state, @scrape_action, packet, tx_id, _conn_id, source_ip, write) do
    case Parser.parse_scrape(packet, source_ip, state.config.parse_opts) do
      {:ok, scrape} ->
        af = IP.address_family(source_ip)
        scrape = %{scrape | address_family: af}

        case Logic.handle_scrape(state.logic, %{}, scrape) do
          {:ok, ctx, response} ->
            write.(Writer.write_scrape(tx_id, response))
            after_fun = fn -> Logic.after_scrape(state.logic, ctx, scrape, response) end
            {"scrape", af, nil, after_fun}

          {:error, error} ->
            write.(Writer.write_error(tx_id, error))
            {"scrape", af, error, nil}
        end

      {:error, error} ->
        write.(Writer.write_error(tx_id, error))
        {"scrape", nil, error, nil}
    end
  end

  defp dispatch(_state, _action_id, _packet, tx_id, _conn_id, _source_ip, write) do
    error = ClientError.new("unknown action ID")
    write.(Writer.write_error(tx_id, error))
    # chihaya's default case never sets an action name or address family.
    {"", nil, error, nil}
  end

  defp valid_connection_id?(state, conn_id, source_ip) do
    ConnectionID.valid?(
      conn_id,
      source_ip,
      TimeCache.now_unix(),
      state.config.max_clock_skew_seconds,
      state.config.private_key
    )
  end
end
