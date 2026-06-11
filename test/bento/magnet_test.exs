defmodule Bento.MagnetTest do
  use ExUnit.Case, async: true

  doctest Bento.Magnet

  alias Bento.{Magnet, MagnetError}

  @hex "c12fe1c06bba254a9dc9f519b335aa7c1367a88a"
  @raw Base.decode16!(@hex, case: :lower)
  @base32 Base.encode32(@raw, padding: false)

  # The BEP-52 example info-hash.
  @v2_hex "caf1e1c30e81cb361b9ee167c4aa64228a7fa4fa9f6105232b28ad099f3a302e"
  @v2_raw Base.decode16!(@v2_hex, case: :lower)

  describe "parse/1" do
    test "parses a minimal magnet URI" do
      assert {:ok, magnet} = Magnet.parse("magnet:?xt=urn:btih:#{@hex}")
      assert magnet.info_hash == @raw
      assert magnet.info_hash_v2 == nil
      assert magnet.display_name == nil
      assert magnet.trackers == []
    end

    test "parses every supported parameter" do
      uri =
        "magnet:?xt=urn:btih:#{@hex}" <>
          "&dn=Example+%26+File" <>
          "&xl=123456789" <>
          "&tr=udp%3A%2F%2Ftracker.example.com%3A80" <>
          "&tr=http%3A%2F%2Fbackup.example.org%2Fannounce" <>
          "&ws=http%3A%2F%2Fmirror.example%2Ffile" <>
          "&as=http%3A%2F%2Fsource.example%2Ffile" <>
          "&xs=http%3A%2F%2Fcache.example%2Ffile.torrent" <>
          "&kt=red+hat&kt=linux" <>
          "&so=0,2,4-6" <>
          "&x.pe=192.0.2.7:6881&x.pe=%5B2001%3Adb8%3A%3A1%5D:6881"

      assert {:ok, magnet} = Magnet.parse(uri)
      assert magnet.info_hash == @raw
      assert magnet.display_name == "Example & File"
      assert magnet.length == 123_456_789

      assert magnet.trackers == [
               "udp://tracker.example.com:80",
               "http://backup.example.org/announce"
             ]

      assert magnet.web_seeds == ["http://mirror.example/file"]
      assert magnet.acceptable_sources == ["http://source.example/file"]
      assert magnet.exact_sources == ["http://cache.example/file.torrent"]
      assert magnet.keywords == ["red", "hat", "linux"]
      assert magnet.select_only == [0, 2, 4..6]
      assert magnet.peers == ["192.0.2.7:6881", "[2001:db8::1]:6881"]
    end

    test "accepts base32 info-hashes, uppercase and lowercase" do
      assert Magnet.parse!("magnet:?xt=urn:btih:#{@base32}").info_hash == @raw
      assert Magnet.parse!("magnet:?xt=urn:btih:#{String.downcase(@base32)}").info_hash == @raw
    end

    test "accepts uppercase hex info-hashes" do
      assert Magnet.parse!("magnet:?xt=urn:btih:#{String.upcase(@hex)}").info_hash == @raw
    end

    test "accepts case-insensitive scheme and URN prefix" do
      assert Magnet.parse!("MAGNET:?xt=URN:BTIH:#{@hex}").info_hash == @raw
    end

    test "parses v2 and hybrid exact topics" do
      assert {:ok, v2} = Magnet.parse("magnet:?xt=urn:btmh:1220#{@v2_hex}")
      assert v2.info_hash == nil
      assert v2.info_hash_v2 == @v2_raw

      assert {:ok, hybrid} =
               Magnet.parse("magnet:?xt=urn:btih:#{@hex}&xt=urn:btmh:1220#{@v2_hex}")

      assert hybrid.info_hash == @raw
      assert hybrid.info_hash_v2 == @v2_raw
    end

    test "treats numbered parameters as their base parameter" do
      assert {:ok, magnet} = Magnet.parse("magnet:?xt.1=urn:btih:#{@hex}&tr.1=a&tr.2=b")
      assert magnet.info_hash == @raw
      assert magnet.trackers == ["a", "b"]
    end

    test "ignores unknown parameters, empty values, and fragments" do
      uri = "magnet:?xt=urn:btih:#{@hex}&dn=&future=yes&&x=1#fragment&tr=gone"
      assert {:ok, magnet} = Magnet.parse(uri)
      assert magnet.info_hash == @raw
      assert magnet.display_name == nil
      assert magnet.trackers == []
    end

    test "trims surrounding whitespace" do
      assert {:ok, _} = Magnet.parse("  magnet:?xt=urn:btih:#{@hex}\n")
    end

    test "percent-decodes UTF-8 display names" do
      assert Magnet.parse!("magnet:?xt=urn:btih:#{@hex}&dn=caf%C3%A9").display_name == "café"
    end

    test "rejects non-magnet URIs" do
      for uri <- ["", "http://example.com/?xt=urn:btih:#{@hex}", "magnet:", "magnet"] do
        assert {:error, %MagnetError{message: "Not a magnet URI:" <> _}} = Magnet.parse(uri)
      end
    end

    test "rejects magnet URIs without an exact topic" do
      assert {:error, %MagnetError{message: "Missing exact topic:" <> _}} =
               Magnet.parse("magnet:?dn=name&tr=udp%3A%2F%2Fexample")
    end

    test "rejects unsupported exact topics" do
      assert {:error, %MagnetError{message: "Unsupported exact topic" <> _}} =
               Magnet.parse("magnet:?xt=urn:ed2k:31d6cfe0d16ae931b73c59d7e0c089c0")

      assert {:error, %MagnetError{message: "Unsupported exact topic" <> _}} =
               Magnet.parse("magnet:?xt=oops")
    end

    test "rejects malformed info-hashes" do
      for xt <- [
            # bad length
            "urn:btih:abcdef",
            # 40 chars, not hex
            "urn:btih:" <> String.duplicate("zz", 20),
            # 32 chars, not base32 (0 and 1 are not in the alphabet)
            "urn:btih:" <> String.duplicate("01", 16),
            # v2: valid hex, wrong multihash prefix
            "urn:btmh:1120" <> @v2_hex,
            # v2: truncated digest
            "urn:btmh:1220" <> binary_part(@v2_hex, 0, 62),
            # v2: not hex
            "urn:btmh:zz20" <> @v2_hex
          ] do
        assert {:error, %MagnetError{}} = Magnet.parse("magnet:?xt=" <> xt)
      end
    end

    test "rejects repeated single-valued parameters" do
      base = "magnet:?xt=urn:btih:#{@hex}"

      for uri <- [
            base <> "&xt=urn:btih:#{String.upcase(@hex)}",
            base <> "&xt=urn:btmh:1220#{@v2_hex}&xt=urn:btmh:1220#{@v2_hex}",
            base <> "&dn=a&dn=b",
            base <> "&xl=1&xl=2",
            base <> "&so=1&so=2"
          ] do
        assert {:error, %MagnetError{message: "Duplicate parameter:" <> _}} = Magnet.parse(uri)
      end
    end

    test "rejects malformed percent-encoding" do
      for dn <- ["%zz", "%a", "100%", "%%41"] do
        assert {:error, %MagnetError{message: "Malformed percent-encoding" <> _}} =
                 Magnet.parse("magnet:?xt=urn:btih:#{@hex}&dn=#{dn}")
      end
    end

    test "rejects malformed lengths" do
      # "42%0A" decodes to "42\n": a `$`-anchored digit check would pass it.
      for xl <- ["-1", "1.5", "abc", "1e3", "+1", "42%0A", String.duplicate("9", 21)] do
        assert {:error, %MagnetError{message: "Invalid exact length" <> _}} =
                 Magnet.parse("magnet:?xt=urn:btih:#{@hex}&xl=#{xl}")
      end
    end

    test "rejects malformed select-only values" do
      for so <- ["x", "1,", ",1", "1,,2", "3-1", "1-", "-1", "1-2-3", "1%0A"] do
        assert {:error, %MagnetError{message: "Invalid select-only" <> _}} =
                 Magnet.parse("magnet:?xt=urn:btih:#{@hex}&so=#{so}")
      end
    end

    test "rejects malformed peer addresses" do
      for peer <- ["nohost", "host:", ":6881", "host:0", "host:65536", "host:abc", "h:1%0A"] do
        assert {:error, %MagnetError{message: "Invalid peer address" <> _}} =
                 Magnet.parse("magnet:?xt=urn:btih:#{@hex}&x.pe=#{peer}")
      end
    end

    test "error messages stay bounded on oversized values" do
      huge = String.duplicate("a", 100_000)
      assert {:error, error} = Magnet.parse("magnet:?xt=urn:btih:#{huge}")
      assert byte_size(error.message) < 200
    end

    test "parse!/1 raises on malformed input" do
      assert_raise MagnetError, fn -> Magnet.parse!("magnet:?dn=x") end
    end
  end

  describe "to_string/1" do
    test "round-trips a fully populated struct" do
      magnet = %Magnet{
        info_hash: @raw,
        info_hash_v2: @v2_raw,
        display_name: "Example & File",
        length: 42,
        trackers: ["udp://tracker.example.com:80"],
        web_seeds: ["http://mirror.example/file"],
        acceptable_sources: ["http://source.example/file"],
        exact_sources: ["http://cache.example/file.torrent"],
        keywords: ["red", "hat"],
        select_only: [0, 2, 4..6],
        peers: ["192.0.2.7:6881", "[2001:db8::1]:6881"]
      }

      assert magnet |> Magnet.to_string() |> Magnet.parse!() == magnet
    end

    test "emits parameters in conventional order" do
      magnet = %Magnet{info_hash: @raw, display_name: "x", length: 1, trackers: ["t"]}
      assert Magnet.to_string(magnet) == "magnet:?xt=urn:btih:#{@hex}&dn=x&xl=1&tr=t"
    end

    test "emits both topics for hybrid torrents" do
      assert Magnet.to_string(%Magnet{info_hash: @raw, info_hash_v2: @v2_raw}) ==
               "magnet:?xt=urn:btih:#{@hex}&xt=urn:btmh:1220#{@v2_hex}"
    end

    test "leaves colons and brackets raw in peer addresses" do
      magnet = %Magnet{info_hash: @raw, peers: ["[2001:db8::1]:6881"]}
      assert Magnet.to_string(magnet) =~ "&x.pe=[2001:db8::1]:6881"
    end

    test "skips nil and empty values" do
      magnet = %Magnet{info_hash: @raw, display_name: "", trackers: ["", "t"]}
      assert Magnet.to_string(magnet) == "magnet:?xt=urn:btih:#{@hex}&tr=t"
    end

    test "implements String.Chars" do
      assert "#{%Magnet{info_hash: @raw}}" == "magnet:?xt=urn:btih:#{@hex}"
    end

    test "raises without an info-hash" do
      assert_raise MagnetError, "Cannot render a magnet URI without an info-hash", fn ->
        Magnet.to_string(%Magnet{display_name: "x"})
      end
    end

    test "raises on invalid field values" do
      for magnet <- [
            %Magnet{info_hash: "too short"},
            %Magnet{info_hash: @raw <> "x"},
            %Magnet{info_hash_v2: @raw},
            %Magnet{info_hash: @raw, length: -1},
            %Magnet{info_hash: @raw, display_name: 42},
            %Magnet{info_hash: @raw, trackers: [:not_a_string]},
            %Magnet{info_hash: @raw, trackers: "not a list"},
            %Magnet{info_hash: @raw, keywords: ["two words"]},
            %Magnet{info_hash: @raw, select_only: [-1]},
            %Magnet{info_hash: @raw, select_only: [3..1//-1]},
            %Magnet{info_hash: @raw, select_only: [0..6//2]}
          ] do
        assert_raise MagnetError, fn -> Magnet.to_string(magnet) end
      end
    end
  end

  describe "from_torrent/1" do
    @single_file File.read!(Path.expand("./test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent"))
    @multi_file File.read!(Path.expand("./test/_data/huck_finn_librivox_archive.torrent"))

    test "builds a magnet link from a single-file torrent" do
      assert {:ok, magnet} = Magnet.from_torrent(@single_file)

      # Independently computed: the SHA-1 of the raw info dictionary bytes,
      # sliced straight out of the file (see "matches a raw byte slice").
      assert Base.encode16(magnet.info_hash, case: :lower) ==
               "33395da120c9a4758e896ded4dec5f2495c9973f"

      assert magnet.info_hash_v2 == nil
      assert magnet.display_name == "ubuntu-14.04.4-desktop-amd64.iso"
      assert magnet.length == 1_069_547_520

      assert magnet.trackers == [
               "http://torrent.ubuntu.com:6969/announce",
               "http://ipv6.torrent.ubuntu.com:6969/announce"
             ]
    end

    test "builds a magnet link from a multi-file torrent" do
      assert {:ok, magnet} = Magnet.from_torrent(@multi_file)

      assert Base.encode16(magnet.info_hash, case: :lower) ==
               "a40d3a5b3e9f32a1f5540875e2188f6b7709fc58"

      assert magnet.display_name == "huck_finn_librivox"

      # The sum of all 321 file lengths.
      torrent = Bento.torrent!(@multi_file)
      assert magnet.length == torrent.info.files |> Enum.map(& &1.length) |> Enum.sum()

      # BEP-19 url-list entries become web seeds.
      assert "https://archive.org/download/" in magnet.web_seeds
    end

    test "info-hash matches a raw byte slice of the torrent file" do
      for bytes <- [@single_file, @multi_file] do
        # An independent oracle: the info value's bytes are located by
        # parsing one value off the input right after the "info" key.
        {pos, 6} = :binary.match(bytes, "4:info")
        start = pos + 6
        value_and_rest = binary_part(bytes, start, byte_size(bytes) - start)
        {_value, rest} = Bento.decode_prefix!(value_and_rest)
        info_bytes = binary_part(value_and_rest, 0, byte_size(value_and_rest) - byte_size(rest))

        assert Magnet.from_torrent!(bytes).info_hash == :crypto.hash(:sha, info_bytes)
      end
    end

    test "hashes the original bytes of non-canonical files" do
      # Unsorted info keys: hashing a re-sorted re-encoding would produce a
      # different (wrong) hash than clients hashing the file as-is.
      info = "d6:pieces20:#{<<0::160>>}4:name7:example6:lengthi42e12:piece lengthi16384ee"
      torrent = "d8:announce7:udp://t4:info#{info}e"

      assert Magnet.from_torrent!(torrent).info_hash == :crypto.hash(:sha, info)
    end

    test "prefers the nonstandard name.utf-8 key for the display name" do
      data =
        Bento.encode!(%{
          "info" => %{
            "length" => 1,
            "name" => <<"caf", 0xE9>>,
            "name.utf-8" => "café",
            "pieces" => <<0::160>>
          }
        })

      assert Magnet.from_torrent!(data).display_name == "café"
    end

    test "uses announce when announce-list is absent or empty" do
      base = %{"info" => %{"length" => 1, "name" => "x", "pieces" => <<0::160>>}}

      data = Bento.encode!(Map.put(base, "announce", "udp://a"))
      assert Magnet.from_torrent!(data).trackers == ["udp://a"]

      data = Bento.encode!(base |> Map.put("announce", "udp://a") |> Map.put("announce-list", []))
      assert Magnet.from_torrent!(data).trackers == ["udp://a"]

      assert Magnet.from_torrent!(Bento.encode!(base)).trackers == []
    end

    test "flattens and deduplicates announce-list tiers" do
      data =
        Bento.encode!(%{
          "announce" => "udp://a",
          "announce-list" => [["udp://a", "udp://b"], ["udp://a"], ["udp://c"]],
          "info" => %{"length" => 1, "name" => "x", "pieces" => <<0::160>>}
        })

      assert Magnet.from_torrent!(data).trackers == ["udp://a", "udp://b", "udp://c"]
    end

    test "builds a hybrid magnet link from a BEP-52 hybrid torrent" do
      data =
        Bento.encode!(%{
          "info" => %{
            "file tree" => %{"x" => %{"" => %{"length" => 42, "pieces root" => <<0::256>>}}},
            "length" => 42,
            "meta version" => 2,
            "name" => "x",
            "piece length" => 16_384,
            "pieces" => <<0::160>>
          }
        })

      magnet = Magnet.from_torrent!(data)
      assert byte_size(magnet.info_hash) == 20
      assert byte_size(magnet.info_hash_v2) == 32
      assert magnet.length == 42
    end

    test "builds a v2-only magnet link with the file tree's total length" do
      info = %{
        "file tree" => %{
          "dir" => %{
            "a.txt" => %{"" => %{"length" => 10, "pieces root" => <<0::256>>}},
            "b.txt" => %{"" => %{"length" => 20, "pieces root" => <<1::256>>}}
          },
          "c.txt" => %{"" => %{"length" => 30, "pieces root" => <<2::256>>}}
        },
        "meta version" => 2,
        "name" => "x",
        "piece length" => 16_384
      }

      data = Bento.encode!(%{"info" => info})
      magnet = Magnet.from_torrent!(data)

      assert magnet.info_hash == nil
      assert magnet.info_hash_v2 == :crypto.hash(:sha256, Bento.encode!(info))
      assert magnet.length == 60
    end

    test "rejects data that is not a metainfo dictionary" do
      assert {:error, %Bento.SyntaxError{}} = Magnet.from_torrent("not bencoding")
      assert {:error, %MagnetError{message: msg}} = Magnet.from_torrent("i42e")
      assert msg == "Invalid metainfo file: not a dictionary"

      assert {:error, %MagnetError{}} = Magnet.from_torrent("de")
      assert {:error, %MagnetError{}} = Magnet.from_torrent("d4:infoi42ee")

      # An info dictionary that is neither v1 nor v2.
      assert {:error, %MagnetError{}} =
               Magnet.from_torrent(Bento.encode!(%{"info" => %{"name" => "x"}}))
    end

    test "rejects duplicate info dictionaries" do
      info = "d6:lengthi1e4:name1:x6:pieces20:#{<<0::160>>}e"
      data = "d4:info#{info}4:info#{info}e"

      assert {:error, %MagnetError{message: msg}} = Magnet.from_torrent(data)
      assert msg == "Invalid metainfo file: duplicate info dictionary"
    end

    test "from_torrent!/1 raises on error" do
      assert_raise MagnetError, fn -> Magnet.from_torrent!("de") end
      assert_raise Bento.SyntaxError, fn -> Magnet.from_torrent!("oops") end
    end
  end
end
