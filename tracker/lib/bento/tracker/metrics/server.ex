defmodule Bento.Tracker.Metrics.Server do
  @moduledoc """
  The HTTP server exposing the Prometheus metrics endpoint.

  Serves `/metrics` in the Prometheus text exposition format rendered by
  `Bento.Tracker.Metrics`. chihaya's server also serves pprof profiles;
  on the BEAM live introspection is done with `:observer`, `:recon` and
  remote shells instead, so only `/metrics` is exposed here.
  """

  alias Bento.Tracker.HTTP.Request
  alias Bento.Tracker.HTTP.Server
  alias Bento.Tracker.Metrics

  @content_type "text/plain; version=0.0.4; charset=utf-8"

  @doc "Starts the metrics server listening on `addr` (\"ip:port\")."
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(addr, opts \\ []) do
    Server.start_link([listeners: [http: addr], handler: &handle/1], opts)
  end

  @doc "Returns the `{:ok, {ip, port}}` the server is bound to."
  @spec listen_address(pid()) :: {:ok, {:inet.ip_address(), :inet.port_number()}}
  def listen_address(pid), do: Server.listen_address(pid, :http)

  # Like chihaya's promhttp handler on net/http's mux, /metrics answers
  # any method and the query string is ignored.
  defp handle(%Request{} = request) do
    case Request.path(request) do
      "/metrics" -> {200, Metrics.render(), content_type: @content_type}
      _other -> {404, "404 page not found\n"}
    end
  end
end
