defmodule Bento.Tracker.Scrape do
  @moduledoc """
  The state of a swarm that is returned in a scrape response.
  """

  alias Bento.Tracker.InfoHash

  @enforce_keys [:info_hash]
  defstruct info_hash: nil, snatches: 0, complete: 0, incomplete: 0

  @type t :: %__MODULE__{
          info_hash: InfoHash.t(),
          snatches: non_neg_integer(),
          complete: non_neg_integer(),
          incomplete: non_neg_integer()
        }
end

defmodule Bento.Tracker.ScrapeResponse do
  @moduledoc """
  The parameters used to create a scrape response.

  The `files` must be in the same order as the infohashes in the
  corresponding `Bento.Tracker.ScrapeRequest`.
  """

  alias Bento.Tracker.Scrape

  defstruct files: []

  @type t :: %__MODULE__{files: [Scrape.t()]}
end
