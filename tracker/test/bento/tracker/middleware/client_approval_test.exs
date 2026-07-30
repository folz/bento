defmodule Bento.Tracker.Middleware.ClientApprovalTest do
  # Ported from chihaya's middleware/clientapproval/clientapproval_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Middleware.ClientApproval
  alias Bento.Tracker.Peer

  @err_client_unapproved %ClientError{message: "unapproved client"}

  @cases [
    # Client ID is whitelisted
    {%{whitelist: ["010203"]}, "01020304050607080900", true},
    # Client ID is not whitelisted
    {%{whitelist: ["010203"]}, "10203040506070809000", false},
    # Client ID is not blacklisted
    {%{blacklist: ["010203"]}, "00000000001234567890", true},
    # Client ID is blacklisted
    {%{blacklist: ["123456"]}, "12345678900000000000", false}
  ]

  test "handle_announce approves and rejects by client ID" do
    for {config, peer_id, approved} <- @cases do
      assert {:ok, state} = ClientApproval.new(config)

      request = %AnnounceRequest{
        info_hash: String.duplicate("i", 20),
        peer: %Peer{id: peer_id, ip: {1, 2, 3, 4}, port: 1}
      }

      result = ClientApproval.handle_announce(state, %{}, request, %AnnounceResponse{})

      if approved do
        assert {:ok, %{}, %AnnounceResponse{}} = result
      else
        assert result == {:error, @err_client_unapproved}
      end
    end
  end

  test "using both whitelist and blacklist is invalid" do
    assert {:error, _reason} = ClientApproval.new(%{whitelist: ["010203"], blacklist: ["040506"]})
  end

  test "client IDs must be 6 bytes" do
    assert {:error, _reason} = ClientApproval.new(%{whitelist: ["0102"]})
    assert {:error, _reason} = ClientApproval.new(%{blacklist: ["01020304"]})
  end

  test "scrapes are not protected" do
    assert {:ok, state} = ClientApproval.new(%{whitelist: ["010203"]})

    assert {:ok, %{}, %Bento.Tracker.ScrapeResponse{}} =
             ClientApproval.handle_scrape(
               state,
               %{},
               %Bento.Tracker.ScrapeRequest{},
               %Bento.Tracker.ScrapeResponse{}
             )
  end
end
