defmodule Bento.Tracker.Middleware.VarIntervalTest do
  # Ported from chihaya's middleware/varinterval/varinterval_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.Middleware.VarInterval
  alias Bento.Tracker.Peer

  @config_tests [
    {%{modify_response_probability: 0.5, max_increase_delta: 60, modify_min_interval: true}, nil},
    {%{modify_response_probability: 1.0, max_increase_delta: 60, modify_min_interval: true}, nil},
    {%{modify_response_probability: 0.0, max_increase_delta: 60, modify_min_interval: true},
     :invalid_modify_response_probability},
    {%{modify_response_probability: 1.1, max_increase_delta: 60, modify_min_interval: true},
     :invalid_modify_response_probability},
    {%{modify_response_probability: 0.5, max_increase_delta: 0, modify_min_interval: true},
     :invalid_max_increase_delta},
    {%{modify_response_probability: 0.5, max_increase_delta: -10, modify_min_interval: true},
     :invalid_max_increase_delta}
  ]

  test "check_config validates the configuration" do
    for {config, expected} <- @config_tests do
      case expected do
        nil -> assert {:ok, _state} = VarInterval.new(config)
        error -> assert VarInterval.new(config) == {:error, error}
      end
    end
  end

  test "handle_announce increases the intervals" do
    assert {:ok, state} =
             VarInterval.new(%{
               modify_response_probability: 1.0,
               max_increase_delta: 10,
               modify_min_interval: true
             })

    request = %AnnounceRequest{
      info_hash: <<0::160>>,
      peer: %Peer{id: <<0::160>>, ip: {0, 0, 0, 0}, port: 0}
    }

    assert {:ok, %{}, response} =
             VarInterval.handle_announce(state, %{}, request, %AnnounceResponse{})

    assert response.interval > 0, "interval should have been increased"
    assert response.min_interval > 0, "min_interval should have been increased"
  end

  test "the interval modification is deterministic per request" do
    assert {:ok, state} =
             VarInterval.new(%{
               modify_response_probability: 1.0,
               max_increase_delta: 10,
               modify_min_interval: false
             })

    request = %AnnounceRequest{
      info_hash: String.duplicate("i", 20),
      peer: %Peer{id: String.duplicate("p", 20), ip: {1, 2, 3, 4}, port: 1}
    }

    {:ok, _ctx, response_a} =
      VarInterval.handle_announce(state, %{}, request, %AnnounceResponse{})

    {:ok, _ctx, response_b} =
      VarInterval.handle_announce(state, %{}, request, %AnnounceResponse{})

    assert response_a.interval == response_b.interval
    assert response_a.interval in 1..10
    assert response_a.min_interval == 0
  end

  test "scrapes are not altered" do
    assert {:ok, state} =
             VarInterval.new(%{modify_response_probability: 1.0, max_increase_delta: 10})

    response = %Bento.Tracker.ScrapeResponse{}

    assert {:ok, %{}, ^response} =
             VarInterval.handle_scrape(state, %{}, %Bento.Tracker.ScrapeRequest{}, response)
  end
end
