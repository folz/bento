defmodule Bento.EncodeError do
  @moduledoc """
  Raised when a map with non-string keys is passed to the encoder.
  """

  defexception value: nil, message: nil

  def message(%{value: value, message: nil}) do
    "Unable to encode value: #{inspect(value)}"
  end

  def message(%{message: msg}) do
    msg
  end
end

defmodule Bento.Encode do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      # Macro to ensure a map key is a string or atom-as-a-string.
      defp encode_key(value) when is_binary(value), do: value
      defp encode_key(value) when is_atom(value), do: Atom.to_string(value)

      defp encode_key(value) do
        raise Bento.EncodeError,
          value: value,
          message: "Expected string or atom key, got: #{inspect(value)}"
      end
    end
  end
end

defprotocol Bento.Encoder do
  @moduledoc ~S"""
  Protocol and implementations to encode Elixir data structures into
  their Bencoded forms.

  ## Examples

      iex> Bento.Encoder.encode("foo") |> IO.iodata_to_binary()
      "3:foo"

      iex> Bento.Encoder.encode([1, "two", [3]]) |> IO.iodata_to_binary()
      "li1e3:twoli4eee"
  """

  @type bencodable :: atom | String.t() | integer | map | list | Range.t() | Stream.t()
  @type t :: iodata

  @doc """
  Encode an Elixir value into its Bencoded form.
  """
  @spec encode(bencodable) :: t
  def encode(value)
end

defimpl Bento.Encoder, for: Atom do
  def encode(nil), do: "4:null"
  def encode(true), do: "4:true"
  def encode(false), do: "5:false"

  def encode(atom) do
    atom |> Atom.to_string() |> Bento.Encoder.BitString.encode()
  end
end

defimpl Bento.Encoder, for: BitString do
  def encode(str) do
    [str |> byte_size() |> Integer.to_string(), ?:, str]
  end
end

defimpl Bento.Encoder, for: Integer do
  def encode(int) do
    [?i, Integer.to_string(int), ?e]
  end
end

defimpl Bento.Encoder, for: Map do
  alias Bento.Encoder
  use Bento.Encode

  # `def encode(%{})` matchs all Maps, so we guard on map_size instead
  def encode(map) when map_size(map) == 0, do: "de"

  def encode(map) do
    fun = fn x ->
      [Encoder.BitString.encode(encode_key(x)), Encoder.encode(Map.get(map, x))]
    end

    [?d, map |> Map.keys() |> Enum.sort() |> Enum.map(fun), ?e]
  end
end

defimpl Bento.Encoder, for: [List, Range, Stream] do
  alias Bento.Encoder

  def encode([]), do: "le"

  def encode(coll) do
    [?l, coll |> Enum.map(&Encoder.encode/1), ?e]
  end
end

# TODO: implement for Any using deriving
