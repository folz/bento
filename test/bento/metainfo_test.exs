defmodule Bento.MetainfoTest do
  use ExUnit.Case, async: true

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

  # Some clients (e.g. Vuze/Azureus) write nonstandard "name.utf-8" and
  # "path.utf-8" keys, holding the UTF-8 encoding of torrents whose standard
  # fields use a legacy charset. See https://github.com/folz/bento/issues/14
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
