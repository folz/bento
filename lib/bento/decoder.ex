defmodule Bento.Decoder do
  @moduledoc false

  alias Bento.Parser

  @type t :: Parser.t() | struct()

  @spec decode(iodata(), Keyword.t()) :: t() | {:error, Parser.parse_err()}
  def decode(value, opts \\ []) do
    with {:ok, p} <- Parser.parse(value), do: {:ok, transform(p, opts)}
  end

  @spec decode!(iodata(), Keyword.t()) :: t() | no_return()
  def decode!(value, opts \\ []) do
    Parser.parse!(value) |> transform(opts)
  end

  defguardp is_transable(v, as) when is_map(v) and is_struct(as)

  @spec transform(Parser.t(), Keyword.t()) :: t()
  def transform(value, as: as) when is_transable(value, as) do
    Enum.reduce(Map.from_struct(as), %{}, fn {key, default}, acc ->
      item = Map.get(value, Atom.to_string(key), default)

      if is_struct(default) do
        Map.put(acc, key, transform(item, as: default))
      else
        Map.put(acc, key, item)
      end
    end)
    |> Map.put(:__struct__, as.__struct__)
  end

  def transform(value, _opts), do: value
end
