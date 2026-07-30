defmodule Bento.Tracker.Event do
  @moduledoc """
  An event reported by a BitTorrent client in an announce.

    * `:none` - the client announced due to time lapsed since the previous
      announce.
    * `:started` - the client joined the swarm.
    * `:stopped` - the client left the swarm.
    * `:completed` - the client finished downloading all required chunks.
  """

  @type t :: :none | :started | :stopped | :completed

  @events %{
    "" => :none,
    "none" => :none,
    "started" => :started,
    "stopped" => :stopped,
    "completed" => :completed
  }

  @doc """
  Returns the event for the given string, case-insensitively.

  The empty string maps to `:none`. Unrecognized strings return
  `{:error, :unknown_event}`.
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, :unknown_event}
  def new(event_str) when is_binary(event_str) do
    case Map.fetch(@events, String.downcase(event_str)) do
      {:ok, event} -> {:ok, event}
      :error -> {:error, :unknown_event}
    end
  end

  @doc "Returns the canonical string name of an event."
  @spec to_string(t()) :: String.t()
  def to_string(:none), do: "none"
  def to_string(:started), do: "started"
  def to_string(:stopped), do: "stopped"
  def to_string(:completed), do: "completed"
end
