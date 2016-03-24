defmodule Bento.EncodeError do
  defexception value: nil, message: nil

  def message(%{value: value, message: nil}) do
     "Unable to encode value: #{inspect value}"
  end

  def message(%{message: message}) do
    message
  end
end

defmodule Bento.Encode do
  @moduledoc ~S"""
  Macros useful for bencoding Maps and Map-like objects.

  For the actual encoding step, see `Bento.Encoder`
  """

  defmacro __using__(_) do
    quote do
      defp encode_name(value) when is_binary(value), do: value
      defp encode_name(value) when is_atom(value), do: Atom.to_string(value)
      defp encode_name(value) do
        raise Bento.EncodeError,
                value: value,
                message: "Expected string or atom key, got: #{inspect value}"

      end
    end
  end
end

defprotocol Bento.Encoder do
  @moduledoc ~S"""
  Protocol and implementations to encode Elixir data structures into
  their Bencoded forms.

  ## Examples

      iex> Bento.Encoder.encode("foo")
      "3:foo"

      iex> Bento.Encoder.encode([1, "mixed", "types", 4])
      "li1e5:mixed5:typesi4ee"
  """

  @type bencodable :: atom | String.t | integer | map | list | Range.t | Stream.t
  @type t :: String.t

  @doc """
  Encode an Elixir value into its Bencoded form.
  """
  @spec encode(bencodable) :: t
  def encode(value)
end

defimpl Bento.Encoder, for: Atom do
  def encode(nil),   do: "4:null"
  def encode(true),  do: "4:true"
  def encode(false), do: "5:false"

  def encode(atom) do
    Atom.to_string(atom) |> Bento.Encoder.BitString.encode()
  end
end

defimpl Bento.Encoder, for: BitString do
  use Bitwise

  def encode(""), do: "0:"
  def encode(str) do
    (byte_size(str) |> Integer.to_string()) <> ":" <> str
  end
end

defimpl Bento.Encoder, for: Integer do
  def encode(0), do: "i0e"
  def encode(int) do
    "i" <> Integer.to_string(int) <> "e"
  end
end

defimpl Bento.Encoder, for: Map do
  alias Bento.Encoder

  use Bento.Encode

  # `def encode(%{})` matchs all Maps, so we guard on map_size instead
  def encode(map) when map_size(map) == 0, do: "de"
  def encode(map) do
    fun = fn (x, acc) -> acc <> Encoder.BitString.encode(encode_name(x)) <> Encoder.encode(Map.get(map, x)) end
    "d" <> Enum.reduce(Enum.sort(Map.keys(map)), "", fun) <> "e"
  end
end

defimpl Bento.Encoder, for: [List, Range, Stream] do
  alias Bento.Encoder

  def encode([]), do: "le"
  def encode(coll) do
    fun = fn (x, acc) -> acc <> Encoder.encode(x) end
    "l" <> Enum.reduce(coll, "", fun) <> "e"
  end
end

# TODO: implement for Any using deriving
