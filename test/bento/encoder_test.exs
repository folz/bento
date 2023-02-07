defmodule Bento.EncoderTest do
  use ExUnit.Case, async: true

  alias Bento.EncodeError

  test "Atom" do
    assert to_benc(nil) == "4:null"
    assert to_benc(false) == "5:false"
    assert to_benc(true) == "4:true"
    assert to_benc(:bento) == "5:bento"
    assert to_benc(:Bento) == "5:Bento"
    assert to_benc(:"Ben To") == "6:Ben To"
  end

  test "Integer" do
    assert to_benc(0) == "i0e"
    assert to_benc(-0) == "i0e"
    assert to_benc(1) == "i1e"
    assert to_benc(-1) == "i-1e"
    assert to_benc(42) == "i42e"
    assert to_benc(4_294_967_295) == "i4294967295e"
    assert to_benc(18_446_744_073_709_551_615) == "i18446744073709551615e"
  end

  test "BitString" do
    assert to_benc("") == "0:"
    assert to_benc("hello world") == "11:hello world"
    assert to_benc("hełło") == "7:hełło"
    # "2:ł"
    assert to_benc("ł") == <<50, 58, 197, 130>>
    # "4:𝄞"
    assert to_benc("𝄞") == <<52, 58, 240, 157, 132, 158>>
    # "1:" <> <<31>>
    assert to_benc(<<31>>) == <<49, 58, 31>>
  end

  test "Map" do
    assert to_benc(%{}) == "de"
    assert to_benc(%{foo: :bar}) == "d3:foo3:bare"
    assert to_benc(%{foo: :bar, baz: :qux}) == "d3:baz3:qux3:foo3:bare"
    assert to_benc(%{"foo" => [1, "bar", :baz]}) == "d3:fooli1e3:bar3:bazee"
  end

  test "List" do
    assert to_benc([]) == "le"
    assert to_benc([1, 2, 3]) == "li1ei2ei3ee"
    assert to_benc([1, "mixed", "types", 4]) == "li1e5:mixed5:typesi4ee"
    assert to_benc([0, 1, "a", "ł", "𝄞"]) == "li0ei1e1:a2:ł4:𝄞e"
  end

  test "Range" do
    assert to_benc(1..3) == "li1ei2ei3ee"
    assert to_benc(-1..1) == "li-1ei0ei1ee"
  end

  test "Stream" do
    range = 1..10
    assert to_benc(Stream.take(range, 0)) == "le"
    assert to_benc(Stream.take(range, 3)) == "li1ei2ei3ee"
  end

  test "EncodeError" do
    assert_raise EncodeError, fn ->
      assert to_benc(%{42.0 => "foo"})
    end
  end

  defp to_benc(value) do
    Bento.Encoder.encode(value) |> IO.iodata_to_binary()
  end

  describe "Any" do
    defmodule User do
      defstruct name: "John", age: 47
    end

    defmodule Truly do
      defstruct be: true

      defimpl Bento.Encoder do
        def encode(_), do: "4:true"
      end
    end

    test "Struct" do
      assert to_benc(%User{}) == "d3:agei47e4:name4:Johne"
      assert to_benc(%User{name: "Bob"}) == "d3:agei47e4:name3:Bobe"

      assert to_benc(%Truly{be: false}) == "4:true"
    end

    # Otherweise

    test "Float" do
      assert_raise EncodeError, ~r/Float/, fn ->
        assert to_benc(42.1)
      end
    end

    test "Function" do
      assert_raise EncodeError, ~r/Function/, fn ->
        assert to_benc(fn -> nil end)
      end
    end

    test "PID" do
      assert_raise EncodeError, ~r/PID/, fn ->
        assert to_benc(self())
      end
    end

    test "Port" do
      port = Port.open({:spawn, "sh"}, [])

      assert_raise EncodeError, ~r/Port/, fn ->
        assert to_benc(port)
      end

      Port.close(port)
    end

    test "Reference" do
      assert_raise EncodeError, ~r/Reference/, fn ->
        assert to_benc(make_ref())
      end
    end

    test "Tuple" do
      assert_raise EncodeError, ~r/Tuple/, fn ->
        assert to_benc({:foo, :bar})
      end
    end
  end
end
