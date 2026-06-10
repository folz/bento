defmodule Bento.BencodeTestSuite do
  @moduledoc """
  Conformance suite driven by the vector files in `test/bencode_test_suite/`.

  File name prefixes follow the usual convention:

    * `y_` - input every BEP-3 conforming parser must accept,
    * `n_` - input every BEP-3 conforming parser must reject,
    * `i_` - implementation-defined behavior; expectations are encoded
      explicitly below.
  """

  use ExUnit.Case, async: true

  alias Bento.SyntaxError

  for path <- Path.wildcard(Path.join(__DIR__, "bencode_test_suite/*.bencode")) do
    case Path.basename(path) do
      "y_" <> name ->
        test "accepts #{name}" do
          data = File.read!(unquote(path))
          assert {:ok, _} = Bento.decode(data)
        end

      "n_" <> name ->
        test "rejects #{name}" do
          data = File.read!(unquote(path))
          assert {:error, %SyntaxError{position: position}} = Bento.decode(data)
          assert is_integer(position)
          assert position >= 0 and position <= byte_size(data)
        end

      "i_" <> _name ->
        :ok
    end
  end

  describe "implementation-defined vectors" do
    test "i_dict_unsorted_keys: rejected by default, accepted by dicts: :lenient" do
      data = File.read!(Path.join(__DIR__, "bencode_test_suite/i_dict_unsorted_keys.bencode"))

      assert {:error, %SyntaxError{}} = Bento.decode(data)
      assert {:ok, %{"a" => 2, "b" => 1}} = Bento.decode(data, dicts: :lenient)
    end

    test "i_dict_duplicate_key: rejected by default, first occurrence wins with dicts: :lenient" do
      data = File.read!(Path.join(__DIR__, "bencode_test_suite/i_dict_duplicate_key.bencode"))

      assert {:error, %SyntaxError{}} = Bento.decode(data)
      assert {:ok, %{"foo" => 1}} = Bento.decode(data, dicts: :lenient)
    end

    test "i_integer_1025_digits: rejected by the default digit limit" do
      data = File.read!(Path.join(__DIR__, "bencode_test_suite/i_integer_1025_digits.bencode"))

      assert {:error, %SyntaxError{position: 1}} = Bento.decode(data)
    end

    test "y_ vectors round-trip byte-for-byte" do
      # All y_ vectors here are canonical, so decode |> encode is the
      # identity on bytes.
      for path <- Path.wildcard(Path.join(__DIR__, "bencode_test_suite/y_*.bencode")) do
        data = File.read!(path)
        assert data |> Bento.decode!() |> Bento.encode!() == data, Path.basename(path)
      end
    end

    test "y_ vectors also pass dicts: :lenient and dicts: :ordered" do
      for path <- Path.wildcard(Path.join(__DIR__, "bencode_test_suite/y_*.bencode")) do
        data = File.read!(path)
        assert {:ok, _} = Bento.decode(data, dicts: :lenient)
        assert {:ok, _} = Bento.decode(data, dicts: :ordered)
      end
    end
  end
end
