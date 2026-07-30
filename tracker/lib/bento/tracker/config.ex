defmodule Bento.Tracker.Config do
  @moduledoc """
  Loads and normalizes tracker configuration.

  A configuration is a plain map mirroring chihaya's YAML schema, loaded
  either directly or from an Elixir `.exs` file that evaluates to such a
  map (optionally wrapped under a `:bento_tracker` or `:chihaya` key).

  Duration values may be given as chihaya-style strings (`"30m"`,
  `"15s"`, `"10s"`) or as integers. After normalization, the announce
  intervals in `:response_config` are expressed in **seconds** (the unit
  the frontends put on the wire) and every other duration is in
  **milliseconds** (the unit the OTP modules expect).
  """

  @doc """
  Loads configuration from a map or from the path to an `.exs` file.

  Returns a normalized map with `:response_config`, `:metrics_addr`,
  `:http`, `:udp`, `:storage`, `:prehooks` and `:posthooks` keys. `:http`
  and `:udp` are `nil` when their section is absent or has no address.
  """
  @spec load(map() | String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) do
    case Code.eval_file(path) do
      {value, _bindings} -> load(value)
    end
  rescue
    error -> {:error, {:config_read_error, Exception.message(error)}}
  end

  def load(config) when is_map(config) do
    {:ok, normalize(unwrap(config))}
  end

  defp unwrap(%{bento_tracker: config}), do: config
  defp unwrap(%{"bento_tracker" => config}), do: config
  defp unwrap(%{chihaya: config}), do: config
  defp unwrap(%{"chihaya" => config}), do: config
  defp unwrap(config), do: config

  defp normalize(config) do
    config = atomize(config)

    %{
      response_config: %{
        announce_interval: duration_seconds(config[:announce_interval], 1800),
        min_announce_interval: duration_seconds(config[:min_announce_interval], 900)
      },
      metrics_addr: config[:metrics_addr] || "",
      http: normalize_frontend(config[:http]),
      udp: normalize_frontend(config[:udp]),
      storage: normalize_storage(config[:storage]),
      prehooks: normalize_hooks(config[:prehooks]),
      posthooks: normalize_hooks(config[:posthooks])
    }
  end

  defp normalize_frontend(nil), do: nil

  defp normalize_frontend(frontend) do
    frontend = atomize(frontend)

    if blank?(frontend[:addr]) and blank?(frontend[:https_addr]) do
      nil
    else
      frontend
      |> convert_durations([
        :read_timeout,
        :write_timeout,
        :idle_timeout,
        :max_clock_skew
      ])
    end
  end

  defp normalize_storage(nil), do: %{name: "memory", config: %{}}

  defp normalize_storage(storage) do
    storage = atomize(storage)

    inner =
      (storage[:config] || %{})
      |> atomize()
      |> convert_durations([
        :gc_interval,
        :peer_lifetime,
        :prometheus_reporting_interval,
        :redis_read_timeout,
        :redis_write_timeout,
        :redis_connect_timeout
      ])

    %{name: storage[:name] || "memory", config: inner}
  end

  defp normalize_hooks(nil), do: []

  defp normalize_hooks(hooks) when is_list(hooks) do
    Enum.map(hooks, fn hook ->
      hook = atomize(hook)
      %{name: hook[:name], options: atomize(hook[:options] || %{})}
    end)
  end

  defp convert_durations(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        value -> Map.put(acc, key, duration_ms(value, value))
      end
    end)
  end

  # Converts a duration to milliseconds; integers pass through unchanged.
  defp duration_ms(value, _default) when is_integer(value), do: value
  defp duration_ms(value, default) when is_binary(value), do: parse_duration(value, default)
  defp duration_ms(_value, default), do: default

  # Converts a duration to whole seconds for wire intervals.
  defp duration_seconds(nil, default_seconds), do: default_seconds
  defp duration_seconds(value, _default) when is_integer(value), do: value

  defp duration_seconds(value, default_seconds) when is_binary(value) do
    div(parse_duration(value, default_seconds * 1000), 1000)
  end

  @unit_ms %{"ms" => 1, "s" => 1000, "m" => 60_000, "h" => 3_600_000}

  # Parses a Go-style duration ("30m", "1h30m", "500ms") to milliseconds.
  defp parse_duration(string, default) do
    matches = Regex.scan(~r/(\d+)(ms|s|m|h)/, string)

    if matches == [] do
      default
    else
      Enum.reduce(matches, 0, fn [_whole, number, unit], acc ->
        acc + String.to_integer(number) * Map.fetch!(@unit_ms, unit)
      end)
    end
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize(other), do: other

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
