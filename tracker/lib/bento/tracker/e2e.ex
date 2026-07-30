defmodule Bento.Tracker.E2E do
  @moduledoc """
  The end-to-end test suite, ported from chihaya's `cmd/chihaya/e2e.go`.

  It announces two distinct peers for a random infohash against a running
  tracker and asserts that the tracker returns the other peer, over HTTP
  and/or UDP. `Bento.Tracker.E2ETest` drives this in-process against a
  `Bento.Tracker.Runner`; the CLI's `e2e` subcommand drives it against an
  external tracker.
  """

  @initial_connection_id <<0, 0, 0x04, 0x17, 0x27, 0x10, 0x19, 0x80>>

  @doc """
  Runs the HTTP and/or UDP end-to-end tests.

  Options: `:http_addr` (a full announce URL like
  `"http://127.0.0.1:6969/announce"`), `:udp_addr` (like
  `"udp://127.0.0.1:6969"`), and `:delay` in milliseconds between the two
  announces. A `nil` or empty address skips that protocol.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    delay = Keyword.get(opts, :delay, 1000)

    with :ok <- maybe_test(:http, Keyword.get(opts, :http_addr), delay),
         :ok <- maybe_test(:udp, Keyword.get(opts, :udp_addr), delay) do
      :ok
    end
  end

  defp maybe_test(_protocol, addr, _delay) when addr in [nil, ""], do: :ok

  defp maybe_test(:http, addr, delay), do: test_http(addr, delay)
  defp maybe_test(:udp, addr, delay), do: test_udp(addr, delay)

  # The shared scenario from chihaya's e2e: announce two distinct peers
  # for one infohash and require the second to be given the first.
  defp run_scenario(announce, delay) do
    with {:ok, peers} <- announce.(peer_id(20), {50, 10, 12, 1}, 10_001),
         :ok <- expect(length(peers), 1, "first announce"),
         :ok <- sleep(delay),
         {:ok, peers} <- announce.(peer_id(21), {50, 10, 12, 2}, 10_002),
         :ok <- expect(length(peers), 1, "second announce") do
      expect(hd(peers).port, 10_001, "returned peer port")
    end
  end

  defp sleep(delay), do: Process.sleep(delay)

  ## HTTP

  defp test_http(base_url, delay) do
    info_hash = :crypto.strong_rand_bytes(20)

    run_scenario(
      fn peer_id, ip, port -> http_announce(base_url, info_hash, peer_id, ip, port) end,
      delay
    )
  end

  defp http_announce(base_url, info_hash, peer_id, ip, port) do
    query =
      URI.encode_query(%{
        "info_hash" => info_hash,
        "peer_id" => peer_id,
        "ip" => :inet.ntoa(ip) |> List.to_string(),
        "port" => port,
        "downloaded" => 50,
        "left" => 100,
        "uploaded" => 50,
        "event" => "started",
        "numwant" => 50,
        "compact" => 1
      })

    url = base_url <> "?" <> query

    case http_get(url) do
      {:ok, body} -> decode_http_peers(body)
      {:error, reason} -> {:error, {:announce_failed, reason}}
    end
  end

  defp http_get(url) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_v, 200, _r}, _headers, body}} -> {:ok, body}
      {:ok, {{_v, status, _r}, _headers, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_http_peers(body) do
    with {:ok, decoded} <- Bento.decode(body) do
      cond do
        is_map(decoded) and Map.has_key?(decoded, "failure reason") ->
          {:error, {:failure_reason, decoded["failure reason"]}}

        is_map(decoded) ->
          {:ok, decode_compact_peers(Map.get(decoded, "peers", ""))}

        true ->
          {:error, :unexpected_response}
      end
    end
  end

  defp decode_compact_peers(compact) when is_binary(compact) do
    for <<a, b, c, d, port::16-big <- compact>>, do: %{ip: {a, b, c, d}, port: port}
  end

  defp decode_compact_peers(_other), do: []

  ## UDP

  defp test_udp(addr, delay) do
    %URI{host: host, port: port} = URI.parse(addr)
    {:ok, host_ip} = :inet.parse_address(String.to_charlist(host))
    info_hash = :crypto.strong_rand_bytes(20)

    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    try do
      run_scenario(
        fn peer_id, ip, peer_port ->
          udp_announce(socket, host_ip, port, info_hash, peer_id, ip, peer_port)
        end,
        delay
      )
    after
      :gen_udp.close(socket)
    end
  end

  defp udp_announce(socket, host_ip, port, info_hash, peer_id, ip, peer_port) do
    tx_id = :crypto.strong_rand_bytes(4)

    with {:ok, connection_id} <- udp_connect(socket, host_ip, port, tx_id) do
      {a, b, c, d} = ip

      packet =
        connection_id <>
          <<1::32-big>> <>
          tx_id <>
          info_hash <>
          peer_id <>
          <<50::64-big, 100::64-big, 50::64-big, 2::32-big, a, b, c, d, 0::32-big, 50::32-big,
            peer_port::16-big>>

      with {:ok, response} <- udp_round_trip(socket, host_ip, port, packet) do
        <<1::32-big, ^tx_id::binary-size(4), _interval::32-big, _incomplete::32-big,
          _complete::32-big, peers::binary>> = response

        {:ok, for(<<a, b, c, d, p::16-big <- peers>>, do: %{ip: {a, b, c, d}, port: p})}
      end
    end
  end

  defp udp_connect(socket, host_ip, port, tx_id) do
    packet = @initial_connection_id <> <<0::32-big>> <> tx_id

    with {:ok, response} <- udp_round_trip(socket, host_ip, port, packet) do
      <<0::32-big, ^tx_id::binary-size(4), connection_id::binary-size(8)>> = response
      {:ok, connection_id}
    end
  end

  defp udp_round_trip(socket, host_ip, port, packet) do
    :ok = :gen_udp.send(socket, host_ip, port, packet)

    case :gen_udp.recv(socket, 0, 5000) do
      {:ok, {_ip, _port, response}} -> {:ok, response}
      {:error, reason} -> {:error, {:udp_recv, reason}}
    end
  end

  ## Helpers

  defp peer_id(last_byte) do
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, last_byte>>
  end

  defp expect(actual, expected, _label) when actual == expected, do: :ok
  defp expect(actual, expected, label), do: {:error, {label, expected: expected, got: actual}}
end
