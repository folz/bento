defmodule BentoTest do
  use ExUnit.Case, async: true
  doctest Bento

  test "encode and decode are inverse" do
    raw = File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
    assert raw |> Bento.decode!() |> Bento.encode!() == raw
  end
end
