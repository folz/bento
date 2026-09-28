defmodule Bento.Tracker.HTTP.Request do
  @moduledoc """
  A minimal HTTP request as produced by `Bento.Tracker.HTTP.Server`: the
  method, the HTTP version, the raw request target (path and query), a lowercase-keyed
  header map, and the remote IP of the connection.
  """

  @enforce_keys [:target, :remote_ip]
  defstruct method: "GET", version: {1, 1}, target: "", headers: %{}, remote_ip: nil

  @type t :: %__MODULE__{
          method: String.t(),
          version: {1, 0 | 1},
          target: String.t(),
          headers: %{optional(String.t()) => String.t()},
          remote_ip: :inet.ip_address()
        }

  @doc "The request path: the target up to (excluding) any `?`."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{target: target}), do: target |> :binary.split("?") |> hd()
end
