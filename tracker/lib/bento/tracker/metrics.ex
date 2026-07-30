defmodule Bento.Tracker.Metrics do
  @moduledoc """
  A minimal, dependency-free Prometheus-compatible metrics registry.

  Metric names, labels, help texts and histogram buckets mirror chihaya's
  metrics exactly, so existing dashboards keep working. Values live in a
  public ETS table updated with atomic operations; when the registry is
  not running every recording function is a no-op, so instrumented code
  never needs to care.
  """

  use GenServer

  @table :bento_tracker_metrics

  # value * @fixed_point is stored as an integer so histogram sums can be
  # updated atomically with :ets.update_counter/3.
  @fixed_point 1_000_000

  @duration_buckets [9.375, 18.75, 37.5, 75.0, 150.0, 300.0, 600.0, 1200.0, 2400.0, 4800.0]

  @definitions %{
    "chihaya_storage_gc_duration_milliseconds" =>
      {:histogram, "The time it takes to perform storage garbage collection", @duration_buckets},
    "chihaya_storage_infohashes_count" => {:gauge, "The number of Infohashes tracked", nil},
    "chihaya_storage_seeders_count" => {:gauge, "The number of seeders tracked", nil},
    "chihaya_storage_leechers_count" => {:gauge, "The number of leechers tracked", nil},
    "chihaya_http_response_duration_milliseconds" =>
      {:histogram,
       "The duration of time it takes to receive and write a response to an API request",
       @duration_buckets},
    "chihaya_udp_response_duration_milliseconds" =>
      {:histogram,
       "The duration of time it takes to receive and write a response to an API request",
       @duration_buckets}
  }

  @doc "Starts the metrics registry."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a child specification for the metrics registry."
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    {:ok, nil}
  end

  @doc "Whether the registry is running."
  @spec started?() :: boolean()
  def started?, do: :ets.whereis(@table) != :undefined

  @doc "Sets a gauge to the given value."
  @spec set_gauge(String.t(), map(), number()) :: :ok
  def set_gauge(name, labels \\ %{}, value) do
    if started?() do
      :ets.insert(@table, {{:gauge, name, labels}, value})
    end

    :ok
  end

  @doc "Increments a counter by `by` (default 1)."
  @spec add_counter(String.t(), map(), non_neg_integer()) :: :ok
  def add_counter(name, labels \\ %{}, by \\ 1) do
    if started?() do
      key = {:counter, name, labels}
      :ets.update_counter(@table, key, {2, by}, {key, 0})
    end

    :ok
  end

  @doc """
  Records an observation into the histogram registered under `name`.
  """
  @spec observe(String.t(), map(), number()) :: :ok
  def observe(name, labels \\ %{}, value) do
    with true <- started?(),
         {:histogram, _help, buckets} <- Map.get(@definitions, name) do
      key = {:histogram, name, labels}
      bucket_index = Enum.find_index(buckets, &(value <= &1))
      # Row: {key, count, fixed-point sum, b1..bn, +Inf}
      zero_row =
        List.to_tuple([key, 0, 0 | List.duplicate(0, length(buckets) + 1)])

      bucket_pos = if bucket_index, do: 4 + bucket_index, else: 4 + length(buckets)

      ops = [{2, 1}, {3, round(value * @fixed_point)}, {bucket_pos, 1}]
      :ets.update_counter(@table, key, ops, zero_row)
    end

    :ok
  end

  @doc """
  Renders all recorded metrics in the Prometheus text exposition format.
  """
  @spec render() :: String.t()
  def render do
    if started?() do
      @table
      |> :ets.tab2list()
      |> Enum.group_by(fn row -> elem(elem(row, 0), 1) end)
      |> Enum.sort()
      |> Enum.map_join("", fn {name, rows} -> render_metric(name, rows) end)
    else
      ""
    end
  end

  defp render_metric(name, rows) do
    {kind, help, buckets} = Map.get(@definitions, name, {kind_of(hd(rows)), "", nil})

    header = "# HELP #{name} #{help}\n# TYPE #{name} #{prom_type(kind)}\n"

    body =
      rows
      |> Enum.sort_by(fn row -> elem(elem(row, 0), 2) end)
      |> Enum.map_join("", fn row -> render_row(name, kind, buckets, row) end)

    header <> body
  end

  defp kind_of({{kind, _name, _labels}, _value}), do: kind
  defp kind_of(row) when is_tuple(row), do: elem(elem(row, 0), 0)

  defp prom_type(:gauge), do: "gauge"
  defp prom_type(:counter), do: "counter"
  defp prom_type(:histogram), do: "histogram"

  defp render_row(name, kind, _buckets, {{_, _, labels}, value})
       when kind in [:gauge, :counter] do
    "#{name}#{format_labels(labels)} #{format_value(value)}\n"
  end

  defp render_row(name, :histogram, buckets, row) do
    {_, _, labels} = elem(row, 0)
    count = elem(row, 1)
    sum = elem(row, 2) / @fixed_point
    bucket_counts = for i <- 0..length(buckets), do: elem(row, 3 + i)

    {lines, _cumulative} =
      buckets
      |> Enum.zip(bucket_counts)
      |> Enum.map_reduce(0, fn {bound, n}, acc ->
        cumulative = acc + n

        {"#{name}_bucket#{format_labels(labels, %{"le" => format_value(bound)})} #{cumulative}\n",
         cumulative}
      end)

    Enum.join(lines) <>
      "#{name}_bucket#{format_labels(labels, %{"le" => "+Inf"})} #{count}\n" <>
      "#{name}_sum#{format_labels(labels)} #{format_value(sum)}\n" <>
      "#{name}_count#{format_labels(labels)} #{count}\n"
  end

  defp format_labels(labels, extra \\ %{}) do
    labels =
      labels
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.merge(extra)

    if labels == %{} do
      ""
    else
      inner =
        labels
        |> Enum.sort()
        |> Enum.map_join(",", fn {k, v} -> "#{k}=\"#{escape_label(v)}\"" end)

      "{" <> inner <> "}"
    end
  end

  defp escape_label(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_float(value) do
    if value == trunc(value) do
      Integer.to_string(trunc(value))
    else
      Float.to_string(value)
    end
  end
end
