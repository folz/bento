defmodule Bento.Tracker.EventTest do
  # Ported from chihaya's bittorrent/event_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.Event

  @table [
    {"", :none, nil},
    {"NONE", :none, nil},
    {"none", :none, nil},
    {"started", :started, nil},
    {"stopped", :stopped, nil},
    {"completed", :completed, nil},
    {"notAnEvent", nil, :unknown_event}
  ]

  test "new/1 parses event strings" do
    for {data, expected, expected_err} <- @table do
      case expected_err do
        nil -> assert Event.new(data) == {:ok, expected}, "parsing #{inspect(data)}"
        err -> assert Event.new(data) == {:error, err}, "parsing #{inspect(data)}"
      end
    end
  end

  test "to_string/1 renders event names" do
    assert Event.to_string(:none) == "none"
    assert Event.to_string(:started) == "started"
    assert Event.to_string(:stopped) == "stopped"
    assert Event.to_string(:completed) == "completed"
  end
end
