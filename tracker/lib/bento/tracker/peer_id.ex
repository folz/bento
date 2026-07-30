defmodule Bento.Tracker.PeerID do
  @moduledoc """
  A 20-byte BitTorrent peer ID.

  Peer IDs are represented as raw 20-byte binaries. This module provides
  validation and formatting helpers around them.
  """

  @type t :: <<_::160>>

  @doc "Returns `true` if `term` is a valid 20-byte peer ID."
  defguard is_peer_id(term) when is_binary(term) and byte_size(term) == 20

  @doc """
  Validates that the given binary is a 20-byte peer ID.

  Raises `ArgumentError` if it is not.
  """
  @spec from_binary!(binary()) :: t()
  def from_binary!(bin) when is_peer_id(bin), do: bin

  def from_binary!(bin) when is_binary(bin) do
    raise ArgumentError, "peer ID must be 20 bytes"
  end

  @doc "Returns the base16-encoded (lowercase) representation of the peer ID."
  @spec to_string(t()) :: String.t()
  def to_string(peer_id) when is_peer_id(peer_id) do
    Base.encode16(peer_id, case: :lower)
  end
end
