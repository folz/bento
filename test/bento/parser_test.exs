defmodule Bento.ParserTest do
  use ExUnit.Case, async: true

  doctest Bento.Parser

  import Bento.Parser
  alias Bento.SyntaxError

  test "numbers" do
    assert_raise SyntaxError, fn -> parse!("ie") end
    assert_raise SyntaxError, fn -> parse!("i-e") end
    assert_raise SyntaxError, fn -> parse!("i-0e") end
    assert_raise SyntaxError, fn -> parse!("i-00e") end
    assert_raise SyntaxError, fn -> parse!("i-01e") end
    assert_raise SyntaxError, fn -> parse!("i--1e") end
    assert_raise SyntaxError, fn -> parse!("i1") end
    assert_raise SyntaxError, fn -> parse!("i00e") end
    assert_raise SyntaxError, fn -> parse!("i01e") end
    assert_raise SyntaxError, fn -> parse!("iabc123e") end
    assert_raise SyntaxError, fn -> parse!("i123abce") end

    for i <- -11..11 do
      assert parse!("i#{i}e") == i
    end

    assert parse!("i4294967295e") == 4_294_967_295
    assert parse!("i18446744073709551615e") == 18_446_744_073_709_551_615
  end

  test "strings" do
    assert_raise SyntaxError, fn -> parse!("0") end
    assert_raise SyntaxError, fn -> parse!(":foo") end
    assert_raise SyntaxError, fn -> parse!("3foo") end
    assert_raise SyntaxError, fn -> parse!("2:foo") end
    assert_raise SyntaxError, fn -> parse!("4:foo") end
    assert_raise SyntaxError, fn -> parse!("-1:x") end

    assert parse!("0:") == ""
    assert parse!(<<49, 58, 31>>) == <<31>>
    assert parse!("3:foo") == "foo"
    assert parse!(<<52, 58, 240, 157, 132, 158>>) == "𝄞"
    assert parse!("4:𝄞") == "𝄞"
    assert parse!("10:aaaaaaaaaa") == "aaaaaaaaaa"
    assert parse!("11:aaaaaaaaaaa") == "aaaaaaaaaaa"
  end

  test "lists" do
    assert_raise SyntaxError, fn -> parse!("l") end
    assert_raise SyntaxError, fn -> parse!("lle") end
    assert_raise SyntaxError, fn -> parse!("li4e") end
    assert_raise SyntaxError, fn -> parse!("l2:fooe") end
    assert_raise SyntaxError, fn -> parse!("l4:fooe") end

    assert parse!("le") == []
    assert parse!("l0:e") == [""]
    assert parse!("li0ee") == [0]
    assert parse!("li1ee") == [1]
    assert parse!("llee") == [[]]
    assert parse!("llelee") == [[], []]
    assert parse!("li0elle3:fooelee") == [0, [[], "foo"], []]
    assert parse!("li1e5:mixed5:typesi4ee") == [1, "mixed", "types", 4]
    assert parse!("li1e5:mixedl5:typesi4eei5ee") == [1, "mixed", ["types", 4], 5]
  end

  test "maps" do
    assert_raise SyntaxError, fn -> parse!("d") end
    assert_raise SyntaxError, fn -> parse!("dde") end
    assert_raise SyntaxError, fn -> parse!("di4e") end
    assert_raise SyntaxError, fn -> parse!("di4ee") end
    assert_raise SyntaxError, fn -> parse!("d3:fooe") end
    assert_raise SyntaxError, fn -> parse!("di4ei4ee") end
    assert_raise SyntaxError, fn -> parse!("dlei4ee") end
    assert_raise SyntaxError, fn -> parse!("ddei4ee") end
    assert_raise SyntaxError, fn -> parse!("d4:fooi4ee") end
    assert_raise SyntaxError, fn -> parse!("d4:foode") end

    # BEP-3: keys must be unique and sorted as raw strings
    assert_raise SyntaxError, fn -> parse!("d1:b0:1:a0:e") end
    assert_raise SyntaxError, fn -> parse!("d1:a1:x1:a1:ye") end
    assert_raise SyntaxError, fn -> parse!("d1:a0:1:B0:e") end
    assert_raise SyntaxError, fn -> parse!("d3:food1:b0:1:a0:ee") end

    assert parse!("de") == %{}
    assert parse!("d3:foodee") == %{"foo" => %{}}
    assert parse!("d11:aaaaaaaaaaai4ee") == %{"aaaaaaaaaaa" => 4}
    assert parse!("d3:food3:bar3:bazee") == %{"foo" => %{"bar" => "baz"}}
    assert parse!("d3:food3:bardeee") == %{"foo" => %{"bar" => %{}}}
    assert parse!("d1:a1:b3:foo3:bar1:x1:ye") == %{"a" => "b", "foo" => "bar", "x" => "y"}
    assert parse!("d1:B0:1:a0:e") == %{"B" => "", "a" => ""}
  end

  test "collections" do
    assert_raise SyntaxError, fn -> parse!("ldede") end

    assert parse!("ldee") == [%{}]
    assert parse!("ldededee") == [%{}, %{}, %{}]
  end

  describe "error reporting" do
    test "errors carry the byte position of the offending input" do
      assert {:error, %SyntaxError{position: 0}} = parse("x")
      assert {:error, %SyntaxError{position: 2}} = parse("i4x2e")
      assert {:error, %SyntaxError{position: 2}} = parse("i-0e")
      assert {:error, %SyntaxError{position: 3}} = parse("i1ex")
    end

    test "end of input is reported at the input size" do
      assert {:error, %SyntaxError{position: 1} = error} = parse("i")
      assert Exception.message(error) == "unexpected end of input at position 1"

      assert {:error, %SyntaxError{position: 5}} = parse("5:abc")
      assert {:error, %SyntaxError{position: 4}} = parse("li1e")
      assert {:error, %SyntaxError{position: 6}} = parse("l3:foo")
    end

    test "messages identify the offending byte" do
      assert {:error, error} = parse("i4x2e")
      assert Exception.message(error) == ~S|unexpected byte at position 2: 0x78 ("x")|
    end

    test "messages render non-printable bytes as hex only" do
      assert {:error, error} = parse(<<0xFF>>)
      assert Exception.message(error) == "unexpected byte at position 0: 0xFF"
    end

    test "exceptions raised by hand still produce messages" do
      assert Exception.message(%SyntaxError{token: "abc"}) =~ "unexpected sequence"
      assert Exception.message(%SyntaxError{message: "custom"}) == "custom"
      assert Exception.message(%SyntaxError{}) == "unexpected end of input"
    end

    test "messages stay bounded for large inputs" do
      truncated = "1000000:" <> String.duplicate("a", 1_000)

      assert {:error, error} = parse(truncated)
      assert byte_size(Exception.message(error)) < 200

      huge_int = "i" <> String.duplicate("9", 2_000) <> "e"

      assert {:error, error} = parse(huge_int)
      assert byte_size(Exception.message(error)) < 200
    end
  end

  describe "integer digit limit" do
    test "integers up to the limit parse" do
      digits = String.duplicate("9", 1024)
      assert parse!("i#{digits}e") == String.to_integer(digits)
    end

    test "integers beyond the limit are rejected" do
      digits = String.duplicate("9", 1025)
      assert {:error, %SyntaxError{position: 1}} = parse("i#{digits}e")
    end
  end

  describe ":keys option" do
    test ":strings is the default" do
      assert parse!("d3:fooi1ee") == %{"foo" => 1}
    end

    test ":atoms converts keys" do
      assert parse!("d3:fooi1ee", keys: :atoms) == %{foo: 1}
    end

    test ":atoms! requires existing atoms" do
      assert parse!("d3:fooi1ee", keys: :atoms!) == %{foo: 1}

      assert_raise ArgumentError, fn ->
        parse!("d34:no-such-atom-bento-parser-test-1ai1ee", keys: :atoms!)
      end
    end

    test "a custom function transforms keys" do
      assert parse!("d3:fooi1ee", keys: &String.upcase/1) == %{"FOO" => 1}
    end

    test "invalid option values raise ArgumentError" do
      assert_raise ArgumentError, fn -> parse!("de", keys: :bogus) end
    end
  end

  describe ":strings option" do
    test ":reference returns sub-binaries into the input" do
      input = :binary.copy("3:foo", 1_000) |> then(&("#{div(byte_size(&1), 1)}:" <> &1))
      [string] = parse!("l" <> input <> "e")

      assert :binary.referenced_byte_size(string) > byte_size(string)
    end

    test ":copy detaches strings from the input" do
      input = "5000:" <> String.duplicate("a", 5_000)
      string = parse!(input, strings: :copy)

      assert :binary.referenced_byte_size(string) == byte_size(string)
    end

    test "invalid option values raise ArgumentError" do
      assert_raise ArgumentError, fn -> parse!("de", strings: :bogus) end
    end
  end

  describe ":dicts option" do
    test ":strict is the default and accepts canonical input" do
      assert parse!("d1:ai1e2:aai3e1:bi2ee") == %{"a" => 1, "aa" => 3, "b" => 2}
    end

    test ":strict rejects unsorted keys with the key as token" do
      assert {:error, %SyntaxError{token: "a", position: 9}} = parse("d1:bi1e1:ai2ee")
    end

    test ":strict rejects duplicate keys" do
      assert {:error, %SyntaxError{token: "foo"}} = parse("d3:fooi1e3:fooi2ee")
    end

    test ":strict applies to nested dictionaries" do
      assert {:error, %SyntaxError{}} = parse("d1:ad1:bi1e1:ai2eee")
    end

    test ":strict checks raw keys regardless of the :keys option" do
      assert parse!("d1:ai1e1:bi2ee", keys: :atoms!) == %{a: 1, b: 2}
      assert {:error, %SyntaxError{token: "a"}} = parse("d1:bi1e1:ai2ee", keys: :atoms!)
    end

    test ":lenient accepts unsorted keys" do
      assert parse!("d1:bi1e1:ai2ee", dicts: :lenient) == %{"a" => 2, "b" => 1}
    end

    test ":lenient keeps the first occurrence of duplicate keys" do
      assert parse!("d3:fooi1e3:fooi2ee", dicts: :lenient) == %{"foo" => 1}
    end

    test ":ordered preserves wire order" do
      assert parse!("d1:bi1e1:ai2ee", dicts: :ordered) ==
               %Bento.OrderedDict{values: [{"b", 1}, {"a", 2}]}
    end

    test "invalid option values raise ArgumentError" do
      assert_raise ArgumentError, fn -> parse!("de", dicts: :bogus) end
    end
  end

  describe "parse_prefix/2" do
    test "returns the value and the remaining bytes" do
      assert parse_prefix("i1ei2e") == {:ok, 1, "i2e"}
      assert parse_prefix("3:foo3:bar") == {:ok, "foo", "3:bar"}
      assert parse_prefix("d1:ai1ee") == {:ok, %{"a" => 1}, ""}
    end

    test "still rejects invalid prefixes" do
      assert {:error, %SyntaxError{position: 0}} = parse_prefix("x")
      assert {:error, %SyntaxError{position: 4}} = parse_prefix("li1e")
    end
  end

  test "deeply nested input does not exhaust the call stack" do
    depth = 1_000_000
    nested = String.duplicate("l", depth) <> String.duplicate("e", depth)

    result = parse!(nested)
    assert is_list(result)
  end
end
