defmodule Bento do
  @moduledoc ~S"""
  An incredibly fast, correct, pure-Elixir Bencoding library.

  This module contains high-level methods to encode and decode Bencoded data.
  """

  alias Bento.Encoder
  alias Bento.Parser
  alias Bento.Metainfo

  @doc """
  Bencode a value.

      iex> Bento.encode([1, "two", [3]])
      {:ok, "li1e3:twoli3eee"}

  """
  @spec encode(Encoder.t, Keyword.t) :: {:ok, iodata} | {:ok, String.t} | {:error, {:invalid, any}}
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
  @spec encode!(Encoder.t, Keyword.t) :: iodata | String.t | no_return
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
  @spec encode_to_iodata(Encoder.t, Keyword.t) :: {:ok, iodata} | {:error, {:invalid, any}}
  def encode_to_iodata(value, options \\ []) do
    encode(value, [iodata: true] ++ options)
  end

  @doc """
  Bencode a value as iodata, raises an exception on error.

      iex> Bento.encode_to_iodata!([1, "two", [3]])
      [108, [[105, "1", 101], ["3", 58, "two"], [108, [[105, "3", 101]], 101]], 101]
  """
  @spec encode_to_iodata!(Encoder.t, Keyword.t) :: iodata | no_return
  def encode_to_iodata!(value, options \\ []) do
    encode!(value, [iodata: true] ++ options)
  end

  @doc """
  Decode bencoded data to a value.

      iex> Bento.decode("li1e3:twoli3eee")
      {:ok, [1, "two", [3]]}
  """
  @spec decode(iodata, Keyword.t) :: {:ok, Parser.t} | {:error, :invalid} | {:error, {:invalid, String.t}}
  def decode(iodata, options \\ []) do
    with {:ok, parsed} <- Parser.parse(iodata),
    do: {:ok, Poison.Decode.decode(parsed, options)}
  end

  @doc """
  Decode bencoded data to a value, raising an exception on error.

      iex> Bento.decode!("li1e3:twoli3eee")
      [1, "two", [3]]
  """
  @spec decode!(iodata, Keyword.t) :: Parser.t | no_return
  def decode!(iodata, options \\ []) do
    iodata
      |> Parser.parse!()
      |> Poison.Decode.decode(options)
  end

  @doc """
  Like `decode`, but ensures the data is a valid torrent metainfo file.
  """
  def torrent(iodata) do
    with {:ok, decoded} <- decode(iodata, as: %Metainfo.Torrent{}),
         {:ok, info} <- Metainfo.info(decoded),
    do: {:ok, struct(decoded, [info: info])}
  end

  @doc """
  Like `decode!`, but ensures the data is a valid torrent metainfo file.
  """
  def torrent!(iodata) do
    decoded = decode!(iodata, as: %Metainfo.Torrent{})
    struct(decoded, [info: Metainfo.info!(decoded)])
  end
end
