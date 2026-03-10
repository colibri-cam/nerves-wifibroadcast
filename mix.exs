defmodule Wifibroadcast.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Linux/Nerves-first Elixir Wifibroadcast RX/TX stack with pure-Elixir radio control and AF_PACKET transport."
  @source_url "https://github.com/colibri-cam/nerves-wifibroadcast"

  def project do
    [
      app: :wifibroadcast,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      compilers: [:bundlex] ++ Mix.compilers(),
      description: @description,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Wifibroadcast.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bundlex, "~> 1.5"},
      {:membrane_core, "~> 1.2"},
      {:ex_doc, "~> 0.37", only: :dev, runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  defp package do
    [
      licenses: ["GPL-3.0-only"],
      links: %{
        "GitHub" => @source_url,
        "Issues" => @source_url <> "/issues"
      },
      files: [
        "lib",
        "c_src",
        "config",
        "examples",
        "bundlex.exs",
        "mix.exs",
        "README.md",
        "LICENSE.txt"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Wifibroadcast",
      source_url: @source_url,
      extras: [
        {"README.md", [filename: "readme", title: "Overview"]},
        {"examples/README.md", [filename: "examples", title: "Examples"]}
      ]
    ]
  end
end
