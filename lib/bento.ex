defmodule Bento do
  @moduledoc """
  An incredibly fast, correct, pure-Elixir Bencoding library.

  This module contains high-level methods to encode and decode Bencoded data.
  """

  alias Bento.{Encoder, Decoder, Metainfo}

  @doc """
  Bencode a value.

      iex> Bento.encode([1, "two", [3]])
      {:ok, "li1e3:twoli3eee"}

  """
  @spec encode(Encoder.bencodable(), Keyword.t()) :: success | failure
        when success: {:ok, Encoder.t() | String.t()},
             failure: {:error, Encoder.encode_err()}
  def encode(value, options \\ []) do
    {:ok, encode!(value, options)}
  rescue
    exception in [Bento.EncodeError] ->
      {:error, {:invalid, exception.value}}
  end

  @doc """
  Bencode a value, raising an exception on error.

      iex> Bento.encode!([1, "two", [3]])
      "li1e3:twoli3eee"
  """
  @spec encode!(Encoder.bencodable(), Keyword.t()) :: Encoder.t() | String.t() | no_return()
  def encode!(value, options \\ []) do
    iodata = Encoder.encode(value)

    if options[:iodata] do
      iodata
    else
      iodata |> IO.iodata_to_binary()
    end
  end

  @doc """
  Bencode a value as iodata.

      iex> Bento.encode_to_iodata([1, "two", [3]])
      {:ok, [108, [[105, "1", 101], ["3", 58, "two"], [108, [[105, "3", 101]], 101]], 101]}
  """

  @spec encode_to_iodata(Encoder.bencodable(), Keyword.t()) :: success | failure
        when success: {:ok, Encoder.t()},
             failure: {:error, Encoder.encode_err()}
  def encode_to_iodata(value, options \\ []) do
    encode(value, [iodata: true] ++ options)
  end

  @doc """
  Bencode a value as iodata, raises an exception on error.

      iex> Bento.encode_to_iodata!([1, "two", [3]])
      [108, [[105, "1", 101], ["3", 58, "two"], [108, [[105, "3", 101]], 101]], 101]
  """

  @spec encode_to_iodata!(Encoder.bencodable(), Keyword.t()) :: Encoder.t() | no_return()
  def encode_to_iodata!(value, options \\ []) do
    encode!(value, [iodata: true] ++ options)
  end

  @doc """
  Decode bencoded data to a value.

      iex> Bento.decode("li1e3:twoli3eee")
      {:ok, [1, "two", [3]]}
  """
  @spec decode(iodata(), Keyword.t()) :: {:ok, Decoder.t()} | {:error, Decoder.decode_err()}
  def decode(iodata, options \\ []), do: Decoder.decode(iodata, options)

  @doc """
  Decode bencoded data to a value, raising an exception on error.

      iex> Bento.decode!("li1e3:twoli3eee")
      [1, "two", [3]]
  """
  @spec decode!(iodata(), Keyword.t()) :: Decoder.t() | no_return()
  def decode!(iodata, options \\ []), do: Decoder.decode!(iodata, options)

  @doc """
  Like `decode`, but ensures the data is a valid torrent metainfo file.
  """
  @spec torrent(iodata()) :: {:ok, Metainfo.Torrent.t()} | failure
        when failure: {:error, Decoder.decode_err() | String.t()}
  def torrent(iodata) do
    with {:ok, decoded} <- decode(iodata, as: %Metainfo.Torrent{}),
         {:ok, info} <- Metainfo.info(decoded),
         do: {:ok, struct(decoded, info: info)}
  end

  @doc """
  Like `decode!`, but ensures the data is a valid torrent metainfo file.
  """
  @spec torrent!(iodata()) :: Metainfo.Torrent.t() | no_return()
  def torrent!(iodata) do
    decoded = decode!(iodata, as: %Metainfo.Torrent{})
    struct(decoded, info: Metainfo.info!(decoded))
  end
end
