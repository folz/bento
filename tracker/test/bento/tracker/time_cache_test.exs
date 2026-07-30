defmodule Bento.Tracker.TimeCacheTest do
  # Ported from chihaya's pkg/timecache/timecache_test.go. The Go package
  # runs a goroutine to cache time.Now(); on the BEAM the system time BIFs
  # are already cheap, so the module is a thin facade and the Run/Stop
  # lifecycle tests do not apply.
  use ExUnit.Case, async: true

  alias Bento.Tracker.TimeCache

  test "now/0, now_unix/0 and now_unix_nano/0 return non-zero times" do
    assert %DateTime{} = TimeCache.now()

    nsec = TimeCache.now_unix_nano()
    assert is_integer(nsec) and nsec != 0

    sec = TimeCache.now_unix()
    assert is_integer(sec) and sec != 0

    assert_in_delta nsec, sec * 1_000_000_000, 2_000_000_000
  end
end
