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

    property "magnet links round-trip through to_string |> parse" do
      check all(magnet <- magnet()) do
        assert magnet |> Bento.Magnet.to_string() |> Bento.Magnet.parse!() == magnet
      end
    end

    property "parsing mutated magnet links returns an error or a value, never crashes" do
      check all(
              magnet <- magnet(),
              index <- non_negative_integer(),
              replacement <- integer(0..255)
            ) do
        bytes = Bento.Magnet.to_string(magnet)
        index = rem(index, byte_size(bytes))

        <<prefix::binary-size(index), _byte, suffix::binary>> = bytes
        mutated = <<prefix::binary, replacement, suffix::binary>>

        case Bento.Magnet.parse(mutated) do
          {:ok, _} ->
            :ok

          {:error, %Bento.MagnetError{} = error} ->
            # Messages must stay bounded no matter the input.
            assert byte_size(Exception.message(error)) < 200
        end
      end
    end

    defp magnet do
      gen all(
            info_hash <- binary(length: 20),
            info_hash_v2 <- one_of([constant(nil), binary(length: 32)]),
            display_name <- one_of([constant(nil), binary(min_length: 1)]),
            length <- one_of([constant(nil), non_negative_integer()]),
            trackers <- list_of(binary(min_length: 1)),
            web_seeds <- list_of(binary(min_length: 1)),
            keywords <- list_of(string(:alphanumeric, min_length: 1)),
            select_only <- list_of(select_item()),
            peers <- list_of(peer())
          ) do
        %Bento.Magnet{
          info_hash: info_hash,
          info_hash_v2: info_hash_v2,
          display_name: display_name,
          length: length,
          trackers: trackers,
          web_seeds: web_seeds,
          keywords: keywords,
          select_only: select_only,
          peers: peers
        }
      end
    end

    defp select_item do
      one_of([
        non_negative_integer(),
        gen all(first <- non_negative_integer(), span <- non_negative_integer()) do
          first..(first + span)
        end
      ])
    end

    defp peer do
      # Hosts must satisfy the RFC 1123 label grammar (up to 63 chars).
      gen all(
            host <- string(:alphanumeric, min_length: 1, max_length: 63),
            port <- integer(1..65_535)
          ) do
        "#{host}:#{port}"
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
