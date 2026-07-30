defmodule Bento.Tracker.Middleware.ClientApproval do
  @moduledoc """
  A hook that fails an announce based on a whitelist or blacklist of
  BitTorrent client IDs.

  ## Options

    * `:whitelist` - a list of 6-byte client ID strings to approve
    * `:blacklist` - a list of 6-byte client ID strings to reject

  Using both at once is invalid.
  """

  @behaviour Bento.Tracker.Middleware.Hook

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.ClientID
  alias Bento.Tracker.Middleware

  @err_client_unapproved ClientError.new("unapproved client")

  @doc "The error returned when a client's peer ID is not approved."
  @spec err_client_unapproved() :: ClientError.t()
  def err_client_unapproved, do: @err_client_unapproved

  @impl true
  def new(options) do
    whitelist = Middleware.get_option(options, :whitelist) || []
    blacklist = Middleware.get_option(options, :blacklist) || []

    with :ok <- Middleware.check_exclusive(whitelist, blacklist),
         {:ok, approved} <- client_id_set(whitelist),
         {:ok, unapproved} <- client_id_set(blacklist) do
      {:ok, %{approved: approved, unapproved: unapproved}}
    end
  end

  defp client_id_set(client_ids) do
    Enum.reduce_while(client_ids, {:ok, MapSet.new()}, fn client_id, {:ok, set} ->
      if byte_size(client_id) == 6 do
        {:cont, {:ok, MapSet.put(set, client_id)}}
      else
        {:halt, {:error, "client ID #{client_id} must be 6 bytes"}}
      end
    end)
  end

  @impl true
  def handle_announce(state, ctx, request, response) do
    if Middleware.approved?(state, ClientID.new(request.peer.id)) do
      {:ok, ctx, response}
    else
      {:error, @err_client_unapproved}
    end
  end

  @impl true
  def handle_scrape(_state, ctx, _request, response) do
    # Scrapes don't require any protection.
    {:ok, ctx, response}
  end
end
