defmodule Bento.OrderedDictTest do
  use ExUnit.Case, async: true

  doctest Bento.OrderedDict
  doctest Bento.Fragment

  alias Bento.OrderedDict

  defp dict, do: OrderedDict.new([{"b", 1}, {"a", 2}])

  test "decoding with dicts: :ordered produces an OrderedDict" do
    assert Bento.decode!("d1:bi1e1:ai2ee", dicts: :ordered) == dict()
  end

  describe "Access" do
    test "fetch" do
      assert Access.fetch(dict(), "a") == {:ok, 2}
      assert Access.fetch(dict(), "missing") == :error
      assert dict()["b"] == 1
      assert dict()["missing"] == nil
    end

    test "get_and_update" do
      {previous, updated} =
        Access.get_and_update(dict(), "a", fn value -> {value, value + 10} end)

      assert previous == 2
      assert updated.values == [{"b", 1}, {"a", 12}]
    end

    test "get_and_update inserts missing keys at the end" do
      {nil, updated} = Access.get_and_update(dict(), "c", fn nil -> {nil, 3} end)
      assert updated.values == [{"b", 1}, {"a", 2}, {"c", 3}]
    end

    test "get_and_update pops" do
      {1, updated} = Access.get_and_update(dict(), "b", fn _ -> :pop end)
      assert updated.values == [{"a", 2}]
    end

    test "pop" do
      {value, updated} = Access.pop(dict(), "b")
      assert value == 1
      assert updated.values == [{"a", 2}]

      {default, unchanged} = OrderedDict.pop(dict(), "missing", :default)
      assert default == :default
      assert unchanged == dict()
    end
  end

  describe "Enumerable" do
    test "count" do
      assert Enum.count(dict()) == 2
      assert Enum.count(OrderedDict.new()) == 0
    end

    test "preserves order while enumerating" do
      assert Enum.map(dict(), fn {key, value} -> {key, value} end) == [{"b", 1}, {"a", 2}]
      assert Enum.into(dict(), %{}) == %{"a" => 2, "b" => 1}
    end

    test "member?" do
      assert Enum.member?(dict(), {"a", 2})
      refute Enum.member?(dict(), {"a", 1})
    end
  end
end
