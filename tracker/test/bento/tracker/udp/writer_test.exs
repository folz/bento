defmodule Bento.Tracker.UDP.WriterTest do
  # chihaya's frontend/udp has no writer_test.go; these tests cover the
  # BEP 15 wire formats produced by the writer.
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Peer
  alias Bento.Tracker.Scrape
  alias Bento.Tracker.ScrapeResponse
  alias Bento.Tracker.UDP.Writer

  @tx_id <<0xDE, 0xAD, 0xBE, 0xEF>>

  defp bin(iodata), do: IO.iodata_to_binary(iodata)

  test "write_connection_id emits action 0, the txID and the connection ID" do
    conn_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
    assert bin(Writer.write_connection_id(@tx_id, conn_id)) == <<0::32-big>> <> @tx_id <> conn_id
  end

  test "write_error emits action 3, the txID, the message and a NUL" do
    body = bin(Writer.write_error(@tx_id, ClientError.new("bad connection ID")))
    assert body == <<3::32-big>> <> @tx_id <> "bad connection ID" <> <<0>>
  end

  test "write_error wraps internal errors" do
    body = bin(Writer.write_error(@tx_id, :boom))
    assert body == <<3::32-big>> <> @tx_id <> "internal error occurred: boom" <> <<0>>
  end

  test "write_announce emits action 1 with interval, counts and compact IPv4 peers" do
    response = %AnnounceResponse{
      interval: 1800,
      incomplete: 5,
      complete: 7,
      ipv4_peers: [
        %Peer{id: String.duplicate("a", 20), ip: {1, 2, 3, 4}, port: 6881},
        %Peer{id: String.duplicate("b", 20), ip: {5, 6, 7, 8}, port: 6882}
      ]
    }

    expected =
      <<1::32-big>> <>
        @tx_id <>
        <<1800::32-big, 5::32-big, 7::32-big>> <>
        <<1, 2, 3, 4, 6881::16-big, 5, 6, 7, 8, 6882::16-big>>

    assert bin(Writer.write_announce(@tx_id, response, false, false)) == expected
  end

  test "write_announce uses action 4 and IPv6 peers for the v6 action" do
    {:ok, ip} = :inet.parse_address(~c"2001:db8::1")

    response = %AnnounceResponse{
      interval: 60,
      incomplete: 1,
      complete: 0,
      ipv6_peers: [%Peer{id: String.duplicate("c", 20), ip: ip, port: 6881}]
    }

    ip_bytes = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>

    expected =
      <<4::32-big>> <>
        @tx_id <> <<60::32-big, 1::32-big, 0::32-big>> <> ip_bytes <> <<6881::16-big>>

    assert bin(Writer.write_announce(@tx_id, response, true, true)) == expected
  end

  test "write_scrape emits action 2 with complete/snatches/incomplete per file" do
    response = %ScrapeResponse{
      files: [
        %Scrape{info_hash: String.duplicate("a", 20), complete: 1, snatches: 2, incomplete: 3},
        %Scrape{info_hash: String.duplicate("b", 20), complete: 4, snatches: 5, incomplete: 6}
      ]
    }

    expected =
      <<2::32-big>> <>
        @tx_id <>
        <<1::32-big, 2::32-big, 3::32-big, 4::32-big, 5::32-big, 6::32-big>>

    assert bin(Writer.write_scrape(@tx_id, response)) == expected
  end
end
