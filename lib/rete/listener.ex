defmodule Rete.Listener do
  @moduledoc """
  Observing what a session does, through one callback.

  A listener is a module and a piece of state. Every event the engine produces is
  folded through it, and the state it returns is kept on the session — so a
  session with listeners is still an immutable value, with no processes and no
  side channel.

      defmodule CountFirings do
        @behaviour Rete.Listener

        @impl true
        def handle_event({:activation_fired, _node_id, _token, _facts}, count), do: count + 1
        def handle_event(_event, count), do: count
      end

      session =
        [MyRuleset]
        |> Rete.Session.new()
        |> Rete.Session.with_listener(CountFirings, 0)
        |> Rete.Session.insert(facts)
        |> Rete.Session.fire_rules()

      Rete.Session.listener_state(session, CountFirings)

  ## One callback, not seventeen

  Clara's listener protocol has seventeen methods, and calls to them are
  scattered through every node implementation. That follows from Clara's nodes
  calling each other: there is no single point every event passes through, so
  each node has to report for itself.

  This engine drains a work queue, so `Rete.Engine` sees every propagation and
  every firing. Events are emitted there and nowhere else — no node knows a
  listener exists. Adding an event is a change in one function, and a listener
  that cares about one kind of event pattern-matches it and lets the rest fall
  through:

      def handle_event({:fact_retracted, fact, _origin}, state), do: ...
      def handle_event(_event, state), do: state

  A listener **must** have a catch-all clause. New event kinds are added as the
  engine grows, and one that crashes on an unfamiliar event would make upgrading
  a breaking change.

  ## Cost when nobody is listening

  The overwhelmingly common case is no listeners at all, and that case must cost
  nothing. The engine's `emit` helper checks for an empty list before it builds the
  event term, so an unobserved session allocates nothing and calls nothing.

  ## Events

  | event | when |
  |---|---|
  | `{:fire_started, opts}` | `fire_rules/2` begins |
  | `{:fire_finished, fired}` | the agenda is empty; `fired` is how many activations ran |
  | `{:fact_inserted, fact, origin}` | a fact is added to working memory |
  | `{:fact_retracted, fact, origin}` | a fact leaves working memory |
  | `{:fact_duplicated, fact}` | an equal fact was already present, so nothing propagated |
  | `{:propagated, op, node_id, count}` | a node consumed `count` items |
  | `{:activation_added, node_id, token}` | a production's LHS became satisfied |
  | `{:activation_removed, node_id, token}` | a pending activation was cancelled before firing |
  | `{:activation_fired, node_id, token, facts}` | a rule ran and returned `facts` |

  `origin` is `:asserted` for a fact the caller inserted, or `{:derived, node_id}`
  for one a rule concluded. That distinction is what lets a listener reconstruct
  provenance without reading memory.

  `op` is `:left`, `:left_retract`, `:right` or `:right_retract`.
  """

  @typedoc "Anything a listener chooses to carry between events."
  @type state :: term()

  @typedoc "Where a fact came from."
  @type origin :: :asserted | {:derived, term()}

  @typedoc "An engine event. Match the ones you care about and ignore the rest."
  @type event ::
          {:fire_started, keyword()}
          | {:fire_finished, non_neg_integer()}
          | {:fact_inserted, term(), origin()}
          | {:fact_retracted, term(), origin()}
          | {:fact_duplicated, term()}
          | {:propagated, atom(), term(), non_neg_integer()}
          | {:activation_added, term(), Rete.Token.t()}
          | {:activation_removed, term(), Rete.Token.t()}
          | {:activation_fired, term(), Rete.Token.t(), [term()]}

  @doc """
  Handles one event, returning the listener's next state.

  Implementations must include a catch-all clause.
  """
  @callback handle_event(event(), state()) :: state()
end

defmodule Rete.Listener.Collect do
  @moduledoc """
  Records every event, newest last.

  The substrate for inspection and for tests that need to assert on what the
  engine did rather than on what it ended up holding. It keeps everything, so it
  grows without bound — fine for a test or a debugging session, not something to
  leave attached to a long-lived one.
  """

  @behaviour Rete.Listener

  @impl true
  def handle_event(event, events), do: [event | events]

  @doc """
  The events a session recorded, in the order they happened.
  """
  @spec events(Rete.Session.t()) :: [Rete.Listener.event()]
  def events(session) do
    (Rete.Session.listener_state(session, __MODULE__) || []) |> Enum.reverse()
  end

  @doc """
  Only the events matching a tag, in order.

      Rete.Listener.Collect.by_tag(session, :activation_fired)
  """
  @spec by_tag(Rete.Session.t(), atom()) :: [Rete.Listener.event()]
  def by_tag(session, tag), do: session |> events() |> Enum.filter(&(elem(&1, 0) == tag))
end

defmodule Rete.Listener.Trace do
  @moduledoc """
  Writes a readable line per event.

  Attach it when a rule is not doing what you expect and you want to watch the
  session work. Propagation events are the noisy ones, so they are off unless
  asked for:

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

  defp describe({:fact_inserted, fact, {:derived, node}}),
    do: "  + #{inspect(fact)} (from node #{inspect(node)})"

  defp describe({:fact_retracted, fact, :asserted}), do: "  - #{inspect(fact)}"

  defp describe({:fact_retracted, fact, {:derived, node}}),
    do: "  - #{inspect(fact)} (support at node #{inspect(node)} gone)"

  defp describe({:fact_duplicated, fact}), do: "  = #{inspect(fact)} (already present)"

  defp describe({:activation_added, node, token}),
    do: "  ready  node #{inspect(node)} #{inspect(token.bindings)}"

  defp describe({:activation_removed, node, token}),
    do: "  cancel node #{inspect(node)} #{inspect(token.bindings)}"

  defp describe({:activation_fired, node, token, facts}),
    do: "  fire   node #{inspect(node)} #{inspect(token.bindings)} -> #{inspect(facts)}"

  defp describe({:propagated, op, node, count}),
    do: "    #{op} #{inspect(node)} x#{count}"

  defp describe(other), do: inspect(other)
end
