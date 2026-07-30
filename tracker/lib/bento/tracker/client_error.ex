defmodule Bento.Tracker.ClientError do
  @moduledoc """
  An error that should be exposed to the client over the BitTorrent
  protocol.

  Client errors are passed around as `{:error, %ClientError{}}` values;
  frontends render them in failure responses. Any other error reason is
  internal and must not leak to clients.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}

  @doc "Builds a client error with the given message."
  @spec new(String.t()) :: t()
  def new(message) when is_binary(message), do: %__MODULE__{message: message}
end
