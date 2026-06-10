if Code.ensure_loaded?(ExUnitProperties) do
  defmodule Bento.PropertyTest do
    use ExUnit.Case, async: true
    use ExUnitProperties

    alias Bento.SyntaxError

    property "encode/decode round-trip for binary-keyed data" do
      check all(term <- bencodable(binary())) do
        assert term |> Bento.encode!() |> Bento.decode!() == term
      end
    end

    property "canonical encoding is a fixed point of decode |> encode" do
      check all(term <- bencodable(binary())) do
        bytes = Bento.encode!(term)
        assert bytes |> Bento.decode!() |> Bento.encode!() == bytes
      end
    end

    property "encoded dictionaries are canonical, even from atom keys" do
      # Each map draws keys from a single style: a map mixing :a and "a"
      # is rejected by the encoder (collision after normalization).
      check all(term <- bencodable([binary(), atom(:alphanumeric)])) do
        bytes = Bento.encode!(term)
        # The default :strict mode verifies key order and uniqueness.
        assert {:ok, _} = Bento.decode(bytes)
      end
    end

    property "atom-keyed maps round-trip with keys: :atoms!" do
      check all(map <- map_of(atom(:alphanumeric), integer())) do
        assert map |> Bento.encode!() |> Bento.decode!(keys: :atoms!) == map
      end
    end

    property "ordered decoding re-encodes byte-for-byte" do
      check all(term <- bencodable(binary())) do
        bytes = Bento.encode!(term)
        assert bytes |> Bento.decode!(dicts: :ordered) |> Bento.encode!() == bytes
      end
    end

    property "strings: :copy decodes to equal values" do
      check all(term <- bencodable(binary())) do
        bytes = Bento.encode!(term)
        assert Bento.decode!(bytes, strings: :copy) == Bento.decode!(bytes)
      end
    end

    property "decoding mutated input returns a positioned error or a value, never crashes" do
      check all(
              term <- bencodable(binary()),
              index <- non_negative_integer(),
              replacement <- integer(0..255)
            ) do
        bytes = Bento.encode!(term)
        index = rem(index, byte_size(bytes))

        <<prefix::binary-size(index), _byte, suffix::binary>> = bytes
        mutated = <<prefix::binary, replacement, suffix::binary>>

        case Bento.decode(mutated) do
          {:ok, _} ->
            :ok

          {:error, %SyntaxError{position: position} = error} ->
            assert position >= 0 and position <= byte_size(mutated)
            # Messages must stay bounded no matter the input.
            assert byte_size(Exception.message(error)) < 200
        end
      end
    end

    property "decoding truncated input returns a positioned error, never crashes" do
      check all(
              term <- bencodable(binary()),
              cut <- positive_integer()
            ) do
        bytes = Bento.encode!(term)
        cut = rem(cut, byte_size(bytes)) + 1
        truncated = binary_part(bytes, 0, byte_size(bytes) - cut)

        assert {:error, %SyntaxError{position: position}} = Bento.decode(truncated)
        assert position >= 0 and position <= byte_size(truncated)
      end
    end

    defp bencodable(key_generator_or_generators) do
      key_generators = List.wrap(key_generator_or_generators)
      simple = one_of([integer(), binary()])

      tree(simple, fn child ->
        one_of([list_of(child) | Enum.map(key_generators, &map_of(&1, child))])
      end)
    end
  end
end
