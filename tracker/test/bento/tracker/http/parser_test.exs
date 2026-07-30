defmodule Bento.Tracker.HTTP.ParserTest do
  # chihaya's frontend/http has no parser_test.go; these tests cover the
  # documented behavior of ParseAnnounce/ParseScrape and requestedIP.
  use ExUnit.Case, async: true

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.HTTP.Parser
  alias Bento.Tracker.HTTP.Request

  @peer_id "-TEST01-6wfG2wk6wWLc"
  @info_hash String.duplicate("a", 20)

  defp request(query, opts \\ []) do
    %Request{
      target: "/announce?" <> query,
      headers: Keyword.get(opts, :headers, %{}),
      remote_ip: Keyword.get(opts, :remote_ip, {203, 0, 113, 5})
    }
  end

  defp base_query(extra \\ %{}) do
    %{
      "info_hash" => @info_hash,
      "peer_id" => @peer_id,
      "port" => "6881",
      "left" => "100",
      "downloaded" => "0",
      "uploaded" => "0"
    }
    |> Map.merge(extra)
    |> Enum.map_join("&", fn {k, v} -> URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v) end)
  end

  test "parses a minimal valid announce" do
    assert {:ok, announce} = Parser.parse_announce(request(base_query()), %{})
    assert announce.info_hash == @info_hash
    assert announce.peer.id == @peer_id
    assert announce.peer.port == 6881
    assert announce.left == 100
    assert announce.peer.ip == {203, 0, 113, 5}
    assert announce.event == :none
    refute announce.event_provided?
    # default numwant applied by sanitize
    assert announce.numwant == 50
    refute announce.numwant_provided?
  end

  test "parses the event and marks it provided" do
    assert {:ok, announce} =
             Parser.parse_announce(request(base_query(%{"event" => "started"})), %{})

    assert announce.event == :started
    assert announce.event_provided?
  end

  test "rejects an unknown event" do
    assert Parser.parse_announce(request(base_query(%{"event" => "bogus"})), %{}) ==
             {:error, ClientError.new("failed to provide valid client event")}
  end

  test "detects a compact request" do
    assert {:ok, %{compact?: true}} =
             Parser.parse_announce(request(base_query(%{"compact" => "1"})), %{})

    assert {:ok, %{compact?: false}} =
             Parser.parse_announce(request(base_query(%{"compact" => "0"})), %{})
  end

  test "clamps and defaults numwant" do
    assert {:ok, %{numwant: 100, numwant_provided?: true}} =
             Parser.parse_announce(request(base_query(%{"numwant" => "500"})), %{max_numwant: 100})

    assert {:ok, %{numwant: 7, numwant_provided?: true}} =
             Parser.parse_announce(request(base_query(%{"numwant" => "7"})), %{max_numwant: 100})
  end

  test "requires a single info_hash" do
    assert Parser.parse_announce(
             request("peer_id=#{@peer_id}&port=6881&left=1&downloaded=0&uploaded=0"),
             %{}
           ) ==
             {:error, ClientError.new("no info_hash parameter supplied")}

    two = "info_hash=#{@info_hash}&info_hash=#{String.duplicate("b", 20)}&" <> base_query()

    assert Parser.parse_announce(
             %Request{target: "/announce?" <> two, remote_ip: {1, 2, 3, 4}},
             %{}
           ) ==
             {:error, ClientError.new("multiple info_hash parameters supplied")}
  end

  test "requires a valid peer_id" do
    assert Parser.parse_announce(request(base_query(%{"peer_id" => "short"})), %{}) ==
             {:error, ClientError.new("failed to provide valid peer_id")}
  end

  test "rejects a zero port" do
    assert Parser.parse_announce(request(base_query(%{"port" => "0"})), %{}) ==
             {:error, ClientError.new("invalid port")}
  end

  test "uses the spoofed ip when spoofing is allowed" do
    req = request(base_query(%{"ip" => "198.51.100.9"}))
    assert {:ok, announce} = Parser.parse_announce(req, %{allow_ip_spoofing: true})
    assert announce.peer.ip == {198, 51, 100, 9}
    assert announce.ip_provided?
  end

  test "ignores the ip parameter when spoofing is disabled" do
    req = request(base_query(%{"ip" => "198.51.100.9"}))
    assert {:ok, announce} = Parser.parse_announce(req, %{allow_ip_spoofing: false})
    assert announce.peer.ip == {203, 0, 113, 5}
    refute announce.ip_provided?
  end

  test "uses the real ip header when configured" do
    req = request(base_query(), headers: %{"x-real-ip" => "198.51.100.20"})
    assert {:ok, announce} = Parser.parse_announce(req, %{real_ip_header: "X-Real-IP"})
    assert announce.peer.ip == {198, 51, 100, 20}
    refute announce.ip_provided?
  end

  describe "parse_scrape/2" do
    test "collects info hashes" do
      hash_b = String.duplicate("b", 20)
      target = "/scrape?info_hash=#{@info_hash}&info_hash=#{hash_b}"
      req = %Request{target: target, remote_ip: {203, 0, 113, 5}}

      assert {:ok, scrape} = Parser.parse_scrape(req, %{})
      assert scrape.info_hashes == [@info_hash, hash_b]
    end

    test "requires at least one info hash" do
      req = %Request{target: "/scrape?", remote_ip: {203, 0, 113, 5}}

      assert Parser.parse_scrape(req, %{}) ==
               {:error, ClientError.new("no info_hash parameter supplied")}
    end

    test "truncates to the max number of info hashes" do
      hashes = for c <- ?a..?e, do: String.duplicate(<<c>>, 20)
      query = Enum.map_join(hashes, "&", &("info_hash=" <> &1))
      req = %Request{target: "/scrape?" <> query, remote_ip: {203, 0, 113, 5}}

      assert {:ok, scrape} = Parser.parse_scrape(req, %{max_scrape_info_hashes: 2})
      assert length(scrape.info_hashes) == 2
    end
  end
end
