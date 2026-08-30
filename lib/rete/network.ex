defmodule Rete.Network do
  @moduledoc """
  A compiled rulebase: everything the engine needs, and nothing that changes.

  A network is built once from a set of ruleset modules and is then immutable,
  so any number of sessions can share one. All the per-session state — working
  memory, the agenda, pending propagations — belongs to the engine, not here.

  ## Shape

      alphas      alpha node id => %Rete.Network.Node.Alpha{}
      alpha_beta  alpha node id => the beta node ids it feeds
      taxonomy    %Rete.Taxonomy{}, indexed: fact type => alpha node ids
      graph       %Rete.Compiler.BetaGraph{}, the beta nodes and their edges
      queries     query name => query node id
      productions the productions compiled in, including generated helpers

  ## How a fact travels

  1. `Rete.Taxonomy.alpha_ids/2` maps the fact's type to alpha node ids. This is
     the **only** place the taxonomy is consulted: `derive(:premium, :customer)`
     is what makes a `:premium` fact reach a condition written against
     `:customer`.
  2. Each alpha's arity 1 function turns the fact into a bindings map, or `nil`.
     It matches a fact of any type on purpose — the type decision was step 1.
  3. Matching elements go to the beta nodes in `alpha_beta`, and from there the
     engine propagates along the graph's forward edges.

  Splitting it this way is what lets one alpha serve many rules: conditions are
  grouped by expression code, so `{:customer, cid}` written in four rules is
  matched once per fact.

  An alpha node id **is** the expression code of the conditions it was built
  from, which is why `Rete.Compiler.disambiguate_codes/1` runs first: a code two
  modules disagree about would otherwise put two different functions under one
  id and this map would keep whichever it reduced first.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.IR
  alias Rete.Network.Node
  alias Rete.Taxonomy

  @type t :: %__MODULE__{
          alphas: %{term() => Node.Alpha.t()},
          alpha_beta: %{term() => [BetaGraph.id()]},
          taxonomy: Taxonomy.t(),
          graph: BetaGraph.t(),
          queries: %{atom() => BetaGraph.id()},
          productions: [IR.Production.t()]
        }

  defstruct alphas: %{},
            alpha_beta: %{},
            taxonomy: nil,
            graph: nil,
            queries: %{},
            productions: []

  @doc """
  Assembles a network from productions that are already sorted, classified and
  free of compound negations.

  Most callers want `Rete.Compiler.build/2`, which runs the phases that get a
  production into that state.
  """
  @spec new([IR.Production.t()], [Taxonomy.declaration()], keyword()) :: t()
  def new(productions, taxo_data \\ [], opts \\ []) do
    graph = BetaGraph.build(productions)
    {alphas, alpha_beta} = alpha_network(productions, graph)

    taxonomy =
      taxo_data
      |> Taxonomy.new(Keyword.take(opts, [:fact_type_fn]))
      |> Taxonomy.index(alpha_types(alphas, productions))

    %__MODULE__{
      alphas: alphas,
      alpha_beta: alpha_beta,
      taxonomy: taxonomy,
      graph: graph,
      queries: query_index(graph),
      productions: productions
    }
  end

  @doc """
  The beta node under an id, or `nil`.
  """
  @spec node(t(), BetaGraph.id()) :: Node.t() | nil
  def node(%__MODULE__{graph: graph}, id), do: BetaGraph.node(graph, id)

  @doc """
  The children of a beta node.
  """
  @spec children(t(), BetaGraph.id()) :: [BetaGraph.id()]
  def children(%__MODULE__{graph: graph}, id), do: BetaGraph.children(graph, id)

  @doc """
  The alpha nodes a fact must be offered to, resolved through the taxonomy.
  """
  @spec alphas_for(t(), term()) :: [Node.Alpha.t()]
  def alphas_for(%__MODULE__{alphas: alphas, taxonomy: taxonomy}, fact) do
    taxonomy |> Taxonomy.alpha_ids(fact) |> Enum.map(&Map.fetch!(alphas, &1))
  end

  @doc """
  The beta nodes an alpha node feeds.
  """
  @spec beta_children(t(), term()) :: [BetaGraph.id()]
  def beta_children(%__MODULE__{alpha_beta: alpha_beta}, code),
    do: Map.get(alpha_beta, code, [])

  @doc """
  The query node registered under a name, or `nil`.
  """
  @spec query(t(), atom()) :: Node.Query.t() | nil
  def query(%__MODULE__{graph: graph, queries: queries}, name) do
    case Map.fetch(queries, name) do
      {:ok, id} -> BetaGraph.node(graph, id)
      :error -> nil
    end
  end

  @doc """
  Every production terminal, most salient first.

  The ordering is `{salience, internal_salience}` descending. The internal tier
  is what makes an extracted negation helper run before the rule that negates
  its marker; without it that rule would fire once against an absence that had
  simply not been computed yet.
  """
  @spec production_nodes(t()) :: [Node.Production.t()]
  def production_nodes(%__MODULE__{graph: graph}) do
    graph
    |> BetaGraph.filter(&match?(%Node.Production{}, &1))
    |> Enum.sort_by(&{-&1.salience, -&1.internal_salience, &1.id})
  end

  @doc """
  Every beta node reachable from the root, by ascending id.
  """
  @spec beta_nodes(t()) :: [Node.t()]
  def beta_nodes(%__MODULE__{graph: graph}), do: BetaGraph.filter(graph, fn _ -> true end)

  # --- alpha side --------------------------------------------------------------

  # One alpha per distinct expression code, feeding every beta node built from a
  # condition with that code. The code is the sharing key, so a condition written
  # in several rules is matched once per fact rather than once per rule.
  #
  # Keeping the first condition's function is only safe because every condition
  # reaching here with the same code came from the same module - see
  # `Rete.Compiler.disambiguate_codes/1` - and one module compiles one function
  # per code, guarded by `Module.defines?/2` in `Rete.DSL.Codegen.expr_def/1`.
  # The code also carries the fact type, so `:type` cannot differ either.
  defp alpha_network(productions, graph) do
    beta_by_code = beta_ids_by_alpha_code(graph)

    productions
    |> Enum.flat_map(&conditions/1)
    |> Enum.reduce({%{}, %{}}, fn condition, {alphas, alpha_beta} ->
      %{alpha: %IR.Expr{code: code} = expr, type: type} = condition

      alphas =
        Map.put_new_lazy(alphas, code, fn ->
          %Node.Alpha{id: code, type: type, code: code, fun: expr.fun}
        end)

      {alphas, Map.put(alpha_beta, code, Map.get(beta_by_code, code, []))}
    end)
  end

  defp beta_ids_by_alpha_code(graph) do
    graph
    |> BetaGraph.filter(&Map.has_key?(&1, :alpha_code))
    |> Enum.group_by(& &1.alpha_code, & &1.id)
  end

  # The type index is keyed on the type a *condition* is written against, which
  # is not the same as the alpha's own type when several conditions share a code.
  defp alpha_types(alphas, productions) do
    productions
    |> Enum.flat_map(&conditions/1)
    |> Enum.reduce(%{}, fn %{alpha: %IR.Expr{code: code}, type: type}, acc ->
      if Map.has_key?(alphas, code) do
        Map.update(acc, type, [code], &Enum.uniq([code | &1]))
      else
        acc
      end
    end)
    |> Map.new(fn {type, codes} -> {type, Enum.sort(codes)} end)
  end

  # Every condition with an alpha expression, including inside negations and
  # disjunction branches. A Test has no fact input and therefore no alpha.
  defp conditions(%IR.Production{lhs: lhs}), do: Enum.flat_map(lhs, &conditions/1)
  defp conditions(%IR.Fact{} = fact), do: [fact]
  defp conditions(%IR.Coll{} = coll), do: [coll]
  defp conditions(%IR.Negation{condition: condition}), do: conditions(condition)
  defp conditions(%IR.CompoundNegation{conditions: cs}), do: Enum.flat_map(cs, &conditions/1)

  defp conditions({:or, branches}),
    do: Enum.flat_map(branches, &Enum.flat_map(&1, fn c -> conditions(c) end))

  defp conditions(_), do: []

  defp query_index(graph) do
    graph
    |> BetaGraph.filter(&match?(%Node.Query{}, &1))
    |> Map.new(&{&1.name, &1.id})
  end
end
