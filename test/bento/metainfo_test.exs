defmodule Bento.MetainfoTest do
  use ExUnit.Case, async: true

  alias Bento.MetainfoError
  alias Bento.Metainfo.Torrent

  test "invalid torrent file raises an error" do
    assert_raise MetainfoError, fn -> Bento.torrent!("d3:foo3:bare") end
  end

  test "valid torrent file is decoded" do
    raw = File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
    assert Bento.torrent!(raw).__struct__ == Torrent
  end

end
