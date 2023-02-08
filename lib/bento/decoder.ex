defmodule Bento.Decoder do
  @moduledoc false

  alias Bento.Parser

  @type t :: Parser.t() | struct()
  @type opts :: [as: map() | list() | struct()]

  @spec decode(iodata(), opts()) :: t() | {:error, Parser.parse_err()}
  def decode(value, opts \\ []) do
    with {:ok, p} <- Parser.parse(value), do: {:ok, transform(p, opts)}
  end

  @spec decode!(iodata(), opts()) :: t() | no_return()
  def decode!(value, opts \\ []) do
    Parser.parse!(value) |> transform(opts)
  end

  defguardp is_transable(v) when is_map(v) or is_list(v)

  @spec transform(Parser.t(), opts()) :: t()
  def transform(value, as: as) when is_transable(value) do
    do_transform(value, as)
  end

  def transform(value, _opts), do: value

  defp do_transform(value, as) when is_struct(as) do
    do_transform(value, Map.from_struct(as))
    |> Map.put(:__struct__, as.__struct__)
  end

  defp do_transform(value, as) when is_list(as) do
    Enum.map(value, &transform(&1, as: List.first(as)))
  end

  defp do_transform(value, as) when is_map(as) do
    Enum.reduce(as, %{}, fn {key, default}, acc ->
      item = Map.get(value, to_string(key), default)

      Map.put(acc, key, transform(item, as: default))
    end)
  end

  defp do_transform(value, _as), do: value
end
