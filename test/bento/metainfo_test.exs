defmodule Bento.MetainfoTest do
  use ExUnit.Case, async: true

  doctest Bento.Metainfo

  alias Bento.Metainfo
  alias Bento.MetainfoError
  alias Bento.Metainfo.Torrent

  test "invalid torrent file raises an error" do
    assert_raise MetainfoError, fn -> Bento.torrent!("d3:foo3:bare") end
  end

  @single_file File.read!(Path.expand("./test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent"))

  test "valid torrent file (single) is decoded" do
    torrent = Bento.torrent!(@single_file)
    assert is_struct(torrent, Torrent)
    assert torrent.announce == "http://torrent.ubuntu.com:6969/announce"
    assert torrent.info.length == 1_069_547_520

    assert torrent."creation date" == ~U[2016-02-18 20:12:51Z]
  end

  @multi_file File.read!(Path.expand("./test/_data/huck_finn_librivox_archive.torrent"))

  test "valid torrent file (multi) is decoded" do
    torrent = Bento.torrent!(@multi_file)
    assert is_struct(torrent, Torrent)
    assert torrent.announce == "http://bt1.archive.org:6969/announce"

    assert torrent."creation date" == ~U[2016-01-01 17:44:59Z]

    assert length(torrent.info.files) == 321
    assert List.first(torrent.info.files).path == ["AdventuresOfHuckleberryFinn_librivox.m4b"]
    assert List.first(torrent.info.files).length == 309_931_842
  end

  # Some clients write nonstandard "name.utf-8"/"path.utf-8" keys; see issue #14.
  test "torrent file (single) with .utf-8 keys is decoded" do
    data =
      Bento.encode!(%{
        "announce" => "http://tracker.example.com/announce",
        "info" => %{
          "length" => 42,
          # "café.txt" in Latin-1, not valid UTF-8
          "name" => <<"caf", 0xE9, ".txt">>,
          "name.utf-8" => "café.txt",
          "piece length" => 16_384,
          "pieces" => <<0::160>>
        }
      })

    torrent = Bento.torrent!(data)
    assert torrent.info.name == <<"caf", 0xE9, ".txt">>
    assert torrent.info."name.utf-8" == "café.txt"
  end

  test "torrent file (multi) with .utf-8 keys is decoded" do
    data =
      Bento.encode!(%{
        "announce" => "http://tracker.example.com/announce",
        "info" => %{
          "files" => [
            %{
              "length" => 12,
              "path" => ["dir", <<"caf", 0xE9, ".txt">>],
              "path.utf-8" => ["dir", "café.txt"]
            }
          ],
          "name" => <<"f", 0xF6, "lder">>,
          "name.utf-8" => "földer",
          "piece length" => 16_384,
          "pieces" => <<0::160>>
        }
      })

    torrent = Bento.torrent!(data)
    assert torrent.info."name.utf-8" == "földer"

    file = List.first(torrent.info.files)
    assert file.path == ["dir", <<"caf", 0xE9, ".txt">>]
    assert file."path.utf-8" == ["dir", "café.txt"]
  end

  describe "info_hash/1" do
    test "computes the v1 info-hash of real torrent files" do
      assert {:ok, hash} = Metainfo.info_hash(@single_file)
      assert Base.encode16(hash, case: :lower) == "33395da120c9a4758e896ded4dec5f2495c9973f"

      assert Metainfo.info_hash!(@multi_file) |> Base.encode16(case: :lower) ==
               "a40d3a5b3e9f32a1f5540875e2188f6b7709fc58"
    end

    test "hashes the exact original bytes, even for non-canonical files" do
      # Unsorted keys inside the info dictionary: the hash must cover the
      # bytes as they appear in the file, not a canonical re-encoding.
      info = "d6:pieces20:#{<<0::160>>}4:name1:x6:lengthi1ee"
      data = "d4:info#{info}e"

      assert Metainfo.info_hash!(data) == :crypto.hash(:sha, info)
    end

    test "returns errors for invalid or v2-only metainfo" do
      assert {:error, %Bento.SyntaxError{}} = Metainfo.info_hash("garbage")
      assert {:error, "Invalid metainfo file: not a dictionary"} = Metainfo.info_hash("le")
      assert {:error, "Invalid metainfo file: missing info dictionary"} = Metainfo.info_hash("de")

      assert {:error, "Invalid metainfo file: info is not a dictionary"} =
               Metainfo.info_hash("d4:infoi42ee")

      v2_only = Bento.encode!(%{"info" => %{"meta version" => 2, "name" => "x"}})
      assert {:error, "Not a v1 torrent:" <> _} = Metainfo.info_hash(v2_only)
    end

    test "rejects duplicate info dictionaries" do
      info = "d6:lengthi1e4:name1:x6:pieces20:#{<<0::160>>}e"
      data = "d4:info#{info}4:info#{info}e"

      assert {:error, "Invalid metainfo file: duplicate info dictionary"} =
               Metainfo.info_hash(data)
    end

    test "info_hash!/1 raises on error" do
      assert_raise MetainfoError, fn -> Metainfo.info_hash!("de") end
      assert_raise Bento.SyntaxError, fn -> Metainfo.info_hash!("garbage") end
    end
  end

  describe "info_hash_v2/1" do
    test "computes the v2 info-hash of a BEP-52 torrent" do
      info = %{
        "file tree" => %{"x" => %{"" => %{"length" => 1, "pieces root" => <<0::256>>}}},
        "meta version" => 2,
        "name" => "x",
        "piece length" => 16_384
      }

      data = Bento.encode!(%{"info" => info})

      assert {:ok, hash} = Metainfo.info_hash_v2(data)
      assert hash == :crypto.hash(:sha256, Bento.encode!(info))
      assert Metainfo.info_hash_v2!(data) == hash
    end

    test "returns an error for v1 torrents" do
      assert {:error, "Not a v2 torrent:" <> _} = Metainfo.info_hash_v2(@single_file)
      assert_raise MetainfoError, fn -> Metainfo.info_hash_v2!(@single_file) end
    end
  end

  test "unknown metainfo keys are allowed and ignored" do
    data =
      Bento.encode!(%{
        "announce" => "http://tracker.example.com/announce",
        "publisher" => "nobody",
        "info" => %{
          "length" => 42,
          "name" => "file.txt",
          "name.weird" => "file.txt",
          "piece length" => 16_384,
          "pieces" => <<0::160>>
        }
      })

    torrent = Bento.torrent!(data)
    assert torrent.info.name == "file.txt"
    refute Map.has_key?(torrent, :publisher)
    refute Map.has_key?(torrent.info, :"name.weird")
  end
end
