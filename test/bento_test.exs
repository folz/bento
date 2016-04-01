defmodule BentoTest do
  use ExUnit.Case, async: true
  doctest Bento

  test "encode and decode are inverse for single" do
    raw = File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
    assert raw |> Bento.decode!() |> Bento.encode!() == raw
  end

  test "encode and decode are inverse for multi" do
    raw = File.read!("test/_data/huck_finn_librivox_archive.torrent")
    assert raw |> Bento.decode!() |> Bento.encode!() == raw
  end

  test "UTF-8 stress test" do
    raw = File.read!("test/_data/UTF-8-demo.txt")
    assert raw |> Bento.encode!() |> Bento.decode!() == raw
  end
end
