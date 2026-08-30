defmodule Rete.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/rulvio/rete"

  def project do
    [
      app: :rete,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Rete",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [preferred_envs: [dialyzer: :dev, docs: :dev]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:taxo, "~> 0.1.0"},
      {:stream_data, "~> 1.2", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A forward-chaining Rete rules engine for Elixir, with a pattern-matching DSL " <>
      "in which a rule reads as a function: its arguments are the conditions and " <>
      "its body is what follows."
  end

  defp package do
    [
      files:
        ~w(lib docs/dsl.md docs/design .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "docs/dsl.md": [title: "Writing rules"],
        "CHANGELOG.md": [title: "Changelog"],
        "docs/design/w1-ir.md": [title: "Design: the IR and the DSL front end"],
        "docs/design/w2-network.md": [title: "Design: the compiled network"],
        "docs/design/w3-engine.md": [title: "Design: the engine"],
        "docs/design/w5-observability.md": [title: "Design: observability"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        Guides: ["README.md", "docs/dsl.md"],
        Design: ~r"docs/design/",
        About: ["CHANGELOG.md", "LICENSE"]
      ],
      groups_for_modules: [
        Rete: [
          Rete,
          Rete.Ruleset,
          Rete.Session,
          Rete.Inspect,
          Rete.Listener,
          Rete.Listener.Collect,
          Rete.Listener.Trace
        ],
        "Facts and memory": [
          Rete.Token,
          Rete.Element,
          Rete.Activation,
          Rete.Memory,
          Rete.Agenda,
          Rete.Taxonomy
        ],
        "The DSL front end": [
          Rete.DSL.Parser,
          Rete.DSL.Normalize,
          Rete.DSL.Bindings,
          Rete.DSL.Codegen,
          Rete.DSL.Vars
        ],
        "The IR": [Rete.IR, ~r/^Rete\.IR\./],
        Compiler: [
          Rete.Compiler,
          Rete.Compiler.Sort,
          Rete.Compiler.Negation,
          Rete.Compiler.BetaGraph,
          Rete.Network
        ],
        "Network nodes": [Rete.Network.Node, ~r/^Rete\.Network\.Node\./],
        Engine: [
          Rete.Engine,
          Rete.Engine.State,
          Rete.Engine.Nodes
        ]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end
end
