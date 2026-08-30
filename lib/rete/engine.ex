defmodule Rete.Engine do
  @moduledoc """
  The propagation loop and the fire cycle.

  ## Two nested loops

  **Propagation** drains a queue of pending work. A node consumes one unit and
  returns the work it produced; the loop enqueues that and continues. Flat
  iteration rather than recursion, so a cascade of any depth costs stack space
  proportional to nothing.

  **Firing** takes the most salient activation, runs its right hand side, and
  inserts whatever it returned — which propagates, which may activate more rules.
  It repeats until the agenda is empty, which is the point at which the session
  is consistent: every rule whose left hand side holds has fired, and no rule
  whose support has gone is still asserting anything.

  Propagation is drained to completion *before* the next activation fires. A rule
  must see a settled network, or it could act on a half-built match.

  ## Truth maintenance

  Facts a rule inserts are **logical**: they exist only while the match that
  concluded them does. Every insertion is recorded against the token that caused
  it, and when that token is retracted the facts go with it — which may retract
  the support of other conclusions, cascading until it settles.

  This is why the right hand side inserts and never retracts. A rule states what
  follows from a match; keeping that true as facts change is the engine's job,
  not the rule author's. There is no unconditional insert, so there is no way to
  leave a conclusion behind whose support is gone.

  Support is **well founded**, not merely counted. A conclusion the concluding
  match itself rests on — `symmetric({:edge, a, b}) -> {:edge, b, a}` applied to
  its own output — would otherwise support itself, and neither fact could ever be
  retracted. Such a conclusion is dropped rather than recorded; see
  `well_founded/3`. The cost of deciding that at insertion time rather than by
  re-deriving on every retraction is that the dropped support is not
  reconsidered: if the grounded route to a fact goes away while the circular one
  would still have held, the fact goes too.

  A retraction can therefore arrive at a production in two states. If its
  activation is still pending it simply never fires. If it already fired, the
  facts it inserted are taken back. `Rete.Agenda.remove/2` reports which.

  ## The loop guard

  A ruleset can oscillate: rule A concludes something that invalidates rule B,
  whose retraction re-enables A. Left alone that spins forever inside
  `fire_rules/2`, with no output and no way to interrupt it. The cycle cap turns
  it into an error naming the rules that kept firing.

  `max_cycles: n` permits n activations, and the cap is only reached when there
  is still something pending after them. A ruleset that settles on its last
  permitted activation has not run away, and raising over it would produce an
  error naming nothing at all.
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

  @default_max_cycles 10_000

  @doc """
  A state over a network, with nothing inserted.

  The root token is planted here rather than on the first propagation, because a
  rule whose whole left hand side is an absence or an empty collection is true of
  the empty session and has to be able to fire without a fact ever arriving.
  `Rete.Engine.Nodes.seed_root/1` is idempotent, so seeding here does not stop
  the lazy path from being correct — it just never has anything left to do.
  """
  @spec new(Network.t()) :: State.t()
  def new(%Network{} = network) do
    {state, ops} = network |> State.new() |> Nodes.seed_root()

    state |> State.enqueue(ops) |> drain()
  end

  @doc """
  Inserts facts and propagates them.

  A fact equal to one already present bumps its count and propagates nothing:
  the matches it would make already exist. That keeps a session a multiset, so
  that two rules independently concluding the same thing does not make one of
  them retracting it remove the fact.
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

  Only the last occurrence of a fact propagates. Anything that was concluded from
  it is retracted in turn, and so on until the network settles.
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

  # One batch of ops per fact, collected newest first because appending to the
  # accumulator would copy it once per fact — quadratic in the size of a single
  # insert. Order is part of the contract, so it is restored here rather than
  # given up: propagation order decides the order matches reach the agenda.
  defp ordered_ops(batches), do: batches |> Enum.reverse() |> Enum.concat()

  @doc """
  Fires until the agenda is empty.

  Options:

    * `:max_cycles` — how many activations one call may fire, #{@default_max_cycles}
      by default. Firing that many and still having work pending raises rather
      than spinning; firing that many and settling is fine.
  """
  @spec fire_rules(State.t(), keyword()) :: State.t()
  def fire_rules(%State{} = state, opts \\ []) do
    max_cycles = Keyword.get(opts, :max_cycles, @default_max_cycles)

    state
    |> emit(fn -> {:fire_started, opts} end)
    |> drain()
    |> fire_loop(max_cycles, 0, %{})
  end

  @doc """
  Runs a query: one result per match, computed by the query's body.

  A query is named by the `{module, name}` pair it was defined under, because a
  bare name belongs to no one — two rulesets may each define a `:summary`.
  Callers normally do not write the pair at all: `defquery summary(...)` defines
  `summary/2` in its own module, so the readable form is
  `MyRuleset.summary(session, filters)`. This is what that calls, and what to
  use when the query is decided at runtime.

  `filters` narrows the matches by equality on the *bindings*, before the body
  runs, and may name any variable the query's left hand side binds. There is no
  separate parameter declaration — a query is its conditions and its body, and
  anything it binds can be constrained at call time.

  Row order is **unspecified** — sort by whatever you need. It is deterministic
  for a given set of facts, so the same session always answers the same way, but
  nothing about the order is a guarantee to build on.
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
    # The body is what the caller asked for. Filtering happens on the bindings
    # first, because that is what a filter names.
    |> Enum.map(&node.rhs.(node.hash, &1.bindings))
    # Beta memory is arrival ordered, so without this the same facts inserted in
    # a different order would answer the same query in a different order. The
    # order itself is not a contract - see above - but varying with insertion
    # order is a trap.
    |> Enum.sort()
  end

  def query(%State{} = state, name, _filters) when is_atom(name) do
    raise ArgumentError, bare_name_message(state, name)
  end

  # A bare name used to be the way to run a query, and the fix is not obvious
  # from "expected a tuple": say which module, when the network knows.
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

  # Naming a query in a ruleset the session was never built from reads exactly
  # like a typo unless the error separates the two.
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

  # A filter naming something the query does not bind would silently match
  # nothing, which reads as "no results" rather than "you typoed".
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

  Excludes the marker facts extracted compound negations insert: they are how a
  negated conjunction is expressed to the network, not something the user's
  rules concluded, and a tuple named after a generated rule appearing in this
  list is confusing at best. They are still ordinary facts everywhere else —
  the negation node matches on them, and truth maintenance retracts them.
  """
  @spec facts(State.t()) :: [term()]
  def facts(%State{memory: memory, network: network}) do
    memory |> Memory.facts() |> Enum.reject(&Network.marker?(network, &1))
  end

  # --- firing ---------------------------------------------------------------------

  # The cap is checked against work that is *still there*, never against the
  # count alone. A ruleset that fires exactly `max_cycles` activations and then
  # settles has not run away, and refusing it would raise an error naming no
  # pending rule — because there is none.
  defp fire_loop(%State{} = state, max_cycles, fired, tally) do
    case Agenda.pop(state.agenda) do
      :empty ->
        emit(%State{state | fired: state.fired + fired}, fn -> {:fire_finished, fired} end)

      {:ok, _activation, _agenda} when fired >= max_cycles ->
        raise RuntimeError, runaway(state, fired, tally)

      {:ok, activation, agenda} ->
        %State{state | agenda: agenda}
        |> fire(activation)
        |> drain()
        |> fire_loop(max_cycles, fired + 1, Map.update(tally, activation.node_id, 1, &(&1 + 1)))
    end
  end

  # The pending activations say what is queued *now*, which for a loop is
  # whichever rule happened to be next. What identifies the loop is which rules
  # kept firing, so lead with that.
  defp runaway(%State{} = state, fired, tally) do
    worst =
      tally
      |> Enum.sort_by(fn {_node_id, count} -> -count end)
      |> Enum.take(5)
      |> Enum.map_join("\n", fn {node_id, count} ->
        "  #{count}x  #{rule_name(state, node_id)}"
      end)

    """
    fired #{fired} activations without the agenda emptying, which suggests rules \
    that keep re-triggering each other.

    Fired most:
    #{worst}

    Still pending:
    #{state.agenda |> Agenda.to_list() |> Enum.take(5) |> Enum.map_join("\n", &"  #{describe(state, &1)}")}

    A rule that concludes something its own left hand side matches on will do \
    this. If the ruleset genuinely needs more activations than this to settle, \
    raise :max_cycles.
    """
  end

  # Qualified, because a loop between two rules of the same name in different
  # rulesets is exactly the case where the bare name explains nothing.
  defp rule_name(%State{} = state, node_id) do
    case Network.node(state.network, node_id) do
      %{name: name, module: module} -> Network.ref_string({module, name})
      %{name: name} -> to_string(name)
      _ -> inspect(node_id)
    end
  end

  # The right hand side is a pure function of the bindings; the facts it returns
  # are recorded against the token before they are inserted, so that retracting
  # the token later can find them even if the insertion cascades.
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

  # Support has to be *well founded*, not merely counted. A match that rests on
  # the very fact it concludes would support that fact with itself: the count
  # never reaches zero, so the fact survives the retraction of everything the
  # user ever asserted and the memories behind it never drain.
  #
  #     defrule symmetric({:edge, a, b}), do: {:edge, b, a}
  #
  # One `{:edge, 1, 2}` concludes `{:edge, 2, 1}`, which concludes `{:edge, 1, 2}`
  # right back. Counting supports would leave both facts standing for ever.
  #
  # So a conclusion the match already depends on is dropped: not inserted, not
  # recorded, no count bumped. The check runs only when the fact is already
  # present, which is the only way the loop can close, and the derivation walk it
  # then does is over the insertion records rather than over the network. It
  # costs one pass over those records, so a rule that keeps re-concluding a fact
  # some other rule concluded pays for the check on every activation. Indexing
  # that away is a performance question, and is deferred.
  #
  # The limit of doing this at insertion time rather than by re-deriving on every
  # retraction: the dropped support is not reconsidered later. If the grounded
  # route to a fact goes away while the circular one would still have held, the
  # fact goes with it rather than being re-derived from the other side.
  defp well_founded(facts, %State{} = state, token) do
    if Enum.any?(facts, &Map.has_key?(state.memory.facts, &1)) do
      support = support_closure(state, token)
      Enum.reject(facts, &MapSet.member?(support, &1))
    else
      facts
    end
  end

  # Every fact the match rests on: the ones it matched, plus — for each of those
  # that some other match concluded — everything *that* match rested on, all the
  # way down to what the user asserted.
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

  # `MapSet.t()` is opaque and has two internal representations, and dialyzer
  # loses track of which one a set threaded through a local recursion holds. The
  # set here never leaves these two functions and is only ever built by
  # `MapSet.new/0` and `MapSet.put/2`.
  @dialyzer {:no_opaque, walk: 3, well_founded: 3}

  # fact => the tokens whose activation inserted it, built from the truth
  # maintenance records. Built on demand rather than kept, because it is only
  # ever needed for a conclusion that is already present.
  defp inserted_by(%Memory{insertions: insertions}) do
    for {_node_id, by_token} <- insertions,
        {token, batches} <- by_token,
        batch <- batches,
        fact <- batch,
        reduce: %{} do
      acc -> Map.update(acc, fact, [token], &[token | &1])
    end
  end

  # A collection match holds the list it gathered rather than one fact, and it
  # rests on every member of that list.
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

  # A body that returns something that is not a fact — an `Enum.each` result, a
  # bare `:ok` — is a mistake, and it would otherwise surface as
  # `Rete.Taxonomy.default_fact_type/1` complaining about a value, several
  # frames inside the engine, with nothing to say which of a hundred rules
  # produced it. The engine knows: it is holding the node.
  #
  # The `try` wraps the type call for **one fact** and nothing else. Wrapping
  # the insertion instead would catch whatever the resulting cascade raises —
  # another rule firing, deeper — and blame it on this one.
  #
  # Going through `Rete.Taxonomy.fact_type/2` rather than re-testing the shape
  # here means a custom `:fact_type_fn` decides what a fact is, and whatever it
  # raises is attributed too.
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

  # The single point every event passes through. `build` is a function rather
  # than a term so that an unobserved session - the overwhelmingly common case -
  # allocates nothing and calls nothing.
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

  # Drains the queue. `{:retract_facts, facts}` is the one op a node cannot carry
  # out itself: a production retracting its conclusions has to go back through
  # the alpha network, which only the engine can reach.
  defp drain(%State{} = state) do
    case State.dequeue(state) do
      :empty ->
        state

      {:ok, {:retract_facts, node_id, facts}, state} ->
        # The op carries the node id; the origin carries the rule as well, so
        # only the node has to be looked up again here.
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

  # A fact is offered to the alpha nodes its type routes it to, and each turns it
  # into an element or rejects it. The taxonomy is consulted here and nowhere
  # else, which is what lets an alpha match a fact of any type.
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
