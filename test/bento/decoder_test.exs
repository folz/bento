defmodule Bento.DecoderTest do
  use ExUnit.Case, async: true

  alias Bento.Decoder

  test "decode" do
    assert Decoder.decode("d4:spaml1:a1:bee") == {:ok, %{"spam" => ["a", "b"]}}
  end

  test "decode!" do
    assert Decoder.decode!("d4:spaml1:a1:bee") == %{"spam" => ["a", "b"]}
  end

  describe "Transform" do
    defmodule User do
      defstruct name: "John", age: 27
    end

    test "transform a map into a struct" do
      assert Decoder.transform(%{"name" => "Bob"}, as: %User{}) == %User{age: 27, name: "Bob"}
    end

    defmodule UserList do
      defstruct list: [%User{}]
    end

    test "transform a map with list into a struct" do
      simple = %{"list" => [%{"name" => "Bob"}]}
      result = %UserList{list: [%User{age: 27, name: "Bob"}]}

      assert Decoder.transform(simple, as: %UserList{}) == result
    end

    defmodule UserMap do
      defstruct map: %{"user" => %User{}}
    end

    test "transform a map with map into a struct" do
      simple = %{"map" => %{"user" => %{"name" => "Bob"}}}
      result = %UserMap{map: %{"user" => %User{age: 27, name: "Bob"}}}

      assert Decoder.transform(simple, as: %UserMap{}) == result
    end

    defmodule UserStruct do
      defstruct struct: %UserMap{
                  map: %{"user" => %UserList{list: [%User{}]}}
                },
                other: "value",
                foo: "foo"
    end

    test "transform a map with struct into a struct" do
      simple = %{
        "struct" => %{"map" => %{"user" => %{"list" => [%{"name" => "Bob"}]}}},
        "foo" => "bar"
      }

      result = %UserStruct{
        struct: %UserMap{map: %{"user" => %UserList{list: [%User{age: 27, name: "Bob"}]}}},
        other: "value",
        foo: "bar"
      }

      assert Decoder.transform(simple, as: %UserStruct{}) == result
    end

    test "transform a list into a list" do
      simple = [%{"list" => [%{"name" => "Alice"}]}]
      result = [%UserList{list: [%User{age: 27, name: "Alice"}]}]

      assert Decoder.transform(simple, as: [%UserList{}]) == result
      assert Decoder.transform(simple, as: [%UserMap{}]) == [%UserMap{}]
    end

    test "transform a map into a map" do
      simple = %{"user" => %{"name" => "Bob"}}
      result = %{"user" => %User{age: 27, name: "Bob"}}

      assert Decoder.transform(simple, as: %{"user" => %User{}}) == result
    end

    test "transform an integer into a DateTime" do
      assert Decoder.transform(100, as: DateTime.utc_now()) == ~U[1970-01-01 00:01:40Z]
      assert Decoder.transform(-100, as: DateTime.utc_now()) == ~U[1969-12-31 23:58:20Z]
      assert Decoder.transform(-377_705_116_801, as: DateTime.utc_now()) == -377_705_116_801
    end
  end
end
