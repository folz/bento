defmodule Bento.Tracker.Middleware.Hook do
  @moduledoc """
  Anything that needs to interact with a BitTorrent client's request
  and response to a BitTorrent tracker. Pre-hooks and post-hooks both
  use the same behaviour.

  `new/1` builds the hook's state from its configuration options; the
  optional `stop/1` is invoked on shutdown for hooks that need clean
  teardown.
  """

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.Middleware
  alias Bento.Tracker.ScrapeRequest
  alias Bento.Tracker.ScrapeResponse

  @callback new(options :: map()) :: {:ok, term()} | {:error, term()}

  @callback handle_announce(
              state :: term(),
              Middleware.ctx(),
              AnnounceRequest.t(),
              AnnounceResponse.t()
            ) :: {:ok, Middleware.ctx(), AnnounceResponse.t()} | {:error, term()}

  @callback handle_scrape(
              state :: term(),
              Middleware.ctx(),
              ScrapeRequest.t(),
              ScrapeResponse.t()
            ) :: {:ok, Middleware.ctx(), ScrapeResponse.t()} | {:error, term()}

  @callback stop(state :: term()) :: :ok

  @optional_callbacks new: 1, stop: 1
end
