defmodule Bento.Tracker.BittorrentTest do
  # Ported from chihaya's bittorrent/bittorrent_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.InfoHash
  alias Bento.Tracker.Peer
  alias Bento.Tracker.PeerID

  @b <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20>>
  @expected "0102030405060708090a0b0c0d0e0f1011121314"

  test "PeerID.to_string/1 returns the base16 encoded peer ID" do
    assert @b |> PeerID.from_binary!() |> PeerID.to_string() == @expected
  end

  test "InfoHash.to_string/1 returns the base16 encoded infohash" do
    assert @b |> InfoHash.from_binary!() |> InfoHash.to_string() == @expected
  end

  test "PeerID.from_binary!/1 rejects binaries that are not 20 bytes" do
    assert_raise ArgumentError, "peer ID must be 20 bytes", fn ->
      PeerID.from_binary!(<<1, 2, 3>>)
    end
  end

  test "InfoHash.from_binary!/1 rejects binaries that are not 20 bytes" do
    assert_raise ArgumentError, "infohash must be 20 bytes", fn ->
      InfoHash.from_binary!(<<1, 2, 3>>)
    end
  end

  describe "Peer.to_string/1" do
    test "formats an IPv4 peer as <hex id>@[<ip>]:<port>" do
      peer = %Peer{id: @b, ip: {10, 11, 12, 1}, port: 1234}
      assert Peer.to_string(peer) == "#{@expected}@[10.11.12.1]:1234"
    end

    test "formats an IPv6 peer as <hex id>@[<ip>]:<port>" do
      {:ok, ip} = :inet.parse_address(~c"2001:db8::ff00:42:8329")
      peer = %Peer{id: @b, ip: ip, port: 1234}
      assert Peer.to_string(peer) == "#{@expected}@[2001:db8::ff00:42:8329]:1234"
    end
  end
end
