defmodule Rete.Inspect do
  @moduledoc """
  Asking a session why.

  Truth maintenance already records which match inserted what, and read backwards that is
  a provenance graph. These functions walk it.

      Rete.Inspect.explain(session, {:escalated, 1})
      Rete.Inspect.fired(session)
      Rete.Inspect.why_not(session, {MyRuleset, :some_rule})

  Everything here works on **any** session, with no listener and no setup, because it
  reads working memory rather than a history. A listener adds what memory cannot know:
  what happened, in what order, including activations that fired and were later
  retracted. See `Rete.Listener`.

  A rule is named by `{module, name}`, the identity `Rete.Session.query/3` also uses.

  Marker facts and the empty root token are engine machinery. An explanation describes
  them rather than presenting them as matched facts. See
  `docs/design/observability.md` §2.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.Engine.State
  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Session

  @typedoc """
  Why one fact exists.

  `:origin` is `:asserted`, `:derived`, or `:unknown` when the session does not hold the
  fact. `:rule`, `:module` and `:bindings` are `nil` when asserted. `:supports` holds one
  nested explanation per fact the match rested on. `:module` is reported alongside
  `:rule` rather than folded into it, so a caller matching on a bare name still works.
  """
  @type explanation :: %{
          fact: term(),
          origin: :asserted | :derived | :unknown,
          rule: atom() | nil,
          module: module() | nil,
          bindings: map() | nil,
          supports: [explanation()]
        }

  @doc """
  Why a fact exists, recursively down to the facts you asserted.

  Returns a **list**, one entry per independent support. A fact can have more than one,
  and removing one does not remove the fact. An asserted fact gives one entry with no
  supports. A fact the session does not hold gives one with `origin: :unknown`.

      iex> alias Rete.{Inspect, Session}
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> [%{origin: origin, rule: rule, supports: supports}] =
      ...>   Inspect.explain(session, {:flagged, 1, 250})
      iex> {origin, rule, supports |> Enum.map(& &1.fact) |> Enum.sort()}
      {:derived, :large_order, [{:customer, 1}, {:order, 1, 250}]}
  """
  @dialyzer {:no_opaque, do_explain: 3}
  @spec explain(Session.t(), term()) :: [explanation()]
  def explain(%Session{state: state}, fact), do: do_explain(state, fact, MapSet.new())

  # `MapSet.t()` is opaque with two internal representations, and dialyzer loses track of
  # which one a set threaded through a local recursion holds. `seen` never leaves this
  # function and is only built by `MapSet.new/0` and `MapSet.put/2`.
  @spec do_explain(State.t(), term(), MapSet.t()) :: [explanation()]
  defp do_explain(state, fact, seen) do
    cond do
      MapSet.member?(seen, fact) ->
        # A conclusion that supports itself. Report it once rather than recursing forever.
        [
          %{
            fact: fact,
            origin: :derived,
            rule: :"...cycle",
            module: nil,
            bindings: nil,
            supports: []
          }
        ]

      not Map.has_key?(state.memory.facts, fact) ->
        [%{fact: fact, origin: :unknown, rule: nil, module: nil, bindings: nil, supports: []}]

      true ->
        case derivations(state, fact) do
          [] ->
            [
              %{
                fact: fact,
                origin: :asserted,
                rule: nil,
                module: nil,
                bindings: nil,
                supports: []
              }
            ]

          derivations ->
            seen = MapSet.put(seen, fact)

            for {node, token} <- derivations do
              %{
                fact: fact,
                origin: :derived,
                rule: node.name,
                module: node.module,
                bindings: token.bindings,
                supports: Enum.flat_map(matched_facts(state, token), &do_explain(state, &1, seen))
              }
            end
        end
    end
  end

  # Truth maintenance records "this match at this production inserted these facts", which
  # read backwards is a provenance edge.
  defp derivations(state, fact) do
    for {node_id, by_token} <- state.memory.insertions,
        {token, batches} <- by_token,
        Enum.any?(batches, &(fact in &1)),
        node = Network.node(state.network, node_id),
        match?(%Node.Production{}, node) do
      {node, token}
    end
  end

  # A token's matches are the facts behind it, in order. The empty root token contributes
  # none, and a collection contributes the list it gathered rather than one fact.
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

  Reads truth maintenance, so it reports what is *currently* concluded rather than a
  history. A rule that fired and was later retracted does not appear. Attach
  `Rete.Listener.Collect` and read `:activation_fired` events for that.

  Generated negation helpers are excluded unless `generated: true`.

      iex> alias Rete.{Inspect, Session}
      iex> Session.new([Rete.Doc.Orders])
      ...> |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...> |> Session.fire_rules()
      ...> |> Inspect.fired()
      [%{rule: :large_order, module: Rete.Doc.Orders,
         bindings: %{amt: 250, cid: 1}, inserted: [{:flagged, 1, 250}]}]
  """
  @spec fired(Session.t(), keyword()) :: [
          %{rule: atom(), module: module(), bindings: map(), inserted: [term()]}
        ]
  def fired(%Session{state: state}, opts \\ []) do
    include_generated? = Keyword.get(opts, :generated, false)

    for {node_id, by_token} <- state.memory.insertions,
        node = Network.node(state.network, node_id),
        match?(%Node.Production{}, node),
        include_generated? or not node.generated?,
        {token, batches} <- by_token,
        facts <- batches do
      %{rule: node.name, module: node.module, bindings: token.bindings, inserted: facts}
    end
    |> Enum.sort_by(&{&1.rule, inspect(&1.module), inspect(&1.bindings)})
  end

  @doc """
  How far a rule got, condition by condition.

  The question behind "why did this not fire?". Each entry reports what one node on the
  rule's chain holds: `:elements` are facts that matched this condition alone, `:tokens`
  are partial matches from the left, and `:activations` (terminals only) is how many
  matches it concluded from.

  ```
  [%{node: 1, kind: "root_join", type: :customer, elements: 3, tokens: 0},
   %{node: 2, kind: "hash_join", type: :order,    elements: 0, tokens: 3}]
  ```

  Read it in order and find the first node where the two counts disagree. Above, three
  customers reached the order condition and no order matched them.

  Neither count is "matches that got through", and the two mean different things per node
  kind, so `0` in one column is not by itself a failure. Compare a node with the one
  before it. See `docs/design/observability.md` §2.
  """
  @spec why_not(Session.t(), {module(), atom()}) :: [map()]
  def why_not(%Session{state: state}, {module, name} = ref)
      when is_atom(module) and is_atom(name) do
    case terminal(state, ref) do
      nil ->
        raise ArgumentError,
              "no rule or query #{Network.ref_string(ref)} in this network. Defined: " <>
                Enum.map_join(rule_refs(state), ", ", &Network.ref_string/1)

      terminal ->
        state
        |> chain_to(terminal.id)
        |> Enum.map(fn id -> describe_node(state, id) end)
    end
  end

  def why_not(%Session{state: state}, name) when is_atom(name) do
    raise ArgumentError,
          "a rule is named by {module, name}, not by #{inspect(name)} alone — " <>
            "two rulesets may each define one. Defined: " <>
            Enum.map_join(rule_refs(state), ", ", &Network.ref_string/1)
  end

  @doc """
  The facts a collection gathered behind a token that came from it.

  A collection propagates only its result, so the members are otherwise invisible once a
  token has moved on. Give it the node id of the accumulate node, which `why_not/2`
  reports, and the join key from the token.
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

  defp terminal(state, {module, name}) do
    Enum.find(Network.beta_nodes(state.network), fn node ->
      terminal?(node) and node.name == name and node.module == module
    end)
  end

  defp terminal?(%Node.Production{}), do: true
  defp terminal?(%Node.Query{}), do: true
  defp terminal?(_node), do: false

  defp rule_refs(state) do
    for node <- Network.beta_nodes(state.network),
        terminal?(node),
        not generated?(node),
        do: {node.module, node.name}
  end

  # Walks back from the terminal to the root and reports root-first, so the list reads in
  # the order the conditions are evaluated. A disjunction gives a node several parents.
  # The first is enough to show where a chain broke without producing a tree.
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
