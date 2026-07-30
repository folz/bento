defmodule Bento.Tracker.TimeCache do
  @moduledoc """
  Access to the current system time.

  chihaya's `pkg/timecache` caches `time.Now()` in an atomically-updated
  global to avoid syscall overhead. On the BEAM, `System.system_time/1`
  compiles to a fast BIF backed by the VM's own time infrastructure, so no
  caching process is needed; this module is a thin facade kept for parity
  with the original architecture.
  """

  @doc "Returns the current time."
  @spec now() :: DateTime.t()
  def now, do: DateTime.from_unix!(now_unix_nano(), :nanosecond)

  @doc "Returns the current time as nanoseconds since the Unix epoch."
  @spec now_unix_nano() :: integer()
  def now_unix_nano, do: System.system_time(:nanosecond)

  @doc "Returns the current time as seconds since the Unix epoch."
  @spec now_unix() :: integer()
  def now_unix, do: System.system_time(:second)
end
