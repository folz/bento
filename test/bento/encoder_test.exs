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

  test "Map keys are sorted byte-wise after normalization, even when mixed" do
    # Atom and binary keys must interleave in canonical byte order, not
    # group by their Erlang term order.
    assert to_benc(%{"a" => 1, z: 2}) == "d1:ai1e1:zi2ee"
    assert to_benc(%{"z" => 1, a: 2}) == "d1:ai2e1:zi1ee"
    assert to_benc(%{"b" => 1, :a => 2, "aa" => 3}) == "d1:ai2e2:aai3e1:bi1ee"
  end

  test "Map keys that collide after normalization raise" do
    assert_raise EncodeError, ~r/[Dd]uplicate key/, fn ->
      to_benc(%{:a => 1, "a" => 2})
    end
  end

  test "Map with non-string non-atom keys raises" do
    assert_raise EncodeError, ~r/Expected string or atom key/, fn ->
      to_benc(%{1 => "foo"})
    end
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

  describe "deriving" do
    defmodule Derived do
      @derive Bento.Encoder
      defstruct name: "demo", length: 42
    end

    defmodule DerivedOnly do
      @derive {Bento.Encoder, only: [:name]}
      defstruct name: "demo", length: 42
    end

    defmodule DerivedExcept do
      @derive {Bento.Encoder, except: [:length]}
      defstruct name: "demo", length: 42
    end

    defmodule DerivedSkipNil do
      @derive {Bento.Encoder, skip_nil: true}
      defstruct name: "demo", md5sum: nil
    end

    test "derives all fields in canonical order by default" do
      assert to_benc(%Derived{}) == "d6:lengthi42e4:name4:demoe"
    end

    test "only: limits encoded fields" do
      assert to_benc(%DerivedOnly{}) == "d4:name4:demoe"
    end

    test "except: removes encoded fields" do
      assert to_benc(%DerivedExcept{}) == "d4:name4:demoe"
    end

    test "skip_nil: leaves out nil fields" do
      assert to_benc(%DerivedSkipNil{}) == "d4:name4:demoe"
      assert to_benc(%DerivedSkipNil{md5sum: "abc"}) == "d6:md5sum3:abc4:name4:demoe"
    end

    test "unknown fields in only:/except: raise at compile time" do
      assert_raise ArgumentError, ~r/`:only` specified keys/, fn ->
        defmodule BadDerive do
          @derive {Bento.Encoder, only: [:nope]}
          defstruct name: "demo"
        end
      end
    end
  end

  test "BitString that is not a binary raises" do
    assert_raise EncodeError, ~r/Bitstring/, fn ->
      Bento.Encoder.encode(<<1::3>>)
    end
  end

  test "EncodeError builds a default message from the value" do
    assert Exception.message(%EncodeError{value: 42.0}) == "Unable to encode value: 42.0"
    assert Exception.message(%EncodeError{message: "custom"}) == "custom"
  end

  describe "Fragment" do
    test "is emitted verbatim" do
      fragment = Bento.Fragment.new("d1:ai1ee")

      assert to_benc(fragment) == "d1:ai1ee"
      assert to_benc(%{"frag" => fragment}) == "d4:fragd1:ai1eee"
      assert to_benc([fragment, fragment]) == "ld1:ai1eed1:ai1eee"
    end

    test "accepts iodata" do
      fragment = Bento.Fragment.new([?d, ["1:a", "i1e"], ?e])

      assert to_benc(fragment) == "d1:ai1ee"
    end

    test "matches the output of encoding the original value" do
      info = %{"name" => "demo", "length" => 42}
      encoded = Bento.encode!(info)

      assert Bento.encode!(%{"info" => Bento.Fragment.new(encoded)}) ==
               Bento.encode!(%{"info" => info})
    end
  end

  describe "OrderedDict" do
    test "preserves entry order without sorting or duplicate checks" do
      dict = Bento.OrderedDict.new([{"b", 1}, {"a", 2}])
      assert to_benc(dict) == "d1:bi1e1:ai2ee"
    end

    test "normalizes atom keys" do
      dict = Bento.OrderedDict.new([{:b, 1}, {:a, 2}])
      assert to_benc(dict) == "d1:bi1e1:ai2ee"
    end

    test "empty dict" do
      assert to_benc(Bento.OrderedDict.new()) == "de"
    end

    test "non-canonical input round-trips byte-for-byte through dicts: :ordered" do
      input = "d1:bi1e1:ai2e1:ad2:zad2:ba1:xeee"
      assert input |> Bento.decode!(dicts: :ordered) |> Bento.encode!() == input
    end
  end
end
