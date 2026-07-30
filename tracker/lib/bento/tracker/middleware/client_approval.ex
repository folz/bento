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

  @name "client approval"

  @err_client_unapproved ClientError.new("unapproved client")

  @doc "The error returned when a client's peer ID is not approved."
  @spec err_client_unapproved() :: ClientError.t()
  def err_client_unapproved, do: @err_client_unapproved

  @impl true
  def new(options) do
    whitelist = get_option(options, :whitelist) || []
    blacklist = get_option(options, :blacklist) || []

    with :ok <- check_exclusive(whitelist, blacklist),
         {:ok, approved} <- client_id_set(whitelist),
         {:ok, unapproved} <- client_id_set(blacklist) do
      {:ok, %{approved: approved, unapproved: unapproved}}
    end
  end

  defp check_exclusive([_ | _], [_ | _]) do
    {:error, "using both whitelist and blacklist is invalid"}
  end

  defp check_exclusive(_whitelist, _blacklist), do: :ok

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
    client_id = ClientID.new(request.peer.id)

    cond do
      MapSet.size(state.approved) > 0 and not MapSet.member?(state.approved, client_id) ->
        {:error, @err_client_unapproved}

      MapSet.size(state.unapproved) > 0 and MapSet.member?(state.unapproved, client_id) ->
        {:error, @err_client_unapproved}

      true ->
        {:ok, ctx, response}
    end
  end

  @impl true
  def handle_scrape(_state, ctx, _request, response) do
    # Scrapes don't require any protection.
    {:ok, ctx, response}
  end

  @doc false
  def name, do: @name

  defp get_option(options, key) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key))
  end
end
