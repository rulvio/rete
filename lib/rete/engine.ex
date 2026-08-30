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
  @spec insert(State.t(), [term()]) :: State.t()
  def insert(%State{} = state, facts) do
    {state, ops} =
      Enum.reduce(facts, {state, []}, fn fact, {%State{} = state, ops} ->
        case Memory.add_fact(state.memory, fact) do
          {memory, :new} ->
            {%State{state | memory: memory}, ops ++ alpha_ops(state, fact, :right)}

          {memory, :duplicate} ->
            {%State{state | memory: memory}, ops}
        end
      end)

    state |> State.enqueue(ops) |> drain()
  end

  @doc """
  Retracts facts and propagates the retraction.

  Only the last occurrence of a fact propagates. Anything that was concluded from
  it is retracted in turn, and so on until the network settles.
  """
  @spec retract(State.t(), [term()]) :: State.t()
  def retract(%State{} = state, facts) do
    {state, ops} =
      Enum.reduce(facts, {state, []}, fn fact, {%State{} = state, ops} ->
        case Memory.remove_fact(state.memory, fact) do
          {memory, :gone} ->
            {%State{state | memory: memory}, ops ++ alpha_ops(state, fact, :right_retract)}

          {memory, _} ->
            {%State{state | memory: memory}, ops}
        end
      end)

    state |> State.enqueue(ops) |> drain()
  end

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
    fire_loop(drain(state), max_cycles, 0)
  end

  @doc """
  The tokens that reached a query node, as binding maps filtered by `params`.
  """
  @spec query(State.t(), atom(), %{atom() => term()}) :: [%{atom() => term()}]
  def query(%State{} = state, name, params \\ %{}) do
    case Network.query(state.network, name) do
      nil ->
        raise ArgumentError,
              "no query named #{inspect(name)} in this network. Defined: " <>
                inspect(Map.keys(state.network.queries))

      node ->
        unknown = Map.keys(params) -- node.param_keys

        if unknown != [] do
          raise ArgumentError,
                "the query #{name} takes #{inspect(node.param_keys)}, " <>
                  "and was given #{inspect(unknown)}"
        end

        state.memory
        |> Memory.all_tokens(node.id)
        |> Enum.map(& &1.bindings)
        |> Enum.filter(fn bindings ->
          Enum.all?(params, fn {key, value} -> Map.get(bindings, key) == value end)
        end)
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
  defp fire_loop(%State{} = state, max_cycles, fired) do
    case Agenda.pop(state.agenda) do
      :empty ->
        %State{state | fired: state.fired + fired}

      {:ok, _activation, _agenda} when fired >= max_cycles ->
        raise RuntimeError, runaway(state, fired)

      {:ok, activation, agenda} ->
        %State{state | agenda: agenda}
        |> fire(activation)
        |> drain()
        |> fire_loop(max_cycles, fired + 1)
    end
  end

  defp runaway(%State{} = state, fired) do
    """
    fired #{fired} activations without the agenda emptying, which suggests rules \
    that keep re-triggering each other.

    Still pending:
    #{state.agenda |> Agenda.to_list() |> Enum.take(5) |> Enum.map_join("\n", &"  #{describe(state, &1)}")}

    Raise :max_cycles if the ruleset genuinely needs more.
    """
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
      |> well_founded(state, activation.token)

    case facts do
      [] ->
        state

      facts ->
        memory = Memory.add_insertion(state.memory, node.id, activation.token, facts)
        insert(%State{state | memory: memory}, facts)
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
  # that away is W5's problem, not this one's.
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

  defp walk(seen, [], _inserters), do: seen

  defp walk(seen, [fact | rest], inserters) do
    if MapSet.member?(seen, fact) do
      walk(seen, rest, inserters)
    else
      supports = inserters |> Map.get(fact, []) |> Enum.flat_map(&matched_facts/1)
      walk(MapSet.put(seen, fact), supports ++ rest, inserters)
    end
  end

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

  defp describe(state, %Activation{node_id: id, token: token}) do
    case Network.node(state.network, id) do
      %{name: name} -> "#{name} #{inspect(token.bindings)}"
      other -> inspect(other)
    end
  end

  # --- propagation ------------------------------------------------------------------

  # Drains the queue. `{:retract_facts, facts}` is the one op a node cannot carry
  # out itself: a production retracting its conclusions has to go back through
  # the alpha network, which only the engine can reach.
  defp drain(%State{} = state) do
    case State.dequeue(state) do
      :empty ->
        state

      {:ok, {:retract_facts, facts}, state} ->
        state |> retract(facts) |> drain()

      {:ok, op, state} ->
        {state, ops} = Nodes.handle(state, op)
        state |> State.enqueue(ops) |> drain()
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
