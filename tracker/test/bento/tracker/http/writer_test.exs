defmodule Bento.Tracker.HTTP.WriterTest do
  # Ported from chihaya's frontend/http/writer_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.HTTP.Writer
  alias Bento.Tracker.Peer
  alias Bento.Tracker.Scrape
  alias Bento.Tracker.ScrapeResponse

  defp encode(iodata), do: IO.iodata_to_binary(iodata)

  describe "write_error/1" do
    @error_table [
      {"hello world", "d14:failure reason11:hello worlde"},
      {"what's up", "d14:failure reason9:what's upe"},
      {"something is missing", "d14:failure reason20:something is missinge"}
    ]

    test "encodes a client error as a failure reason dictionary" do
      for {reason, expected} <- @error_table do
        assert encode(Writer.write_error(ClientError.new(reason))) == expected
      end
    end

    test "a non-client error is written as an internal server error" do
      assert encode(Writer.write_error(:some_internal_error)) ==
               "d14:failure reason21:internal server errore"
    end
  end

  describe "write_announce_response/1" do
    test "compact response packs IPv4 peers into the peers key" do
      response = %AnnounceResponse{
        compact?: true,
        complete: 1,
        incomplete: 2,
        interval: 1800,
        min_interval: 900,
        ipv4_peers: [%Peer{id: String.duplicate("a", 20), ip: {1, 2, 3, 4}, port: 6881}]
      }

      # 6881 = 0x1AE1
      expected =
        "d8:completei1e10:incompletei2e8:intervali1800e12:min intervali900e" <>
          "5:peers6:" <> <<1, 2, 3, 4, 0x1A, 0xE1>> <> "e"

      assert encode(Writer.write_announce_response(response)) == expected
    end

    test "compact response packs IPv6 peers into the peers6 key" do
      {:ok, ip} = :inet.parse_address(~c"2001:db8::1")

      response = %AnnounceResponse{
        compact?: true,
        complete: 0,
        incomplete: 1,
        interval: 60,
        min_interval: 60,
        ipv6_peers: [%Peer{id: String.duplicate("b", 20), ip: ip, port: 6881}]
      }

      # 2001:0db8:0000:0000:0000:0000:0000:0001 as 16 bytes
      ip_bytes = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>

      expected =
        "d8:completei0e10:incompletei1e8:intervali60e12:min intervali60e" <>
          "6:peers618:" <> ip_bytes <> <<0x1A, 0xE1>> <> "e"

      assert encode(Writer.write_announce_response(response)) == expected
    end

    test "compact response omits empty peer lists" do
      response = %AnnounceResponse{compact?: true, interval: 60, min_interval: 30}

      assert encode(Writer.write_announce_response(response)) ==
               "d8:completei0e10:incompletei0e8:intervali60e12:min intervali30ee"
    end

    test "non-compact response lists peer dictionaries" do
      response = %AnnounceResponse{
        compact?: false,
        complete: 1,
        incomplete: 0,
        interval: 1800,
        min_interval: 900,
        ipv4_peers: [%Peer{id: String.duplicate("a", 20), ip: {1, 2, 3, 4}, port: 6881}]
      }

      # Each peer dict has canonically sorted keys: ip, peer id, port.
      peer = "d2:ip7:1.2.3.47:peer id20:aaaaaaaaaaaaaaaaaaaa4:porti6881ee"

      expected =
        "d8:completei1e10:incompletei0e8:intervali1800e12:min intervali900e" <>
          "5:peersl" <> peer <> "ee"

      assert encode(Writer.write_announce_response(response)) == expected
    end
  end

  describe "write_scrape_response/1" do
    test "encodes a files dictionary keyed by infohash" do
      response = %ScrapeResponse{
        files: [
          %Scrape{info_hash: String.duplicate("a", 20), complete: 1, incomplete: 0},
          %Scrape{info_hash: String.duplicate("b", 20), complete: 3, incomplete: 4}
        ]
      }

      expected =
        "d5:filesd" <>
          "20:aaaaaaaaaaaaaaaaaaaad8:completei1e10:incompletei0ee" <>
          "20:bbbbbbbbbbbbbbbbbbbbd8:completei3e10:incompletei4ee" <>
          "ee"

      assert encode(Writer.write_scrape_response(response)) == expected
    end

    test "encodes an empty files dictionary" do
      assert encode(Writer.write_scrape_response(%ScrapeResponse{})) == "d5:filesdee"
    end
  end
end
