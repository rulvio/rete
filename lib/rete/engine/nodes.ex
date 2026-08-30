defmodule Rete.Engine.Nodes do
  @moduledoc """
  What each node kind does when tokens or elements arrive.

  Every clause has the same shape: take the state and the items, return the new
  state and the propagation work produced. The loop in `Rete.Engine` does the
  walking, so nothing here calls a child directly.

  ## The retraction rule

  Every node must retract exactly what it propagated. Not "something equivalent"
  — the same value, because downstream memories remove by value and a mismatch
  leaves a token stranded forever, which then fires a rule whose support is gone.

  The discipline that makes this hold is that a node never propagates from what
  it was *handed*; it propagates from what its memory says, after the memory has
  been updated. `Rete.Memory.remove_elements/4` and `remove_tokens/4` report what
  was actually there, and only that is propagated onward. A retraction of
  something never stored produces no downstream work at all.

  ## The root token

  Nothing binds before a rule's first condition, so a rule that opens with a
  negation, a collection or a test has no element to build its first token from.
  A `RootJoin` does not need one — it mints a token per element — but a
  `Negation` hanging off the beta root has to pass *something* while nothing
  matches, and an `Accumulate` there has to emit its collection to someone.

  Classic Rete answers this with a single empty token seeded at the root, and so
  does this. `seed_root/1` plants it: one `%Rete.Token{}` sent left to every
  child of the beta root, once per session and never retracted. Without it those
  rules are dead — they never fire, and nothing says so.

  It has to be planted at state creation rather than on the first fact, because
  a rule whose whole left hand side is an absence or an empty collection is true
  of the *empty* session and must be able to fire before anything is inserted.
  `Rete.Engine.new/1` is what calls it, and calling it twice is a no-op — a
  second root token would give every one of those rules a second support that no
  retraction clears.
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

  Every child of the beta root is sent one `%Rete.Token{}` from the left. A
  `RootJoin` ignores it — its elements are its own starting point — but a
  negation, a collection or a test in first position has no other way to receive
  the match it is entitled to.

  Does nothing after the first call: the root token is permanent, and a second
  one would give every rule that opens with a negation or a collection a second
  support that no retraction clears.
  """
  @spec seed_root(State.t()) :: {State.t(), [State.op()]}
  def seed_root(%State{memory: %Memory{root_seeded?: true}} = state), do: {state, []}

  def seed_root(%State{network: network} = state) do
    state = %State{state | memory: Memory.mark_root_seeded(state.memory)}
    children = Network.children(network, BetaGraph.root_id())

    {state, for(child <- children, do: {:left, child, [@root_token]})}
  end

  # --- root join -----------------------------------------------------------------

  # No token to join against: each element becomes a match on its own.
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
    # The root token reaches it like every other child of the root, and it has
    # no use for it: joining the empty token with each element is exactly what
    # the `:right` clause already does, so honouring it would double every match.
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

  # A token passes only while nothing matches it. The interesting transitions are
  # the edges: the *first* element to arrive suppresses the tokens that already
  # went through, and the *last* to leave releases them.
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

      # Suppress the tokens that passed before and do not any more.
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

      # Release the tokens that were suppressed and no longer are.
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

  # An element joining or leaving a collection changes the value every matching
  # token carries, so each one is retracted at its old value and re-sent at the
  # new one. Sending without retracting would leave two contradictory matches
  # downstream, both of which believe they are current.
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

  # No fact input and no memory: a test is a filter on the way past. It must
  # apply the same predicate on retraction, or it would try to retract tokens it
  # never let through.
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
    {%State{state | agenda: agenda}, []}
  end

  # Either the match is still waiting to fire, in which case it simply never
  # does, or it already fired and truth maintenance has to take back what it
  # inserted. Those are the only two possibilities, and telling them apart is
  # exactly what `Agenda.remove/2` reports.
  defp dispatch(%Node.Production{} = node, :left_retract, tokens, %State{} = state) do
    Enum.reduce(tokens, {state, []}, fn token, {%State{} = state, ops} ->
      {agenda, outcome} = Agenda.remove(state.agenda, activation(state, node, token))
      state = %State{state | agenda: agenda}

      case outcome do
        :removed ->
          {state, ops}

        :missing ->
          {memory, facts} = Memory.take_insertion(state.memory, node.id, token)
          {%State{state | memory: memory}, ops ++ [{:retract_facts, facts}]}
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

  # One extended token per group, plus the empty one when the locked rule says a
  # collection with no new variables still matches with nothing in it.
  defp collected(%State{} = state, node, key, tokens) do
    groups = groups_for(state, node, key)

    for token <- tokens,
        {group_key, candidates} <- groups,
        facts = visible(node, token, candidates),
        facts != [] or node.propagates_empty? do
      Token.extend(token, facts, node.id, Map.merge(group_key, collection_binding(node, facts)))
    end
  end

  # A group with no members is not the same as no group. When the pattern binds
  # no new variables every variable it uses is already fixed by the token, so
  # there is exactly one group and it exists whether or not a fact ever landed in
  # it — that is the locked empty-collection rule, precomputed as
  # :propagates_empty? in W2.
  defp groups_for(%State{} = state, node, key) do
    case Memory.groups(state.memory, node.id, key) do
      empty when empty == %{} -> if node.propagates_empty?, do: %{key => []}, else: %{}
      groups -> groups
    end
  end

  # A plain collection takes its group whole. A filtered one cannot: whether a
  # candidate belongs depends on the token, so the stored group is only a
  # candidate set and membership is decided per token. That is why groups hold
  # elements rather than bare facts — the filter needs the bindings the alpha
  # produced, which a fact on its own has thrown away.
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
            # A group that loses its last member is dropped, whether or not the
            # collection groups. Keeping an empty one for a non-grouping
            # collection would leak: the key holds binding *values*, so a
            # session that inserts and retracts a million customers would
            # accumulate a million empty groups that nothing ever reads. The
            # empty collection a non-grouping pattern still matches is virtual —
            # `groups_for/3` conjures it whenever a token asks — so there is
            # nothing to preserve here.
            [] -> Memory.drop_group(memory, node.id, key, group_key)
            remaining -> Memory.put_group(memory, node.id, key, group_key, remaining)
          end
      end
    end)
  end

  # A group is kept in the term order of its facts, not in the order they
  # arrived. What a rule concludes has to be a function of the fact set: with
  # arrival order, `hd(orders)` depends on how the session was fed, and
  # retracting a member and putting it back moves it to the end and changes the
  # conclusion — a round trip that does not round trip. The list is built sorted,
  # so one element costs a walk rather than a re-sort.
  defp insert_ordered([], element), do: [element]

  defp insert_ordered([head | tail] = elements, element) do
    if order_key(element) <= order_key(head) do
      [element | elements]
    else
      [head | insert_ordered(tail, element)]
    end
  end

  # The fact first, because that is what the rule sees. The bindings only break
  # ties between two elements over the same fact, so the order is total.
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

  # Items arriving together can belong to different join groups, so they are
  # split before anything touches memory: a group is the unit a join works on.
  defp reduce_groups(%State{} = state, items, key_fun, fun) do
    items
    |> Enum.group_by(key_fun)
    |> Enum.sort_by(fn {key, _} -> :erlang.phash2(key) end)
    |> Enum.reduce({state, []}, fn {key, group}, {%State{} = state, ops} ->
      {state, more} = fun.(state, key, group)
      {state, ops ++ more}
    end)
  end
end
