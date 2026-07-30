defmodule Bento.Tracker.InfoHash do
  @moduledoc """
  A 20-byte BitTorrent infohash.

  Infohashes are represented as raw 20-byte binaries. This module provides
  validation and formatting helpers around them.
  """

  @type t :: <<_::160>>

  @doc "Returns `true` if `term` is a valid 20-byte infohash."
  defguard is_info_hash(term) when is_binary(term) and byte_size(term) == 20

  @doc """
  Validates that the given binary is a 20-byte infohash.

  Raises `ArgumentError` if it is not.
  """
  @spec from_binary!(binary()) :: t()
  def from_binary!(bin) when is_info_hash(bin), do: bin

  def from_binary!(bin) when is_binary(bin) do
    raise ArgumentError, "infohash must be 20 bytes"
  end

  @doc "Returns the base16-encoded (lowercase) representation of the infohash."
  @spec to_string(t()) :: String.t()
  def to_string(info_hash) when is_info_hash(info_hash) do
    Base.encode16(info_hash, case: :lower)
  end
end
