defmodule Bento.Tracker.HTTP.Request do
  @moduledoc """
  A minimal HTTP request abstraction consumed by
  `Bento.Tracker.HTTP.Parser`: the raw request target (path and query),
  a lowercase-keyed header map, and the remote IP of the connection.
  """

  @enforce_keys [:target, :remote_ip]
  defstruct target: "", headers: %{}, remote_ip: nil

  @type t :: %__MODULE__{
          target: String.t(),
          headers: %{optional(String.t()) => String.t()},
          remote_ip: :inet.ip_address()
        }
end
