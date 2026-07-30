defmodule Bento.Tracker.AnnounceResponse do
  @moduledoc """
  The parameters used to create an announce response.

  Intervals are expressed in seconds.
  """

  alias Bento.Tracker.Peer

  defstruct compact?: false,
            complete: 0,
            incomplete: 0,
            interval: 0,
            min_interval: 0,
            ipv4_peers: [],
            ipv6_peers: []

  @type t :: %__MODULE__{
          compact?: boolean(),
          complete: non_neg_integer(),
          incomplete: non_neg_integer(),
          interval: non_neg_integer(),
          min_interval: non_neg_integer(),
          ipv4_peers: [Peer.t()],
          ipv6_peers: [Peer.t()]
        }
end
