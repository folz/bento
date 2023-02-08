defmodule Bento.EncodeError do
  @moduledoc """
  Raised when a map with non-string keys is passed to the encoder.
  """

  defexception value: nil, message: nil

  def message(%{value: value, message: nil}) do
    "Unable to encode value: #{inspect(value)}"
  end

  def message(%{message: msg}), do: msg
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
  @moduledoc """
  Protocol and implementations to encode Elixir data structures into
  their Bencoded forms.

  ## Examples

      iex> Bento.Encoder.encode("foo") |> IO.iodata_to_binary()
      "3:foo"

      iex> Bento.Encoder.encode([1, "two", [3]]) |> IO.iodata_to_binary()
      "li1e3:twoli4eee"
  """

  @fallback_to_any true

  @type bencodable :: atom() | Bento.Parser.t() | Enumerable.t()
  @type t :: iodata()
  @type encode_err :: {:invalid, term()}

  @doc """
  Encode an Elixir value into its Bencoded form.
  """
  @spec encode(bencodable()) :: t() | no_return()
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

defimpl Bento.Encoder, for: Any do
  # Default `encode/1` for ANY Struct.
  # If necessary, you can implement `Bento.Encoder` for a specific Struct.
  def encode(struct) when is_struct(struct) do
    struct |> Map.from_struct() |> Bento.Encoder.encode()
  end

  # Types that do not conform to the bencoding specification.
  # See: http://www.bittorrent.org/beps/bep_0003.html#bencoding
  def encode(value) do
    raise Bento.EncodeError,
      value: value,
      message: "Unsupported types: #{value_type(value)}"
  end

  defp value_type(value) when is_float(value), do: "Float"
  defp value_type(value) when is_function(value), do: "Function"
  defp value_type(value) when is_pid(value), do: "PID"
  defp value_type(value) when is_port(value), do: "Port"
  defp value_type(value) when is_reference(value), do: "Reference"
  defp value_type(value) when is_tuple(value), do: "Tuple"
end
