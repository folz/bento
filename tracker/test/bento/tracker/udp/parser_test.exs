defmodule Bento.Tracker.UDP.ParserTest do
  # Ported from chihaya's frontend/udp/parser_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Params
  alias Bento.Tracker.UDP.Parser

  @err_malformed_packet ClientError.new("malformed packet")

  # {data bytes, expected key/value map or nil, expected error or nil}
  @table [
    {<<0x2, 0x5, ?/, ??, ?a, ?=, ?b>>, %{"a" => "b"}, nil},
    {<<0x2, 0x0>>, %{}, nil},
    {<<0x2, 0x1>>, nil, @err_malformed_packet},
    {<<0x2>>, nil, @err_malformed_packet},
    {<<0x2, 0x8, ?/, ?c, ?/, ?d, ??, ?a, ?=, ?b>>, %{"a" => "b"}, nil},
    {<<0x2, 0x2, ?/, ??, 0x2, 0x3, ?a, ?=, ?b>>, %{"a" => "b"}, nil},
    {<<0x2, 0x9, ?/, ??, ?a, ?=, ?b, ?%, ?2, ?0, ?c>>, %{"a" => "b c"}, nil}
  ]

  test "handle_optional_parameters parses BEP 41 URLData" do
    for {data, values, error} <- @table do
      result = Parser.handle_optional_parameters(data)

      case error do
        nil ->
          assert {:ok, %Params{} = params} = result

          for {key, want} <- values do
            assert Params.string(params, key) == {:ok, want}
          end

        expected ->
          assert result == {:error, expected}
      end
    end
  end

  # A minimal BEP 15 announce packet builder.
  defp announce_packet(opts \\ []) do
    conn_id = Keyword.get(opts, :conn_id, <<0::64>>)
    tx_id = Keyword.get(opts, :tx_id, <<1, 2, 3, 4>>)
    info_hash = Keyword.get(opts, :info_hash, String.duplicate("a", 20))
    peer_id = Keyword.get(opts, :peer_id, String.duplicate("p", 20))
    downloaded = Keyword.get(opts, :downloaded, 100)
    left = Keyword.get(opts, :left, 200)
    uploaded = Keyword.get(opts, :uploaded, 50)
    event = Keyword.get(opts, :event, 0)
    ip = Keyword.get(opts, :ip, 0)
    key = Keyword.get(opts, :key, 0)
    numwant = Keyword.get(opts, :numwant, 30)
    port = Keyword.get(opts, :port, 6881)
    options = Keyword.get(opts, :options, <<>>)

    conn_id <>
      <<1::32-big>> <>
      tx_id <>
      info_hash <>
      peer_id <>
      <<downloaded::64-big, left::64-big, uploaded::64-big, event::32-big, ip::32-big,
        key::32-big, numwant::32-big, port::16-big>> <> options
  end

  describe "parse_announce/4" do
    test "parses a valid IPv4 announce" do
      packet = announce_packet(event: 2, left: 42)

      assert {:ok, announce} =
               Parser.parse_announce(packet, {203, 0, 113, 9}, false, Parser.default_options())

      assert announce.info_hash == String.duplicate("a", 20)
      assert announce.peer.id == String.duplicate("p", 20)
      assert announce.peer.port == 6881
      assert announce.peer.ip == {203, 0, 113, 9}
      assert announce.left == 42
      assert announce.downloaded == 100
      assert announce.uploaded == 50
      # event id 2 maps to :started
      assert announce.event == :started
      assert announce.event_provided?
      assert announce.numwant_provided?
    end

    test "maps BEP 15 event ids to events" do
      for {id, event} <- [{0, :none}, {1, :completed}, {2, :started}, {3, :stopped}] do
        packet = announce_packet(event: id)

        assert {:ok, announce} =
                 Parser.parse_announce(packet, {1, 2, 3, 4}, false, Parser.default_options())

        assert announce.event == event
      end
    end

    test "rejects an unknown event id" do
      packet = announce_packet(event: 4)

      assert Parser.parse_announce(packet, {1, 2, 3, 4}, false, Parser.default_options()) ==
               {:error, ClientError.new("malformed event ID")}
    end

    test "rejects a short packet" do
      assert Parser.parse_announce(<<0::97*8>>, {1, 2, 3, 4}, false, Parser.default_options()) ==
               {:error, @err_malformed_packet}
    end

    test "uses the spoofed IP when spoofing is allowed" do
      packet = announce_packet(ip: 0xC0A80001)
      opts = %{Parser.default_options() | allow_ip_spoofing: true}

      assert {:ok, announce} = Parser.parse_announce(packet, {203, 0, 113, 9}, false, opts)
      assert announce.peer.ip == {192, 168, 0, 1}
      assert announce.ip_provided?
    end

    test "clamps numwant to the maximum" do
      packet = announce_packet(numwant: 1000)
      opts = %{Parser.default_options() | max_numwant: 100}

      assert {:ok, announce} = Parser.parse_announce(packet, {1, 2, 3, 4}, false, opts)
      assert announce.numwant == 100
    end
  end

  describe "parse_scrape/3" do
    test "collects info hashes from the packet" do
      ih_a = String.duplicate("a", 20)
      ih_b = String.duplicate("b", 20)
      packet = <<0::64, 2::32-big, 9::32-big>> <> ih_a <> ih_b

      assert {:ok, scrape} = Parser.parse_scrape(packet, {1, 2, 3, 4}, Parser.default_options())
      assert scrape.info_hashes == [ih_a, ih_b]
    end

    test "rejects a packet shorter than 36 bytes" do
      assert Parser.parse_scrape(<<0::35*8>>, {1, 2, 3, 4}, Parser.default_options()) ==
               {:error, @err_malformed_packet}
    end

    test "rejects a body that is not a multiple of 20 bytes" do
      packet = <<0::128>> <> String.duplicate("a", 25)

      assert Parser.parse_scrape(packet, {1, 2, 3, 4}, Parser.default_options()) ==
               {:error, @err_malformed_packet}
    end

    test "truncates to the max number of info hashes" do
      hashes = for c <- ?a..?e, do: String.duplicate(<<c>>, 20)
      packet = <<0::128>> <> Enum.join(hashes)
      opts = %{Parser.default_options() | max_scrape_info_hashes: 2}

      assert {:ok, scrape} = Parser.parse_scrape(packet, {1, 2, 3, 4}, opts)
      assert length(scrape.info_hashes) == 2
    end
  end
end
