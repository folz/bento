defmodule Bento.Tracker.E2ETest do
  # The end-to-end suite ported from chihaya's cmd/chihaya e2e command,
  # driven in-process against a full Runner-managed tracker.
  use ExUnit.Case, async: false

  alias Bento.Tracker.E2E
  alias Bento.Tracker.Runner

  setup do
    :inets.start()

    config = %{
      bento_tracker: %{
        announce_interval: "30m",
        min_announce_interval: "15m",
        metrics_addr: "",
        http: %{
          addr: "127.0.0.1:0",
          announce_routes: ["/announce"],
          scrape_routes: ["/scrape"]
        },
        udp: %{addr: "127.0.0.1:0", private_key: "e2e-test-key"},
        storage: %{name: "memory", config: %{shard_count: 16}}
      }
    }

    {:ok, runner} = Runner.start_link(config)
    Process.unlink(runner)
    components = Runner.components(runner)

    {:ok, {_ip, http_port}} = Bento.Tracker.HTTP.Frontend.listen_address(components.http)
    {:ok, {_ip, udp_port}} = Bento.Tracker.UDP.Frontend.listen_address(components.udp)

    on_exit(fn ->
      if Process.alive?(runner) do
        try do
          GenServer.stop(runner)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{http_port: http_port, udp_port: udp_port}
  end

  test "HTTP announces exchange peers", %{http_port: port} do
    assert E2E.run(http_addr: "http://127.0.0.1:#{port}/announce", udp_addr: "", delay: 100) ==
             :ok
  end

  test "UDP announces exchange peers", %{udp_port: port} do
    assert E2E.run(http_addr: "", udp_addr: "udp://127.0.0.1:#{port}", delay: 100) == :ok
  end

  test "the full HTTP and UDP suite passes", %{http_port: http_port, udp_port: udp_port} do
    assert E2E.run(
             http_addr: "http://127.0.0.1:#{http_port}/announce",
             udp_addr: "udp://127.0.0.1:#{udp_port}",
             delay: 100
           ) == :ok
  end
end
