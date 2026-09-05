defmodule Bento.Tracker.HTTP.FrontendTest do
  # End-to-end tests for the HTTP frontend over a real TCP socket.
  use ExUnit.Case, async: false

  alias Bento.Tracker.HTTP.Frontend
  alias Bento.Tracker.Logic
  alias Bento.Tracker.Storage

  @peer_id "-TEST01-6wfG2wk6wWLc"
  @info_hash String.duplicate("a", 20)

  setup do
    {:ok, store} = Storage.new("memory", %{shard_count: 4})
    logic = Logic.new(%{announce_interval: 1800, min_announce_interval: 900}, store)

    config = %{
      addr: "127.0.0.1:0",
      announce_routes: ["/announce"],
      scrape_routes: ["/scrape"],
      enable_keepalive: false
    }

    {:ok, pid} = Frontend.start_link({logic, config})
    # Decouple the frontend's lifecycle from the test process so on_exit
    # controls shutdown regardless of async scheduling.
    Process.unlink(pid)
    {:ok, {ip, port}} = Frontend.listen_address(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{ip: ip, port: port}
  end

  defp http_get(port, target), do: http_request(port, "GET", target)

  defp http_request(port, method, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    request = "#{method} #{target} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, <<>>)
    :gen_tcp.close(socket)
    split_body(response)
  end

  defp status_line(port, method, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    request = "#{method} #{target} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, <<>>)
    :gen_tcp.close(socket)
    [line | _] = :binary.split(response, "\r\n")
    line
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, _reason} -> acc
    end
  end

  defp split_body(response) do
    [_headers, body] = :binary.split(response, "\r\n\r\n")
    body
  end

  test "announce returns a bencoded response with the announcing peer", %{port: port} do
    query =
      "info_hash=#{@info_hash}&peer_id=#{@peer_id}&port=6881&left=100&downloaded=0&uploaded=0&compact=1"

    body = http_get(port, "/announce?" <> query)

    assert {:ok, decoded} = Bento.decode(body)
    assert decoded["interval"] == 1800
    assert decoded["min interval"] == 900
    assert decoded["incomplete"] == 1
    # compact peers: the announcing peer, 127.0.0.1:6881 = 6 bytes
    assert <<127, 0, 0, 1, 0x1A, 0xE1>> = decoded["peers"]
  end

  test "a bad announce returns a failure reason", %{port: port} do
    body = http_get(port, "/announce?peer_id=#{@peer_id}&port=6881")
    assert {:ok, %{"failure reason" => "no info_hash parameter supplied"}} = Bento.decode(body)
  end

  test "scrape returns a files dictionary", %{port: port} do
    # Seed the swarm via an announce first.
    query =
      "info_hash=#{@info_hash}&peer_id=#{@peer_id}&port=6881&left=0&downloaded=0&uploaded=0&event=completed"

    _ = http_get(port, "/announce?" <> query)
    Process.sleep(50)

    body = http_get(port, "/scrape?info_hash=#{@info_hash}")
    assert {:ok, decoded} = Bento.decode(body)
    assert %{"files" => files} = decoded
    assert %{"complete" => 1, "incomplete" => 0} = files[@info_hash]
  end

  test "an unmatched route returns a plain-text 404", %{port: port} do
    assert status_line(port, "GET", "/nope") == "HTTP/1.1 404 Not Found"
    assert http_get(port, "/nope") == "404 page not found\n"
  end

  # A pre-hook that reports the request context it was given.
  defmodule CtxProbe do
    @behaviour Bento.Tracker.Middleware.Hook

    def handle_announce(test, ctx, _request, response) do
      send(test, {:ctx, ctx})
      {:ok, ctx, response}
    end

    def handle_scrape(test, ctx, _request, response) do
      send(test, {:ctx, ctx})
      {:ok, ctx, response}
    end
  end

  test "routes may be httprouter patterns whose params reach the hooks" do
    port =
      start_frontend(
        %{announce_routes: ["/:passkey/announce"], scrape_routes: ["/:passkey/scrape"]},
        [{CtxProbe, self()}]
      )

    body = http_get(port, "/abc123/announce?#{announce_query(@peer_id)}&compact=1")
    assert {:ok, %{"interval" => 1800}} = Bento.decode(body)
    assert_receive {:ctx, %{route_params: [{"passkey", "abc123"}]}}

    assert status_line(port, "GET", "/announce") == "HTTP/1.1 404 Not Found"
    assert status_line(port, "POST", "/abc123/announce") == "HTTP/1.1 405 Method Not Allowed"
  end

  # Starts a second frontend with its own config; returns its port.
  defp start_frontend(config, pre_hooks \\ []) do
    {:ok, store} = Storage.new("memory", %{shard_count: 4})
    logic = Logic.new(%{announce_interval: 1800, min_announce_interval: 900}, store, pre_hooks)

    base = %{addr: "127.0.0.1:0", announce_routes: ["/announce"], scrape_routes: ["/scrape"]}
    {:ok, pid} = Frontend.start_link({logic, Map.merge(base, config)})
    Process.unlink(pid)
    {:ok, {_ip, port}} = Frontend.listen_address(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    port
  end

  defp announce_query(peer_id) do
    "info_hash=#{@info_hash}&peer_id=#{peer_id}&port=6881&left=100&downloaded=0&uploaded=0"
  end

  test "keep-alive serves several requests over one connection" do
    port = start_frontend(%{enable_keepalive: true})
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)

    for i <- 1..2 do
      peer_id = "-TEST0#{i}-6wfG2wk6wWLc"
      request = "GET /announce?#{announce_query(peer_id)} HTTP/1.1\r\nHost: t\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      response = recv_response(socket)
      assert [_headers, body] = :binary.split(response, "\r\n\r\n")
      assert {:ok, decoded} = Bento.decode(body)
      assert decoded["interval"] == 1800
    end

    :gen_tcp.close(socket)
  end

  test "keep-alive serves two requests pipelined in one segment" do
    port = start_frontend(%{enable_keepalive: true})
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)

    # Both requests are written in a single send, so the second arrives
    # while the server is still parsing the first. The bytes past the first
    # request's blank line must be carried into the next read, not dropped.
    request = "GET /announce?#{announce_query(@peer_id)} HTTP/1.1\r\nHost: t\r\n\r\n"
    :ok = :gen_tcp.send(socket, request <> request)

    responses = recv_n_responses(socket, 2)
    assert length(responses) == 2

    for response <- responses do
      assert [_headers, body] = :binary.split(response, "\r\n\r\n")
      assert {:ok, decoded} = Bento.decode(body)
      assert decoded["interval"] == 1800
    end

    :gen_tcp.close(socket)
  end

  # Reads exactly n complete responses, framing each by its Content-Length
  # and carrying any leftover bytes (e.g. a coalesced second response).
  defp recv_n_responses(socket, n), do: recv_n_responses(socket, n, <<>>, [])
  defp recv_n_responses(_socket, 0, _buffer, acc), do: Enum.reverse(acc)

  defp recv_n_responses(socket, n, buffer, acc) do
    case parse_one_response(buffer) do
      {:ok, response, rest} ->
        recv_n_responses(socket, n - 1, rest, [response | acc])

      :incomplete ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        recv_n_responses(socket, n, buffer <> data, acc)
    end
  end

  defp parse_one_response(buffer) do
    with [headers, body] <- :binary.split(buffer, "\r\n\r\n"),
         [_full, len] <- Regex.run(~r/content-length: (\d+)/i, headers),
         len = String.to_integer(len),
         true <- byte_size(body) >= len do
      <<this_body::binary-size(len), rest::binary>> = body
      {:ok, headers <> "\r\n\r\n" <> this_body, rest}
    else
      _incomplete -> :incomplete
    end
  end

  test "the real ip header is honored by the live server" do
    port = start_frontend(%{real_ip_header: "x-real-ip"})
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)

    request =
      "GET /announce?#{announce_query(@peer_id)}&compact=1 HTTP/1.1\r\n" <>
        "Host: t\r\nX-Real-IP: 198.51.100.7\r\nConnection: close\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, <<>>)
    :gen_tcp.close(socket)

    assert {:ok, decoded} = Bento.decode(split_body(response))
    # The lone peer echoed back must carry the header-provided IP.
    assert <<198, 51, 100, 7, 0x1A, 0xE1>> = decoded["peers"]
  end

  # Reads one keep-alive response using its Content-Length.
  defp recv_response(socket), do: socket |> recv_n_responses(1) |> hd()

  test "a non-GET method on a known route returns 405", %{port: port} do
    assert status_line(port, "POST", "/announce") == "HTTP/1.1 405 Method Not Allowed"
  end

  test "a non-GET method on an unknown route returns 404", %{port: port} do
    assert status_line(port, "POST", "/nope") == "HTTP/1.1 404 Not Found"
  end
end
