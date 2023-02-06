defmodule Bento.ParserTest do
  use ExUnit.Case, async: true

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

    assert parse!("de") == %{}
    assert parse!("d3:foodee") == %{"foo" => %{}}
    assert parse!("d11:aaaaaaaaaaai4ee") == %{"aaaaaaaaaaa" => 4}
    assert parse!("d3:food3:bar3:bazee") == %{"foo" => %{"bar" => "baz"}}
    assert parse!("d3:food3:bardeee") == %{"foo" => %{"bar" => %{}}}
  end

  test "collections" do
    assert_raise SyntaxError, fn -> parse!("ldede") end

    assert parse!("ldee") == [%{}]
    assert parse!("ldededee") == [%{}, %{}, %{}]
  end
end
