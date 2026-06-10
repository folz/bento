defmodule Bento.EncodeError do
  @moduledoc """
  Raised when a value cannot be encoded into Bencoding - for example a
  float, a dictionary key that isn't a string or an atom, or two keys
  that collide once normalized to strings (such as `%{:a => 1, "a" => 2}`).
  """

  @type t :: %__MODULE__{value: term(), message: String.t() | nil}

  defexception value: nil, message: nil

  def message(%{value: value, message: nil}) do
    "Unable to encode value: #{inspect(value)}"
  end

  def message(%{message: msg}), do: msg
end

defmodule Bento.Encode do
  @moduledoc false

  # Internal encoding fast path. Values are dispatched on their type
  # directly, falling back to the `Bento.Encoder` protocol only for
  # structs and other custom types. All functions return iodata.

  alias Bento.Encoder

  @spec value(Encoder.bencodable()) :: iodata()
  def value(value) when is_binary(value), do: string(value)
  def value(value) when is_atom(value), do: atom(value)
  def value(value) when is_integer(value), do: integer(value)
  def value(value) when is_list(value), do: list(value)
  def value(%Bento.Fragment{iodata: iodata}), do: iodata
  def value(%Bento.OrderedDict{values: values}), do: ordered_pairs(values)
  def value(%_{} = struct), do: Encoder.encode(struct)
  def value(value) when is_map(value), do: dict(value)
  def value(value), do: Encoder.encode(value)

  @spec atom(atom()) :: iodata()
  def atom(nil), do: "4:null"
  def atom(true), do: "4:true"
  def atom(false), do: "5:false"
  def atom(atom), do: string(Atom.to_string(atom))

  @compile {:inline, string: 1, integer: 1}

  @spec string(binary()) :: iodata()
  def string(str), do: [Integer.to_string(byte_size(str)), ?:, str]

  @spec integer(integer()) :: iodata()
  def integer(int), do: [?i, Integer.to_string(int), ?e]

  @spec list(list()) :: iodata()
  def list([]), do: "le"
  def list([head | tail]), do: [?l, value(head) | list_loop(tail)]

  defp list_loop([]), do: [?e]
  defp list_loop([head | tail]), do: [value(head) | list_loop(tail)]

  # Dictionary keys must be encoded as strings and emitted in byte-wise
  # sorted order, so keys are normalized *before* sorting. After the
  # sort, duplicates are adjacent and detected with a single comparison
  # per entry.
  @spec dict(map()) :: iodata()
  def dict(map) when map_size(map) == 0, do: "de"

  def dict(map) do
    [{key, value} | tail] = map |> Map.to_list() |> normalize_keys() |> List.keysort(0)
    [?d, string(key), value(value) | dict_loop(tail, key)]
  end

  defp dict_loop([], _prev), do: [?e]

  defp dict_loop([{key, _value} | _tail], key) do
    raise Bento.EncodeError,
      value: key,
      message: "Duplicate key after normalization: #{inspect(key)}"
  end

  defp dict_loop([{key, value} | tail], _prev) do
    [string(key), value(value) | dict_loop(tail, key)]
  end

  # In the common all-binary-keys case the pair list is returned as-is;
  # it is only rebuilt when an atom key needs converting.
  defp normalize_keys(pairs) do
    if all_binary_keys?(pairs) do
      pairs
    else
      normalize_keys(pairs, [])
    end
  end

  defp all_binary_keys?([{key, _value} | tail]) when is_binary(key), do: all_binary_keys?(tail)
  defp all_binary_keys?([]), do: true
  defp all_binary_keys?(_pairs), do: false

  defp normalize_keys([{key, value} | tail], acc) when is_binary(key) do
    normalize_keys(tail, [{key, value} | acc])
  end

  defp normalize_keys([{key, value} | tail], acc) when is_atom(key) do
    normalize_keys(tail, [{Atom.to_string(key), value} | acc])
  end

  defp normalize_keys([{key, _value} | _tail], _acc) do
    raise Bento.EncodeError,
      value: key,
      message: "Expected string or atom key, got: #{inspect(key)}"
  end

  defp normalize_keys([], acc), do: acc

  # Entries of an ordered dictionary are emitted as-is: no sorting and
  # no duplicate detection, by design.
  @spec ordered_pairs([{term(), term()}]) :: iodata()
  def ordered_pairs([]), do: "de"

  def ordered_pairs([{key, value} | tail]) do
    [?d, string(normalize_key(key)), value(value) | ordered_loop(tail)]
  end

  defp ordered_loop([]), do: [?e]

  defp ordered_loop([{key, value} | tail]) do
    [string(normalize_key(key)), value(value) | ordered_loop(tail)]
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_key(key) do
    raise Bento.EncodeError,
      value: key,
      message: "Expected string or atom key, got: #{inspect(key)}"
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
      "li1e3:twoli3eee"

  ## Supported types

  **Available types**: `Atom`, `BitString`, `Integer`, `List`, `Map`,
  `Range`, `Stream`, `Bento.Fragment`, `Bento.OrderedDict` and structs
  (encoded as a `Map` by default).

  **Unavailable types**: `Float`, `Function`, `PID`, `Port`, `Reference`
  and `Tuple`. Encoding them raises `Bento.EncodeError`.

  Dictionary keys must be strings or atoms; they are normalized to
  strings and emitted in the byte-wise sorted order required for
  canonical Bencoding. Two keys that normalize to the same string raise
  `Bento.EncodeError`.

  ## Deriving

  Structs can derive an implementation, optionally restricting or
  post-processing the encoded fields:

    * `:only` - encodes only the given keys.
    * `:except` - encodes all keys except the given ones.
    * `:skip_nil` - when `true`, fields whose value is `nil` are left
      out entirely instead of being encoded as the string `"null"`.

  ```elixir
  defmodule Torrent do
    @derive {Bento.Encoder, only: [:announce, :info], skip_nil: true}
    defstruct [:announce, :info, :private_notes]
  end
  ```

  Field keys are encoded at compile time and emitted in canonical
  order, so derived implementations are faster than the default
  struct-to-map fallback.

  ## Implementing for custom structs

  Structs without a derived or explicit implementation are encoded as
  maps of their fields (via `Map.from_struct/1`). To customize, either
  derive as shown above or implement the protocol directly:

  ```elixir
  defimpl Bento.Encoder, for: MyStruct do
    def encode(struct) do
      # return iodata
    end
  end
  ```

  Here is a struct that _"always be true"_:

  ```elixir
  defmodule Truly do
    defstruct be: true

    defimpl Bento.Encoder do
      def encode(_), do: "4:true"
    end
  end

  iex> %Truly{be: false} |> Bento.Encoder.encode() |> IO.iodata_to_binary()
  "4:true"
  ```
  """

  @fallback_to_any true

  @type bencodable ::
          atom()
          | String.t()
          | integer()
          | list()
          | map()
          | Bento.Fragment.t()
          | Bento.OrderedDict.t()
          | Enumerable.t()
  @type t :: iodata()
  @type encode_err :: Bento.EncodeError.t()

  @doc """
  Encode an Elixir value into its Bencoded form.
  """
  @spec encode(bencodable()) :: t() | no_return()
  def encode(value)
end

defimpl Bento.Encoder, for: Atom do
  def encode(atom), do: Bento.Encode.atom(atom)
end

defimpl Bento.Encoder, for: BitString do
  def encode(str) when is_binary(str), do: Bento.Encode.string(str)

  def encode(bits) do
    raise Bento.EncodeError,
      value: bits,
      message: "Unsupported types: Bitstring"
  end
end

defimpl Bento.Encoder, for: Integer do
  def encode(int), do: Bento.Encode.integer(int)
end

defimpl Bento.Encoder, for: List do
  def encode(list), do: Bento.Encode.list(list)
end

defimpl Bento.Encoder, for: Map do
  def encode(map), do: Bento.Encode.dict(map)
end

defimpl Bento.Encoder, for: [Range, Stream] do
  def encode(coll) do
    [?l, Enum.map(coll, &Bento.Encode.value/1), ?e]
  end
end

defimpl Bento.Encoder, for: Bento.Fragment do
  def encode(%{iodata: iodata}), do: iodata
end

defimpl Bento.Encoder, for: Bento.OrderedDict do
  def encode(%{values: values}), do: Bento.Encode.ordered_pairs(values)
end

defimpl Bento.Encoder, for: Any do
  defmacro __deriving__(module, struct, opts) do
    fields = fields_to_encode(struct, opts)
    skip_nil? = Keyword.get(opts, :skip_nil, false)

    # Keys are normalized and sorted at compile time, so the generated
    # implementation emits canonical output with static key segments.
    kv =
      fields
      |> Enum.map(fn field -> {Atom.to_string(field), field} end)
      |> List.keysort(0)

    match_vars = Enum.map(kv, fn {_str, field} -> {field, Macro.var(field, __MODULE__)} end)

    segments =
      Enum.map(kv, fn {str, field} ->
        key_segment = IO.iodata_to_binary(Bento.Encode.string(str))
        var = Macro.var(field, __MODULE__)

        if skip_nil? do
          quote do
            case unquote(var) do
              nil -> []
              value -> [unquote(key_segment), Bento.Encode.value(value)]
            end
          end
        else
          quote do
            [unquote(key_segment), Bento.Encode.value(unquote(var))]
          end
        end
      end)

    quote do
      defimpl Bento.Encoder, for: unquote(module) do
        def encode(%{unquote_splicing(match_vars)}) do
          [?d, unquote_splicing(segments), ?e]
        end
      end
    end
  end

  defp fields_to_encode(struct, opts) do
    fields = struct |> Map.keys() |> List.delete(:__struct__)

    cond do
      only = Keyword.get(opts, :only) ->
        case only -- fields do
          [] ->
            only

          error_keys ->
            raise ArgumentError,
                  "`:only` specified keys (#{inspect(error_keys)}) that are not defined " <>
                    "in defstruct: #{inspect(fields)}"
        end

      except = Keyword.get(opts, :except) ->
        case except -- fields do
          [] ->
            fields -- except

          error_keys ->
            raise ArgumentError,
                  "`:except` specified keys (#{inspect(error_keys)}) that are not defined " <>
                    "in defstruct: #{inspect(fields)}"
        end

      true ->
        fields
    end
  end

  # Default for any struct without its own implementation: encode the
  # struct as a dictionary of its fields.
  def encode(struct) when is_struct(struct) do
    struct |> Map.from_struct() |> Bento.Encode.dict()
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
