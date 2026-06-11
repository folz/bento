defmodule Bento do
  @moduledoc """
  An incredibly fast, correct, pure-Elixir Bencoding library.

  This module contains high-level methods to encode and decode Bencoded data.
  """

  alias Bento.{Encoder, Decoder, Magnet, Metainfo}

  @doc """
  Bencode a value.

      iex> Bento.encode([1, "two", [3]])
      {:ok, "li1e3:twoli3eee"}

  Dictionary keys are always emitted in the canonical byte-wise sorted
  order required by BEP-3, regardless of whether they are given as
  strings or atoms:

      iex> Bento.encode(%{"b" => 1, a: 2})
      {:ok, "d1:ai2e1:bi1ee"}
  """
  @spec encode(Encoder.bencodable(), Keyword.t()) :: success | failure
        when success: {:ok, String.t() | iodata()},
             failure: {:error, Encoder.encode_err()}
  def encode(value, options \\ []) do
    {:ok, encode!(value, options)}
  rescue
    exception in [Bento.EncodeError] ->
      {:error, exception}
  end

  @doc """
  Bencode a value, raising an exception on error.

      iex> Bento.encode!([1, "two", [3]])
      "li1e3:twoli3eee"
  """
  @spec encode!(Encoder.bencodable(), Keyword.t()) :: success | no_return()
        when success: String.t() | iodata()
  def encode!(value, options \\ []) do
    if Keyword.get(options, :iodata, false) do
      Bento.Encode.value(value)
    else
      value |> Bento.Encode.value() |> IO.iodata_to_binary()
    end
  end

  @doc """
  Bencode a value as iodata.

  Prefer this over `encode/2` when the result is written to a socket or
  a file: the runtime can write the list of binaries directly, without
  allocating a contiguous buffer for the whole result first.

      iex> {:ok, iodata} = Bento.encode_to_iodata([1, "two", [3]])
      iex> IO.iodata_to_binary(iodata)
      "li1e3:twoli3eee"
  """
  @spec encode_to_iodata(Encoder.bencodable(), Keyword.t()) :: success | failure
        when success: {:ok, iodata()},
             failure: {:error, Encoder.encode_err()}
  def encode_to_iodata(value, options \\ []) do
    encode(value, Keyword.merge(options, iodata: true))
  end

  @doc """
  Bencode a value as iodata, raises an exception on error.

      iex> iodata = Bento.encode_to_iodata!([1, "two", [3]])
      iex> IO.iodata_to_binary(iodata)
      "li1e3:twoli3eee"
  """
  @spec encode_to_iodata!(Encoder.bencodable(), Keyword.t()) :: iodata() | no_return()
  def encode_to_iodata!(value, options \\ []) do
    encode!(value, Keyword.merge(options, iodata: true))
  end

  @doc """
  Decode bencoded data to a value.

      iex> Bento.decode("li1e3:twoli3eee")
      {:ok, [1, "two", [3]]}

  Errors carry the byte position of the offending input:

      iex> {:error, error} = Bento.decode("i4x2e")
      iex> {error.position, Exception.message(error)}
      {2, ~S|unexpected byte at position 2: 0x78 ("x")|}

  ## Options

    * `:as` - transform the parsed value into a struct, see
      `Bento.Decoder.transform/2`:

          defmodule User do
            defstruct name: "John", age: 27
          end

          Bento.decode("d4:name3:Bobe", as: %User{})
          # {:ok, %User{name: "Bob", age: 27}}

    * `:keys` - controls how dictionary keys are decoded: `:strings`
      (default), `:atoms`, `:atoms!`, or a function taking the key
      string. Note `:atoms` creates atoms at runtime, which is unsafe
      on untrusted input.

    * `:strings` - `:reference` (default) returns sub-binaries into the
      input; `:copy` copies every string, which avoids keeping the whole
      input binary alive when decoded values are stored long-term.

    * `:dicts` - `:strict` (default) decodes dictionaries as maps and
      requires unique, canonically sorted keys, as BEP-3 mandates;
      `:lenient` skips those checks for non-conforming files;
      `:ordered` decodes dictionaries as `Bento.OrderedDict` structs
      preserving wire order.
  """
  @spec decode(iodata(), Decoder.opts()) :: {:ok, Decoder.t()} | failure
        when failure: {:error, Decoder.decode_err()}
  def decode(iodata, options \\ []), do: Decoder.decode(iodata, options)

  @doc """
  Decode bencoded data to a value, raising an exception on error.

      iex> Bento.decode!("li1e3:twoli3eee")
      [1, "two", [3]]

  Accepts the same options as `decode/2`.
  """
  @spec decode!(iodata(), Decoder.opts()) :: Decoder.t() | no_return()
  def decode!(iodata, options \\ []), do: Decoder.decode!(iodata, options)

  @doc """
  Decode a single bencoded value off the front of the input, returning
  the remaining bytes as well.

  Useful when consuming streams that carry several consecutive values.

      iex> Bento.decode_prefix("i1ei2e")
      {:ok, 1, "i2e"}

  Accepts the same options as `decode/2`, except `:as`.
  """
  @spec decode_prefix(iodata(), Bento.Parser.opts()) ::
          {:ok, Bento.Parser.t(), binary()} | {:error, Decoder.decode_err()}
  def decode_prefix(iodata, options \\ []), do: Bento.Parser.parse_prefix(iodata, options)

  @doc """
  Like `decode_prefix/2`, but raises an exception on error.

      iex> Bento.decode_prefix!("i1ei2e")
      {1, "i2e"}
  """
  @spec decode_prefix!(iodata(), Bento.Parser.opts()) ::
          {Bento.Parser.t(), binary()} | no_return()
  def decode_prefix!(iodata, options \\ []) do
    case Bento.Parser.parse_prefix(iodata, options) do
      {:ok, value, rest} -> {value, rest}
      {:error, error} -> raise error
    end
  end

  @doc """
  Like `decode`, but ensures the data is a valid torrent metainfo file.
  """
  @spec torrent(iodata()) :: {:ok, Metainfo.Torrent.t()} | failure
        when failure: {:error, Decoder.decode_err() | String.t()}
  def torrent(iodata) do
    with {:ok, decoded} <- decode(iodata, as: %Metainfo.Torrent{}),
         {:ok, info} <- Metainfo.info(decoded) do
      {:ok, struct(decoded, info: info)}
    end
  end

  @doc """
  Like `decode!`, but ensures the data is a valid torrent metainfo file.
  """
  @spec torrent!(iodata()) :: Metainfo.Torrent.t() | no_return()
  def torrent!(iodata) do
    decoded = decode!(iodata, as: %Metainfo.Torrent{})
    struct(decoded, info: Metainfo.info!(decoded))
  end

  @doc """
  Build a magnet link from the raw bytes of a torrent metainfo file.

  The info-hash is computed over the exact bytes of the info dictionary
  as they appear in the input. See `Bento.Magnet.from_torrent/1`.
  """
  @spec magnet(iodata()) :: {:ok, Magnet.t()} | failure
        when failure: {:error, Bento.MagnetError.t() | Bento.SyntaxError.t()}
  def magnet(iodata), do: Magnet.from_torrent(iodata)

  @doc """
  Like `magnet/1`, but raises on error.

      iex> File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
      ...> |> Bento.magnet!()
      ...> |> to_string()
      "magnet:?xt=urn:btih:33395da120c9a4758e896ded4dec5f2495c9973f" <>
        "&dn=ubuntu-14.04.4-desktop-amd64.iso&xl=1069547520" <>
        "&tr=http%3A%2F%2Ftorrent.ubuntu.com%3A6969%2Fannounce" <>
        "&tr=http%3A%2F%2Fipv6.torrent.ubuntu.com%3A6969%2Fannounce"
  """
  @spec magnet!(iodata()) :: Magnet.t() | no_return()
  def magnet!(iodata), do: Magnet.from_torrent!(iodata)
end
