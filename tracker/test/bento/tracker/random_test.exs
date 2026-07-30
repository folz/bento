defmodule Bento.Tracker.RandomTest do
  # Ported from chihaya's middleware/pkg/random/xorshift_test.go
  use ExUnit.Case, async: true

  import Bitwise

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.Peer
  alias Bento.Tracker.Random

  test "intn/3 generates k where 0 <= k < n" do
    s0 = :rand.uniform(1 <<< 64) - 1
    s1 = :rand.uniform(1 <<< 64) - 1

    Enum.reduce(1..10_000, {s0, s1}, fn _i, {s0, s1} ->
      {k, s0, s1} = Random.intn(s0, s1, 10)
      assert k >= 0, "intn() must be >= 0"
      assert k < 10, "intn(k) must be < k"
      {s0, s1}
    end)
  end

  test "generate_and_advance/2 matches XORShift128Plus" do
    # XORShift128Plus(1, 2):
    #   v      = 1 + 2                                   = 3
    #   newS0  = 2
    #   s0'    = 1 xor (1 <<< 23)                        = 0x800001
    #   newS1  = s0' xor 2 xor (s0' >>> 18) xor (2 >>> 5)
    #          = 0x800001 xor 0x2 xor 0x20 xor 0x0       = 0x800023
    assert Random.generate_and_advance(1, 2) == {3, 2, 0x800023}
  end

  test "generate_and_advance/2 wraps sums at 64 bits" do
    max = (1 <<< 64) - 1
    {v, s0, _s1} = Random.generate_and_advance(max, 2)
    assert v == 1
    assert s0 == 2
  end

  test "derive_entropy_from_request/1 is deterministic" do
    info_hash = <<1::64-big, 2::64-big, 0::32>>
    peer_id = <<3::64-big, 4::64-big, 0::32>>

    request = %AnnounceRequest{
      info_hash: info_hash,
      peer: %Peer{id: peer_id, ip: {10, 0, 0, 1}, port: 6881}
    }

    assert Random.derive_entropy_from_request(request) == {3, 7}

    assert Random.derive_entropy_from_request(request) ==
             Random.derive_entropy_from_request(request)
  end
end
