defmodule Rete.Compiler.BetaGraph do
  @moduledoc """
  The beta side of the network: a graph of `Rete.Network.Node` descriptions.

  Each production's sorted left hand side is walked in order, adding one node
  per condition and hanging it off the nodes the previous condition produced.
  Node `0` is an artificial root that every rule's first condition attaches to,
  so the graph has a single entry point.

  ## Parents are a list

  A condition is added under a *list* of parent ids, not one. A disjunction
  needs it: `{:or, [b1, b2]}` adds each branch as its own chain under the
  current parents, and hands the union of the branch terminals to the next
  condition. The condition after a disjunction therefore has one parent per
  branch, and the branches re-converge on it.

  This is also why the left hand side is never flattened to disjunctive normal
  form. Whole-LHS DNF is exponential in the number of disjunctions; fanning out
  and re-converging per condition is linear.

  ## Sharing

  Two conditions collapse onto one node when they are **equal** and have the
  **same parent set**. Equality alone is not enough, and the difference is a
  correctness bug rather than a missed optimisation:

      defrule a({:customer, cid}, {:order, cid, amt})
      defrule b({:vendor, cid},   {:order, cid, amt})

  The two `{:order, cid, amt}` conditions are equal, but they sit under
  different parents. Sharing them would let a token from `{:vendor, ...}` join
  elements that only ever belonged to `{:customer, ...}`, so `a` would fire on
  `b`'s facts. Clara records the same requirement as issue 433.

  Equality itself is `Rete.Network.Node.sharing_key/1`, built from expression
  codes. The front end guarantees a code is deterministic across compilations and equal
  exactly when behaviour is equal, which is what makes sharing reproducible
  between a full build and an incremental one.

  Sharing is what makes two rules over a common prefix evaluate that prefix
  once, so it is worth pinning precisely in tests rather than treating as an
  incidental optimisation.

  ## Terminals

  A production or query node is keyed on the production's identity, so two rules
  with an identical left hand side still get one terminal each and fire
  independently.

  ## Unsatisfiable left hand sides

  `{:or, []}` is *false*: no branch, so nothing on that path can ever match.
  Normalization keeps it rather than dropping it, because dropping it would
  change the meaning of the production. Nothing is built for a path that runs
  through one — not the conditions after it, and not the terminal — because a
  keyless condition after a false element would otherwise become an entry point
  the alpha index feeds, and an unsatisfiable rule would fire on every fact.
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

  # A disjunction: each branch is a chain under the current parents, and the
  # union of their terminals becomes the parents of whatever follows. A branch
  # that is itself unsatisfiable contributes no chain and no terminal;
  # `add_production/2` has already established that at least one branch here is
  # satisfiable, so the union is never empty.
  defp add_element(graph, {:or, branches}, parents) do
    {graph, terminals} =
      branches
      |> Enum.filter(&satisfiable?/1)
      |> Enum.reduce({graph, []}, fn branch, {graph, acc} ->
        {graph, branch_parents} = add_elements(graph, branch, parents)
        {graph, acc ++ branch_parents}
      end)

    # An empty branch matches unconditionally, so its "terminal" is the parent
    # set itself; dedupe in case two branches converge on a shared node.
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

  # A condition with no equality key is a `RootJoin` only when it is *first*.
  # Later on it is a cartesian product: there is an incoming token, and a
  # `RootJoin` would turn each element straight into a token of its own, drop
  # everything the prefix bound and make the conditions before it vacuous. A
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

  # `Rete.IR.Negation` may hold a collection as well as a fact, and negating a
  # collection can only mean "this collection is empty". Collections are
  # collect-all, so an element belongs to the collection exactly when it matches
  # the pattern and the token, and "the collection is empty" is therefore
  # literally "no element matches" — a plain negation over the element pattern,
  # with no accumulation to do. The collection binding is dropped because a
  # negation binds nothing downstream, and `:propagates_empty?` does not apply:
  # it describes what an accumulate node emits, and there is no accumulate node.
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

  # The locked empty-collection rule: a collection that introduces no new
  # variable has every variable fixed by the token, so it has exactly one group
  # and propagates [] when nothing matches. One that introduces a new variable
  # groups by it, and a group only exists where a fact created it.
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

  # `:internal_salience` is the tier `Rete.Compiler.Negation` uses to put an
  # extracted helper ahead of the rule that negates its marker. A user-written
  # one would silently invert that ordering — the negating rule would observe an
  # absence that had merely not been computed yet — so the key is reserved
  # rather than merged with the user's options.
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
