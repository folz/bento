defmodule Bento do
  alias Bento.Encoder
  alias Bento.Parser

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
  Bencode a value, raises an exception on error.

      iex> Bento.encode!([1, "two", [3]])
      "li1e3:twoli3eee"
  """
  @spec encode!(Encoder.t, Keyword.t) :: iodata | no_return
  def encode!(value, options \\ []) do
    Encoder.encode(value)
  end

  @doc """
  Decode bencoded data to a value.

      iex> Bento.decode("li1e3:twoli3eee")
      {:ok, [1, "two", [3]]}
  """
  @spec decode(iodata, Keyword.t) :: {:ok, Parser.t} | {:error, :invalid} | {:error, {:invalid, String.t}}
  def decode(iodata, options \\ []) do
    case Parser.parse(iodata) do
      {:ok, value} -> {:ok, Poison.Decode.decode(value, options)}
      error -> error
    end
  end

  @doc """
  Decode bencoded data to a value, raises an exception on error.

      iex> Bento.decode!("li1e3:twoli3eee")
      [1, "two", [3]]
  """
  @spec decode!(iodata, Keyword.t) :: Parser.t | no_return
  def decode!(iodata, options \\ []) do
    Parser.parse!(iodata) |> Poison.Decode.decode(options)
  end
end
