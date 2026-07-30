defmodule Bento.Tracker.RunnerTest do
  use ExUnit.Case, async: false

  alias Bento.Tracker.Runner
  alias Bento.Tracker.Storage

  test "starts and cleanly stops the configured components" do
    config = %{
      bento_tracker: %{
        announce_interval: "30m",
        min_announce_interval: "15m",
        http: %{addr: "127.0.0.1:0", announce_routes: ["/announce"], scrape_routes: ["/scrape"]},
        udp: %{addr: "127.0.0.1:0", private_key: "runner-test"},
        storage: %{name: "memory", config: %{shard_count: 8}},
        prehooks: [
          %{
            name: "interval variation",
            options: %{modify_response_probability: 1.0, max_increase_delta: 10}
          }
        ]
      }
    }

    {:ok, runner} = Runner.start_link(config)
    components = Runner.components(runner)

    assert is_pid(components.http)
    assert is_pid(components.udp)
    assert {_module, _state} = components.store

    # The store is usable through the running logic.
    assert %Bento.Tracker.Scrape{} =
             Storage.scrape_swarm(components.store, String.duplicate("z", 20), :ipv4)

    assert :ok = GenServer.stop(runner)
    refute Process.alive?(runner)
  end

  test "fails to start when a hook config is invalid" do
    config = %{
      bento_tracker: %{
        storage: %{name: "memory", config: %{}},
        prehooks: [%{name: "does not exist", options: %{}}]
      }
    }

    Process.flag(:trap_exit, true)
    assert {:error, {"does not exist", :driver_does_not_exist}} = Runner.start_link(config)
  end
end
