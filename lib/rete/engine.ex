defmodule Rete.Engine do
  @moduledoc """
  The propagation loop and the fire cycle.

  **Internal.** Not part of the public API. Call it through `Rete.Session`.

  Propagation drains a queue of pending work. A node consumes one unit, and returns the
  work it produced. Firing pops the most salient activation, runs its right hand side, and
  inserts what it returned. Propagation drains to completion **before** the next
  activation fires, so a rule always sees a settled network.

  `fire_rules/2` is the only entry point that drains. `new/1`, `insert/3` and `retract/3`
  queue work and return.

  `fire_rules/2` returns at quiescence. Every rule whose left hand side holds has fired,
  and nothing whose support has gone is still asserting anything.

  See `docs/design/engine.md` §2 for the loops, §8 for truth maintenance, and
  `docs/design/observability.md` §3 for the loop guard.
  """

  alias Rete.Activation
  alias Rete.Agenda
  alias Rete.Compiler.Negation
  alias Rete.Element
  alias Rete.Engine.Nodes
  alias Rete.Engine.State
  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Taxonomy

  # A rule that reads the type its own body concludes never settles, and nothing detects
  # that shape. So the cap is what turns a hang into an error that names the rule. See
  # `docs/design/observability.md` §3 for the number, and for what it costs either way.
  @default_max_cycles 100_000
  @default_concurrency 1
  @default_timeout :infinity

  @doc """
  A state over a network, with nothing inserted.

  Queues the root token rather than propagating it. A rule whose whole left hand side is an
  absence or an empty collection is true of the empty session. So the token must exist
  before a fact arrives. `fire_rules/2` is what propagates it. A state nobody has fired
  holds no matches and no activations. See `docs/design/engine.md` §6.
  """
  @spec new(Network.t()) :: State.t()
  def new(%Network{} = network) do
    {state, ops} = network |> State.new() |> Nodes.seed_root()

    State.enqueue(state, ops)
  end

  @doc """
  Records facts and queues their propagation.

  Every occurrence propagates. A fact equal to one already present is a second occurrence
  of it, and the network gets a second element for it. See `docs/design/engine.md` §4.

  This does **not** propagate. `Rete.Memory` holds the fact at once, so `facts/1` sees it.
  The alpha work waits in the queue until `fire_rules/2` drains it. See
  `docs/design/engine.md` §2.
  """
  @spec insert(State.t(), [term()], Rete.Listener.origin()) :: State.t()
  def insert(state, facts, origin \\ {Rete.Session, :insert})

  def insert(%State{} = state, facts, origin) do
    check_reserved!(state, facts, origin, "insert")

    {state, batches} =
      Enum.reduce(facts, {state, []}, fn fact, {%State{} = state, batches} ->
        state =
          %State{state | memory: Memory.add_fact(state.memory, fact)}
          |> emit(fn -> {:fact_inserted, fact, origin} end)

        {state, [alpha_ops(state, fact, :right) | batches]}
      end)

    State.enqueue(state, ordered_ops(batches))
  end

  @doc """
  Removes facts and queues the retraction.

  Every occurrence a session holds queues a retraction of its own. A fact it never held
  queues nothing. The engine retracts anything concluded from an occurrence in turn, once
  `fire_rules/2` drains the queue and the network settles.

  This does **not** propagate, for the reason `insert/3` gives. Queuing an insert and then
  a retract of the same fact drains to a net no-op. The queued work for one node keeps the
  order it arrived in, whatever a caller put between the two calls.
  """
  @spec retract(State.t(), [term()], Rete.Listener.origin()) :: State.t()
  def retract(state, facts, origin \\ {Rete.Session, :retract})

  def retract(%State{} = state, facts, origin) do
    check_reserved!(state, facts, origin, "retract")

    {state, batches} =
      Enum.reduce(facts, {state, []}, fn fact, {%State{} = state, batches} ->
        case Memory.remove_fact(state.memory, fact) do
          {memory, :removed} ->
            state =
              emit(%State{state | memory: memory}, fn -> {:fact_retracted, fact, origin} end)

            {state, [alpha_ops(state, fact, :right_retract) | batches]}

          {memory, :absent} ->
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

  # Merges across calls, once, before a fire drains anything, so a caller feeding one fact
  # at a time still hands a node one batch.
  #
  # Safe over the whole queue only here: a fire drains to empty, so the queue holds nothing
  # but `{direction, node, items}` at this point. `coalesce/1` re-checks rather than trust
  # that. It is also the call that needs the merge window, because a queue built by several
  # calls carries both directions for one node. See `docs/design/engine.md` §2.
  defp coalesce_queue(%State{queue: queue} = state) do
    %State{state | queue: queue |> :queue.to_list() |> coalesce() |> :queue.from_list()}
  end

  # Merges ops that go the same way to the same node. A node's per-call work is not all per
  # item, so paying it once per fact is what made an unkeyed negation quadratic.
  #
  # **A node's merge window closes when the opposite direction reaches it.** The two
  # directions do not commute, so an op moved back past its own inverse can lose a
  # retraction. `docs/design/engine.md` §2 works the case through, and §7 covers the arrival
  # order this decides.
  #
  # Only a direction merges. `{:retract_facts, node, facts}` is a 3-tuple too, so without the
  # check it would merge as though `:retract_facts` were a direction. `merge_op/2` refuses
  # it, and says so.
  @mergeable [:left, :left_retract, :right, :right_retract]

  defp coalesce([]), do: []
  defp coalesce([_only] = ops), do: ops

  # `open` holds the key of the batch each target may still merge into. `merged` only grows,
  # so its size is a generation number, and a closed window cannot be reopened into the batch
  # it named. `keys` keeps the order the batches were opened in.
  defp coalesce(ops) do
    {merged, keys, _open} = Enum.reduce(ops, {%{}, [], %{}}, &merge_op/2)

    for {{direction, child}, _generation} = key <- Enum.reverse(keys) do
      {direction, child, merged |> Map.fetch!(key) |> Enum.reverse() |> Enum.concat()}
    end
  end

  defp merge_op({direction, child, items}, {merged, keys, open})
       when direction in @mergeable do
    target = {direction, child}
    open = Map.delete(open, {opposite(direction), child})

    case open do
      %{^target => key} ->
        {Map.update!(merged, key, &[items | &1]), keys, open}

      _ ->
        key = {target, map_size(merged)}
        {Map.put(merged, key, [items]), [key | keys], Map.put(open, target, key)}
    end
  end

  # Reaching this is a bug in the engine, not in a ruleset. Say which op, and say what the
  # two ways to get here are, because the caller cannot see the queue from where it stands.
  defp merge_op(op, _acc) do
    raise RuntimeError, """
    #{inspect(op)} cannot be merged. Only #{inspect(@mergeable)} ops can.

    `{:retract_facts, node, facts}` and `{:event, event}` are work a node makes while a \
    drain runs. A drain ends with an empty queue. So neither can be in the queue at the \
    point `coalesce_queue/1` merges it, which is before a fire drains anything.

    One of two things is wrong. Something queued drain-time work outside a drain. Or \
    `Rete.Engine.State.op/0` has a new kind of op, and this function was not told about it.

    Merging it as a direction would reorder it, and report nothing.\
    """
  end

  defp opposite(:left), do: :left_retract
  defp opposite(:left_retract), do: :left
  defp opposite(:right), do: :right_retract
  defp opposite(:right_retract), do: :right

  @doc """
  Fires until the agenda is empty.

  Options:

    * `:max_cycles` — how many **cycles** one call may fire. A cycle is one pass of the
      fire loop: one activation at the default concurrency, one whole activation group
      above it. `100_000` by default, so a ruleset that never settles raises instead of
      spinning. Firing that many and still having work pending raises with the rules that
      fired most. Firing that many and settling is fine. Pass `:infinity` to remove the
      cap. See `docs/design/observability.md` §3.
    * `:concurrency` — how many tasks that rule bodies returned may run at once. `1` by
      default, which is the sequential path: the engine awaits a returned task before the
      next body runs. Above `1`, it runs every body of one activation group in turn, and
      it awaits up to this many returned tasks together. It applies their conclusions in
      group order. A body that does not return a task never runs in parallel. See
      `docs/design/engine.md` §11.
    * `:timeout` — milliseconds the engine waits for one returned task, or `:infinity`, the
      default. A task that takes longer is shut down, and the call raises.
    * `:activation_cache` — a map from `Rete.ActivationCache.from_session/2`, or `nil`, the
      default. A rule can set `:cache` to a value other than `nil` or `false`. An
      activation of it then takes the facts that the cache holds for an equal activation,
      and its body does not run.
    * `:activation_cache_key_fn` — an arity-1 function that gives the key of an
      activation, or `nil` to run it without the cache. `Rete.ActivationCache.key/1` by
      default. Give the same function that built the cache.
  """
  @spec fire_rules(State.t(), keyword()) :: State.t()
  def fire_rules(%State{} = state, opts \\ []) do
    key_fn =
      opts
      |> Keyword.get(:activation_cache_key_fn, &Rete.ActivationCache.key/1)
      |> validate_key_fn!()

    cfg = %{
      max_cycles: opts |> Keyword.get(:max_cycles, @default_max_cycles) |> validate_cycles!(),
      concurrency:
        opts |> Keyword.get(:concurrency, @default_concurrency) |> validate_concurrency!(),
      timeout: opts |> Keyword.get(:timeout, @default_timeout) |> validate_timeout!(),
      cache: opts |> Keyword.get(:activation_cache) |> validate_cache!(),
      key_fn: key_fn
    }

    state
    |> emit(fn -> {:fire_started, opts} end)
    |> coalesce_queue()
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

  defp validate_key_fn!(fun) when is_function(fun, 1), do: fun

  defp validate_key_fn!(other) do
    raise ArgumentError,
          ":activation_cache_key_fn must be a function of arity 1, got: #{inspect(other)}"
  end

  defp validate_cache!(nil), do: nil
  defp validate_cache!(cache) when is_map(cache) and not is_struct(cache), do: cache

  defp validate_cache!(other) do
    raise ArgumentError,
          ":activation_cache must be a map from Rete.ActivationCache.from_session/2, or " <>
            "nil, got: #{inspect(other)}"
  end

  @doc """
  Runs a query: one result per match, computed by the query's body.

  A query is named by the `{module, name}` pair it was defined under. `defquery
  summary(...)` also defines `summary` in its own module, and calling that is the readable
  form of this call.

  `params` gives a value for every binding that the head of the query makes, and for no
  other name. The engine keys the matches on those bindings, so this is a map lookup and
  not a scan. A query with no head takes no parameters, and it answers with every match.

  **This takes the bindings, and not the head.** The head of a query is a list of patterns,
  and the generated function matches them. This call is dispatched by `{module, name}` at
  run time, so it cannot know those patterns. For a head of `({cid, tid})`, the generated
  function takes `{1, 2}` and this one takes `%{cid: 1, tid: 2}`.

  A parameter matches a binding by **term equality**, in the same way as a map key. `1` and
  `1.0` are therefore different parameter values, but `==` reports that they are equal.

  Row order is **unspecified**. Rows follow the order the facts arrived in.
  """
  @spec query(State.t(), {module(), atom()}, keyword() | %{atom() => term()}) :: [term()]
  def query(state, ref, params \\ [])

  def query(%State{} = state, {module, name} = ref, params)
      when is_atom(module) and is_atom(name) do
    node = query_node!(state, ref)
    params = normalize_params(params)
    check_params!(node, params)

    state.memory
    |> Memory.tokens(node.id, params)
    |> Enum.map(&node.rhs.(node.hash, &1.bindings))
  end

  def query(%State{} = state, name, _params) when is_atom(name) do
    raise ArgumentError, bare_name_message(state, name)
  end

  defp bare_name_message(state, name) do
    suggestions =
      for {module, ^name} = ref <- Network.query_refs(state.network),
          node = Network.query(state.network, ref),
          do:
            "    #{inspect(module)}.#{name}(#{call_args(node)})\n" <>
              "    Rete.Session.query(session, #{inspect(ref)}, #{param_args(node)})"

    detail =
      case suggestions do
        [] ->
          "No query of that name is defined here. " <> defined(state)

        _ ->
          "Did you mean one of these, with your own values in place of the names:\n\n" <>
            Enum.join(suggestions, "\n")
      end

    "a query is named by {module, name}, not by #{inspect(name)} alone — " <>
      "two rulesets may each define one. " <> detail
  end

  # The two calls differ in what they take, so the suggestion spells out both. The head
  # decides the arguments of the generated function, and `Rete.Network.Node.Query` carries
  # it as source for this. `:params` decides the keys this call wants. Neither line stands
  # a placeholder in for the other, and the lead-in says the names are not values.
  defp call_args(%{head: [_ | _] = head}), do: Enum.join(["session" | head], ", ")
  defp call_args(_node), do: "session"

  defp param_args(%{params: [_ | _] = params}), do: Enum.map_join(params, ", ", &"#{&1}: ...")
  defp param_args(_node), do: "[]"

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

  defp normalize_params(params) when is_list(params), do: Map.new(params)
  defp normalize_params(params) when is_map(params), do: params

  # The parameters key the store, so a call must name every one, and no other name. A
  # partial set is not a more narrow lookup. It is a different key, and nothing is stored
  # under it, so the call would answer `[]` instead of failing. This check prevents that.
  defp check_params!(%Node.Query{params: params} = node, given) do
    cond do
      Enum.sort(Map.keys(given)) == Enum.sort(params) ->
        :ok

      params == [] ->
        asked = given |> Map.keys() |> Enum.sort()

        raise ArgumentError,
              "the query #{Network.ref_string({node.module, node.name})} takes no " <>
                "parameters, and was given #{inspect(asked)}. It binds " <>
                "#{inspect(node.bind)}." <> head_advice(node, asked)

      true ->
        raise ArgumentError,
              "the query #{Network.ref_string({node.module, node.name})} takes parameters " <>
                "#{inspect(params)}, and was given #{inspect(Enum.sort(Map.keys(given)))}. " <>
                "The engine keys its matches on its parameters, so a call must name every " <>
                "one of them, and no other name."
    end
  end

  # This gives the head only when every key that the caller asked for is a binding.
  # If it is not, the suggested `defquery` would not compile, and the true mistake of the
  # caller is the name.
  defp head_advice(%Node.Query{bind: bind, name: name}, asked) do
    if asked != [] and asked -- bind == [] do
      " Declare what you read by in the head: " <>
        "`defquery #{name}(#{Enum.join(asked, ", ")})(...)`. Or filter the rows that this " <>
        "returns."
    else
      ""
    end
  end

  @doc """
  Every fact the session holds, inserted or concluded, one entry for each occurrence.

  This excludes the marker facts an extracted compound negation inserts. They express a
  negated conjunction to the network, and no rule of the user's concluded them. Everywhere
  else, they are ordinary facts.
  """
  @spec facts(State.t()) :: [term()]
  def facts(%State{memory: memory, network: network}) do
    memory |> Memory.facts() |> Enum.reject(&Network.reserved?(network, &1))
  end

  @doc """
  Whether the state has no propagation queued.

  `false` means a fact reached working memory and no node has seen it yet. A state fresh
  from `new/1` is unsettled, because the root token is queued too. See
  `docs/design/engine.md` §2.

  This reads the queue alone, and that is sufficient. On every state that a caller can
  hold, the agenda is empty whenever the queue is empty. `fire_loop/4` returns only on
  `:empty`, and every other exit from a fire raises an error, which discards the state.
  So there is no state with work queued nowhere and an activation still waiting. Keep it
  that way, or this answers `true` about a state that has yet to fire something.
  """
  @spec settled?(State.t()) :: boolean()
  def settled?(%State{queue: queue}), do: :queue.is_empty(queue)

  @doc false
  # How many propagation operations wait for the next `fire_rules/2`. Counts operations,
  # not facts: one insert of many facts queues one operation per node the facts reach.
  #
  # This exists for the error message in `Rete.Inspect`, which reports the size of what the
  # caller forgot to fire. It is not a private function only because that caller is in
  # another module. Ask `settled?/1` whether there is any work. Nothing else needs the
  # count.
  @spec pending_ops(State.t()) :: non_neg_integer()
  def pending_ops(%State{queue: queue}), do: :queue.len(queue)

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

    Still pending:
    #{pending}

    A rule that concludes something its own left hand side matches on will do \
    this. If the ruleset genuinely needs more cycles than this to settle, \
    raise :max_cycles.
    """
  end

  # Both lists are cut to @runaway_shown, and only the rules say so. The pending list is a
  # sample of an arbitrary queue, so its length describes the fan-out and not the loop.
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

  # The sequential path. The activation is already off the agenda. A task the body returns
  # is awaited at once, so nothing overlaps.
  defp fire_cycle(%State{} = state, [activation], cfg, :popped) do
    node = Network.node(state.network, activation.node_id)

    result =
      case lookup(cfg, node, activation) do
        {:ok, facts} -> {:cached, facts}
        :error -> node |> compute(activation) |> settle(node, activation, cfg.timeout)
      end

    state |> conclude(activation, node, result) |> drain()
  end

  # Every body runs here, in the caller, and in group order. Only a task that a body
  # returns runs in parallel. The caller owns that task, which is what lets it await it.
  #
  # Applying what the bodies returned is not parallel: one conclusion can retract the
  # support of a later activation in the same group, and that activation must then not
  # fire. So the engine applies conclusions in group order, with a drain between each, and
  # `Rete.Agenda.remove/2` reports which case each one is.
  #
  # The window holds outcomes not yet applied, in group order. A result that is not a task
  # leaves it as soon as it reaches the head. A task at the head waits until `:concurrency`
  # tasks are in flight. So one slow task holds back only what is behind it.
  #
  # With no task in flight, everything ahead of an activation is applied. Whether it is
  # still pending is then final, so a cancelled one skips its body, as it would at
  # `concurrency: 1`. Behind a task, a conclusion not yet applied can still add it back.
  defp fire_cycle(%State{} = state, activations, cfg, :peeked) do
    {state, window, in_flight} =
      Enum.reduce(activations, {state, :queue.new(), 0}, fn
        activation, {%State{} = state, window, 0} ->
          case Agenda.pending(state.agenda, activation) do
            {agenda, :pending} ->
              run_body(%State{state | agenda: agenda}, activation, window, 0, cfg)

            {agenda, :missing} ->
              {%State{state | agenda: agenda}, window, 0}
          end

        activation, {state, window, n} ->
          run_body(state, activation, window, n, cfg)
      end)

    {state, _window, 0} = shrink(state, window, in_flight, cfg, 0)
    state
  end

  # A hit is not a task, so `shrink/5` applies it as soon as it reaches the head.
  defp run_body(state, activation, window, in_flight, cfg) do
    node = Network.node(state.network, activation.node_id)

    outcome =
      case lookup(cfg, node, activation) do
        {:ok, facts} -> {:cached, facts}
        :error -> compute(node, activation)
      end

    in_flight = if match?({:task, _}, outcome), do: in_flight + 1, else: in_flight

    shrink(state, :queue.in({activation, node, outcome}, window), in_flight, cfg, cfg.concurrency)
  end

  # A limit of 0 empties the window.
  defp shrink(state, window, in_flight, cfg, limit) do
    case :queue.out(window) do
      {{:value, {_activation, _node, {:task, _}} = head}, rest} when in_flight >= limit ->
        state |> apply_head(head, rest, cfg) |> shrink(rest, in_flight - 1, cfg, limit)

      {{:value, {_activation, _node, outcome} = head}, rest} when elem(outcome, 0) != :task ->
        state |> apply_head(head, rest, cfg) |> shrink(rest, in_flight, cfg, limit)

      _ ->
        {state, window, in_flight}
    end
  end

  # A raise here leaves the tasks behind the head running, and nothing would ever await
  # them. So they are shut down before the error goes on.
  defp apply_head(state, head, rest, cfg) do
    apply_conclusions(head, state, cfg.timeout)
  catch
    kind, reason ->
      for {_activation, _node, {:task, task}} <- :queue.to_list(rest) do
        _ = Task.shutdown(task, :brutal_kill)
      end

      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Each activation leaves the agenda as its own conclusions are applied. `:missing` means
  # a conclusion applied earlier in this cycle retracted the match behind it. So it must
  # not fire — the same outcome firing one at a time would give. Its body ran while a task
  # ahead of it was in flight, and the engine discards the result. Its task is shut down
  # rather than awaited, so a task that fails cannot raise for a match that no longer holds.
  defp apply_conclusions({activation, node, outcome}, %State{} = state, timeout) do
    case Agenda.remove(state.agenda, activation) do
      {agenda, :removed} ->
        result = settle(outcome, node, activation, timeout)
        %State{state | agenda: agenda} |> conclude(activation, node, result) |> drain()

      {_agenda, :missing} ->
        with {:task, task} <- outcome, do: _ = Task.shutdown(task, :brutal_kill)
        state
    end
  end

  defp lookup(%{cache: nil}, _node, _activation), do: :error

  defp lookup(cfg, %Node.Production{cache: cache} = node, %Activation{token: token})
       when cache != nil and cache != false,
       do: Rete.ActivationCache.lookup(cfg.cache, node, token, cfg.key_fn)

  defp lookup(_cfg, _node, _activation), do: :error

  # It returns failure rather than raising it. Under concurrency the failure waits for its
  # turn in group order, so it is raised where the sequential path would raise it.
  defp compute(node, %Activation{token: token}) do
    case node.rhs.(node.args, token.bindings) do
      %Task{} = task -> {:task, task}
      result -> {:ok, normalize_facts(result)}
    end
  rescue
    error -> {:raised, error, __STACKTRACE__}
  catch
    kind, value -> {:caught, kind, value, __STACKTRACE__}
  end

  # `Task.yield/2` raises for a task that another process owns, and that error names no
  # rule. So the owner is checked first. A timeout shuts the task down, because nothing
  # else would.
  defp settle({:task, %Task{owner: owner} = task}, node, %Activation{token: token}, _timeout)
       when owner != self() do
    raise ArgumentError, foreign_task(node, token, task)
  end

  defp settle({:task, task}, node, %Activation{token: token}, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, %Task{} = inner} -> raise ArgumentError, task_in_facts(node, token, inner)
      {:ok, value} -> {:ok, normalize_facts(value)}
      {:exit, reason} -> {:exited, reason}
      nil -> :timed_out
    end
  end

  defp settle(outcome, _node, _activation, _timeout), do: outcome

  # The engine records facts against the token before inserting them. So retracting the
  # token later finds them, even if the insertion cascades.
  #
  # A firing that concluded nothing is recorded too, as an empty batch. Without it,
  # `Rete.Inspect` could not tell that rule from one that never matched, and the cache
  # could not answer for its body.
  #
  # A hit takes this path too, so it is recorded like a firing. Truth maintenance and
  # `Rete.Inspect` then see no difference, and this session can be the cache of the next.
  # The facts are checked again, because the cache can come from another network.
  defp conclude(%State{} = state, %Activation{token: token}, node, result) do
    facts = result |> unwrap!(node, token) |> check_facts!(state, node, token)
    source = source(node, result)

    case facts do
      [] ->
        memory = Memory.add_insertion(state.memory, node.id, token, [])

        emit(%State{state | memory: memory}, fn -> {:activation_fired, source, token, []} end)

      facts ->
        memory = Memory.add_insertion(state.memory, node.id, token, facts)

        %State{state | memory: memory}
        |> emit(fn -> {:activation_fired, source, token, facts} end)
        |> insert(facts, {node.module, node.name})
    end
  end

  defp source(node, {:cached, _facts}), do: Map.put(Node.source(node), :cached, true)
  defp source(node, _result), do: Node.source(node)

  defp unwrap!({:ok, facts}, _node, _token), do: facts
  defp unwrap!({:cached, facts}, _node, _token), do: facts

  # Reraised exactly as thrown, with the original stacktrace. That stacktrace already
  # names the generated `__rhs_<name>__` frame, in the ruleset module or its image. So the
  # rule is identified without inventing a wrapper exception. Under concurrency the error
  # waits for its turn, so the original stacktrace is the only one that names the body.
  defp unwrap!({:raised, error, stacktrace}, _node, _token), do: reraise(error, stacktrace)

  defp unwrap!({:caught, kind, value, stacktrace}, _node, _token),
    do: :erlang.raise(kind, value, stacktrace)

  # The engine shut the task down, so there is no original error to reraise.
  defp unwrap!(:timed_out, node, token) do
    raise RuntimeError,
          "#{Network.ref_string({node.module, node.name})} did not finish: " <>
            ":timeout. It fired on #{inspect(token.bindings)}. " <>
            "Raise :timeout, or remove it to wait indefinitely."
  end

  # The caller outlived the exit of the task, so `Task.yield/2` reported it.
  defp unwrap!({:exited, reason}, node, token) do
    raise RuntimeError, """
    #{Network.ref_string({node.module, node.name})} returned a task that exited: \
    #{inspect(reason)}

    It fired on #{inspect(token.bindings)}.\
    """
  end

  # A rule may return one fact, a list of them, or nothing.
  defp normalize_facts(nil), do: []
  defp normalize_facts(facts) when is_list(facts), do: Enum.reject(facts, &is_nil/1)
  defp normalize_facts(fact), do: [fact]

  # Attributes a body's non-fact return value to the rule that returned it. The `try`
  # must wrap the type call for one fact, and nothing else. Wrapping the insertion too
  # would catch whatever the resulting cascade raises, and blame it on this rule.
  defp check_facts!(facts, %State{} = state, node, token) do
    Enum.each(facts, fn
      # A task is a struct, so the taxonomy would give it a type and insert it.
      %Task{} = task ->
        raise ArgumentError, task_in_facts(node, token, task)

      fact ->
        check_fact!(fact, state, node, token)
    end)

    facts
  end

  defp check_fact!(fact, %State{} = state, node, token) do
    type =
      try do
        Taxonomy.fact_type(state.network.taxonomy, fact)
      rescue
        error ->
          reraise ArgumentError,
                  [message: not_a_fact(node, token, fact, error)],
                  __STACKTRACE__
      end

    if not node.generated? and MapSet.member?(state.network.reserved_types, type) do
      raise ArgumentError, concluded_marker(node, token, fact, type)
    end
  end

  defp task_in_facts(node, token, task) do
    """
    #{Network.ref_string({node.module, node.name})} returned #{inspect(task)} among its \
    facts.

    It fired on #{inspect(token.bindings)}. A body may return one task, and the result of \
    that task is the facts. The engine does not await a task in a list, or a task that a \
    task returns.\
    """
  end

  defp foreign_task(node, token, task) do
    """
    #{Network.ref_string({node.module, node.name})} returned #{inspect(task)}, which \
    another process started.

    It fired on #{inspect(token.bindings)}. Only the process that starts a task can await \
    it. Start the task in the body itself.\
    """
  end

  defp concluded_marker(node, token, fact, type) do
    """
    #{Network.ref_string({node.module, node.name})} returned #{inspect(fact)}. \
    #{Negation.reserved_message(type)}

    It fired on #{inspect(token.bindings)}. Return a fact of another type.\
    """
  end

  # All facts are checked before any of them changes the state. See
  # `Rete.Compiler.Negation.marker_alpha/1` for why a marker type is reserved.
  defp check_reserved!(%State{network: network}, facts, {Rete.Session, _call}, action) do
    case Enum.find(facts, &reserved?(network, &1)) do
      nil ->
        :ok

      fact ->
        type = Taxonomy.fact_type(network.taxonomy, fact)

        raise ArgumentError, """
        cannot #{action} #{inspect(fact)}. \
        #{Negation.reserved_message(type)}

        Give the fact another type. If a :fact_type_fn gave it this type, change the \
        function.\
        """
    end
  end

  defp check_reserved!(_state, _facts, _origin, _action), do: :ok

  # A value with no type is not a marker. `Taxonomy.default_fact_type/1` raises
  # `ArgumentError` for one. A retract of it stays a no-op, and an insert of it raises later,
  # where the type is read for the alpha nodes. Any other error comes from a user
  # `:fact_type_fn`, and surfaces here. The type is read twice only when the network has
  # reserved types, because `Network.reserved?/2` checks that first.
  defp reserved?(network, fact) do
    Network.reserved?(network, fact)
  rescue
    ArgumentError -> false
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
        node = Network.node(state.network, node_id)

        state |> retract(facts, {node.module, node.name}) |> drain()

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
        child <- alpha.children do
      {direction, child, [%Element{fact: fact, bindings: bindings}]}
    end
  end

  defp alphas_for(network, fact) do
    network.taxonomy
    |> Taxonomy.alpha_ids(fact)
    |> Enum.map(&Map.fetch!(network.alphas, &1))
  end
end
