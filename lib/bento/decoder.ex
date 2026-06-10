defmodule Bento.Decoder do
  @moduledoc """
  Useful wrapper for `Bento.Parser`.

  Accepts all of `Bento.Parser`'s options (`:keys`, `:strings` and
  `:dicts`) plus `:as`, which transforms the parsed value into a struct
  via `transform/2`.
  """

  alias Bento.Parser

  @type t :: Parser.t() | struct()
  @type opts :: [
          as: map() | list() | struct(),
          keys: :strings | :atoms | :atoms! | (String.t() -> term()),
          strings: :reference | :copy,
          dicts: :strict | :lenient | :ordered
        ]
  @type decode_err :: Parser.parse_err()

  @doc """
  Decode a bencoded value.
  """
  @spec decode(iodata(), opts()) :: {:ok, t()} | {:error, decode_err()}
  def decode(value, opts \\ []) do
    with {:ok, parsed} <- Parser.parse(value, parser_opts(opts)) do
      {:ok, maybe_transform(parsed, opts)}
    end
  end

  @doc """
  Decode a bencoded value, but raise an error if it fails.
  """
  @spec decode!(iodata(), opts()) :: t() | no_return()
  def decode!(value, opts \\ []) do
    value |> Parser.parse!(parser_opts(opts)) |> maybe_transform(opts)
  end

  @doc """
  Transform a parsed value into a struct.

      defmodule User do
        defstruct name: "John", age: 27
      end

      Bento.Decoder.transform(%{"name" => "Bob"}, as: %User{})
      # %User{name: "Bob", age: 27}

  Composes with the `:keys` option: values are looked up first under the
  field's string name, then under its atom name. `Bento.OrderedDict`
  values (from `dicts: :ordered`) are returned unchanged, as their wire
  order cannot be mapped onto struct fields.
  """
  @spec transform(Parser.t(), opts()) :: t()
  def transform(%Bento.OrderedDict{} = value, _opts), do: value

  def transform(value, as: as) when is_map(value) do
    transform_map(value, as)
  end

  def transform(value, as: as) when is_list(value) do
    transform_list(value, as)
  end

  def transform(value, as: as) when is_integer(value) do
    transform_time(value, as)
  end

  def transform(value, _opts), do: value

  defp parser_opts(opts), do: Keyword.take(opts, [:keys, :strings, :dicts])

  defp maybe_transform(value, opts) do
    case Keyword.fetch(opts, :as) do
      {:ok, as} -> transform(value, as: as)
      :error -> value
    end
  end

  # Transform for maps and structs
  defp transform_map(value, as) when is_struct(as) do
    value
    |> transform_map(Map.from_struct(as))
    |> Map.put(:__struct__, as.__struct__)
  end

  defp transform_map(value, as) when is_map(as) do
    Enum.reduce(as, %{}, fn {key, default}, acc ->
      item = fetch_key(value, key, default)

      Map.put(acc, key, transform(item, as: default))
    end)
  end

  defp transform_map(value, _as), do: value

  # Decoded dictionaries are string-keyed by default, but atom-keyed when
  # the `keys: :atoms`/`:atoms!` options are used.
  defp fetch_key(value, key, default) do
    string_key = to_string(key)

    case value do
      %{^string_key => item} -> item
      %{^key => item} -> item
      _ -> default
    end
  end

  # Transform for lists
  defp transform_list(value, [to]) do
    Enum.map(value, &transform(&1, as: to))
  end

  defp transform_list(value, _as), do: value

  # Transform for DateTime
  defguardp is_time(value) when is_struct(value, DateTime)

  defp transform_time(value, as) when is_time(as) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      _ -> value
    end
  end

  defp transform_time(value, _as), do: value
end
