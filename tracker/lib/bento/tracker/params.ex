defmodule Bento.Tracker.Params do
  @moduledoc """
  Optional request parameters from an announce or scrape.

  For HTTP requests this includes the request path and parsed query; for
  UDP requests this is the extracted path and parsed query from optional
  URLData as specified in BEP 41.

  See `parse_url_data/1` for specifics on parsing and limitations.
  """

  import Bitwise

  alias Bento.Tracker.ClientError

  defstruct path: "", query: "", params: %{}, info_hashes: []

  @type t :: %__MODULE__{
          path: String.t(),
          query: String.t(),
          params: %{optional(String.t()) => String.t()},
          info_hashes: [Bento.Tracker.InfoHash.t()]
        }

  @err_invalid_infohash ClientError.new("provided invalid infohash")
  @err_invalid_query_escape ClientError.new("invalid query escape")

  @doc """
  Parses a request URL or UDP URLData as defined in BEP 41.

  It expects a concatenated string of the request's path and query parts
  as defined in RFC 3986. As both the udp: and http: schemes used by
  BitTorrent include an authority part, the path part must always begin
  with a slash. An example of the expected URLData would be
  `"/announce?port=1234&uploaded=0"` or `"/?auth=0x1337"`.

  HTTP frontends should pass the unmodified request target; UDP frontends
  should pass the concatenated, unchanged URLData as defined in BEP 41.

  In the case of a key occurring multiple times in the query, only the
  last value for that key is kept. The only exception is the key
  `info_hash`, whose values must each be a 20-byte infohash; they are all
  collected in order and can be retrieved with `info_hashes/1`.

  Any error encountered during parsing is returned as a
  `Bento.Tracker.ClientError`, as this function parses client-provided
  data.
  """
  @spec parse_url_data(String.t()) :: {:ok, t()} | {:error, ClientError.t()}
  def parse_url_data(url_data) when is_binary(url_data) do
    {path, query} =
      case :binary.match(url_data, "?") do
        {i, 1} ->
          {binary_part(url_data, 0, i), binary_part(url_data, i + 1, byte_size(url_data) - i - 1)}

        :nomatch ->
          {url_data, ""}
      end

    with {:ok, params} <- parse_query(query) do
      {:ok, %{params | path: path}}
    end
  end

  @doc """
  Parses a URL query into `Params`. The query is expected to exclude the
  delimiting `?`.
  """
  @spec parse_query(String.t()) :: {:ok, t()} | {:error, ClientError.t()}
  def parse_query(query) when is_binary(query) do
    query
    |> :binary.split(["&", ";"], [:global])
    |> parse_segments(%{}, [])
    |> case do
      {:ok, params, info_hashes} ->
        {:ok, %__MODULE__{query: query, params: params, info_hashes: info_hashes}}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_segments([], params, info_hashes), do: {:ok, params, Enum.reverse(info_hashes)}

  defp parse_segments(["" | rest], params, info_hashes) do
    parse_segments(rest, params, info_hashes)
  end

  defp parse_segments([segment | rest], params, info_hashes) do
    {key, value} =
      case :binary.split(segment, "=") do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end

    with {:ok, key} <- query_unescape(key),
         {:ok, value} <- query_unescape(value) do
      if key == "info_hash" do
        if byte_size(value) == 20 do
          parse_segments(rest, params, [value | info_hashes])
        else
          {:error, @err_invalid_infohash}
        end
      else
        parse_segments(rest, Map.put(params, String.downcase(key), value), info_hashes)
      end
    else
      :error -> {:error, @err_invalid_query_escape}
    end
  end

  # The equivalent of Go's url.QueryUnescape: percent-escapes are decoded,
  # "+" becomes a space, and a "%" not followed by two hex digits is an
  # error.
  defp query_unescape(str), do: unescape(str, <<>>)

  defp unescape(<<>>, acc), do: {:ok, acc}

  defp unescape(<<?+, rest::binary>>, acc), do: unescape(rest, <<acc::binary, ?\s>>)

  defp unescape(<<?%, hi, lo, rest::binary>>, acc)
       when hi in ?0..?9 or hi in ?a..?f or hi in ?A..?F do
    case {hex_value(hi), hex_value(lo)} do
      {_, nil} -> :error
      {h, l} -> unescape(rest, <<acc::binary, h * 16 + l>>)
    end
  end

  defp unescape(<<?%, _rest::binary>>, _acc), do: :error

  defp unescape(<<char, rest::binary>>, acc), do: unescape(rest, <<acc::binary, char>>)

  defp hex_value(c) when c in ?0..?9, do: c - ?0
  defp hex_value(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_value(c) when c in ?A..?F, do: c - ?A + 10
  defp hex_value(_c), do: nil

  @doc """
  Returns the string value for a key in the parsed query.

  Every key can be returned as a string because they are encoded in the
  URL as strings.
  """
  @spec string(t(), String.t()) :: {:ok, String.t()} | :error
  def string(%__MODULE__{params: params}, key), do: Map.fetch(params, key)

  @doc """
  Returns an unsigned integer parsed from the value for a key, bounded to
  `bit_size` bits.
  """
  @spec uint(t(), String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :key_not_found | :invalid_uint}
  def uint(%__MODULE__{params: params}, key, bit_size \\ 64) do
    case Map.fetch(params, key) do
      :error -> {:error, :key_not_found}
      {:ok, str} -> parse_uint(str, bit_size)
    end
  end

  defp parse_uint(str, bit_size) do
    if str != "" and digits_only?(str) do
      value = String.to_integer(str)

      if value < 1 <<< bit_size do
        {:ok, value}
      else
        {:error, :invalid_uint}
      end
    else
      {:error, :invalid_uint}
    end
  end

  defp digits_only?(str), do: str |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  @doc "Returns the list of requested infohashes, in request order."
  @spec info_hashes(t()) :: [Bento.Tracker.InfoHash.t()]
  def info_hashes(%__MODULE__{info_hashes: info_hashes}), do: info_hashes

  @doc """
  Returns the raw path from the parsed URL. The path returned can contain
  URL encoded data. For `"/announce?port=1234"` this returns
  `"/announce"`.
  """
  @spec raw_path(t()) :: String.t()
  def raw_path(%__MODULE__{path: path}), do: path

  @doc """
  Returns the raw query from the parsed URL, excluding the delimiter `?`.
  For `"/announce?port=1234"` this returns `"port=1234"`.
  """
  @spec raw_query(t()) :: String.t()
  def raw_query(%__MODULE__{query: query}), do: query
end
