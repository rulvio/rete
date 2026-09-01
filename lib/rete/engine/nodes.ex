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
  #
  # A plain negation has **no filter**: `Rete.Network.Node.Negation` carries no `:filter`
  # field, so every token-element pair matches. "Does anything match this token" is
  # therefore the same question for every token — is the bucket empty — and each of these
  # four clauses is an edge test on one boolean. `Node.NegationJoin` below cannot do this,
  # because its filter has to be evaluated per token, and it keeps the general form.
  defp dispatch(%Node.Negation{} = node, :left, tokens, %State{} = state) do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      memory = Memory.add_tokens(state.memory, node.id, key, group)
      state = %State{state | memory: memory}

      if Memory.any_elements?(memory, node.id, key) do
        {state, []}
      else
        send_left(state, node, group)
      end
    end)
  end

  defp dispatch(%Node.Negation{} = node, :left_retract, tokens, %State{} = state) do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      {memory, removed} = Memory.remove_tokens(state.memory, node.id, key, group)
      state = %State{state | memory: memory}

      if Memory.any_elements?(memory, node.id, key) do
        {state, []}
      else
        retract_left(state, node, removed)
      end
    end)
  end

  # `group` is never empty — `reduce_groups/4` only produces groups it has an item for —
  # so the bucket is non-empty afterwards either way. The only edge is the first element
  # under a key. Everything after it changes nothing, and reads no tokens at all.
  defp dispatch(%Node.Negation{} = node, :right, elements, %State{} = state) do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      newly_matched =
        if Memory.any_elements?(state.memory, node.id, key),
          do: [],
          else: Memory.tokens(state.memory, node.id, key)

      memory = Memory.add_elements(state.memory, node.id, key, group)

      retract_left(%State{state | memory: memory}, node, newly_matched)
    end)
  end

  # The mirror. The tokens are read from memory *after* the removal, so what is released
  # is what the node still holds — the retraction rule in the moduledoc.
  defp dispatch(%Node.Negation{} = node, :right_retract, elements, %State{} = state) do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      suppressed? = Memory.any_elements?(state.memory, node.id, key)
      {memory, _removed} = Memory.remove_elements(state.memory, node.id, key, group)
      state = %State{state | memory: memory}

      if suppressed? and not Memory.any_elements?(memory, node.id, key) do
        send_left(state, node, Memory.tokens(memory, node.id, key))
      else
        {state, []}
      end
    end)
  end

  # --- negation with a beta filter ------------------------------------------------------

  defp dispatch(%Node.NegationJoin{} = node, :left, tokens, %State{} = state) do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      memory = Memory.add_tokens(state.memory, node.id, key, group)
      elements = Memory.elements(memory, node.id, key)

      send_left(%State{state | memory: memory}, node, unmatched(node, group, elements))
    end)
  end

  defp dispatch(%Node.NegationJoin{} = node, :left_retract, tokens, %State{} = state) do
    reduce_groups(state, tokens, &Token.join_key(&1, node.join_bind), fn %State{} = state,
                                                                         key,
                                                                         group ->
      {memory, removed} = Memory.remove_tokens(state.memory, node.id, key, group)
      elements = Memory.elements(memory, node.id, key)

      retract_left(%State{state | memory: memory}, node, unmatched(node, removed, elements))
    end)
  end

  # Suppress the tokens that passed before, and no longer do. A token that was unmatched
  # before stops being unmatched exactly when something in `group` matches it, which is
  # cheaper to ask directly than to derive from a second `unmatched/3` over `before ++
  # group` and a list difference.
  defp dispatch(%Node.NegationJoin{} = node, :right, elements, %State{} = state) do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      tokens = Memory.tokens(state.memory, node.id, key)
      before = Memory.elements(state.memory, node.id, key)

      newly_matched =
        node
        |> unmatched(tokens, before)
        |> Enum.filter(fn token -> Enum.any?(group, &negation_match?(node, token, &1)) end)

      memory = Memory.add_elements(state.memory, node.id, key, group)

      retract_left(%State{state | memory: memory}, node, newly_matched)
    end)
  end

  # Release the tokens that were suppressed, and no longer are. A token nothing remaining
  # matches was suppressed before exactly when something *removed* matched it, since the
  # elements before the removal are the remaining ones plus the removed ones.
  defp dispatch(%Node.NegationJoin{} = node, :right_retract, elements, %State{} = state) do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      tokens = Memory.tokens(state.memory, node.id, key)
      {memory, removed} = Memory.remove_elements(state.memory, node.id, key, group)
      remaining = Memory.elements(memory, node.id, key)

      newly_free =
        node
        |> unmatched(tokens, remaining)
        |> Enum.filter(fn token -> Enum.any?(removed, &negation_match?(node, token, &1)) end)

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
  #
  # Only the groups the batch names can have changed, so only those are rebuilt. This used
  # to rebuild **every** group under the key, twice, once per token, and then cancel the
  # unchanged ones out with a pair of list differences.
  defp dispatch(%kind{} = node, right, elements, %State{} = state)
       when kind in [Node.Accumulate, Node.AccumulateJoin] and right in [:right, :right_retract] do
    reduce_groups(state, elements, &Element.join_key(&1, node.join_bind), fn %State{} = state,
                                                                             key,
                                                                             group ->
      case Memory.tokens(state.memory, node.id, key) do
        [] -> {store_only(state, node, key, group, right), []}
        tokens -> recollect(state, node, key, group, right, tokens)
      end
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
    # Collected newest first and reversed once. Appending per token would be quadratic in
    # the size of one batch, and a batch is a whole call's worth of retractions.
    {state, reversed} =
      Enum.reduce(tokens, {state, []}, fn token, {%State{} = state, ops} ->
        {agenda, outcome} = Agenda.remove(state.agenda, activation(state, node, token))
        state = %State{state | agenda: agenda}

        case outcome do
          :removed ->
            {state, [{:event, {:activation_removed, Node.source(node), token}} | ops]}

          :missing ->
            {memory, facts} = Memory.take_insertion(state.memory, node.id, token)
            {%State{state | memory: memory}, [{:retract_facts, node.id, facts} | ops]}
        end
      end)

    {state, Enum.reverse(reversed)}
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

  # The tokens of `tokens` that nothing in `elements` matches. Only a `NegationJoin` needs
  # this. A plain negation's answer does not vary by token, and its clauses use that
  # instead of paying a pass per element.
  defp unmatched(node, tokens, elements) do
    Enum.reject(tokens, fn token ->
      Enum.any?(elements, &negation_match?(node, token, &1))
    end)
  end

  defp negation_match?(%Node.NegationJoin{filter: filter}, token, element) do
    !!filter.(token.bindings, element.bindings)
  end

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
    # Read once per group, not once per group per token: every token under the key sees
    # the same members, and a filtered collection narrows them from the same candidates.
    groups =
      for group_key <- groups_for(state, node, key),
          do: {group_key, group_members(state, node, key, group_key)}

    for token <- tokens,
        {group_key, members} <- groups,
        extended <- group_tokens(node, group_key, members, token),
        do: extended
  end

  # No token under the key, so no match can change and nothing needs reading. Storing the
  # members is all there is to do. This is the ordinary bulk load — a session is fed its
  # facts, and the token that will collect them is still queued behind them — and reading
  # each group back as it grew is what made filling one collection quadratic.
  defp store_only(%State{} = state, node, key, group, direction) do
    {memory, _changed} = update_groups(state.memory, node, key, group, direction)

    %State{state | memory: memory}
  end

  defp recollect(%State{} = state, node, key, group, direction, tokens) do
    candidates = group |> Enum.map(&group_key(node, key, &1)) |> Enum.uniq()
    before = Map.new(candidates, &{&1, group_members(state, node, key, &1)})

    {memory, changed} = update_groups(state.memory, node, key, group, direction)
    state = %State{state | memory: memory}

    touched = Enum.filter(candidates, &MapSet.member?(changed, &1))
    now = Map.new(touched, &{&1, group_members(state, node, key, &1)})
    changes = transitions(node, touched, before, now, tokens)

    {state, retractions} = retract_left(state, node, Enum.flat_map(changes, &elem(&1, 0)))
    {state, additions} = send_left(state, node, Enum.flat_map(changes, &elem(&1, 1)))

    {state, retractions ++ additions}
  end

  # `{was, is}` per token per changed group, token-major so that a rule's matches reach the
  # agenda in token order however many groups the batch touched.
  #
  # A token whose match is unchanged must not appear at all. Retracting and re-sending it
  # nets to the same facts, so the only trace is that the rule ran again — which is exactly
  # what a listener sees, and what a right hand side with an effect in it would do twice.
  #
  # A plain collection cannot hide a change from a token, because every token sees the same
  # members: a group that changed changed for all of them, and the comparison is skipped. A
  # filtered one decides membership per token, so an element landing outside one token's
  # filter leaves that token's match exactly as it was.
  defp transitions(%Node.Accumulate{} = node, touched, before, now, tokens) do
    for token <- tokens, group_key <- touched do
      {group_tokens(node, group_key, before[group_key], token),
       group_tokens(node, group_key, now[group_key], token)}
    end
  end

  defp transitions(%Node.AccumulateJoin{} = node, touched, before, now, tokens) do
    for token <- tokens,
        group_key <- touched,
        was = group_tokens(node, group_key, before[group_key], token),
        is = group_tokens(node, group_key, now[group_key], token),
        was != is do
      {was, is}
    end
  end

  # What one group contributes for one token: one extended token, or nothing.
  #
  # `nil` members mean the group does not exist, which contributes nothing at all. That is
  # not the same as a group holding nothing, which a collection binding no new variables
  # still propagates — see `group_members/4`.
  defp group_tokens(_node, _group_key, nil, _token), do: []

  defp group_tokens(node, group_key, members, token) do
    facts = visible(node, token, members)

    if facts == [] and not node.propagates_empty? do
      []
    else
      [Token.extend(token, facts, node.id, Map.merge(group_key, collection_binding(node, facts)))]
    end
  end

  # The group keys a token must be offered. A group with no members is not the same as no
  # group: a pattern that binds no new variables has every variable fixed by the token, so
  # it has exactly one group whether or not a fact landed in it. This is precomputed as
  # `:propagates_empty?` at build time.
  defp groups_for(%State{} = state, node, key) do
    case Memory.group_keys(state.memory, node.id, key) do
      [] -> if node.propagates_empty?, do: [key], else: []
      group_keys -> group_keys
    end
  end

  # The same rule for one group: `nil` where it does not exist, `[]` where the node
  # conjures the virtual empty one. `propagates_empty?` holds exactly when the pattern
  # binds no new variables, so the only group key it can be asked about is the join key
  # itself, and there is never more than one group to confuse it with.
  #
  # A plain collection reads the facts straight out, because that is all it binds. A
  # filtered one decides membership per token from the bindings its alpha produced, so it
  # has to read elements. `visible/3` closes over the difference.
  defp group_members(%State{} = state, %Node.Accumulate{} = node, key, group_key) do
    absent_or(Memory.group_facts(state.memory, node.id, key, group_key), node)
  end

  defp group_members(%State{} = state, %Node.AccumulateJoin{} = node, key, group_key) do
    absent_or(Memory.group(state.memory, node.id, key, group_key), node)
  end

  defp absent_or(nil, node), do: if(node.propagates_empty?, do: [], else: nil)
  defp absent_or(members, _node), do: members

  # A plain collection takes its group whole. For a filtered one, the stored group is
  # only a candidate set, and membership is decided per token. That is why groups hold
  # elements, not facts — the filter needs the bindings the alpha produced.
  # A filtered collection's group is only a candidate set: membership is decided per token,
  # which is why it is read as elements rather than facts. A plain one gathers its group
  # whole, and `group_members/4` has already read it as facts.
  defp visible(%Node.AccumulateJoin{filter: filter}, token, candidates) do
    for element <- candidates,
        filter.(token.bindings, element.bindings),
        do: element.fact
  end

  defp visible(_node, _token, facts), do: facts

  defp collection_binding(%{coll_binding: nil}, _facts), do: %{}
  defp collection_binding(%{coll_binding: name}, facts), do: %{name => facts}

  # Applies a batch to the groups it names, and reports which of them actually changed.
  # Retracting something a group never held changes nothing, and must not produce a
  # retract-and-resend round trip downstream. That is the same guard
  # `Rete.Memory.remove_elements/4` gives the join nodes.
  #
  # A group that loses its last member is dropped, by `Rete.Memory.remove_from_group/5`.
  # The key holds binding values, so keeping empties would leak one per entity the session
  # has seen; `group_members/4` conjures the virtual empty group when a token asks for one.
  defp update_groups(memory, node, key, elements, direction) do
    Enum.reduce(elements, {memory, MapSet.new()}, fn element, {memory, changed} ->
      group_key = group_key(node, key, element)

      case direction do
        :right ->
          {Memory.add_to_group(memory, node.id, key, group_key, element),
           MapSet.put(changed, group_key)}

        :right_retract ->
          case Memory.remove_from_group(memory, node.id, key, group_key, element) do
            {memory, :removed} -> {memory, MapSet.put(changed, group_key)}
            {memory, :absent} -> {memory, changed}
          end
      end
    end)
  end

  # A collection that binds no new variables has every variable fixed by the token, so its
  # one group is keyed by the join key itself.
  defp group_key(%{new_bind: []}, key, _element), do: key
  defp group_key(node, _key, element), do: Map.take(element.bindings, node.new_bind)

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
  #
  # Each group's ops are pushed and the whole lot reversed once. Appending per group would
  # be quadratic in the number of groups, and one batch of n facts under n distinct join
  # keys is exactly n groups.
  defp reduce_groups(%State{} = state, items, key_fun, fun) do
    {state, reversed} =
      items
      |> group_in_arrival_order(key_fun)
      |> Enum.reduce({state, []}, fn {key, group}, {%State{} = state, ops} ->
        {state, more} = fun.(state, key, group)
        {state, [more | ops]}
      end)

    {state, reversed |> Enum.reverse() |> Enum.concat()}
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
