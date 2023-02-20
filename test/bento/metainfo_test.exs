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
end
