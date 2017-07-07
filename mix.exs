defmodule Bento.Mixfile do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim

  def project do
    [app: :bento,
     version: @version,
     elixir: "~> 1.4",
     description: description(),
     consolidate_protocols: not Mix.env in [:dev, :test],
     deps: deps(),
     package: package(),
     dialyzer: []]
   end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger]]
  end

  defp description do
    """
    An incredibly fast, pure Elixir Bencoding library.
    """
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [{:dialyxir, "~> 0.5", only: :dev, runtime: false},
     {:ex_doc, "~> 0.16", only: :dev, runtime: false},
     {:credo, "~> 0.8", only: [:dev, :test], runtime: false},
     {:poison, "~> 3.1"},
     {:benchfella, "~> 0.3", only: :bench},
     {:bencode, github: "gausby/bencode", only: :bench},
     {:bencodex, github: "patrickgombert/Bencodex", only: :bench},
     {:bencoder, github: "alehander42/bencoder", only: :bench},
     {:bencoded, github: "galina/bencoded", only: :bench}]
  end

  defp package do
    [files: ~w(lib mix.exs README.md LICENSE VERSION),
     maintainers: ["Rodney Folz"],
     licenses: ["MPL-2.0"],
     links: %{"GitHub": "https://github.com/folz/bento"}]
  end
end
