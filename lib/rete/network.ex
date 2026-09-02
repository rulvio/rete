defmodule Rete.Network do
  @moduledoc """
  A compiled rulebase: everything the engine needs, and nothing that changes.

  **Internal.** A network is built once, from a set of ruleset modules, and it is then
  immutable. So any number of sessions can share one. Working memory, the agenda, and
  pending propagations belong to the engine, not here.

      alphas      alpha node id => %Rete.Network.Node.Alpha{}
      alpha_beta  alpha node id => the beta node ids it feeds
      taxonomy    %Rete.Taxonomy{}, indexed: fact type => alpha node ids
      graph       %Rete.Compiler.BetaGraph{}, the beta nodes and their edges
      queries     {module, query name} => query node id
      productions the productions compiled in, including generated helpers

  A fact travels in three steps. `Rete.Taxonomy.alpha_ids/2` maps its type to alpha node
  ids — the **only** place the taxonomy is consulted. Each alpha's arity-1 function turns
  the fact into a bindings map, or `nil`. Matching elements reach the beta nodes in
  `alpha_beta`. The engine propagates them along the graph's forward edges.

  An alpha node id **is** the expression code of the conditions it was built from. That is
  why `Rete.Compiler.disambiguate_codes/1` runs first. See `docs/design/network.md` §2.
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
          queries: %{{module(), atom()} => BetaGraph.id()},
          productions: [IR.Production.t()],
          marker_types: MapSet.t(atom())
        }

  defstruct alphas: %{},
            alpha_beta: %{},
            taxonomy: nil,
            graph: nil,
            queries: %{},
            productions: [],
            marker_types: MapSet.new()

  @doc """
  Assembles a network from productions already sorted, classified and free of compound
  negations.

  Most callers want `Rete.Compiler.build/2`, which runs the phases that get a production
  into that state.
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
      productions: productions,
      marker_types: marker_types(productions)
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
  The query node a `{module, name}` pair refers to, or `nil`.
  """
  @spec query(t(), {module(), atom()}) :: Node.Query.t() | nil
  def query(%__MODULE__{graph: graph, queries: queries}, {module, name})
      when is_atom(module) and is_atom(name) do
    case Map.fetch(queries, {module, name}) do
      {:ok, id} -> BetaGraph.node(graph, id)
      :error -> nil
    end
  end

  @doc """
  A `{module, name}` pair as it is written in source.

      iex> Rete.Network.ref_string({MyApp.Orders, :summary})
      "MyApp.Orders.summary"
  """
  @spec ref_string({module(), atom()}) :: String.t()
  def ref_string({module, name}), do: "#{inspect(module)}.#{name}"

  @doc """
  Every query in the network, as `{module, name}` pairs, sorted.
  """
  @spec query_refs(t()) :: [{module(), atom()}]
  def query_refs(%__MODULE__{queries: queries}), do: queries |> Map.keys() |> Enum.sort()

  @doc """
  The modules that contributed a production to the network, sorted.

  This is what a session was *built from*. It is what tells apart a typo in a query name
  from a ruleset never passed to `Rete.Session.new/2`.
  """
  @spec modules(t()) :: [module()]
  def modules(%__MODULE__{productions: productions}),
    do: productions |> Enum.map(& &1.module) |> Enum.uniq() |> Enum.sort()

  @doc """
  Every production terminal, most salient first.

  Ordered by `{salience, internal_salience}` descending. The internal tier makes an
  extracted negation helper run before the rule that negates its marker.
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

  # One alpha per distinct expression code. It feeds every beta node built from a
  # condition with that code, so a condition written in several rules is matched once per
  # fact. Keeping the first condition's function is safe, because every condition
  # reaching here with the same code came from the same module. See
  # `Rete.Compiler.disambiguate_codes/1`.
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

  # The type index is keyed on the type a *condition* is written against. That is not
  # the same as the alpha's own type, when several conditions share a code.
  defp alpha_types(alphas, productions) do
    productions
    |> Enum.flat_map(&conditions/1)
    |> Enum.reduce(%{}, fn %{alpha: %IR.Expr{code: code}, type: type}, acc ->
      if Map.has_key?(alphas, code) do
        Map.update(acc, type, MapSet.new([code]), &MapSet.put(&1, code))
      else
        acc
      end
    end)
    |> Map.new(fn {type, codes} -> {type, Enum.sort(codes)} end)
  end

  # Every condition with an alpha expression, including ones inside negations and
  # disjunction branches. A Test has no fact input, and therefore no alpha.
  defp conditions(%IR.Production{lhs: lhs}), do: Enum.flat_map(lhs, &conditions/1)
  defp conditions(%IR.Fact{} = fact), do: [fact]
  defp conditions(%IR.Coll{} = coll), do: [coll]
  defp conditions(%IR.Negation{condition: condition}), do: conditions(condition)
  defp conditions(%IR.CompoundNegation{conditions: cs}), do: Enum.flat_map(cs, &conditions/1)

  defp conditions({:or, branches}),
    do: Enum.flat_map(branches, &Enum.flat_map(&1, fn c -> conditions(c) end))

  defp conditions(_), do: []

  # Marker facts are real facts, because the negation node matches on them. But they are
  # engine machinery, so `Rete.Session.facts/1` hides them.
  defp marker_types(productions) do
    for production <- productions,
        Rete.Compiler.Negation.generated?(production),
        into: MapSet.new(),
        do: production.name
  end

  @doc "Whether a fact is an internal marker rather than something a rule concluded."
  @spec marker?(t(), term()) :: boolean()
  def marker?(%__MODULE__{marker_types: markers} = network, fact) do
    MapSet.size(markers) > 0 and
      MapSet.member?(markers, Taxonomy.fact_type(network.taxonomy, fact))
  end

  defp query_index(graph) do
    graph
    |> BetaGraph.filter(&match?(%Node.Query{}, &1))
    |> Map.new(&{{&1.module, &1.name}, &1.id})
  end
end
