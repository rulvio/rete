defmodule Rete.Compiler.BetaGraph do
  @moduledoc """
  The beta side of the network: a graph of `Rete.Network.Node` descriptions.

  **Internal.** Each production's sorted left hand side is walked in order, adding one
  node per condition under the nodes the previous condition produced. Node `0` is an
  artificial root, so the graph has a single entry point.

  **Parents are a list.** A disjunction adds each branch as its own chain and hands the
  union of the branch terminals to the next condition, so the branches re-converge on it.
  That is why the LHS is never flattened to disjunctive normal form: whole-LHS DNF is
  exponential in the number of disjunctions, and fanning out per condition is linear.

  **Sharing** requires equality *and* the same parent set. Equality alone is a correctness
  bug: in `a({:customer, cid}, {:order, cid, amt})` and `b({:vendor, cid}, {:order, cid,
  amt})` the two order conditions are equal but sit under different parents, and sharing
  them would let a `:vendor` token join a `:customer`'s elements. A terminal keys on the
  production's identity, so two rules with an identical LHS fire independently.

  **`{:or, []}` is false**, and nothing is built for a path through one. A keyless
  condition after a false element would otherwise become an entry point the alpha index
  feeds, and an unsatisfiable rule would fire on every fact. See
  `docs/design/w2-network.md` §4.
  """

  alias Rete.IR
  alias Rete.Network.Node

  @root_id 0

  @typedoc "Node ids, allocated in insertion order."
  @type id :: non_neg_integer()

  @type t :: %__MODULE__{
          nodes: %{id() => Node.t()},
          forward: %{id() => [id()]},
          backward: %{id() => MapSet.t(id())},
          next_id: id()
        }

  defstruct nodes: %{}, forward: %{@root_id => []}, backward: %{}, next_id: 1

  @doc """
  The id of the artificial root every rule hangs from.
  """
  @spec root_id() :: id()
  def root_id, do: @root_id

  @doc """
  An empty graph containing only the root.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Adds every production to a new graph, in order.

  Order matters only for id allocation, and therefore only for readability:
  the same productions in the same order always produce the same ids.
  """
  @spec build([IR.Production.t()]) :: t()
  def build(productions), do: Enum.reduce(productions, new(), &add_production(&2, &1))

  @doc """
  Adds one production, sharing nodes with everything already in the graph.

  A production whose left hand side is unsatisfiable — one that contains a
  `{:or, []}` outside every branch that could avoid it — adds nothing at all.
  """
  @spec add_production(t(), IR.Production.t()) :: t()
  def add_production(%__MODULE__{} = graph, %IR.Production{} = production) do
    if satisfiable?(production.lhs) do
      {graph, parents} = add_elements(graph, production.lhs, [@root_id])
      {graph, _id} = add_node(graph, terminal(production), parents)
      graph
    else
      graph
    end
  end

  @doc """
  The children of a node, in the order they were added.
  """
  @spec children(t(), id()) :: [id()]
  def children(%__MODULE__{forward: forward}, id), do: Map.get(forward, id, [])

  @doc """
  The parents of a node.
  """
  @spec parents(t(), id()) :: MapSet.t(id())
  def parents(%__MODULE__{backward: backward}, id), do: Map.get(backward, id, MapSet.new())

  @doc """
  The node under an id, or `nil`.
  """
  @spec node(t(), id()) :: Node.t() | nil
  def node(%__MODULE__{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc """
  Every node whose only parent is the root: the entry points of the beta side.
  """
  @spec roots(t()) :: [id()]
  def roots(%__MODULE__{} = graph), do: children(graph, @root_id)

  @doc """
  Every node satisfying a predicate, by ascending id.
  """
  @spec filter(t(), (Node.t() -> boolean())) :: [Node.t()]
  def filter(%__MODULE__{nodes: nodes}, predicate) do
    nodes |> Map.values() |> Enum.filter(predicate) |> Enum.sort_by(& &1.id)
  end

  # --- walking the left hand side --------------------------------------------

  defp add_elements(%__MODULE__{} = graph, elements, parents) do
    Enum.reduce(elements, {graph, parents}, fn element, {graph, parents} ->
      add_element(graph, element, parents)
    end)
  end

  # Each branch is a chain under the current parents, and the union of their terminals
  # becomes the parents of what follows. `add_production/2` has already established that
  # at least one branch is satisfiable, so the union is never empty.
  defp add_element(graph, {:or, branches}, parents) do
    {graph, terminals} =
      branches
      |> Enum.filter(&satisfiable?/1)
      |> Enum.reduce({graph, []}, fn branch, {graph, acc} ->
        {graph, branch_parents} = add_elements(graph, branch, parents)
        {graph, acc ++ branch_parents}
      end)

    # An empty branch matches unconditionally, so its terminal is the parent set.
    {graph, Enum.uniq(terminals)}
  end

  defp add_element(graph, element, parents) do
    {graph, id} = add_node(graph, node_for(element, parents == [@root_id]), parents)
    {graph, [id]}
  end

  # Only `{:or, []}` is false, and only a disjunction can absorb it: every other
  # element is a condition, which may or may not match at run time but is never
  # statically impossible.
  defp satisfiable?(elements) when is_list(elements),
    do: Enum.all?(elements, &element_satisfiable?/1)

  defp element_satisfiable?({:or, branches}), do: Enum.any?(branches, &satisfiable?/1)
  defp element_satisfiable?(_element), do: true

  # --- node insertion and sharing ---------------------------------------------

  defp add_node(%__MODULE__{} = graph, node, parents) do
    parent_set = MapSet.new(parents)

    case find_shared(graph, node, parents, parent_set) do
      nil ->
        id = graph.next_id
        node = Node.put_id(node, id)

        graph = %__MODULE__{
          graph
          | nodes: Map.put(graph.nodes, id, node),
            forward: Map.put(graph.forward, id, []),
            backward: Map.put(graph.backward, id, parent_set),
            next_id: id + 1
        }

        {link(graph, parents, id), id}

      id ->
        {graph, id}
    end
  end

  # A candidate must be a child of the parents AND have exactly this parent set.
  # Checking only the key would share nodes across different parents, letting
  # tokens from one rule join another rule's elements.
  defp find_shared(%__MODULE__{} = graph, node, parents, parent_set) do
    key = Node.sharing_key(node)

    parents
    |> Enum.flat_map(&children(graph, &1))
    |> Enum.uniq()
    |> Enum.find(fn id ->
      candidate = Map.get(graph.nodes, id)

      candidate != nil and
        Node.sharing_key(candidate) == key and
        MapSet.equal?(parents(graph, id), parent_set)
    end)
  end

  defp link(%__MODULE__{} = graph, parents, child_id) do
    forward =
      Enum.reduce(parents, graph.forward, fn parent, forward ->
        Map.update(forward, parent, [child_id], fn existing ->
          if child_id in existing, do: existing, else: existing ++ [child_id]
        end)
      end)

    %__MODULE__{graph | forward: forward}
  end

  # --- IR condition to node description ---------------------------------------

  # A condition with no equality key is a `RootJoin` only when it is *first*. Later it is
  # a cartesian product, and a `RootJoin` would drop everything the prefix bound. A
  # keyless `HashJoin` pairs every token with every element instead.
  defp node_for(%IR.Fact{join_filter: nil, join_bind: join_bind} = fact, root?)
       when join_bind == [] or is_nil(join_bind) do
    if root? do
      %Node.RootJoin{
        type: fact.type,
        alpha_code: fact.alpha.code,
        fact_binding: fact.fact_binding,
        new_bind: fact.new_bind || fact.bind
      }
    else
      %Node.HashJoin{
        type: fact.type,
        alpha_code: fact.alpha.code,
        fact_binding: fact.fact_binding,
        join_bind: [],
        new_bind: fact.new_bind || fact.bind
      }
    end
  end

  defp node_for(%IR.Fact{join_filter: nil} = fact, _root?) do
    %Node.HashJoin{
      type: fact.type,
      alpha_code: fact.alpha.code,
      fact_binding: fact.fact_binding,
      join_bind: fact.join_bind,
      new_bind: fact.new_bind || []
    }
  end

  defp node_for(%IR.Fact{join_filter: filter} = fact, _root?) do
    %Node.ExprJoin{
      type: fact.type,
      alpha_code: fact.alpha.code,
      fact_binding: fact.fact_binding,
      join_bind: fact.join_bind || [],
      new_bind: fact.new_bind || [],
      filter_code: filter.code,
      filter: filter.fun
    }
  end

  defp node_for(%IR.Coll{join_filter: nil} = coll, _root?) do
    %Node.Accumulate{
      type: coll.type,
      alpha_code: coll.alpha.code,
      coll_binding: coll.coll_binding,
      join_bind: coll.join_bind || [],
      new_bind: coll.new_bind || [],
      propagates_empty?: propagates_empty?(coll)
    }
  end

  defp node_for(%IR.Coll{join_filter: filter} = coll, _root?) do
    %Node.AccumulateJoin{
      type: coll.type,
      alpha_code: coll.alpha.code,
      coll_binding: coll.coll_binding,
      join_bind: coll.join_bind || [],
      new_bind: coll.new_bind || [],
      propagates_empty?: propagates_empty?(coll),
      filter_code: filter.code,
      filter: filter.fun
    }
  end

  defp node_for(%IR.Negation{condition: %IR.Fact{join_filter: nil} = fact}, _root?) do
    %Node.Negation{
      type: fact.type,
      alpha_code: fact.alpha.code,
      join_bind: fact.join_bind || []
    }
  end

  defp node_for(%IR.Negation{condition: %IR.Fact{join_filter: filter} = fact}, _root?) do
    %Node.NegationJoin{
      type: fact.type,
      alpha_code: fact.alpha.code,
      join_bind: fact.join_bind || [],
      filter_code: filter.code,
      filter: filter.fun
    }
  end

  # Negating a collection means "this collection is empty", which for a collect-all is
  # "no element matches": a plain negation over the element pattern, with no accumulation.
  # The collection binding is dropped because a negation binds nothing downstream.
  defp node_for(%IR.Negation{condition: %IR.Coll{join_filter: nil} = coll}, _root?) do
    %Node.Negation{
      type: coll.type,
      alpha_code: coll.alpha.code,
      join_bind: coll.join_bind || []
    }
  end

  defp node_for(%IR.Negation{condition: %IR.Coll{join_filter: filter} = coll}, _root?) do
    %Node.NegationJoin{
      type: coll.type,
      alpha_code: coll.alpha.code,
      join_bind: coll.join_bind || [],
      filter_code: filter.code,
      filter: filter.fun
    }
  end

  defp node_for(%IR.Test{expr: expr}, _root?) do
    %Node.Test{code: expr.code, fun: expr.fun}
  end

  defp node_for(%IR.CompoundNegation{}, _root?) do
    raise ArgumentError,
          "a compound negation cannot be built into the network directly. Run " <>
            "Rete.Compiler.Negation.extract/1 first: a negation node watches one " <>
            "condition, so the conjunction has to become a marker fact."
  end

  defp node_for(%IR.Gate{gate: gate}, _root?) do
    raise ArgumentError,
          "a #{gate} gate reached the network builder. Gates are rewritten by " <>
            "Rete.DSL.Normalize into conditions, negations and {:or, ...}; a Gate " <>
            "here means normalization was skipped."
  end

  defp node_for(other, _root?) do
    raise ArgumentError, "cannot build a network node from: #{inspect(other)}"
  end

  # A collection introducing no new variable has every variable fixed by the token, so it
  # has one group and propagates [] when nothing matches.
  defp propagates_empty?(%IR.Coll{new_bind: new_bind}), do: (new_bind || []) == []

  defp terminal(%IR.Production{type: :query} = production) do
    %Node.Query{
      name: production.name,
      module: production.module,
      hash: production.hash,
      rhs: production.rhs,
      bind: production.bind || []
    }
  end

  defp terminal(%IR.Production{} = production) do
    opts = production.opts || []
    generated? = Keyword.get(opts, :generated, false)

    %Node.Production{
      name: production.name,
      module: production.module,
      hash: production.hash,
      rhs: production.rhs,
      bind: production.bind || [],
      salience: Keyword.get(opts, :salience, 0),
      internal_salience: internal_salience!(production, opts, generated?),
      generated?: generated?
    }
  end

  # `:internal_salience` is reserved. It is the tier that puts a generated helper ahead of
  # the rule that negates its marker, and a user-written one would invert that ordering.
  defp internal_salience!(production, opts, generated?) do
    case Keyword.fetch(opts, :internal_salience) do
      :error ->
        0

      {:ok, value} when generated? ->
        value

      {:ok, _value} ->
        raise ArgumentError, """
        the rule #{production.name} in #{inspect(production.module)} sets \
        :internal_salience, which is reserved.

        It is the tier that puts a generated negation helper ahead of the rule \
        that negates its marker; a rule that outranks its own helper observes an \
        absence that has not been computed yet, fires, and is retracted again. \
        Use :salience to order your own rules.
        """
    end
  end
end
