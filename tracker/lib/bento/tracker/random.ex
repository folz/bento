defmodule Bento.Tracker.Random do
  @moduledoc """
  The XORShift128Plus PRNG and a way to derive random state from an
  `Bento.Tracker.AnnounceRequest`.

  All arithmetic wraps at 64 bits, mirroring the Go implementation's
  `uint64` semantics.
  """

  import Bitwise

  alias Bento.Tracker.AnnounceRequest

  @mask64 (1 <<< 64) - 1

  @typedoc "One half of the 128-bit generator state."
  @type state :: 0..unquote(@mask64)

  @doc """
  Applies XORShift128Plus on `s0` and `s1`, returning
  `{v, new_s0, new_s1}` where `v` is a pseudo-random number and the other
  two elements are the new generator state.
  """
  @spec generate_and_advance(state(), state()) :: {state(), state(), state()}
  def generate_and_advance(s0, s1) do
    v = s0 + s1 &&& @mask64
    new_s0 = s1
    s0 = bxor(s0, s0 <<< 23 &&& @mask64)
    new_s1 = s0 |> bxor(s1) |> bxor(s0 >>> 18) |> bxor(s1 >>> 5)
    {v, new_s0, new_s1}
  end

  @doc """
  Generates an integer `k` that satisfies `k >= 0 and k < n`; `n` must be
  greater than 0. Returns `{k, new_s0, new_s1}`.
  """
  @spec intn(state(), state(), pos_integer()) :: {non_neg_integer(), state(), state()}
  def intn(s0, s1, n) when is_integer(n) and n > 0 do
    {v, new_s0, new_s1} = generate_and_advance(s0, s1)
    # Reinterpret v as a signed 64-bit integer and take its magnitude,
    # like the Go implementation's int(v) conversion.
    k = if v >= 1 <<< 63, do: (1 <<< 64) - v, else: v
    {rem(k, n), new_s0, new_s1}
  end

  @doc """
  Generates 2x64 bits of pseudo-random state from an announce request.

  Calling this function multiple times with the same request yields the
  same values.
  """
  @spec derive_entropy_from_request(AnnounceRequest.t()) :: {state(), state()}
  def derive_entropy_from_request(%AnnounceRequest{} = request) do
    <<ih0::64-big, ih1::64-big, _::binary>> = request.info_hash
    <<id0::64-big, id1::64-big, _::binary>> = request.peer.id
    {ih0 + ih1 &&& @mask64, id0 + id1 &&& @mask64}
  end
end
