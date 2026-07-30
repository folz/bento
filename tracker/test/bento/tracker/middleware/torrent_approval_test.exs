defmodule Bento.Tracker.Middleware.TorrentApprovalTest do
  # Ported from chihaya's middleware/torrentapproval/torrentapproval_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Middleware.TorrentApproval
  alias Bento.Tracker.Peer

  @err_torrent_unapproved %ClientError{message: "unapproved torrent"}

  @cases [
    # Infohash is whitelisted
    {%{whitelist: ["3532cf2d327fad8448c075b4cb42c8136964a435"]},
     "3532cf2d327fad8448c075b4cb42c8136964a435", true},
    # Infohash is not whitelisted
    {%{whitelist: ["3532cf2d327fad8448c075b4cb42c8136964a435"]},
     "4532cf2d327fad8448c075b4cb42c8136964a435", false},
    # Infohash is not blacklisted
    {%{blacklist: ["3532cf2d327fad8448c075b4cb42c8136964a435"]},
     "4532cf2d327fad8448c075b4cb42c8136964a435", true},
    # Infohash is blacklisted
    {%{blacklist: ["3532cf2d327fad8448c075b4cb42c8136964a435"]},
     "3532cf2d327fad8448c075b4cb42c8136964a435", false}
  ]

  test "handle_announce approves and rejects by infohash" do
    for {config, ih_hex, approved} <- @cases do
      assert {:ok, state} = TorrentApproval.new(config)

      request = %AnnounceRequest{
        info_hash: Base.decode16!(ih_hex, case: :lower),
        peer: %Peer{id: String.duplicate("p", 20), ip: {1, 2, 3, 4}, port: 1}
      }

      result = TorrentApproval.handle_announce(state, %{}, request, %AnnounceResponse{})

      if approved do
        assert {:ok, %{}, %AnnounceResponse{}} = result
      else
        assert result == {:error, @err_torrent_unapproved}
      end
    end
  end

  test "using both whitelist and blacklist is invalid" do
    assert {:error, _reason} =
             TorrentApproval.new(%{
               whitelist: ["3532cf2d327fad8448c075b4cb42c8136964a435"],
               blacklist: ["4532cf2d327fad8448c075b4cb42c8136964a435"]
             })
  end

  test "hashes must be valid hex of 20 bytes" do
    assert {:error, _reason} = TorrentApproval.new(%{whitelist: ["nothex"]})
    assert {:error, _reason} = TorrentApproval.new(%{blacklist: ["abcdef"]})
  end
end
