defmodule Rete.Inspect do
  @moduledoc """
  Asking a session why.

  When a fact appears that should not, or a rule does not fire that should, the
  engine has the answer already — truth maintenance records which match inserted
  what, and that record is a provenance graph. These functions walk it.

  Everything here works on **any** session, with no listener attached and no
  setup, because it reads working memory rather than a history. A listener adds
  the things memory cannot know: what happened and in what order, including
  activations that fired and were later retracted. See `Rete.Listener`.

      Rete.Inspect.explain(session, {:escalated, 1})
      Rete.Inspect.fired(session)
      Rete.Inspect.why_not(session, :some_rule)

  ## Internal machinery is translated, not leaked

  A compound negation compiles to a generated helper rule that inserts a marker
  fact. Those markers are engine machinery: `Rete.Session.facts/1` hides them,
  and so does this — but an explanation may legitimately need to say *"suppressed
  because a negated conjunction matched"*, so a marker is described rather than
  merely dropped. The same goes for the empty root token, which is how a rule
  opening with a negation or a collection is anchored: it is not a matched fact
  and is never presented as one.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.Engine.State
  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Session

  @typedoc """
  Why one fact exists.

    * `:fact` — the fact being explained
    * `:origin` — `:asserted` when you inserted it, `:derived` when a rule
      concluded it, `:unknown` when the session does not hold it
    * `:rule` — the rule that concluded it, `nil` when asserted
    * `:bindings` — the match that concluded it, `nil` when asserted
    * `:supports` — one nested explanation per fact the match rested on
  """
  @type explanation :: %{
          fact: term(),
          origin: :asserted | :derived | :unknown,
          rule: atom() | nil,
          bindings: map() | nil,
          supports: [explanation()]
        }

  @doc """
  Why a fact exists, recursively down to the facts you asserted.

  A fact can have more than one support — two rules, or one rule through two
  matches — and each is explained separately, because removing one of them does
  not remove the fact.

      %{fact: {:escalated, 1}, origin: :derived, rule: :escalate,
        supports: [%{fact: {:flagged, 1}, origin: :derived, rule: :flag,
                     supports: [%{fact: {:order, 1, 250}, origin: :asserted}]}]}

  Returns a **list**, one entry per independent support, so that a fact with two
  supports is visibly different from one with a single support. An asserted fact
  gives one entry with no supports; a fact the session does not hold gives one
  with `origin: :unknown`.
  """
  @dialyzer {:no_opaque, do_explain: 3}
  @spec explain(Session.t(), term()) :: [explanation()]
  def explain(%Session{state: state}, fact), do: do_explain(state, fact, MapSet.new())

  # `MapSet.t()` is opaque and has two internal representations, and dialyzer
  # loses track of which one a set threaded through a local recursion holds. The
  # `seen` set never leaves this function and is only ever built by
  # `MapSet.new/0` and `MapSet.put/2`.
  @spec do_explain(State.t(), term(), MapSet.t()) :: [explanation()]
  defp do_explain(state, fact, seen) do
    cond do
      MapSet.member?(seen, fact) ->
        # A conclusion that supports itself, directly or through a cycle. Report
        # it once rather than recursing forever.
        [%{fact: fact, origin: :derived, rule: :"...cycle", bindings: nil, supports: []}]

      not Map.has_key?(state.memory.facts, fact) ->
        [%{fact: fact, origin: :unknown, rule: nil, bindings: nil, supports: []}]

      true ->
        case derivations(state, fact) do
          [] ->
            [%{fact: fact, origin: :asserted, rule: nil, bindings: nil, supports: []}]

          derivations ->
            seen = MapSet.put(seen, fact)

            for {node, token} <- derivations do
              %{
                fact: fact,
                origin: :derived,
                rule: node.name,
                bindings: token.bindings,
                supports: Enum.flat_map(matched_facts(state, token), &do_explain(state, &1, seen))
              }
            end
        end
    end
  end

  # Truth maintenance already records "this match at this production inserted
  # these facts", which read backwards is exactly a provenance edge.
  defp derivations(state, fact) do
    for {node_id, by_token} <- state.memory.insertions,
        {token, batches} <- by_token,
        Enum.any?(batches, &(fact in &1)),
        node = Network.node(state.network, node_id),
        match?(%Node.Production{}, node) do
      {node, token}
    end
  end

  # A token's matches are the facts behind it, in order. Two things in there are
  # not facts the user would recognise: the empty root token contributes none,
  # and a collection contributes the list it gathered rather than a single fact.
  defp matched_facts(state, token) do
    Enum.flat_map(token.matches, fn {matched, _node_id} ->
      cond do
        is_list(matched) -> matched
        Network.marker?(state.network, matched) -> []
        true -> [matched]
      end
    end)
  end

  @doc """
  Every rule that has concluded something, with the match and what it inserted.

  Reads truth maintenance, so it reports what is *currently* concluded rather
  than a history: a rule that fired and was later retracted does not appear.
  Attach `Rete.Listener.Collect` and read `:activation_fired` events for that.

  Generated negation helpers are excluded unless `generated: true`.
  """
  @spec fired(Session.t(), keyword()) :: [%{rule: atom(), bindings: map(), inserted: [term()]}]
  def fired(%Session{state: state}, opts \\ []) do
    include_generated? = Keyword.get(opts, :generated, false)

    for {node_id, by_token} <- state.memory.insertions,
        node = Network.node(state.network, node_id),
        match?(%Node.Production{}, node),
        include_generated? or not node.generated?,
        {token, batches} <- by_token,
        facts <- batches do
      %{rule: node.name, bindings: token.bindings, inserted: facts}
    end
    |> Enum.sort_by(&{&1.rule, inspect(&1.bindings)})
  end

  @doc """
  How far a rule got, condition by condition.

  The question behind "why did this not fire?". Each entry reports what one node
  on the rule's chain is holding:

    * `:elements` — facts that matched this condition on its own, arriving from
      the right;
    * `:tokens` — partial matches arriving from the left, i.e. how far the
      conditions before it got;
    * `:activations` — for a terminal, how many matches it has concluded from.

      [%{node: 1, kind: "root_join", type: :customer, elements: 3, tokens: 0},
       %{node: 2, kind: "hash_join", type: :order,    elements: 0, tokens: 3}]

  Read it left to right and look for the first node where the two disagree. Above,
  three customers reached the order condition and no order matched them, so the
  chain broke there.

  The two counts mean different things per node kind, and neither is "matches
  that got through": a root join holds elements and emits tokens without storing
  them, and a production holds neither — it turns matches into activations. So
  `0` in one column is not by itself a failure. Compare the columns, and compare
  a node with the one before it.
  """
  @spec why_not(Session.t(), atom()) :: [map()]
  def why_not(%Session{state: state}, rule) do
    case terminal(state, rule) do
      nil ->
        raise ArgumentError,
              "no rule or query named #{inspect(rule)} in this network. Defined: " <>
                inspect(rule_names(state))

      terminal ->
        state
        |> chain_to(terminal.id)
        |> Enum.map(fn id -> describe_node(state, id) end)
    end
  end

  @doc """
  The facts a collection gathered behind a token that came from it.

  A collection propagates only its result, so the members are otherwise
  invisible once a token has moved on. Give it the node id of the accumulate
  node — `why_not/2` reports node ids — and the join key from the token.
  """
  @spec collection(Session.t(), term(), map()) :: [term()]
  def collection(%Session{state: state}, node_id, join_key) do
    state.memory
    |> Memory.groups(node_id, join_key)
    |> Enum.flat_map(fn {_group, elements} -> Enum.map(elements, & &1.fact) end)
  end

  defp describe_node(state, id) do
    node = Network.node(state.network, id)

    base = %{
      node: id,
      kind: node.__struct__ |> Module.split() |> List.last() |> Macro.underscore(),
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

  defp terminal(state, rule) do
    Enum.find(Network.beta_nodes(state.network), fn node ->
      terminal?(node) and node.name == rule
    end)
  end

  defp terminal?(%Node.Production{}), do: true
  defp terminal?(%Node.Query{}), do: true
  defp terminal?(_node), do: false

  defp rule_names(state) do
    for node <- Network.beta_nodes(state.network),
        terminal?(node),
        not generated?(node),
        do: node.name
  end

  # Walks back from the terminal to the root, then reports root-first, so the
  # list reads in the order the rule's conditions are evaluated. A disjunction
  # gives a node several parents; the first is enough to show where a chain
  # broke without turning the output into a tree.
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
