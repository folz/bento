defmodule Bento.Tracker.Middleware.TorrentApproval do
  @moduledoc """
  A hook that fails an announce based on a whitelist or blacklist of
  torrent infohashes.

  ## Options

    * `:whitelist` - a list of hex-encoded infohashes to approve
    * `:blacklist` - a list of hex-encoded infohashes to reject

  Using both at once is invalid.
  """

  @behaviour Bento.Tracker.Middleware.Hook

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Middleware

  @err_torrent_unapproved ClientError.new("unapproved torrent")

  @doc "The error returned when a torrent's infohash is not approved."
  @spec err_torrent_unapproved() :: ClientError.t()
  def err_torrent_unapproved, do: @err_torrent_unapproved

  @impl true
  def new(options) do
    whitelist = Middleware.get_option(options, :whitelist) || []
    blacklist = Middleware.get_option(options, :blacklist) || []

    with :ok <- Middleware.check_exclusive(whitelist, blacklist),
         {:ok, approved} <- info_hash_set(whitelist, "whitelist"),
         {:ok, unapproved} <- info_hash_set(blacklist, "blacklist") do
      {:ok, %{approved: approved, unapproved: unapproved}}
    end
  end

  defp info_hash_set(hashes, list_name) do
    Enum.reduce_while(hashes, {:ok, MapSet.new()}, fn hash_string, {:ok, set} ->
      case Base.decode16(hash_string, case: :mixed) do
        {:ok, info_hash} when byte_size(info_hash) == 20 ->
          {:cont, {:ok, MapSet.put(set, info_hash)}}

        # "byes" reproduces chihaya's exact (typo'd) error text.
        {:ok, _wrong_size} ->
          {:halt, {:error, "#{list_name} : hash #{hash_string} is not 20 byes"}}

        :error ->
          {:halt, {:error, "#{list_name} : invalid hash #{hash_string}"}}
      end
    end)
  end

  @impl true
  def handle_announce(state, ctx, request, response) do
    if Middleware.approved?(state, request.info_hash) do
      {:ok, ctx, response}
    else
      {:error, @err_torrent_unapproved}
    end
  end

  @impl true
  def handle_scrape(_state, ctx, _request, response) do
    # Scrapes don't require any protection.
    {:ok, ctx, response}
  end
end
