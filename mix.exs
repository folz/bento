defmodule Bento.Mixfile do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim

  def project do
    [app: :bento,
     version: @version,
     elixir: "~> 1.4",
     description: description(),
     package: package(),
     deps: deps(),
     consolidate_protocols: Mix.env != :test]
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

  defp package do
    [maintainers: ["Rodney Folz"],
     licenses: ["MPL-2.0"],
     links: %{"GitHub": "https://github.com/folz/bento"}]
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
    [{:poison, "~> 2.0"},
     {:credo, "~> 0.8.2", only: [:dev, :test]},
     {:ex_doc, "~> 0.16.2", only: :docs},
     {:benchfella, "~> 0.3", only: :bench},
     {:bencode, github: "gausby/bencode", only: :bench},
     {:bencodex, github: "patrickgombert/Bencodex", only: :bench},
     {:bencoder, github: "alehander42/bencoder", only: :bench},
     {:bencoded, github: "galina/bencoded", only: :bench}]
  end
end
