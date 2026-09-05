defmodule Bento.Tracker.Metrics.ServerTest do
  use ExUnit.Case, async: false

  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Metrics.Server

  setup do
    case Metrics.start_link() do
      {:ok, registry} -> Process.unlink(registry)
      {:error, {:already_started, _registry}} -> :ok
    end

    {:ok, pid} = Server.start_link("127.0.0.1:0")
    Process.unlink(pid)
    {:ok, {_ip, port}} = Server.listen_address(pid)

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    %{port: port}
  end

  test "/metrics renders the registry, ignoring the query string", %{port: port} do
    Metrics.set_gauge("chihaya_storage_seeders_count", %{"probe" => "server"}, 3)

    {status, headers, body} = request(port, "GET", "/metrics?scrape=1")
    assert status == "HTTP/1.1 200 OK"
    assert headers =~ "Content-Type: text/plain; version=0.0.4; charset=utf-8"
    assert body =~ ~s(chihaya_storage_seeders_count{probe="server"} 3\n)
  end

  test "any method is answered and other paths are a plain-text 404", %{port: port} do
    assert {"HTTP/1.1 200 OK", _headers, _body} = request(port, "POST", "/metrics")

    assert {"HTTP/1.1 404 Not Found", _headers, "404 page not found\n"} =
             request(port, "GET", "/")
  end

  defp request(port, method, target) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    :ok = :gen_tcp.send(socket, "#{method} #{target} HTTP/1.1\r\nHost: t\r\n\r\n")
    response = recv_all(socket, <<>>)
    :gen_tcp.close(socket)

    [head, body] = :binary.split(response, "\r\n\r\n")
    [status | _headers] = :binary.split(head, "\r\n")
    {status, head, body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, _reason} -> acc
    end
  end
end
