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
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
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

  # No :extra_applications. The engine has no processes, no supervision tree and no
  # Logger calls. Tracing goes through Rete.Listener.Trace, which writes to a device the
  # caller chooses.
  def application, do: []

  # test/support holds the ruleset the doctests in lib/ run against. It is not shipped.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:taxo, "~> 0.1.0"},
      {:stream_data, "~> 1.2", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # `bench/` is a script rather than a Mix task under `lib/`, so it is not compiled into
  # the package and does not add a `mix bench` to every project that depends on this one.
  defp aliases do
    [bench: ["run bench/run.exs"]]
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
      # Only the first group is covered by semantic versioning. See "What is public" in
      # the README, and docs/design/ for how the internals work.
      groups_for_modules: [
        "Public API": [
          Rete,
          Rete.Ruleset,
          Rete.Session,
          Rete.Inspect,
          Rete.Listener,
          Rete.Listener.Collect,
          Rete.Listener.Trace
        ],
        "Internals: facts and memory": [
          Rete.Token,
          Rete.Element,
          Rete.Activation,
          Rete.Memory,
          Rete.Memory.Bucket,
          Rete.Agenda,
          Rete.Taxonomy
        ],
        "Internals: the DSL front end": [
          Rete.DSL.Parser,
          Rete.DSL.Normalize,
          Rete.DSL.Bindings,
          Rete.DSL.Codegen,
          Rete.DSL.Vars
        ],
        "Internals: the IR": [Rete.IR, ~r/^Rete\.IR\./],
        "Internals: the compiler": [
          Rete.Compiler,
          Rete.Compiler.Sort,
          Rete.Compiler.Negation,
          Rete.Compiler.BetaGraph,
          Rete.Network
        ],
        "Internals: network nodes": [Rete.Network.Node, ~r/^Rete\.Network\.Node\./],
        "Internals: the engine": [
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
