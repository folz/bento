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
  Returns the `:inet` family option (`:inet` / `:inet6`) for listening on
  the given IP tuple. An IPv6 listen address needs `:inet6` or the bind
  fails with `:eafnosupport`.
  """
  @spec inet_family(t()) :: :inet | :inet6
  def inet_family(ip) when tuple_size(ip) == 8, do: :inet6
  def inet_family(_ip), do: :inet

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

  @doc """
  Normalizes an IP tuple to its canonical form: an IPv4-mapped IPv6
  address becomes its IPv4 4-tuple, and any other address is returned
  unchanged. This is the total companion to `to4/1`, which returns `nil`
  for a genuine IPv6 address.
  """
  @spec normalize(t()) :: t()
  def normalize(ip), do: to4(ip) || ip

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

  @doc """
  Parses a listen address of the form `"host:port"` into an IP tuple and
  port. The host may be empty or `"*"` (both mean all interfaces) or a
  bracketed IPv6 address such as `"[::1]"`.
  """
  @spec parse_addr(String.t()) ::
          {:ok, t(), :inet.port_number()} | {:error, {:invalid_addr, String.t()}}
  def parse_addr(addr) do
    parts = String.split(addr, ":")
    port_str = List.last(parts)
    host = parts |> Enum.drop(-1) |> Enum.join(":")

    with {port, ""} <- Integer.parse(port_str),
         {:ok, ip} <- parse_host(host) do
      {:ok, ip, port}
    else
      _error -> {:error, {:invalid_addr, addr}}
    end
  end

  defp parse_host(host) when host in ["", "*"], do: {:ok, {0, 0, 0, 0}}

  defp parse_host(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
  end
end
