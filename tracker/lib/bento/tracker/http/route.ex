defmodule Bento.Tracker.HTTP.Route do
  @moduledoc """
  Matching of request paths against announce and scrape routes with the
  syntax of httprouter, the router chihaya uses: a literal segment matches
  itself, `:name` binds exactly one non-empty segment, and a trailing
  `*name` binds the rest of the path, leading slash included (so
  `/announce/*rest` matches `/announce/` with `rest` bound to `"/"`).

  The bound parameters reach middleware hooks through the request
  context under `Bento.Tracker.Middleware.route_params_key/0`, as
  chihaya's `RouteParams` do.
  """

  @typedoc "Route parameters in pattern order, keyed by their `:name`/`*name`."
  @type params :: [{String.t(), String.t()}]

  @doc """
  Matches `path` against `routes` in order, returning the parameters
  bound by the first route that matches.
  """
  @spec match([String.t()], String.t()) :: {:ok, params()} | :error
  def match(routes, path) do
    segments = String.split(path, "/")

    Enum.find_value(routes, :error, fn route ->
      walk(String.split(route, "/"), segments, [])
    end)
  end

  defp walk([<<"*", name::binary>>], rest, params) do
    {:ok, Enum.reverse([{name, "/" <> Enum.join(rest, "/")} | params])}
  end

  defp walk([], [], params), do: {:ok, Enum.reverse(params)}

  defp walk([<<":", name::binary>> | pattern], [segment | path], params) when segment != "" do
    walk(pattern, path, [{name, segment} | params])
  end

  defp walk([segment | pattern], [segment | path], params), do: walk(pattern, path, params)
  defp walk(_pattern, _path, _params), do: nil
end
