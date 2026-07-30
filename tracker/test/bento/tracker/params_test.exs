defmodule Bento.Tracker.ParamsTest do
  # Ported from chihaya's bittorrent/params_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Params

  @test_peer_id "-TEST01-6wfG2wk6wWLc"

  @valid_announce_arguments [
    %{},
    %{"peer_id" => @test_peer_id, "port" => "6881", "downloaded" => "1234", "left" => "4321"},
    %{
      "peer_id" => @test_peer_id,
      "ip" => "192.168.0.1",
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321"
    },
    %{
      "peer_id" => @test_peer_id,
      "ip" => "192.168.0.1",
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "numwant" => "28"
    },
    %{
      "peer_id" => @test_peer_id,
      "ip" => "192.168.0.1",
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "event" => "stopped"
    },
    %{
      "peer_id" => @test_peer_id,
      "ip" => "192.168.0.1",
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "event" => "started",
      "numwant" => "13"
    },
    %{
      "peer_id" => @test_peer_id,
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "no_peer_id" => "1"
    },
    %{
      "peer_id" => @test_peer_id,
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "compact" => "0",
      "no_peer_id" => "1"
    },
    %{
      "peer_id" => @test_peer_id,
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "compact" => "0",
      "no_peer_id" => "1",
      "key" => "peerKey"
    },
    %{
      "peer_id" => @test_peer_id,
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "compact" => "0",
      "no_peer_id" => "1",
      "key" => "peerKey",
      "trackerid" => "trackerId"
    },
    %{
      "peer_id" => "%3Ckey%3A+0x90%3E",
      "port" => "6881",
      "downloaded" => "1234",
      "left" => "4321",
      "compact" => "0",
      "no_peer_id" => "1",
      "key" => "peerKey",
      "trackerid" => "trackerId"
    },
    %{"peer_id" => "%3Ckey%3A+0x90%3E", "compact" => "1"},
    %{"peer_id" => "", "compact" => ""}
  ]

  @invalid_queries [
    "/announce?info_hash=%0%a"
  ]

  # See https://github.com/chihaya/chihaya/issues/334.
  @should_not_panic_queries [
    "/annnounce?info_hash=" <> @test_peer_id <> "&a",
    "/annnounce?info_hash=" <> @test_peer_id <> "&=b?"
  ]

  # The equivalent of Go's url.Values.Encode: keys sorted, keys and
  # values escaped with www-form encoding.
  defp encode_query(values) do
    values
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} ->
      URI.encode_www_form(k) <> "=" <> URI.encode_www_form(v)
    end)
  end

  test "parse_url_data/1 parses empty URL data" do
    assert {:ok, %Params{}} = Params.parse_url_data("")
  end

  test "parse_url_data/1 parses valid URL data" do
    for values <- @valid_announce_arguments do
      assert {:ok, %Params{} = parsed} =
               Params.parse_url_data("/announce?" <> encode_query(values))

      assert parsed.params == values
      assert Params.raw_path(parsed) == "/announce"
    end
  end

  test "parse_url_data/1 rejects invalid URL data" do
    for query <- @invalid_queries do
      assert {:error, %ClientError{}} = Params.parse_url_data(query)
    end
  end

  test "parse_url_data/1 does not crash on strange queries" do
    for query <- @should_not_panic_queries do
      Params.parse_url_data(query)
    end
  end

  test "parse_url_data/1 collects info_hash values in order" do
    hash_a = String.duplicate("a", 20)
    hash_b = String.duplicate("b", 20)

    assert {:ok, parsed} =
             Params.parse_url_data("/announce?info_hash=#{hash_a}&info_hash=#{hash_b}")

    assert Params.info_hashes(parsed) == [hash_a, hash_b]
  end

  test "parse_url_data/1 rejects an info_hash that is not 20 bytes" do
    assert {:error, %ClientError{message: "provided invalid infohash"}} =
             Params.parse_url_data("/announce?info_hash=deadbeef")
  end

  test "string/2 returns values for present keys and :error otherwise" do
    assert {:ok, parsed} = Params.parse_url_data("/announce?port=1234")
    assert Params.string(parsed, "port") == {:ok, "1234"}
    assert Params.string(parsed, "missing") == :error
  end

  test "uint/3 parses unsigned integers with a bit size" do
    assert {:ok, parsed} = Params.parse_url_data("/announce?port=6881&bad=x&big=70000")
    assert Params.uint(parsed, "port", 16) == {:ok, 6881}
    assert Params.uint(parsed, "missing", 16) == {:error, :key_not_found}
    assert {:error, :invalid_uint} = Params.uint(parsed, "bad", 16)
    assert {:error, :invalid_uint} = Params.uint(parsed, "big", 16)
  end

  test "raw_query/1 returns the query part unchanged" do
    assert {:ok, parsed} = Params.parse_url_data("/announce?port=1234&uploaded=0")
    assert Params.raw_query(parsed) == "port=1234&uploaded=0"
    assert Params.raw_path(parsed) == "/announce"
  end
end
