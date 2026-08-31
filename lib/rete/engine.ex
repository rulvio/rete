defmodule Rete.Engine do
  @moduledoc """
  The propagation loop and the fire cycle.

  **Internal.** Not part of the public API. Call it through `Rete.Session`.

  Propagation drains a queue of pending work: a node consumes one unit and returns the
  work it produced. Firing pops the most salient activation, runs its right hand side and
  inserts what it returned. Propagation is drained to completion **before** the next
  activation fires, so a rule always sees a settled network.

  `fire_rules/2` returns at quiescence. Every rule whose left hand side holds has fired,
  and nothing whose support has gone is still asserting anything.

  See `docs/design/w3-engine.md` §2 for the loops, §8 for truth maintenance, and
  `docs/design/w5-observability.md` §3 for the loop guard.
  """

  alias Rete.Activation
  alias Rete.Agenda
  alias Rete.Element
  alias Rete.Engine.Nodes
  alias Rete.Engine.State
  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Taxonomy
  alias Rete.Token

  @default_max_cycles :infinity

  @doc """
  A state over a network, with nothing inserted.

  Plants the root token now rather than on the first propagation. A rule whose whole left
  hand side is an absence or an empty collection is true of the empty session, and must
  be able to fire before a fact arrives. See `docs/design/w3-engine.md` §6.
  """
  @spec new(Network.t()) :: State.t()
  def new(%Network{} = network) do
    {state, ops} = network |> State.new() |> Nodes.seed_root()

    state |> State.enqueue(ops) |> drain()
  end

  @doc """
  Inserts facts and propagates them.

  A fact equal to one already present bumps its count and propagates nothing. The matches
  it would make already exist.
  """
  @spec insert(State.t(), [term()], Rete.Listener.origin()) :: State.t()
  def insert(state, facts, origin \\ :asserted)

  def insert(%State{} = state, facts, origin) do
    {state, batches} =
      Enum.reduce(facts, {state, []}, fn fact, {%State{} = state, batches} ->
        case Memory.add_fact(state.memory, fact) do
          {memory, :new} ->
            state = emit(%State{state | memory: memory}, fn -> {:fact_inserted, fact, origin} end)
            {state, [alpha_ops(state, fact, :right) | batches]}

          {memory, :duplicate} ->
            {emit(%State{state | memory: memory}, fn -> {:fact_duplicated, fact} end), batches}
        end
      end)

    state |> State.enqueue(ordered_ops(batches)) |> drain()
  end

  @doc """
  Retracts facts and propagates the retraction.

  Only the last occurrence of a fact propagates. Anything concluded from it is retracted
  in turn, until the network settles.
  """
  @spec retract(State.t(), [term()], Rete.Listener.origin()) :: State.t()
  def retract(state, facts, origin \\ :asserted)

  def retract(%State{} = state, facts, origin) do
    {state, batches} =
      Enum.reduce(facts, {state, []}, fn fact, {%State{} = state, batches} ->
        case Memory.remove_fact(state.memory, fact) do
          {memory, :gone} ->
            state =
              emit(%State{state | memory: memory}, fn -> {:fact_retracted, fact, origin} end)

            {state, [alpha_ops(state, fact, :right_retract) | batches]}

          {memory, _} ->
            {%State{state | memory: memory}, batches}
        end
      end)

    state |> State.enqueue(ordered_ops(batches)) |> drain()
  end

  # Batches are collected newest first. Appending per fact would be quadratic in the size
  # of one insert, and propagation order decides the order matches reach the agenda.
  defp ordered_ops(batches), do: batches |> Enum.reverse() |> Enum.concat()

  @doc """
  Fires until the agenda is empty.

  Options:

    * `:max_cycles` — how many activations one call may fire. `:infinity` by default, so
      an oscillating ruleset spins rather than raising. Firing that many and still having
      work pending raises with the rules that fired most. Firing that many and settling is
      fine. See `docs/design/w5-observability.md` §3.
  """
  @spec fire_rules(State.t(), keyword()) :: State.t()
  def fire_rules(%State{} = state, opts \\ []) do
    max_cycles = opts |> Keyword.get(:max_cycles, @default_max_cycles) |> validate_cycles!()

    state
    |> emit(fn -> {:fire_started, opts} end)
    |> drain()
    |> fire_loop(max_cycles, 0, %{})
  end

  # Do not relax this to accept any term. `fired >= nil` is false for every integer under
  # Erlang term order, so a typo would silently turn the guard off.
  defp validate_cycles!(:infinity), do: :infinity
  defp validate_cycles!(n) when is_integer(n) and n >= 0, do: n

  defp validate_cycles!(other) do
    raise ArgumentError,
          ":max_cycles must be a non-negative integer or :infinity, got: #{inspect(other)}"
  end

  @doc """
  Runs a query: one result per match, computed by the query's body.

  A query is named by the `{module, name}` pair it was defined under. `defquery
  summary(...)` also defines `summary/2` in its own module, and
  `MyRuleset.summary(session, filters)` is the readable form of this call.

  `filters` narrows the matches by equality on the *bindings*, before the body runs. It
  may name any variable the left hand side binds.

  Row order is **unspecified**. It is deterministic for a given set of facts, but nothing
  about the order is a guarantee to build on.
  """
  @spec query(State.t(), {module(), atom()}, keyword() | %{atom() => term()}) :: [term()]
  def query(state, ref, filters \\ [])

  def query(%State{} = state, {module, name} = ref, filters)
      when is_atom(module) and is_atom(name) do
    node = query_node!(state, ref)
    filters = normalize_filters(filters)
    check_filters!(node, filters)

    state.memory
    |> Memory.all_tokens(node.id)
    |> Enum.filter(fn %{bindings: bindings} ->
      Enum.all?(filters, fn {key, value} -> Map.get(bindings, key) == value end)
    end)
    |> Enum.map(&node.rhs.(node.hash, &1.bindings))
    # Beta memory is arrival ordered. Without this sort the same facts inserted in a
    # different order would answer the same query in a different order.
    |> Enum.sort()
  end

  def query(%State{} = state, name, _filters) when is_atom(name) do
    raise ArgumentError, bare_name_message(state, name)
  end

  defp bare_name_message(state, name) do
    suggestions =
      for {module, ^name} = ref <- Network.query_refs(state.network),
          do:
            "    #{inspect(module)}.#{name}(session, filters)\n" <>
              "    Rete.Session.query(session, #{inspect(ref)}, filters)"

    detail =
      case suggestions do
        [] -> "No query of that name is defined here. " <> defined(state)
        _ -> "Did you mean:\n\n" <> Enum.join(suggestions, "\n")
      end

    "a query is named by {module, name}, not by #{inspect(name)} alone — " <>
      "two rulesets may each define one. " <> detail
  end

  defp query_node!(state, {module, _name} = ref) do
    case Network.query(state.network, ref) do
      nil ->
        raise ArgumentError,
              "no query #{Network.ref_string(ref)} in this network. " <>
                missing_module(state, module) <> defined(state)

      node ->
        node
    end
  end

  defp missing_module(state, module) do
    modules = Network.modules(state.network)

    if module in modules do
      ""
    else
      "#{inspect(module)} contributed nothing to this session, which was built " <>
        "from #{inspect(modules)}. "
    end
  end

  defp defined(state) do
    case Network.query_refs(state.network) do
      [] ->
        "This session was built from #{inspect(Network.modules(state.network))}, " <>
          "which define no queries at all."

      refs ->
        "Defined: " <> Enum.map_join(refs, ", ", &Network.ref_string/1) <> "."
    end
  end

  defp normalize_filters(filters) when is_list(filters), do: Map.new(filters)
  defp normalize_filters(filters) when is_map(filters), do: filters

  defp check_filters!(node, filters) do
    case Map.keys(filters) -- node.bind do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "the query #{Network.ref_string({node.module, node.name})} binds " <>
                "#{inspect(node.bind)}, and was given #{inspect(Enum.sort(unknown))}"
    end
  end

  @doc """
  Every fact the session holds, inserted or concluded.

  Excludes the marker facts an extracted compound negation inserts. They express a
  negated conjunction to the network and no rule of the user's concluded them. They are
  ordinary facts everywhere else.
  """
  @spec facts(State.t()) :: [term()]
  def facts(%State{memory: memory, network: network}) do
    memory |> Memory.facts() |> Enum.reject(&Network.marker?(network, &1))
  end

  # --- firing ---------------------------------------------------------------------

  # The cap is checked against work still pending, never against the count alone: a
  # ruleset that fires exactly `max_cycles` and then settles has not run away.
  # `is_integer/1` is what makes `:infinity` mean no cap.
  defp fire_loop(%State{} = state, max_cycles, fired, tally) do
    case Agenda.pop(state.agenda) do
      :empty ->
        emit(%State{state | fired: state.fired + fired}, fn -> {:fire_finished, fired} end)

      {:ok, _activation, _agenda} when is_integer(max_cycles) and fired >= max_cycles ->
        raise RuntimeError, runaway(state, fired, tally)

      {:ok, activation, agenda} ->
        %State{state | agenda: agenda}
        |> fire(activation)
        |> drain()
        |> fire_loop(max_cycles, fired + 1, Map.update(tally, activation.node_id, 1, &(&1 + 1)))
    end
  end

  @runaway_shown 5

  # Leads with which rules fired most. Pending activations only say what happened to be
  # queued when the cap hit, which for a loop is arbitrary.
  defp runaway(%State{} = state, fired, tally) do
    worst =
      tally
      |> Enum.sort_by(fn {_node_id, count} -> -count end)
      |> Enum.take(@runaway_shown)
      |> Enum.map_join("\n", fn {node_id, count} ->
        "  #{count}x  #{rule_name(state, node_id)}"
      end)

    pending =
      state.agenda
      |> Agenda.to_list()
      |> Enum.take(@runaway_shown)
      |> Enum.map_join("\n", &"  #{describe(state, &1)}")

    """
    fired #{fired} activations without the agenda emptying, which suggests rules \
    that keep re-triggering each other.

    Fired most#{of_total(map_size(tally), "rules")}:
    #{worst}

    Still pending#{of_total(Agenda.size(state.agenda), "activations")}:
    #{pending}

    A rule that concludes something its own left hand side matches on will do \
    this. If the ruleset genuinely needs more activations than this to settle, \
    raise :max_cycles.
    """
  end

  # Both lists are cut to @runaway_shown. Say so when something was cut, and only then.
  defp of_total(total, noun) when total > @runaway_shown,
    do: " (#{@runaway_shown} of #{total} #{noun})"

  defp of_total(_total, _noun), do: ""

  # Qualified: a loop between two rules of one name in different rulesets is exactly the
  # case where a bare name explains nothing.
  defp rule_name(%State{} = state, node_id) do
    case Network.node(state.network, node_id) do
      %{name: name, module: module} -> Network.ref_string({module, name})
      %{name: name} -> to_string(name)
      _ -> inspect(node_id)
    end
  end

  # Facts are recorded against the token before they are inserted, so that retracting the
  # token later finds them even if the insertion cascades.
  defp fire(%State{} = state, %Activation{} = activation) do
    node = Network.node(state.network, activation.node_id)

    facts =
      node.rhs
      |> apply([node.hash, activation.token.bindings])
      |> normalize_facts()
      |> check_facts!(state, node, activation.token)
      |> well_founded(state, activation.token)

    case facts do
      [] ->
        emit(state, fn -> {:activation_fired, Node.source(node), activation.token, []} end)

      facts ->
        memory = Memory.add_insertion(state.memory, node.id, activation.token, facts)

        %State{state | memory: memory}
        |> emit(fn -> {:activation_fired, Node.source(node), activation.token, facts} end)
        |> insert(facts, {:derived, Node.source(node)})
    end
  end

  # Drops a conclusion the match already rests on, so it cannot support itself. Runs only
  # when the fact is already present, which is the only way the cycle can close. See
  # `docs/design/w3-engine.md` §8.
  defp well_founded(facts, %State{} = state, token) do
    if Enum.any?(facts, &Map.has_key?(state.memory.facts, &1)) do
      support = support_closure(state, token)
      Enum.reject(facts, &MapSet.member?(support, &1))
    else
      facts
    end
  end

  # Every fact the match rests on: the ones it matched, plus what the match that concluded
  # each of those rested on, down to what the user asserted.
  defp support_closure(%State{memory: memory}, token) do
    walk(MapSet.new(), matched_facts(token), inserted_by(memory))
  end

  @spec walk(MapSet.t(), [term()], %{optional(term()) => [Token.t()]}) :: MapSet.t()
  defp walk(seen, [], _inserters), do: seen

  defp walk(seen, [fact | rest], inserters) do
    if MapSet.member?(seen, fact) do
      walk(seen, rest, inserters)
    else
      supports = inserters |> Map.get(fact, []) |> Enum.flat_map(&matched_facts/1)
      walk(MapSet.put(seen, fact), supports ++ rest, inserters)
    end
  end

  # `MapSet.t()` is opaque with two internal representations, and dialyzer loses track of
  # which one a set threaded through a local recursion holds. This set never leaves these
  # two functions and is only built by `MapSet.new/0` and `MapSet.put/2`.
  @dialyzer {:no_opaque, walk: 3, well_founded: 3}

  # fact => the tokens whose activation inserted it. Built on demand, because it is only
  # needed for a conclusion that is already present.
  defp inserted_by(%Memory{insertions: insertions}) do
    for {_node_id, by_token} <- insertions,
        {token, batches} <- by_token,
        batch <- batches,
        fact <- batch,
        reduce: %{} do
      acc -> Map.update(acc, fact, [token], &[token | &1])
    end
  end

  # A collection match holds the list it gathered, and rests on every member of it.
  defp matched_facts(%Token{} = token) do
    Enum.flat_map(Token.facts(token), fn
      facts when is_list(facts) -> facts
      fact -> [fact]
    end)
  end

  # A rule may return one fact, a list of them, or nothing.
  defp normalize_facts(nil), do: []
  defp normalize_facts(facts) when is_list(facts), do: Enum.reject(facts, &is_nil/1)
  defp normalize_facts(fact), do: [fact]

  # Attributes a body that returned something that is not a fact to the rule that returned
  # it. The `try` must wrap the type call for one fact and nothing else. Wrapping the
  # insertion would catch whatever the resulting cascade raises and blame it on this rule.
  defp check_facts!(facts, %State{} = state, node, token) do
    Enum.each(facts, fn fact ->
      try do
        Taxonomy.fact_type(state.network.taxonomy, fact)
      rescue
        error ->
          reraise ArgumentError,
                  [message: not_a_fact(node, token, fact, error)],
                  __STACKTRACE__
      end
    end)

    facts
  end

  defp not_a_fact(node, token, fact, error) do
    """
    #{Network.ref_string({node.module, node.name})} returned #{inspect(fact)}, \
    which is not a fact.

    It fired on #{inspect(token.bindings)}. The body of a rule is the facts to \
    insert: return a struct, a tagged tuple `{:type, ...}`, a tagged map \
    `%{__type__: ...}`, a list of those, or `nil`/`[]` to insert nothing.

    #{Exception.message(error)}\
    """
  end

  defp describe(state, %Activation{node_id: id, token: token}) do
    case Network.node(state.network, id) do
      %{name: _} -> "#{rule_name(state, id)} #{inspect(token.bindings)}"
      other -> inspect(other)
    end
  end

  # --- listeners ----------------------------------------------------------------------

  @doc """
  Attaches a listener with its initial state.
  """
  @spec with_listener(State.t(), module(), term()) :: State.t()
  def with_listener(%State{listeners: listeners} = state, module, init) do
    %State{state | listeners: listeners ++ [{module, init}]}
  end

  @doc """
  The state a listener has accumulated, or `nil` if it is not attached.
  """
  @spec listener_state(State.t(), module()) :: term()
  def listener_state(%State{listeners: listeners}, module) do
    Enum.find_value(listeners, fn
      {^module, listener_state} -> listener_state
      _ -> nil
    end)
  end

  # The single point every event passes through. `build` is a function so that an
  # unobserved session allocates nothing and calls nothing.
  defp emit(%State{listeners: []} = state, _build), do: state

  defp emit(%State{listeners: listeners} = state, build) do
    event = build.()

    %State{
      state
      | listeners:
          Enum.map(listeners, fn {module, listener_state} ->
            {module, module.handle_event(event, listener_state)}
          end)
    }
  end

  # --- propagation ------------------------------------------------------------------

  # Drains the queue. `{:retract_facts, ...}` is the one op a node cannot carry out
  # itself: retracting a conclusion has to re-enter the alpha network.
  defp drain(%State{} = state) do
    case State.dequeue(state) do
      :empty ->
        state

      {:ok, {:retract_facts, node_id, facts}, state} ->
        source = state.network |> Network.node(node_id) |> Node.source()

        state |> retract(facts, {:derived, source}) |> drain()

      {:ok, {:event, event}, state} ->
        state |> emit(fn -> event end) |> drain()

      {:ok, {kind, node_id, items} = op, state} ->
        {state, ops} = Nodes.handle(state, op)

        state
        |> emit(fn -> {:propagated, kind, node_id, length(items)} end)
        |> State.enqueue(ops)
        |> drain()
    end
  end

  # Offers a fact to the alpha nodes its type routes it to. Each turns it into an element
  # or rejects it. The taxonomy is consulted here and nowhere else, which is what lets an
  # alpha match a fact of any type.
  defp alpha_ops(%State{network: network}, fact, direction) do
    for alpha <- alphas_for(network, fact),
        bindings = alpha.fun.(fact),
        bindings != nil,
        child <- Network.beta_children(network, alpha.code) do
      {direction, child, [%Element{fact: fact, bindings: bindings}]}
    end
  end

  defp alphas_for(network, fact) do
    network.taxonomy
    |> Taxonomy.alpha_ids(fact)
    |> Enum.map(&Map.fetch!(network.alphas, &1))
  end
end
