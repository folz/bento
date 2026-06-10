defmodule Bento.OrderedDict do
  @moduledoc """
  A dictionary that preserves the exact order of its entries.

  Returned from decoding when the `dicts: :ordered` option is given, and
  accepted by the encoder. A thin wrapper around a list of key-value
  pairs (keys may be any term, typically strings), implementing the
  `Access` behaviour and the `Enumerable` protocol with list-like
  complexity.

  Encoding a `Bento.OrderedDict` emits its entries **in stored order**,
  without sorting or duplicate checks. This makes byte-faithful
  re-encoding of non-canonical input possible:

      iex> "d1:bi1e1:ai2ee"
      ...> |> Bento.decode!(dicts: :ordered)
      ...> |> Bento.encode!()
      "d1:bi1e1:ai2ee"

  When producing *new* data, prefer plain maps so the encoder can
  guarantee canonical output.
  """

  @behaviour Access

  @type t :: %__MODULE__{values: [{term(), term()}]}

  defstruct values: []

  @doc """
  Creates a new ordered dictionary from a list of key-value pairs.

      iex> Bento.OrderedDict.new([{"b", 1}, {"a", 2}]) |> Bento.encode!()
      "d1:bi1e1:ai2ee"
  """
  @spec new([{term(), term()}]) :: t()
  def new(values \\ []) when is_list(values) do
    %__MODULE__{values: values}
  end

  @impl Access
  def fetch(%__MODULE__{values: values}, key) do
    case :lists.keyfind(key, 1, values) do
      {_, value} -> {:ok, value}
      false -> :error
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{values: values} = dict, key, function) do
    {result, new_values} = get_and_update(values, [], key, function)
    {result, %{dict | values: new_values}}
  end

  @impl Access
  def pop(%__MODULE__{values: values} = dict, key, default \\ nil) do
    case :lists.keyfind(key, 1, values) do
      {_, value} -> {value, %{dict | values: delete_key(values, key)}}
      false -> {default, dict}
    end
  end

  defp get_and_update([{key, current} | tail], acc, key, fun) do
    case fun.(current) do
      {get, value} ->
        {get, :lists.reverse(acc, [{key, value} | tail])}

      :pop ->
        {current, :lists.reverse(acc, tail)}

      other ->
        raise "the given function must return a two-element tuple or :pop, got: #{inspect(other)}"
    end
  end

  defp get_and_update([{_, _} = pair | tail], acc, key, fun) do
    get_and_update(tail, [pair | acc], key, fun)
  end

  defp get_and_update([], acc, key, fun) do
    case fun.(nil) do
      {get, update} ->
        {get, :lists.reverse(acc, [{key, update}])}

      :pop ->
        {nil, :lists.reverse(acc)}

      other ->
        raise "the given function must return a two-element tuple or :pop, got: #{inspect(other)}"
    end
  end

  defp delete_key([{key, _} | tail], key), do: delete_key(tail, key)
  defp delete_key([pair | tail], key), do: [pair | delete_key(tail, key)]
  defp delete_key([], _key), do: []
end

defimpl Enumerable, for: Bento.OrderedDict do
  def count(%{values: values}), do: {:ok, length(values)}

  def member?(_dict, _value), do: {:error, __MODULE__}

  def slice(_dict), do: {:error, __MODULE__}

  def reduce(%{values: values}, acc, fun), do: Enumerable.List.reduce(values, acc, fun)
end
