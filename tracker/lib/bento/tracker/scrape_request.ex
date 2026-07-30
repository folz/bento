defmodule Bento.Tracker.ScrapeRequest do
  @moduledoc """
  The parsed parameters from a scrape request.
  """

  alias Bento.Tracker.InfoHash
  alias Bento.Tracker.IP
  alias Bento.Tracker.Params

  defstruct address_family: :ipv4, info_hashes: [], params: nil

  @type t :: %__MODULE__{
          address_family: IP.address_family(),
          info_hashes: [InfoHash.t()],
          params: Params.t() | nil
        }

  @doc """
  Enforces a max number of infohashes for a single scrape request,
  truncating any excess.
  """
  @spec sanitize(t(), non_neg_integer()) :: {:ok, t()}
  def sanitize(%__MODULE__{} = request, max_scrape_info_hashes) do
    case Enum.split(request.info_hashes, max_scrape_info_hashes) do
      {_kept, []} -> {:ok, request}
      {kept, _dropped} -> {:ok, %{request | info_hashes: kept}}
    end
  end
end
