defmodule Bento.Tracker.UDP.ConnectionID do
  @moduledoc """
  Generation and validation of the 8-byte UDP connection IDs described in
  BEP 15.

  The first 4 bytes are a Unix timestamp (seconds, big-endian); the last
  4 bytes are a truncated HMAC-SHA256 over that timestamp and the source
  IP, keyed with the tracker's private key.

  Truncated HMAC is known to be safe for `2^(-n)` where `n` is the size
  in bits of the truncated token. Here `n = 32`, so the forgery
  probability is approximately 1 in 4 billion.

  Unlike chihaya's pooled `ConnectionIDGenerator`, these functions are
  stateless: `:crypto.mac/4` needs no reusable context on the BEAM.
  """

  alias Bento.Tracker.IP

  # The duration a connection ID is valid, in seconds (BEP 15).
  @ttl 2 * 60

  @doc """
  Creates an 8-byte connection ID for the given IP tuple and time
  (Unix seconds).
  """
  @spec new(:inet.ip_address(), integer(), binary()) :: binary()
  def new(ip, now_unix, key) do
    ts = <<now_unix::32-big>>
    mac = :crypto.mac(:hmac, :sha256, key, ts <> IP.to_binary(ip))
    ts <> binary_part(mac, 0, 4)
  end

  @doc """
  Determines whether a connection ID is legitimate for the given IP and
  time (Unix seconds), allowing up to `max_clock_skew` seconds of
  future skew.
  """
  @spec valid?(binary(), :inet.ip_address(), integer(), integer(), binary()) :: boolean()
  def valid?(
        <<ts_bytes::binary-size(4), token::binary-size(4)>>,
        ip,
        now_unix,
        max_clock_skew,
        key
      ) do
    <<ts::32-big>> = ts_bytes

    cond do
      now_unix > ts + @ttl -> false
      ts > now_unix + max_clock_skew -> false
      true -> constant_time_equal?(expected_token(ts_bytes, ip, key), token)
    end
  end

  def valid?(_connection_id, _ip, _now_unix, _max_clock_skew, _key), do: false

  defp expected_token(ts_bytes, ip, key) do
    mac = :crypto.mac(:hmac, :sha256, key, ts_bytes <> IP.to_binary(ip))
    binary_part(mac, 0, 4)
  end

  # Constant-time comparison to avoid leaking token bytes via timing.
  defp constant_time_equal?(a, b) when byte_size(a) == byte_size(b) do
    :crypto.exor(a, b) == <<0::size(byte_size(a) * 8)>>
  end

  defp constant_time_equal?(_a, _b), do: false
end
