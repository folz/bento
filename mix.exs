defmodule Bento.Mixfile do
  use Mix.Project

  def project do
    [app: :bento,
     version: "0.9.0",
     elixir: "~> 1.2",
     description: description,
     package: package,
     deps: deps,
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod]
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
     {:ex_doc, "~> 0.11", only: :docs}]
  end
end
