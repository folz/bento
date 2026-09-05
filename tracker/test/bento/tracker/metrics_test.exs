defmodule Bento.Tracker.MetricsTest do
  use ExUnit.Case, async: false

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Metrics

  setup do
    case Metrics.start_link() do
      {:ok, registry} -> Process.unlink(registry)
      {:error, {:already_started, _registry}} -> :ok
    end

    :ok
  end

  test "gauges render with sorted, escaped labels" do
    Metrics.set_gauge("chihaya_storage_leechers_count", %{"z" => "1", "a" => ~s(q"uote)}, 42)

    assert Metrics.render() =~
             ~s(# HELP chihaya_storage_leechers_count The number of leechers tracked\n) <>
               ~s(# TYPE chihaya_storage_leechers_count gauge\n)

    assert Metrics.render() =~ ~s(chihaya_storage_leechers_count{a="q\\"uote",z="1"} 42\n)
  end

  test "response durations use chihaya's label vocabulary and histogram buckets" do
    name = "chihaya_udp_response_duration_milliseconds"
    labels = %{"probe" => "render"}
    Metrics.observe(name, labels, 10.0)
    Metrics.observe(name, labels, 5000.0)

    rendered = Metrics.render()
    assert rendered =~ ~s(# TYPE #{name} histogram\n)
    assert rendered =~ ~s(#{name}_bucket{le="9.375",probe="render"} 0\n)
    assert rendered =~ ~s(#{name}_bucket{le="18.75",probe="render"} 1\n)
    assert rendered =~ ~s(#{name}_bucket{le="4800",probe="render"} 1\n)
    assert rendered =~ ~s(#{name}_bucket{le="+Inf",probe="render"} 2\n)
    assert rendered =~ ~s(#{name}_sum{probe="render"} 5010\n)
    assert rendered =~ ~s(#{name}_count{probe="render"} 2\n)

    Metrics.record_response_duration(name, nil, nil, ClientError.new("bad"), 1.0)

    assert Metrics.render() =~
             ~s(#{name}_count{action="",address_family="Unknown",error="bad"} 1\n)
  end
end
