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

  test "encode returns an error tuple for unencodable values" do
    assert {:error, %Bento.EncodeError{}} = Bento.encode(%{1 => "foo"})
    assert {:error, %Bento.EncodeError{}} = Bento.encode_to_iodata(42.0)
  end

  test "decode_prefix! raises on invalid input" do
    assert_raise Bento.SyntaxError, fn -> Bento.decode_prefix!("x") end
  end
end
