defmodule Rete.Engine.Nodes do
  @moduledoc """
  What each node kind does when tokens or elements arrive.

  **Internal.** Every clause has the same shape. It takes the state and the items. It
  returns the new state, and the propagation work produced. The loop in `Rete.Engine`
  does the walking, so nothing here calls a child directly.

  **The retraction rule.** A node must retract exactly what it propagated, by value.
  Downstream memories remove by value, and a mismatch strands a token forever. So a node
  never propagates from what it was *handed*. It propagates from what its memory reports,
  after the memory update. Retracting something never stored produces no downstream work
  at all.

  Two kinds of work are returned as ops, instead of done here.
  `{:retract_facts, node_id, facts}` has to re-enter the alpha network.
  `{:event, event}` is not a node's business either. See `docs/design/engine.md` §5.
  """

  alias Rete.Activation
  alias Rete.Agenda
  alias Rete.Compiler.BetaGraph
  alias Rete.Element
  alias Rete.Engine.State
  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Token

  @root_token %Token{}

  @doc """
  Handles one unit of propagation, returning the state and the work it produced.
  """
  @spec handle(State.t(), State.op()) :: {State.t(), [State.op()]}
  def handle(%State{} = state, {kind, node_id, items}) do
    node = Network.node(state.network, node_id)
    dispatch(node, kind, items, state)
  end

  @doc """
  Seeds the beta root's empty token, returning the state and the work it produced.

  Every child of the beta root is sent one `%Rete.Token{}` from the left. A `RootJoin`
  ignores it. A negation, a collection, or a test in first position has no other way to
  receive the match it is entitled to.

  Does nothing after the first call. A second root token would give every such rule a
  second support that no retraction ever clears. See `docs/design/engine.md` §6.
  """
  @spec seed_root(State.t()) :: {State.t(), [State.op()]}
  def seed_root(%State{memory: %Memory{root_seeded?: true}} = state), do: {state, []}

  def seed_root(%State{network: network} = state) do
    state = %State{state | memory: Memory.mark_root_seeded(state.memory)}
    children = Network.children(network, BetaGraph.root_id())

    {state, for(child <- children, do: {:left, child, [@root_token]})}
  end

  # --- root join -----------------------------------------------------------------

  # No token to join against — each element becomes a match on its own.
  defp dispatch(%Node.RootJoin{} = node, :right, elements, %State{} = state) do
    key = %{}
    memory = Memory.add_elements(state.memory, node.id, key, elements)
    send_left(%State{state | memory: memory}, node, Enum.map(elements, &token(node, &1)))
  end

  defp dispatch(%Node.RootJoin{} = node, :right_retract, elements, %State{} = state) do
    {memory, removed} = Memory.remove_elements(state.memory, node.id, %{}, elements)
    retract_left(%State{state | memory: memory}, node, Enum.map(removed, &token(node, &1)))
  end

  defp dispatch(%Node.RootJoin{}, kind, _items, state) when kind in [:left, :left_retract] do
    # The root token reaches it like every other child of the root, but it has no use for
    # it. The `:right` clause already joins the empty token with each element. So
    # honouring this would double every match.
    {state, []}
  end

  # --- hash join and expression join ------------------------------------------------

  defp dispatch(%kind{} = node, :right, elements, %State{} = state)
       when kind in [Node.HashJoin, Node.ExprJoin] do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      memory = Memory.add_elements(state.memory, node.id, key, group)
      tokens = Memory.tokens(memory, node.id, key)

      send_left(%State{state | memory: memory}, node, joined(node, tokens, group))
    end)
  end

  defp dispatch(%kind{} = node, :right_retract, elements, %State{} = state)
       when kind in [Node.HashJoin, Node.ExprJoin] do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      {memory, removed} = Memory.remove_elements(state.memory, node.id, key, group)
      tokens = Memory.tokens(memory, node.id, key)

      retract_left(%State{state | memory: memory}, node, joined(node, tokens, removed))
    end)
  end

  defp dispatch(%kind{} = node, :left, tokens, %State{} = state)
       when kind in [Node.HashJoin, Node.ExprJoin] do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      memory = Memory.add_tokens(state.memory, node.id, key, group)
      elements = Memory.elements(memory, node.id, key)

      send_left(%State{state | memory: memory}, node, joined(node, group, elements))
    end)
  end

  defp dispatch(%kind{} = node, :left_retract, tokens, %State{} = state)
       when kind in [Node.HashJoin, Node.ExprJoin] do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      {memory, removed} = Memory.remove_tokens(state.memory, node.id, key, group)
      elements = Memory.elements(memory, node.id, key)

      retract_left(%State{state | memory: memory}, node, joined(node, removed, elements))
    end)
  end

  # --- negation ---------------------------------------------------------------------

  # A token passes only while nothing matches it. The edges are what matter here. The
  # first element to arrive suppresses the tokens that already went through. The last to
  # leave releases them.
  defp dispatch(%kind{} = node, :left, tokens, %State{} = state)
       when kind in [Node.Negation, Node.NegationJoin] do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      memory = Memory.add_tokens(state.memory, node.id, key, group)
      elements = Memory.elements(memory, node.id, key)

      send_left(%State{state | memory: memory}, node, unmatched(node, group, elements))
    end)
  end

  defp dispatch(%kind{} = node, :left_retract, tokens, %State{} = state)
       when kind in [Node.Negation, Node.NegationJoin] do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      {memory, removed} = Memory.remove_tokens(state.memory, node.id, key, group)
      elements = Memory.elements(memory, node.id, key)

      retract_left(%State{state | memory: memory}, node, unmatched(node, removed, elements))
    end)
  end

  defp dispatch(%kind{} = node, :right, elements, %State{} = state)
       when kind in [Node.Negation, Node.NegationJoin] do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      tokens = Memory.tokens(state.memory, node.id, key)
      before = Memory.elements(state.memory, node.id, key)
      memory = Memory.add_elements(state.memory, node.id, key, group)

      # Suppress the tokens that passed before, and no longer do.
      newly_matched = unmatched(node, tokens, before) -- unmatched(node, tokens, before ++ group)

      retract_left(%State{state | memory: memory}, node, newly_matched)
    end)
  end

  defp dispatch(%kind{} = node, :right_retract, elements, %State{} = state)
       when kind in [Node.Negation, Node.NegationJoin] do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      tokens = Memory.tokens(state.memory, node.id, key)
      before = Memory.elements(state.memory, node.id, key)
      {memory, _removed} = Memory.remove_elements(state.memory, node.id, key, group)
      remaining = Memory.elements(memory, node.id, key)

      # Release the tokens that were suppressed, and no longer are.
      newly_free = unmatched(node, tokens, remaining) -- unmatched(node, tokens, before)

      send_left(%State{state | memory: memory}, node, newly_free)
    end)
  end

  # --- collection binding -------------------------------------------------------------

  defp dispatch(%kind{} = node, :left, tokens, %State{} = state)
       when kind in [Node.Accumulate, Node.AccumulateJoin] do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      memory = Memory.add_tokens(state.memory, node.id, key, group)
      state = %State{state | memory: memory}

      send_left(state, node, collected(state, node, key, group))
    end)
  end

  defp dispatch(%kind{} = node, :left_retract, tokens, %State{} = state)
       when kind in [Node.Accumulate, Node.AccumulateJoin] do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      {memory, removed} = Memory.remove_tokens(state.memory, node.id, key, group)
      state = %State{state | memory: memory}

      retract_left(state, node, collected(state, node, key, removed))
    end)
  end

  # An element joining or leaving a collection changes the value every matching token
  # carries. So the node retracts each at its old value, and re-sends it at the new one.
  # Sending without retracting would leave two contradictory matches downstream.
  defp dispatch(%kind{} = node, right, elements, %State{} = state)
       when kind in [Node.Accumulate, Node.AccumulateJoin] and right in [:right, :right_retract] do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      tokens = Memory.tokens(state.memory, node.id, key)
      before = collected(state, node, key, tokens)

      state = %State{state | memory: update_groups(state.memory, node, key, group, right)}
      now = collected(state, node, key, tokens)

      {state, retractions} = retract_left(state, node, before -- now)
      {state, additions} = send_left(state, node, now -- before)

      {state, retractions ++ additions}
    end)
  end

  # --- test -----------------------------------------------------------------------------

  # No fact input and no memory. A test is a filter on the way past. It must apply the
  # same predicate on retraction, or it would retract tokens it never let through.
  defp dispatch(%Node.Test{} = node, :left, tokens, %State{} = state) do
    send_left(state, node, Enum.filter(tokens, &passes?(node, &1)))
  end

  defp dispatch(%Node.Test{} = node, :left_retract, tokens, %State{} = state) do
    retract_left(state, node, Enum.filter(tokens, &passes?(node, &1)))
  end

  defp dispatch(%Node.Test{}, kind, _items, state) when kind in [:right, :right_retract] do
    {state, []}
  end

  # --- terminals -------------------------------------------------------------------------

  defp dispatch(%Node.Production{} = node, :left, tokens, %State{} = state) do
    agenda = Enum.reduce(tokens, state.agenda, &Agenda.add(&2, activation(state, node, &1)))
    source = Node.source(node)
    events = for token <- tokens, do: {:event, {:activation_added, source, token}}

    {%State{state | agenda: agenda}, events}
  end

  # Either the match is still pending, so it never fires. Or it fired, and truth
  # maintenance takes back what it inserted. `Agenda.remove/2` reports which case this is.
  defp dispatch(%Node.Production{} = node, :left_retract, tokens, %State{} = state) do
    Enum.reduce(tokens, {state, []}, fn token, {%State{} = state, ops} ->
      {agenda, outcome} = Agenda.remove(state.agenda, activation(state, node, token))
      state = %State{state | agenda: agenda}

      case outcome do
        :removed ->
          {state, ops ++ [{:event, {:activation_removed, Node.source(node), token}}]}

        :missing ->
          {memory, facts} = Memory.take_insertion(state.memory, node.id, token)
          {%State{state | memory: memory}, ops ++ [{:retract_facts, node.id, facts}]}
      end
    end)
  end

  defp dispatch(%Node.Query{} = node, :left, tokens, %State{} = state) do
    {%State{state | memory: Memory.add_tokens(state.memory, node.id, %{}, tokens)}, []}
  end

  defp dispatch(%Node.Query{} = node, :left_retract, tokens, %State{} = state) do
    {memory, _removed} = Memory.remove_tokens(state.memory, node.id, %{}, tokens)
    {%State{state | memory: memory}, []}
  end

  defp dispatch(%Node.Query{}, kind, _items, state) when kind in [:right, :right_retract] do
    {state, []}
  end

  defp dispatch(node, kind, _items, _state) do
    raise ArgumentError, "no #{kind} behaviour for #{inspect(node)}"
  end

  # --- building matches ----------------------------------------------------------------

  defp token(node, %Element{fact: fact, bindings: bindings}) do
    Token.extend(%Token{}, fact, node.id, with_fact_binding(node, fact, bindings))
  end

  defp joined(node, tokens, elements) do
    for token <- tokens,
        element <- elements,
        matches?(node, token, element),
        do:
          Token.extend(
            token,
            element.fact,
            node.id,
            with_fact_binding(node, element.fact, element.bindings)
          )
  end

  defp with_fact_binding(%{fact_binding: nil}, _fact, bindings), do: bindings
  defp with_fact_binding(%{fact_binding: name}, fact, bindings), do: Map.put(bindings, name, fact)
  defp with_fact_binding(_node, _fact, bindings), do: bindings

  defp matches?(%Node.ExprJoin{filter: filter}, token, element) do
    !!filter.(token.bindings, element.bindings)
  end

  defp matches?(_node, _token, _element), do: true

  # The tokens of `tokens` that nothing in `elements` matches.
  defp unmatched(node, tokens, elements) do
    Enum.filter(tokens, fn token ->
      not Enum.any?(elements, &negation_match?(node, token, &1))
    end)
  end

  defp negation_match?(%Node.NegationJoin{filter: filter}, token, element) do
    !!filter.(token.bindings, element.bindings)
  end

  defp negation_match?(_node, _token, _element), do: true

  defp passes?(%Node.Test{fun: fun}, token), do: !!fun.(token.bindings)

  defp activation(%State{} = state, node, token) do
    %Activation{
      node_id: node.id,
      token: token,
      salience: node.salience,
      internal_salience: node.internal_salience,
      order: Map.get(state.order, node.id, 0)
    }
  end

  # --- collections ------------------------------------------------------------------------

  # One extended token per group, plus the empty group when a collection that binds no
  # new variables still matches with nothing gathered.
  defp collected(%State{} = state, node, key, tokens) do
    groups = groups_for(state, node, key)

    for token <- tokens,
        {group_key, candidates} <- groups,
        facts = visible(node, token, candidates),
        facts != [] or node.propagates_empty? do
      Token.extend(token, facts, node.id, Map.merge(group_key, collection_binding(node, facts)))
    end
  end

  # A group with no members is not the same as no group. A pattern that binds no new
  # variables has every variable fixed by the token. So it has exactly one group, whether
  # or not a fact landed in it. This is precomputed as `:propagates_empty?` at build time.
  defp groups_for(%State{} = state, node, key) do
    case Memory.groups(state.memory, node.id, key) do
      empty when empty == %{} -> if node.propagates_empty?, do: %{key => []}, else: %{}
      groups -> groups
    end
  end

  # A plain collection takes its group whole. For a filtered one, the stored group is
  # only a candidate set, and membership is decided per token. That is why groups hold
  # elements, not facts — the filter needs the bindings the alpha produced.
  defp visible(%Node.AccumulateJoin{filter: filter}, token, candidates) do
    for element <- candidates,
        filter.(token.bindings, element.bindings),
        do: element.fact
  end

  defp visible(_node, _token, candidates), do: Enum.map(candidates, & &1.fact)

  defp collection_binding(%{coll_binding: nil}, _facts), do: %{}
  defp collection_binding(%{coll_binding: name}, facts), do: %{name => facts}

  defp update_groups(memory, node, key, elements, direction) do
    Enum.reduce(elements, memory, fn element, memory ->
      group_key = if node.new_bind == [], do: key, else: Map.take(element.bindings, node.new_bind)
      current = memory |> Memory.groups(node.id, key) |> Map.get(group_key, [])

      case direction do
        :right ->
          Memory.put_group(memory, node.id, key, group_key, insert_ordered(current, element))

        :right_retract ->
          case List.delete(current, element) do
            # A group that loses its last member is dropped either way. The key holds
            # binding values, so keeping empties would leak one per entity the session has
            # seen. `groups_for/3` conjures the virtual empty group when a token asks for
            # one.
            [] -> Memory.drop_group(memory, node.id, key, group_key)
            remaining -> Memory.put_group(memory, node.id, key, group_key, remaining)
          end
      end
    end)
  end

  # A group is kept in the term order of its facts, not arrival order. What a rule
  # concludes has to be a function of the fact set. Under arrival order, `hd(orders)`
  # would depend on how the session was fed. A retract-and-reinsert round trip would then
  # move a member to the end, and change the conclusion.
  defp insert_ordered([], element), do: [element]

  defp insert_ordered([head | tail] = elements, element) do
    if order_key(element) <= order_key(head) do
      [element | elements]
    else
      [head | insert_ordered(tail, element)]
    end
  end

  # The fact comes first, because that is what the rule sees. The bindings break ties
  # between two elements over the same fact. This makes the order total.
  defp order_key(%Element{fact: fact, bindings: bindings}), do: {fact, bindings}

  # --- propagation helpers ---------------------------------------------------------------

  defp send_left(%State{} = state, _node, []), do: {state, []}

  defp send_left(%State{} = state, node, tokens) do
    {state, for(child <- Network.children(state.network, node.id), do: {:left, child, tokens})}
  end

  defp retract_left(%State{} = state, _node, []), do: {state, []}

  defp retract_left(%State{} = state, node, tokens) do
    {state,
     for(child <- Network.children(state.network, node.id), do: {:left_retract, child, tokens})}
  end

  # Items arriving together can belong to different join groups. So the engine splits
  # them before anything touches memory. A group is the unit a join works on.
  defp reduce_groups(%State{} = state, items, key_fun, fun) do
    items
    |> group_in_arrival_order(key_fun)
    |> Enum.reduce({state, []}, fn {key, group}, {%State{} = state, ops} ->
      {state, more} = fun.(state, key, group)
      {state, ops ++ more}
    end)
  end

  # Groups keyed the way `Enum.group_by/2` does, handed back in the order each key first
  # appeared. Do not substitute map order. Each group appends its propagation work in
  # turn, so this order decides the order matches reach the agenda. Elixir iterates a map
  # of up to 32 keys in term order, and a larger one in an internal hash order.
  defp group_in_arrival_order(items, key_fun) do
    {groups, keys} =
      Enum.reduce(items, {%{}, []}, fn item, {groups, keys} ->
        key = key_fun.(item)

        case groups do
          %{^key => group} -> {%{groups | key => [item | group]}, keys}
          _ -> {Map.put(groups, key, [item]), [key | keys]}
        end
      end)

    for key <- Enum.reverse(keys), do: {key, groups |> Map.fetch!(key) |> Enum.reverse()}
  end
end
