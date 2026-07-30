defmodule Bento.Tracker.ClientID do
  @moduledoc """
  The part of a `Bento.Tracker.PeerID` that identifies a peer's client
  software.
  """

  alias Bento.Tracker.PeerID

  @type t :: <<_::48>>

  @doc """
  Parses a client ID from a peer ID.

  Azureus-style peer IDs (`-XX1234-...`) yield the six bytes following the
  leading dash; Shadow-style and other peer IDs yield their first six bytes.
  """
  @spec new(PeerID.t()) :: t()
  def new(<<?-, client_id::binary-size(6), _rest::binary-size(13)>>), do: client_id
  def new(<<client_id::binary-size(6), _rest::binary-size(14)>>), do: client_id
end
