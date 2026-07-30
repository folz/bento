defmodule Bento.Tracker.Mixfile do
  use Mix.Project

  def project do
    [
      app: :bento_tracker,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      escript: [main_module: Bento.Tracker.CLI],
      test_coverage: [summary: [threshold: 80]],
      dialyzer: [remove_defaults: [:unknown]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]]
  end

  defp deps do
    [
      {:bento, path: "..", env: :prod}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
