defmodule Bento.Tracker.Peer do
  @moduledoc """
  The connection details of a peer returned in an announce response.
  """

  alias Bento.Tracker.IP
  alias Bento.Tracker.PeerID

  @enforce_keys [:id, :ip, :port]
  defstruct [:id, :ip, :port]

  @type t :: %__MODULE__{
          id: PeerID.t(),
          ip: IP.t(),
          port: 0..65_535
        }

  @doc """
  Returns a human-readable representation of the peer, in the format
  `<PeerID>@[<IP>]:<port>`, for example
  `"0102030405060708090a0b0c0d0e0f1011121314@[10.11.12.13]:1234"`.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = peer) do
    "#{PeerID.to_string(peer.id)}@[#{IP.to_string(peer.ip)}]:#{peer.port}"
  end

  @doc "Returns the address family of the peer's IP."
  @spec address_family(t()) :: IP.address_family()
  def address_family(%__MODULE__{ip: ip}), do: IP.address_family(ip)

  @doc "Reports whether two peers are the same."
  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{} = p, %__MODULE__{} = x) do
    equal_endpoint?(p, x) and p.id == x.id
  end

  @doc "Reports whether two peers have the same endpoint."
  @spec equal_endpoint?(t(), t()) :: boolean()
  def equal_endpoint?(%__MODULE__{} = p, %__MODULE__{} = x) do
    p.port == x.port and ip_equal?(p.ip, x.ip)
  end

  defp ip_equal?(ip, ip), do: true
  defp ip_equal?(a, b), do: IP.to4(a) != nil and IP.to4(a) == IP.to4(b)

  @doc """
  Serializes the peer into the storage key format shared by all peer
  stores: the 20-byte ID, the big-endian port, and the 4- or 16-byte IP.
  For the Redis store this format is persistent data, so it must never
  change incompatibly.
  """
  @spec to_key(t()) :: binary()
  def to_key(%__MODULE__{} = peer) do
    <<peer.id::binary-size(20), peer.port::16-big, IP.to_binary(peer.ip)::binary>>
  end

  @doc "Decodes a peer from its `to_key/1` serialization."
  @spec from_key(binary()) :: t()
  def from_key(<<id::binary-size(20), port::16-big, ip_binary::binary>>) do
    {:ok, ip} = IP.from_binary(ip_binary)
    %__MODULE__{id: id, ip: IP.to4(ip) || ip, port: port}
  end
end
