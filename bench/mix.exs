defmodule Bento.Bench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bento_bench,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: false,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    []
  end

  defp aliases do
    [
      "bench.gen": ["run generate_data.exs"],
      "bench.decode": ["run decode.exs"],
      "bench.encode": ["run encode.exs"],
      "bench.retention": ["run retention.exs"]
    ]
  end

  defp deps do
    [
      {:bento, path: "../", override: true},
      {:benchee, "~> 1.3"},
      {:benchee_html, "~> 1.0"},
      {:bencode, github: "gausby/bencode"},
      {:bencodex, github: "patrickgombert/Bencodex"}
    ]
  end
end
