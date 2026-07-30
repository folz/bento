defmodule Bento.Tracker.UDP.ConnectionIDTest do
  # Ported from chihaya's frontend/udp/connection_id_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.UDP.ConnectionID

  # {created_at, now, ip, key, valid?}
  @golden [
    {0, 1, {127, 0, 0, 1}, "", true},
    {0, 420_420, {127, 0, 0, 1}, "", false},
    {0, 0, {0, 0, 0, 0, 0, 0, 0, 0}, "", true}
  ]

  @minute 60

  # A second, independent implementation used to check the generator.
  defp simple_new_connection_id(ip, now_unix, key) do
    ts = <<now_unix::32-big>>
    mac = :crypto.mac(:hmac, :sha256, key, ts <> ip_bytes(ip))
    ts <> binary_part(mac, 0, 4)
  end

  defp ip_bytes({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_bytes({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  test "generation matches an independent HMAC implementation" do
    for {created_at, _now, ip, key, _valid} <- @golden do
      want = simple_new_connection_id(ip, created_at, key)
      got = ConnectionID.new(ip, created_at, key)
      assert got == want
      assert byte_size(got) == 8
    end
  end

  test "verification honors the TTL and clock skew" do
    for {created_at, now, ip, key, valid?} <- @golden do
      cid = ConnectionID.new(ip, created_at, key)
      assert ConnectionID.valid?(cid, ip, now, @minute, key) == valid?
    end
  end

  test "a connection ID for one IP does not validate for another" do
    cid = ConnectionID.new({1, 2, 3, 4}, 100, "key")
    assert ConnectionID.valid?(cid, {1, 2, 3, 4}, 100, @minute, "key")
    refute ConnectionID.valid?(cid, {5, 6, 7, 8}, 100, @minute, "key")
  end

  test "a connection ID from a different key does not validate" do
    cid = ConnectionID.new({1, 2, 3, 4}, 100, "key-a")
    refute ConnectionID.valid?(cid, {1, 2, 3, 4}, 100, @minute, "key-b")
  end

  test "generation is deterministic for the same inputs" do
    for {created_at, _now, ip, key, _valid} <- @golden do
      first = ConnectionID.new(ip, created_at, key)
      for _ <- 1..3, do: assert(ConnectionID.new(ip, created_at, key) == first)
    end
  end
end
