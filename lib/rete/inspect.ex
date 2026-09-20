defmodule Rete.Inspect do
  @moduledoc """
  Asking a session why.

  Truth maintenance already records which match inserted what. Read backwards, that is a
  provenance graph. These two functions walk it.

      Rete.Inspect.explain(session)
      Rete.Inspect.explain(session, {MyRuleset, :large_order})
      Rete.Inspect.why_not(session, {MyRuleset, :some_rule})

  `explain/1,2` reports what happened: every match a rule fired on, the facts behind that
  match, and the facts it concluded. `why_not/1,2` reports where a rule stopped, condition
  by condition. Give either one a `{module, name}` pair for one rule. Give it no pair for
  every rule and query in the session.

  Both work with no listener and no setup, because they read working memory instead of a
  history. A listener adds what memory cannot know: what happened, in what order, including
  activations that fired and were later retracted. See `Rete.Listener`.

  **Fire before you inspect.** Both functions read what propagation built, and
  `Rete.Session.insert/2` only queues propagation. On a session that never fired they would
  report zero of everything. That reads as "nothing matched", but the truth is "nothing has
  been matched yet". Both raise instead. `Rete.Session.settled?/1` reports whether a session
  needs a fire.

  A rule is named by `{module, name}`, the identity `Rete.Session.query/3` also uses.

  Marker facts and the empty root token are engine machinery. An explanation describes them
  rather than presenting them as matched facts. See
  `docs/design/observability.md` §2.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.Engine
  alias Rete.Engine.State
  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Session

  @typedoc "A rule or query, named the way `Rete.Session.query/3` names one."
  @type ref :: {module(), atom()}

  @typedoc """
  One fact behind a match, and where it came from.

  `:origin` is `:asserted` for a fact you inserted, `:derived` for one a rule concluded,
  and `:gathered` for a collection. `:from` names the rules that concluded the fact. It is
  a **list**, because a fact can rest on more than one independent support, and it is `[]`
  unless `:origin` is `:derived`.

  `:members` is `nil`, except on a collection. There `:fact` is the gathered list, which is
  what the rule received, and `:members` describes each fact in it.
  """
  @type match :: %{
          fact: term(),
          origin: :asserted | :derived | :gathered,
          from: [ref()],
          members: [match()] | nil
        }

  @typedoc """
  One match a rule fired on.

  `:inserted` is what the rule concluded from this match. It is `[]` on a query, because a
  query concludes nothing.
  """
  @type activation :: %{
          bindings: %{atom() => term()},
          matches: [match()],
          inserted: [term()]
        }

  @typedoc "What one rule or query did."
  @type explanation :: %{
          rule: atom(),
          module: module(),
          type: :rule | :query,
          activations: [activation()]
        }

  @typedoc "How far one rule got, node by node."
  @type chain :: %{rule: atom(), module: module(), chain: [map()]}

  @doc """
  What every rule and query in the session did.

  One entry per rule and per query, sorted by module and then by name. Generated negation
  helpers are left out. Name one with `explain/2` to see it anyway.

      iex> alias Rete.{Inspect, Session}
      iex> Session.new([Rete.Doc.Orders])
      ...> |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...> |> Session.fire_rules()
      ...> |> Inspect.explain()
      ...> |> Enum.map(&{&1.type, &1.rule, length(&1.activations)})
      [{:query, :flagged_for, 1}, {:rule, :large_order, 1}]
  """
  @spec explain(Session.t()) :: [explanation()]
  def explain(%Session{state: state}) do
    settled!(state, "explain/1")
    state = indexed(state)

    state |> terminal_nodes() |> Enum.map(&explanation(state, &1))
  end

  @doc """
  What one rule or query did, match by match.

  Each activation is one match the rule fired on. `:bindings` is what that match bound,
  `:matches` is the facts behind it, and `:inserted` is what the rule concluded from it.

  `activations: []` means the rule concluded nothing. That is usually a rule that never
  matched, and `why_not/2` then says where it stopped. A rule whose body returns `nil` or
  `[]` reports the same, because nothing in memory records a match no conclusion rests on.
  `Rete.Listener` sees that firing where this cannot.

  Each entry of `:matches` says where its fact came from. `:from` names the rules that
  concluded it, so you read a chain by following that pair to its own entry in the same
  result. A collection reports the gathered list as its fact, and describes each member
  under `:members`.

  Activations are sorted by their bindings, and not by the order they fired in. Two that
  bind the same values keep an order that carries no meaning. One session gives one answer,
  so a test may rely on the list. Attach `Rete.Listener.Collect` for the order they fired
  in.

      iex> alias Rete.{Inspect, Session}
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> %{activations: [activation]} =
      ...>   Inspect.explain(session, {Rete.Doc.Orders, :large_order})
      iex> activation.inserted
      [{:flagged, 1, 250}]
      iex> Enum.map(activation.matches, &{&1.fact, &1.origin})
      [{{:customer, 1}, :asserted}, {{:order, 1, 250}, :asserted}]

  The query over what that rule concluded names the rule as the source of its own match:

      iex> alias Rete.{Inspect, Session}
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> %{type: :query, activations: [%{matches: [match]}]} =
      ...>   Inspect.explain(session, {Rete.Doc.Orders, :flagged_for})
      iex> {match.fact, match.origin, match.from}
      {{:flagged, 1, 250}, :derived, [{Rete.Doc.Orders, :large_order}]}
  """
  @spec explain(Session.t(), ref()) :: explanation()
  def explain(%Session{state: state}, {module, name} = ref)
      when is_atom(module) and is_atom(name) do
    node = terminal!(state, ref)
    settled!(state, "explain/2")

    explanation(indexed(state), node)
  end

  def explain(%Session{state: state}, name) when is_atom(name) do
    raise ArgumentError, bare_name_message(state, name)
  end

  @doc """
  How far every rule and query got.

  One entry per rule and per query, sorted by module and then by name. Generated negation
  helpers are left out. Name one with `why_not/2` to see it anyway.
  """
  @spec why_not(Session.t()) :: [chain()]
  def why_not(%Session{state: state}) do
    settled!(state, "why_not/1")

    state |> terminal_nodes() |> Enum.map(&chain(state, &1))
  end

  @doc """
  How far a rule got, condition by condition.

  This answers "why did this not fire?". Each entry of `:chain` reports what one node on
  the chain of the rule holds. `:elements` are the facts that matched this condition alone.
  `:tokens` are partial matches from the left. `:activations`, on terminals only, is the
  number of matches that it concluded from.

  ```
  %{rule: :large_order, module: MyRuleset,
    chain: [
      %{node: 1, kind: "root_join", type: :customer, elements: 3, tokens: 0},
      %{node: 2, kind: "hash_join", type: :order,    elements: 0, tokens: 3}
    ]}
  ```

  Read the chain in order, and find the first node where the two counts disagree. Above,
  three customers reached the order condition, and no order matched them.

  Neither count means "matches that got through". The two mean different things per node
  kind, so `0` in one column is not by itself a failure. Compare a node against the one
  before it instead. See `docs/design/observability.md` §2.
  """
  @spec why_not(Session.t(), ref()) :: chain()
  def why_not(%Session{state: state}, {module, name} = ref)
      when is_atom(module) and is_atom(name) do
    node = terminal!(state, ref)
    settled!(state, "why_not/2")

    chain(state, node)
  end

  def why_not(%Session{state: state}, name) when is_atom(name) do
    raise ArgumentError, bare_name_message(state, name)
  end

  # --- building one entry ---------------------------------------------------------

  defp explanation(state, node) do
    %{
      rule: node.name,
      module: node.module,
      type: type(node),
      activations: activations(state, node)
    }
  end

  defp chain(state, node) do
    %{
      rule: node.name,
      module: node.module,
      chain: state |> chain_to(node.id) |> Enum.map(&describe_node(state, &1))
    }
  end

  # --- activations ----------------------------------------------------------------

  # A production's activations come from truth maintenance: `insertions` is
  # `node_id => token => [[fact]]`, which is "this match at this production inserted these
  # facts". One token is one match, so its batches are concatenated rather than reported
  # apart. A query inserts nothing, so its activations are the tokens it holds.
  defp activations(state, %Node.Production{} = node) do
    state.memory.insertions
    |> Map.get(node.id, %{})
    |> Enum.map(fn {token, batches} ->
      activation(state, token, Enum.concat(batches))
    end)
    |> sort_activations()
  end

  defp activations(state, %Node.Query{} = node) do
    state.memory
    |> Memory.all_tokens(node.id)
    |> Enum.map(&activation(state, &1, []))
    |> sort_activations()
  end

  defp activation(state, token, inserted) do
    %{bindings: token.bindings, matches: matches(state, token), inserted: inserted}
  end

  # `all_tokens/2` reads a map of join keys, and `insertions` is a map of tokens, so
  # neither arrives in a defined order. Sorting makes one session give one answer.
  #
  # On the terms, and not on `inspect/1` of them. Term order over maps is already total, and
  # a printed binding grows with the *values*: one holding a 2,000 fact collection sorted
  # 800 times slower.
  #
  # Bindings alone, with no tiebreak. Two activations can share them, because a discarded
  # name in a condition tells two matches apart and never reaches the bindings. Their order
  # is already settled: the map iterates on its key set, not on the order the session
  # reached it in. A tiebreak on `:matches` would order them by term order over facts, and
  # that is no more the order they fired in than this is. `Rete.Listener.Collect` is what
  # answers that, and the doc points there.
  defp sort_activations(activations), do: Enum.sort_by(activations, & &1.bindings)

  # A token's matches are the facts behind it, in order. The empty root token contributes
  # none. A collection contributes the list it gathered, which is what the rule received,
  # so it is reported whole and its members are described under it.
  defp matches(state, token) do
    Enum.flat_map(token.matches, fn {matched, _node_id} ->
      cond do
        is_list(matched) ->
          [%{fact: matched, origin: :gathered, from: [], members: members(state, matched)}]

        Network.marker?(state.network, matched) ->
          []

        true ->
          [fact_match(state, matched)]
      end
    end)
  end

  defp members(state, facts), do: Enum.map(facts, &fact_match(state, &1))

  # Where one fact came from. A fact that reached a match is in working memory by
  # construction, so there is no third answer here: it was asserted, or a rule concluded
  # it. `:from` is a list, because a fact can rest on more than one independent support,
  # and each of them holds it up on its own.
  defp fact_match(state, fact) do
    case state |> derivations(fact) |> Enum.map(&{&1.module, &1.name}) |> Enum.uniq() do
      [] -> %{fact: fact, origin: :asserted, from: [], members: nil}
      refs -> %{fact: fact, origin: :derived, from: refs, members: nil}
    end
  end

  # Builds the `inserters` index, and keeps it for the rest of this call.
  #
  # `Rete.Memory.inserters/2` falls back to a scan of every insertion record when the index
  # is not built, which suits a reader that asks one time. This asks once per matched fact,
  # so the fallback would be quadratic in the size of the session. The index costs one pass
  # and answers every later lookup by map. It is already built on a session where one rule
  # re-concludes what another concluded, and there this is free.
  #
  # The memory this returns does not leave the call. Nothing here changes what the session
  # holds, and `index_support/1` derives the index from `insertions` alone.
  defp indexed(%State{} = state), do: %State{state | memory: Memory.index_support(state.memory)}

  # Truth maintenance records "this match at this production inserted these facts", which
  # read backwards is a provenance edge. `Rete.Memory.inserters/2` is that index, kept the
  # other way round, so this is a lookup rather than a scan of every insertion record.
  defp derivations(state, fact) do
    for {node_id, _token} <- Memory.inserters(state.memory, fact),
        node = Network.node(state.network, node_id),
        match?(%Node.Production{}, node) do
      node
    end
  end

  # --- guards ---------------------------------------------------------------------

  # Refuses to answer from a session with propagation still queued. Both functions read
  # what propagation built, and on a session that never fired that is zero of everything.
  # It reads as "nothing matched" rather than "nothing has been matched yet". A wrong
  # answer from the tool that explains wrong answers is worse than no answer.
  #
  # A session that fired and was then inserted into is refused too. It answers as of that
  # fire, so the counts are real but describe a network your latest facts have not reached.
  # That is the same failure, and harder to catch, because the numbers look plausible.
  #
  # `Rete.Session.query/3` is deliberately not guarded this way. The difference is what the
  # caller asked. A query asks what matched, and `[]` is a true answer about a session where
  # nothing has propagated. These two ask *why*, and there the same zero is a false answer
  # to the question. So the guard belongs here and not there.
  # `Rete.Session.settled?/1` is the check a caller makes for itself.
  defp settled!(%State{} = state, called) do
    if Engine.settled?(state) do
      :ok
    else
      pending = Engine.pending_ops(state)
      operations = if pending == 1, do: "operation", else: "operations"

      raise ArgumentError,
            "#{called} needs a session that you fired. This one has #{pending} " <>
              "propagation #{operations} still queued, so the answer would describe the " <>
              "network before your facts reached it. Call `Rete.Session.fire_rules/2` " <>
              "first."
    end
  end

  # The name is checked before the settled guard, deliberately. Whether the rule exists does
  # not depend on whether the session was fired, and a typo is the more actionable of the
  # two errors. Reporting "you did not fire" for a name that is not there sends the caller
  # to fix the wrong thing.
  defp terminal!(state, ref) do
    case terminal(state, ref) do
      nil ->
        raise ArgumentError,
              "no rule or query #{Network.ref_string(ref)} in this network. Defined: " <>
                Enum.map_join(rule_refs(state), ", ", &Network.ref_string/1)

      node ->
        node
    end
  end

  defp bare_name_message(state, name) do
    "a rule is named by {module, name}, not by #{inspect(name)} alone — " <>
      "two rulesets may each define one. Defined: " <>
      Enum.map_join(rule_refs(state), ", ", &Network.ref_string/1)
  end

  # --- node description -----------------------------------------------------------

  defp describe_node(state, id) do
    node = Network.node(state.network, id)

    base = %{
      node: id,
      kind: kind(node),
      type: Map.get(node, :type),
      elements: length(Memory.all_elements(state.memory, id)),
      tokens: length(Memory.all_tokens(state.memory, id))
    }

    case node do
      %Node.Production{} -> Map.put(base, :activations, activation_count(state, id))
      _ -> base
    end
  end

  defp activation_count(state, node_id) do
    state.memory.insertions |> Map.get(node_id, %{}) |> map_size()
  end

  # --- helpers ------------------------------------------------------------------

  # The node struct name, as `why_not/2` reports it: `Rete.Network.Node.HashJoin` reads
  # `hash_join`.
  defp kind(node), do: node.__struct__ |> Module.split() |> List.last() |> Macro.underscore()

  defp type(%Node.Query{}), do: :query
  defp type(_node), do: :rule

  # One order for one session. A module is sorted by its printed name, because an alias is
  # an atom and atom order is not the order a reader expects.
  defp sort_key({module, name}), do: {inspect(module), name}

  defp terminal(state, {module, name}) do
    Enum.find(Network.beta_nodes(state.network), fn node ->
      terminal?(node) and node.name == name and node.module == module
    end)
  end

  defp terminal?(%Node.Production{}), do: true
  defp terminal?(%Node.Query{}), do: true
  defp terminal?(_node), do: false

  # Every rule and query a caller may name, in one pass, sorted.
  #
  # The arity-1 forms map over **these nodes**, and not over their refs. `terminal/2` scans
  # the beta graph, so resolving a ref per rule would scan it once per rule, which is
  # quadratic in the rule count. That is the exact shape `bench/run.exs` exists to catch:
  # over 400 rules it read ~n^1.7 before, where the gate is n^1.5.
  defp terminal_nodes(state) do
    state.network
    |> Network.beta_nodes()
    |> Enum.filter(&(terminal?(&1) and not generated?(&1)))
    |> Enum.sort_by(&sort_key({&1.module, &1.name}))
  end

  # The same set as a list of refs, for the two error messages that list what exists. An
  # error path pays for one more pass without anybody noticing.
  defp rule_refs(state), do: state |> terminal_nodes() |> Enum.map(&{&1.module, &1.name})

  # Walks back from the terminal to the root, and reports root-first. So the list reads
  # in the order the conditions are evaluated. A disjunction gives a node several
  # parents. The first is enough to show where a chain broke, without producing a tree.
  defp chain_to(state, id), do: chain_to(state, id, [])

  defp chain_to(state, id, acc) do
    case state.network.graph |> BetaGraph.parents(id) |> Enum.sort() do
      [] -> acc
      [0 | _] -> [id | acc]
      [parent | _] -> chain_to(state, parent, [id | acc])
    end
  end

  defp generated?(%Node.Production{} = node), do: node.generated?
  defp generated?(_node), do: false
end
