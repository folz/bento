defmodule Bento.Tracker.IP do
  @moduledoc """
  Helpers for working with IP addresses as `:inet` tuples.

  An IPv4 address is a 4-tuple and an IPv6 address is an 8-tuple, so the
  address family is carried by the representation itself.
  """

  import Bitwise

  @type t :: :inet.ip_address()
  @type address_family :: :ipv4 | :ipv6

  @doc "Returns the address family of an IP tuple."
  @spec address_family(t()) :: address_family()
  def address_family(ip) when tuple_size(ip) == 4, do: :ipv4
  def address_family(ip) when tuple_size(ip) == 8, do: :ipv6

  @doc """
  Converts an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) to its IPv4
  4-tuple, like Go's `net.IP.To4`.

  Returns the address unchanged if it is already IPv4, and `nil` for any
  other IPv6 address.
  """
  @spec to4(t()) :: :inet.ip4_address() | nil
  def to4({_, _, _, _} = ip), do: ip

  def to4({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    {ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF}
  end

  def to4(_ip), do: nil

  @doc "Renders an IP tuple as a string (compressed lowercase form for IPv6)."
  @spec to_string(t()) :: String.t()
  def to_string(ip) when tuple_size(ip) == 4 or tuple_size(ip) == 8 do
    ip |> :inet.ntoa() |> List.to_string()
  end

  @doc """
  Encodes an IP tuple to its network byte order binary representation:
  4 bytes for IPv4, 16 bytes for IPv6.
  """
  @spec to_binary(t()) :: binary()
  def to_binary({a, b, c, d}), do: <<a, b, c, d>>

  def to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  @doc """
  Decodes a network byte order binary (4 or 16 bytes) into an IP tuple.
  """
  @spec from_binary(binary()) :: {:ok, t()} | :error
  def from_binary(<<a, b, c, d>>), do: {:ok, {a, b, c, d}}

  def from_binary(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {:ok, {a, b, c, d, e, f, g, h}}
  end

  def from_binary(_bin), do: :error
end
