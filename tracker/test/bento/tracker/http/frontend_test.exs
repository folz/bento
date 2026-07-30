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

  test "a non-GET method on a known route returns 405", %{port: port} do
    assert status_line(port, "POST", "/announce") == "HTTP/1.1 405 Method Not Allowed"
  end

  test "a non-GET method on an unknown route returns 404", %{port: port} do
    assert status_line(port, "POST", "/nope") == "HTTP/1.1 404 Not Found"
  end
end
