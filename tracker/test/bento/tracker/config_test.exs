defmodule Bento.Tracker.ConfigTest do
  use ExUnit.Case, async: true

  alias Bento.Tracker.Config

  test "normalizes intervals to seconds and other durations to milliseconds" do
    {:ok, config} =
      Config.load(%{
        bento_tracker: %{
          announce_interval: "30m",
          min_announce_interval: "15m",
          metrics_addr: "0.0.0.0:6880",
          http: %{
            addr: "0.0.0.0:6969",
            read_timeout: "5s",
            announce_routes: ["/announce"],
            scrape_routes: ["/scrape"]
          },
          udp: %{addr: "0.0.0.0:6969", max_clock_skew: "10s"},
          storage: %{name: "memory", config: %{gc_interval: "3m", peer_lifetime: "31m"}}
        }
      })

    assert config.response_config.announce_interval == 1800
    assert config.response_config.min_announce_interval == 900
    assert config.http.read_timeout == 5000
    assert config.udp.max_clock_skew == 10_000
    assert config.storage.config.gc_interval == 180_000
    assert config.storage.config.peer_lifetime == 1_860_000
  end

  test "accepts integer durations unchanged" do
    {:ok, config} =
      Config.load(%{
        announce_interval: 1800,
        http: %{
          addr: "0.0.0.0:6969",
          read_timeout: 2000,
          announce_routes: ["/a"],
          scrape_routes: ["/s"]
        }
      })

    assert config.response_config.announce_interval == 1800
    assert config.http.read_timeout == 2000
  end

  test "omits frontends without an address" do
    {:ok, config} = Config.load(%{storage: %{name: "memory", config: %{}}})
    assert config.http == nil
    assert config.udp == nil
  end

  test "defaults storage to memory" do
    {:ok, config} = Config.load(%{})
    assert config.storage == %{name: "memory", config: %{}}
    assert config.prehooks == []
    assert config.posthooks == []
  end

  test "parses compound durations" do
    {:ok, config} =
      Config.load(%{udp: %{addr: "x:1", max_clock_skew: "1h30m"}})

    assert config.udp.max_clock_skew == 5_400_000
  end

  test "loads a config from an .exs file" do
    path =
      Path.join(System.tmp_dir!(), "bento_tracker_test_#{System.unique_integer([:positive])}.exs")

    File.write!(path, """
    %{bento_tracker: %{announce_interval: "10m", storage: %{name: "memory", config: %{}}}}
    """)

    try do
      assert {:ok, config} = Config.load(path)
      assert config.response_config.announce_interval == 600
    after
      File.rm(path)
    end
  end
end
