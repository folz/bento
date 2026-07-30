defmodule Bento.Tracker.SanitizeTest do
  # chihaya's bittorrent/sanitize.go has no test file; these tests cover
  # the documented behavior of SanitizeAnnounce and SanitizeScrape.
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Peer
  alias Bento.Tracker.ScrapeRequest

  defp announce(overrides) do
    peer = %Peer{id: String.duplicate("a", 20), ip: {10, 0, 0, 1}, port: 6881}

    struct!(
      %AnnounceRequest{info_hash: String.duplicate("b", 20), peer: peer},
      overrides
    )
  end

  test "rejects port 0" do
    request = announce(peer: %Peer{id: String.duplicate("a", 20), ip: {10, 0, 0, 1}, port: 0})

    assert AnnounceRequest.sanitize(request, 100, 50) ==
             {:error, %ClientError{message: "invalid port"}}
  end

  test "applies the default numwant when none was provided" do
    assert {:ok, sanitized} =
             AnnounceRequest.sanitize(announce(numwant_provided?: false), 100, 50)

    assert sanitized.numwant == 50
  end

  test "clamps a provided numwant to the maximum" do
    request = announce(numwant_provided?: true, numwant: 200)
    assert {:ok, sanitized} = AnnounceRequest.sanitize(request, 100, 50)
    assert sanitized.numwant == 100
  end

  test "keeps a provided numwant below the maximum" do
    request = announce(numwant_provided?: true, numwant: 25)
    assert {:ok, sanitized} = AnnounceRequest.sanitize(request, 100, 50)
    assert sanitized.numwant == 25
  end

  test "normalizes an IPv4-mapped IPv6 address to IPv4" do
    peer = %Peer{
      id: String.duplicate("a", 20),
      ip: {0, 0, 0, 0, 0, 0xFFFF, 0x0A0B, 0x0C0D},
      port: 1
    }

    assert {:ok, sanitized} = AnnounceRequest.sanitize(announce(peer: peer), 100, 50)
    assert sanitized.peer.ip == {10, 11, 12, 13}
    assert Peer.address_family(sanitized.peer) == :ipv4
  end

  test "keeps a real IPv6 address as IPv6" do
    {:ok, ip} = :inet.parse_address(~c"2001:db8::1")
    peer = %Peer{id: String.duplicate("a", 20), ip: ip, port: 1}
    assert {:ok, sanitized} = AnnounceRequest.sanitize(announce(peer: peer), 100, 50)
    assert sanitized.peer.ip == ip
    assert Peer.address_family(sanitized.peer) == :ipv6
  end

  test "rejects an invalid IP" do
    peer = %Peer{id: String.duplicate("a", 20), ip: nil, port: 1}

    assert AnnounceRequest.sanitize(announce(peer: peer), 100, 50) ==
             {:error, %ClientError{message: "invalid IP"}}
  end

  test "truncates scrape requests to the max number of infohashes" do
    hashes = for c <- ?a..?e, do: String.duplicate(<<c>>, 20)
    request = %ScrapeRequest{info_hashes: hashes}

    assert {:ok, sanitized} = ScrapeRequest.sanitize(request, 2)
    assert sanitized.info_hashes == Enum.take(hashes, 2)

    assert {:ok, unchanged} = ScrapeRequest.sanitize(request, 10)
    assert unchanged.info_hashes == hashes
  end
end
