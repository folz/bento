defmodule Bento.Tracker.Metrics.ServerTest do
  use ExUnit.Case, async: false

  alias Bento.Tracker.HTTPClient
  alias Bento.Tracker.Metrics
  alias Bento.Tracker.Metrics.Server

  setup do
    :ok = Metrics.ensure_started()
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

    {status, head, body} = HTTPClient.request(port, "GET", "/metrics?scrape=1")
    assert status == "HTTP/1.1 200 OK"
    assert head =~ "Content-Type: text/plain; version=0.0.4; charset=utf-8"
    assert body =~ ~s(chihaya_storage_seeders_count{probe="server"} 3\n)
  end

  test "any method is answered and other paths are a plain-text 404", %{port: port} do
    assert {"HTTP/1.1 200 OK", _head, _body} = HTTPClient.request(port, "POST", "/metrics")

    assert {"HTTP/1.1 404 Not Found", _head, "404 page not found\n"} =
             HTTPClient.request(port, "GET", "/")
  end
end
