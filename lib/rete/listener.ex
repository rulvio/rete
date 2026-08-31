defmodule Rete.Listener do
  @moduledoc """
  Observing what a session does, through one callback.

  A listener is a module and a piece of state. Every event is folded through it, and the
  state it returns is kept on the session, so a session with listeners is still an
  immutable value. An unobserved session costs nothing.

      defmodule CountFirings do
        @behaviour Rete.Listener

        @impl true
        def handle_event({:activation_fired, _source, _token, _facts}, count), do: count + 1
        def handle_event(_event, count), do: count
      end

      session |> Rete.Session.with_listener(CountFirings, 0) |> Rete.Session.fire_rules()

  A listener **must** have a catch-all clause. New event kinds are added as the engine
  grows, and one that crashes on an unfamiliar event would make upgrading a breaking
  change.

  ## Events

  | event | when |
  |---|---|
  | `{:fire_started, opts}` | `fire_rules/2` begins |
  | `{:fire_finished, fired}` | the agenda is empty; `fired` is how many activations ran |
  | `{:fact_inserted, fact, origin}` | a fact is added to working memory |
  | `{:fact_retracted, fact, origin}` | a fact leaves working memory |
  | `{:fact_duplicated, fact}` | an equal fact was already present, so nothing propagated |
  | `{:propagated, op, node_id, count}` | a node consumed `count` items |
  | `{:activation_added, source, token}` | a production's LHS became satisfied |
  | `{:activation_removed, source, token}` | a pending activation was cancelled |
  | `{:activation_fired, source, token, facts}` | a rule ran and returned `facts` |

  `source` is `%{node: node_id, rule: {module, name}}`, a map so a field can be added
  without changing the shape every listener matches on. `{:propagated, ...}` is the
  exception and carries the bare id, because a join has no user-facing name. `origin` is
  `:asserted` or `{:derived, source}`, which is what lets a listener reconstruct
  provenance without reading memory. See `docs/design/observability.md` §1.
  """

  @typedoc "Anything a listener chooses to carry between events."
  @type state :: term()

  @typedoc "Which terminal an event came from: its node id and its `{module, name}`."
  @type source :: %{node: term(), rule: {module(), atom()}}

  @typedoc "Where a fact came from."
  @type origin :: :asserted | {:derived, source()}

  @typedoc "An engine event. Match the ones you care about and ignore the rest."
  @type event ::
          {:fire_started, keyword()}
          | {:fire_finished, non_neg_integer()}
          | {:fact_inserted, term(), origin()}
          | {:fact_retracted, term(), origin()}
          | {:fact_duplicated, term()}
          | {:propagated, atom(), term(), non_neg_integer()}
          | {:activation_added, source(), Rete.Token.t()}
          | {:activation_removed, source(), Rete.Token.t()}
          | {:activation_fired, source(), Rete.Token.t(), [term()]}

  @doc """
  Handles one event, returning the listener's next state.

  Implementations must include a catch-all clause.
  """
  @callback handle_event(event(), state()) :: state()
end

defmodule Rete.Listener.Collect do
  @moduledoc """
  Records every event, newest last.

  For tests that assert on what the engine did rather than on what it holds. It keeps
  everything and grows without bound, so do not leave it attached to a long-lived session.
  """

  @behaviour Rete.Listener

  @impl true
  def handle_event(event, events), do: [event | events]

  @doc """
  The events a session recorded, in the order they happened.

      iex> Rete.Session.new([Rete.Doc.Orders]) |> Rete.Listener.Collect.events()
      []
  """
  @spec events(Rete.Session.t()) :: [Rete.Listener.event()]
  def events(session) do
    (Rete.Session.listener_state(session, __MODULE__) || []) |> Enum.reverse()
  end

  @doc """
  Only the events matching a tag, in order.

      iex> alias Rete.{Listener.Collect, Session}
      iex> Session.new([Rete.Doc.Orders])
      ...> |> Session.with_listener(Collect, [])
      ...> |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...> |> Session.fire_rules()
      ...> |> Collect.by_tag(:activation_fired)
      ...> |> Enum.map(fn {_tag, source, _token, facts} -> {source.rule, facts} end)
      [{{Rete.Doc.Orders, :large_order}, [{:flagged, 1, 250}]}]
  """
  @spec by_tag(Rete.Session.t(), atom()) :: [Rete.Listener.event()]
  def by_tag(session, tag), do: session |> events() |> Enum.filter(&(elem(&1, 0) == tag))
end

defmodule Rete.Listener.Trace do
  @moduledoc """
  Writes a readable line per event.

  Attach it to watch a session work. Options are `:device`, which defaults to `:stdio`,
  and `:verbose`, which adds the noisy propagation events.

      Rete.Session.with_listener(session, Rete.Listener.Trace, verbose: true)
  """

  @behaviour Rete.Listener

  @impl true
  def handle_event({:propagated, _op, _node, _count} = event, opts) do
    if Keyword.get(opts, :verbose, false), do: log(event, opts)
    opts
  end

  def handle_event(event, opts) do
    log(event, opts)
    opts
  end

  defp log(event, opts) do
    device = Keyword.get(opts, :device, :stdio)
    IO.puts(device, "[rete] " <> describe(event))
  end

  defp describe({:fire_started, _opts}), do: "fire"
  defp describe({:fire_finished, fired}), do: "settled after #{fired} activations"
  defp describe({:fact_inserted, fact, :asserted}), do: "  + #{inspect(fact)}"

  defp describe({:fact_inserted, fact, {:derived, source}}),
    do: "  + #{inspect(fact)} (from #{rule(source)})"

  defp describe({:fact_retracted, fact, :asserted}), do: "  - #{inspect(fact)}"

  defp describe({:fact_retracted, fact, {:derived, source}}),
    do: "  - #{inspect(fact)} (support from #{rule(source)} gone)"

  defp describe({:fact_duplicated, fact}), do: "  = #{inspect(fact)} (already present)"

  defp describe({:activation_added, source, token}),
    do: "  ready  #{rule(source)} #{inspect(token.bindings)}"

  defp describe({:activation_removed, source, token}),
    do: "  cancel #{rule(source)} #{inspect(token.bindings)}"

  defp describe({:activation_fired, source, token, facts}),
    do: "  fire   #{rule(source)} #{inspect(token.bindings)} -> #{inspect(facts)}"

  defp describe({:propagated, op, node, count}),
    do: "    #{op} #{inspect(node)} x#{count}"

  defp describe(other), do: inspect(other)

  # credo:disable-for-next-line Credo.Check.Design.AliasUsage
  defp rule(%{rule: ref}), do: Rete.Network.ref_string(ref)
end
