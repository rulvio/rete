defmodule Rete.Engine do
  @moduledoc """
  The propagation loop and the fire cycle.

  **Internal.** Not part of the public API. Call it through `Rete.Session`.

  Propagation drains a queue of pending work. A node consumes one unit, and returns the
  work it produced. Firing pops the most salient activation, runs its right hand side, and
  inserts what it returned. Propagation drains to completion **before** the next
  activation fires, so a rule always sees a settled network.

  `fire_rules/2` returns at quiescence. Every rule whose left hand side holds has fired,
  and nothing whose support has gone is still asserting anything.

  See `docs/design/engine.md` §2 for the loops, §8 for truth maintenance, and
  `docs/design/observability.md` §3 for the loop guard.
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
  @default_concurrency 1
  @default_timeout :infinity

  @doc """
  A state over a network, with nothing inserted.

  Queues the root token rather than propagating it. A rule whose whole left hand side is an
  absence or an empty collection is true of the empty session, so the token must exist
  before a fact arrives. `fire_rules/2` is what propagates it, so a state nobody has fired
  holds no matches and no activations. See `docs/design/engine.md` §6.
  """
  @spec new(Network.t()) :: State.t()
  def new(%Network{} = network) do
    {state, ops} = network |> State.new() |> Nodes.seed_root()

    State.enqueue(state, ops)
  end

  @doc """
  Records facts and queues their propagation.

  A fact equal to one already present bumps its count and queues nothing. The matches it
  would make already exist.

  This does **not** propagate. `Rete.Memory` holds the fact at once, so `facts/1` sees it,
  and the alpha work waits in the queue until `fire_rules/2` drains it. See
  `docs/design/engine.md` §2.
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

    State.enqueue(state, ordered_ops(batches))
  end

  @doc """
  Removes facts and queues the retraction.

  Only the last occurrence of a fact queues anything. Anything concluded from it is
  retracted in turn, once `fire_rules/2` drains the queue and the network settles.

  This does **not** propagate, for the reason `insert/3` gives. Queuing an insert and then
  a retract of the same fact drains to a net no-op, because a node reads what its memory
  reports after the update rather than the order the work arrived in.
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

    State.enqueue(state, ordered_ops(batches))
  end

  # Batches are collected newest first. Appending per fact would be quadratic in the size
  # of one insert. Propagation order decides the order matches reach the agenda.
  defp ordered_ops(batches) do
    batches |> Enum.reverse() |> Enum.concat() |> coalesce()
  end

  # Merges the ops of one call that go the same way to the same node, so a node is handed a
  # batch instead of one element per call. A node's per-call work is not all per item. It
  # dispatches, groups by join key, and at a negation or a collection reads back what it
  # already holds. Paying that once per fact is what made an unkeyed negation quadratic.
  #
  # **This decides an order.** A rule's own matches still arrive in fact order. A rule
  # reached by two routes now sees all of one route's matches before the other's. See
  # `docs/design/engine.md` §5.
  defp coalesce([]), do: []
  defp coalesce([_only] = ops), do: ops

  defp coalesce(ops) do
    {merged, targets} =
      Enum.reduce(ops, {%{}, []}, fn {direction, child, items}, {merged, targets} ->
        target = {direction, child}

        case merged do
          %{^target => batches} -> {%{merged | target => [items | batches]}, targets}
          _ -> {Map.put(merged, target, [items]), [target | targets]}
        end
      end)

    for {direction, child} = target <- Enum.reverse(targets) do
      {direction, child, merged |> Map.fetch!(target) |> Enum.reverse() |> Enum.concat()}
    end
  end

  @doc """
  Fires until the agenda is empty.

  Options:

    * `:max_cycles` — how many **cycles** one call may fire. A cycle is one pass of the
      fire loop: one activation at the default concurrency, one whole activation group
      above it. `:infinity` by default, so an oscillating ruleset spins rather than
      raising. Firing that many and still having work pending raises with the rules that
      fired most. Firing that many and settling is fine. See
      `docs/design/observability.md` §3.
    * `:concurrency` — how many rule bodies of one activation group run at once. `1` by
      default, which is the sequential path. Above `1`, the bodies of a group run on tasks
      and their conclusions are applied in group order. Worth raising only when a body is
      expensive: a body that just builds a tuple is about 1.5% of firing, and a task costs
      more than that. See `docs/design/engine.md` §11.
    * `:timeout` — milliseconds a single body may take, or `:infinity`, the default. Only
      applies when `:concurrency` is above `1`.
  """
  @spec fire_rules(State.t(), keyword()) :: State.t()
  def fire_rules(%State{} = state, opts \\ []) do
    cfg = %{
      max_cycles: opts |> Keyword.get(:max_cycles, @default_max_cycles) |> validate_cycles!(),
      concurrency:
        opts |> Keyword.get(:concurrency, @default_concurrency) |> validate_concurrency!(),
      timeout: opts |> Keyword.get(:timeout, @default_timeout) |> validate_timeout!()
    }

    state
    |> emit(fn -> {:fire_started, opts} end)
    |> drain()
    |> fire_loop(cfg, 0, %{})
  end

  # Do not relax this to accept any term. `fired >= nil` is false for every integer under
  # Erlang term order, so a typo would silently turn the guard off.
  defp validate_cycles!(:infinity), do: :infinity
  defp validate_cycles!(n) when is_integer(n) and n >= 0, do: n

  defp validate_cycles!(other) do
    raise ArgumentError,
          ":max_cycles must be a non-negative integer or :infinity, got: #{inspect(other)}"
  end

  defp validate_concurrency!(n) when is_integer(n) and n >= 1, do: n

  defp validate_concurrency!(other) do
    raise ArgumentError, ":concurrency must be a positive integer, got: #{inspect(other)}"
  end

  defp validate_timeout!(:infinity), do: :infinity
  defp validate_timeout!(n) when is_integer(n) and n > 0, do: n

  defp validate_timeout!(other) do
    raise ArgumentError,
          ":timeout must be a positive integer or :infinity, got: #{inspect(other)}"
  end

  @doc """
  Runs a query: one result per match, computed by the query's body.

  A query is named by the `{module, name}` pair it was defined under. `defquery
  summary(...)` also defines `summary/2` in its own module. `MyRuleset.summary(session,
  filters)` is the readable form of this call.

  `filters` narrows the matches by equality on the *bindings*, before the body runs. It
  may name any variable the left hand side binds.

  Row order is **unspecified**. Rows follow the order the facts arrived in.

  This used to sort every result, so that one fact set always answered the same way. The
  contract never promised that, and the sort cost O(n log n) on every call. The rows are
  the same without it. Only their sequence moves.
  """
  @spec query(State.t(), {module(), atom()}, keyword() | %{atom() => term()}) :: [term()]
  def query(state, ref, filters \\ [])

  def query(%State{} = state, {module, name} = ref, filters)
      when is_atom(module) and is_atom(name) do
    node = query_node!(state, ref)
    filters = normalize_filters(filters)
    check_filters!(node, filters)

    state.memory
    |> candidates(node, filters)
    |> Enum.filter(fn %{bindings: bindings} ->
      Enum.all?(filters, fn {key, value} -> Map.get(bindings, key) == value end)
    end)
    |> Enum.map(&node.rhs.(node.hash, &1.bindings))
  end

  def query(%State{} = state, name, _filters) when is_atom(name) do
    raise ArgumentError, bare_name_message(state, name)
  end

  @doc """
  Which index `filters` would use at a query, or `:scan`.

  A declared index that no call ever uses is silently no faster, which is the one thing
  that cannot be seen from the outside. This says so. See `Rete.Inspect.query_plan/3`.
  """
  @spec query_plan(State.t(), {module(), atom()}, keyword() | %{atom() => term()}) ::
          {:index, [atom()]} | :scan
  def query_plan(%State{} = state, ref, filters \\ []) do
    node = query_node!(state, ref)
    filters = normalize_filters(filters)
    check_filters!(node, filters)

    case usable_index(node, filters) do
      nil -> :scan
      {_position, keys} -> {:index, keys}
    end
  end

  # The matches a filter could possibly select. With a usable index that is one bucket,
  # and with none it is every match — which is what the filter above then narrows either
  # way. So an index changes how many matches are considered, never which are returned.
  #
  # Arrival order survives. A bucket holds its tokens in arrival order, and the ones a
  # filter selects are the same subsequence a scan of everything would have found.
  defp candidates(memory, node, filters) do
    case usable_index(node, filters) do
      nil ->
        Memory.all_tokens(memory, node.id)

      {position, keys} ->
        Memory.tokens(memory, Memory.index_id(node.id, position), Map.take(filters, keys))
    end
  end

  # The largest declared key set the filter covers, so the bucket is as narrow as the
  # declarations allow. Ties go to the first declared, so the choice is deterministic.
  # A set the filter only partly covers is no use: its bucket key needs every one of them.
  defp usable_index(%Node.Query{index: []}, _filters), do: nil

  defp usable_index(%Node.Query{index: index}, filters) do
    asked = filters |> Map.keys() |> MapSet.new()

    index
    |> Enum.with_index()
    |> Enum.filter(fn {keys, _position} -> MapSet.subset?(MapSet.new(keys), asked) end)
    |> Enum.max_by(fn {keys, _position} -> length(keys) end, fn -> nil end)
    |> case do
      nil -> nil
      {keys, position} -> {position, keys}
    end
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

  This excludes the marker facts an extracted compound negation inserts. They express a
  negated conjunction to the network, and no rule of the user's concluded them. Everywhere
  else, they are ordinary facts.
  """
  @spec facts(State.t()) :: [term()]
  def facts(%State{memory: memory, network: network}) do
    memory |> Memory.facts() |> Enum.reject(&Network.marker?(network, &1))
  end

  # --- firing ---------------------------------------------------------------------

  # The cap is checked against work still pending, never against the count alone. A
  # ruleset that fires exactly `max_cycles` and then settles has not run away.
  # `is_integer/1` is what makes `:infinity` mean no cap.
  defp fire_loop(%State{} = state, cfg, fired, tally) do
    max_cycles = cfg.max_cycles

    case next_cycle(state, cfg.concurrency) do
      :empty ->
        emit(%State{state | fired: state.fired + fired}, fn -> {:fire_finished, fired} end)

      {:ok, _mode, _activations, _state} when is_integer(max_cycles) and fired >= max_cycles ->
        raise RuntimeError, runaway(state, fired, tally)

      {:ok, mode, activations, state} ->
        state
        |> fire_cycle(activations, cfg, mode)
        |> fire_loop(cfg, fired + 1, tally(tally, activations))
    end
  end

  # One activation at the default concurrency, a whole activation group above it. Either
  # way, what comes back is one cycle. `:max_cycles` counts these, not the activations
  # inside them, so raising `:concurrency` does not consume the allowance faster.
  #
  # The group is **peeked**, not popped. An activation stays on the agenda until its own
  # conclusions are applied. So a conclusion applied earlier in the cycle can still cancel
  # it. See `fire_cycle/4`.
  defp next_cycle(%State{} = state, concurrency) when concurrency <= 1 do
    case Agenda.pop(state.agenda) do
      :empty -> :empty
      {:ok, activation, agenda} -> {:ok, :popped, [activation], %State{state | agenda: agenda}}
    end
  end

  defp next_cycle(%State{} = state, _concurrency) do
    case Agenda.peek_group(state.agenda) do
      [] -> :empty
      activations -> {:ok, :peeked, activations, state}
    end
  end

  defp tally(tally, activations) do
    Enum.reduce(activations, tally, &Map.update(&2, &1.node_id, 1, fn n -> n + 1 end))
  end

  @runaway_shown 5

  # Leads with which rules fired most. Pending activations only say what happened to be
  # queued when the cap hit — arbitrary, for a loop.
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
    fired #{fired} cycles without the agenda emptying, which suggests rules \
    that keep re-triggering each other.

    Fired most#{of_total(map_size(tally), "rules")}:
    #{worst}

    Still pending#{of_total(Agenda.size(state.agenda), "activations")}:
    #{pending}

    A rule that concludes something its own left hand side matches on will do \
    this. If the ruleset genuinely needs more cycles than this to settle, \
    raise :max_cycles.
    """
  end

  # Both lists are cut to @runaway_shown. Say so when something was cut, and only then.
  defp of_total(total, noun) when total > @runaway_shown,
    do: " (#{@runaway_shown} of #{total} #{noun})"

  defp of_total(_total, _noun), do: ""

  # Qualified. A loop between two rules of one name, in different rulesets, is exactly
  # the case where a bare name explains nothing.
  defp rule_name(%State{} = state, node_id) do
    case Network.node(state.network, node_id) do
      %{name: name, module: module} -> Network.ref_string({module, name})
      %{name: name} -> to_string(name)
      _ -> inspect(node_id)
    end
  end

  # The sequential path, unchanged. The activation is already off the agenda.
  defp fire_cycle(%State{} = state, [activation], _cfg, :popped) do
    state |> fire(activation) |> drain()
  end

  # A rule body is a pure function of its hash and its already frozen bindings. So the
  # bodies of a group may run at once. Everything after them threads state instead —
  # `well_founded` reads memory, and one conclusion can retract the support of a later
  # activation in the same group. So the engine applies conclusions in group order, with a
  # drain between each.
  #
  # Only `{rhs, hash, bindings}` is captured, never the state or the network. A closure
  # over either would copy the whole compiled network into every task.
  defp fire_cycle(%State{} = state, activations, cfg, :peeked) do
    nodes = Enum.map(activations, &Network.node(state.network, &1.node_id))

    results =
      nodes
      |> Enum.zip_with(activations, fn node, a -> {node.rhs, node.hash, a.token.bindings} end)
      |> Task.async_stream(&compute/1,
        ordered: true,
        max_concurrency: cfg.concurrency,
        timeout: cfg.timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:exited, reason}
      end)

    [activations, nodes, results]
    |> Enum.zip()
    |> Enum.reduce(state, &apply_conclusions/2)
  end

  # Each activation leaves the agenda as its own conclusions are applied. `:missing` means
  # a conclusion applied earlier in this cycle retracted the match behind it. So it must
  # not fire — the same outcome firing one at a time would give. Its body already ran, and
  # the engine discards the result.
  defp apply_conclusions({activation, node, result}, %State{} = state) do
    case Agenda.remove(state.agenda, activation) do
      {agenda, :removed} ->
        %State{state | agenda: agenda} |> conclude(activation, node, result) |> drain()

      {_agenda, :missing} ->
        state
    end
  end

  defp fire(%State{} = state, %Activation{} = activation) do
    node = Network.node(state.network, activation.node_id)

    conclude(state, activation, node, compute({node.rhs, node.hash, activation.token.bindings}))
  end

  # The pure half. It returns failure rather than raising it, so the error is reported
  # against the rule in the caller, where the node is in hand, instead of surfacing as a
  # task exit.
  defp compute({rhs, hash, bindings}) do
    {:ok, hash |> rhs.(bindings) |> normalize_facts()}
  rescue
    error -> {:raised, error, __STACKTRACE__}
  catch
    kind, value -> {:caught, kind, value, __STACKTRACE__}
  end

  # The engine records facts against the token before inserting them. So retracting the
  # token later finds them, even if the insertion cascades.
  defp conclude(%State{} = state, %Activation{token: token}, node, result) do
    {state, facts} =
      result
      |> unwrap!(node, token)
      |> check_facts!(state, node, token)
      |> well_founded(state, token)

    case facts do
      [] ->
        emit(state, fn -> {:activation_fired, Node.source(node), token, []} end)

      facts ->
        memory = Memory.add_insertion(state.memory, node.id, token, facts)

        %State{state | memory: memory}
        |> emit(fn -> {:activation_fired, Node.source(node), token, facts} end)
        |> insert(facts, {:derived, Node.source(node)})
    end
  end

  defp unwrap!({:ok, facts}, _node, _token), do: facts

  # Reraised exactly as thrown, with the original stacktrace. That stacktrace already
  # names the generated `__rhs_<name>__` frame in the ruleset module, so the rule is
  # identified without inventing a wrapper exception. Without this, a body's error inside
  # a task would surface as an opaque exit.
  defp unwrap!({:raised, error, stacktrace}, _node, _token), do: reraise(error, stacktrace)

  defp unwrap!({:caught, kind, value, stacktrace}, _node, _token),
    do: :erlang.raise(kind, value, stacktrace)

  # A timeout killed the task, so there is no original error to reraise.
  defp unwrap!({:exited, reason}, node, token) do
    raise RuntimeError,
          "#{Network.ref_string({node.module, node.name})} did not finish: " <>
            "#{inspect(reason)}. It fired on #{inspect(token.bindings)}. " <>
            "Raise :timeout, or remove it to wait indefinitely."
  end

  # Drops a conclusion the match already rests on, so it cannot support itself. This runs
  # only when the fact is already present, since that is the only way the cycle can
  # close. See `docs/design/engine.md` §8.
  #
  # Returns the state, because reaching the support index is what builds it. A ruleset
  # where no rule ever re-concludes never gets here, and so never pays for it.
  defp well_founded(facts, %State{} = state, token) do
    if Enum.any?(facts, &Map.has_key?(state.memory.facts, &1)) do
      state = %State{state | memory: Memory.index_inserters(state.memory)}
      support = support_closure(state, token)

      {state, Enum.reject(facts, &MapSet.member?(support, &1))}
    else
      {state, facts}
    end
  end

  # Every fact the match rests on. This is the facts it matched, plus what the match that
  # concluded each of those rested on, down to what the user asserted.
  #
  # Walks `Rete.Memory.inserters/2`, which is maintained as insertions are recorded. This
  # used to build that index on the spot, from every insertion record in the session, on
  # every conclusion that was already present — which made two rules concluding one fact
  # quadratic in the number of conclusions.
  defp support_closure(%State{memory: memory}, token) do
    walk(MapSet.new(), matched_facts(token), memory)
  end

  @spec walk(MapSet.t(), [term()], Memory.t()) :: MapSet.t()
  defp walk(seen, [], _memory), do: seen

  defp walk(seen, [fact | rest], memory) do
    if MapSet.member?(seen, fact) do
      walk(seen, rest, memory)
    else
      supports =
        memory
        |> Memory.inserters(fact)
        |> Enum.flat_map(fn {_node_id, token} -> matched_facts(token) end)

      walk(MapSet.put(seen, fact), supports ++ rest, memory)
    end
  end

  # `MapSet.t()` is opaque, with two internal representations. Dialyzer loses track of
  # which one a set threaded through a local recursion holds. This set never leaves these
  # two functions, and only `MapSet.new/0` and `MapSet.put/2` build it.
  @dialyzer {:no_opaque, walk: 3, well_founded: 3}

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

  # Attributes a body's non-fact return value to the rule that returned it. The `try`
  # must wrap the type call for one fact, and nothing else. Wrapping the insertion too
  # would catch whatever the resulting cascade raises, and blame it on this rule.
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

  # The single point every event passes through. `build` is a function, so that an
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
  # itself — retracting a conclusion has to re-enter the alpha network.
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

  # Offers a fact to the alpha nodes its type routes it to. Each alpha turns it into an
  # element, or rejects it. The engine consults the taxonomy here, and nowhere else. That
  # is what lets an alpha match a fact of any type.
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
