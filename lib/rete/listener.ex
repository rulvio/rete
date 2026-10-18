defmodule Rete.Listener do
  @moduledoc """
  Observing what a session does, through one callback.

  A listener is a module and a piece of state. The engine folds every event through it,
  and keeps the state it returns on the session. So a session with listeners is still an
  immutable value. An unobserved session costs nothing.

      defmodule CountFirings do
        @behaviour Rete.Listener

        @impl true
        def handle_event({:activation_fired, _source, _token, _facts}, count), do: count + 1
        def handle_event(_event, count), do: count
      end

      session |> Rete.Session.with_listener(CountFirings, 0) |> Rete.Session.fire_rules()

  A listener **must** have a catch-all clause. The engine adds new event kinds as it
  grows. A listener that crashes on an unfamiliar event would turn every upgrade into a
  breaking change.

  ## Events

  | event | when |
  |---|---|
  | `{:fire_started}` | `fire_rules/2` begins |
  | `{:fire_finished, fired}` | the agenda is empty. `fired` is how many cycles ran, as `:max_cycles` counts them |
  | `{:fact_inserted, fact, origin}` | one occurrence of a fact is added to working memory |
  | `{:fact_retracted, fact, origin}` | one occurrence of a fact leaves working memory |
  | `{:propagated, op, node_id, count}` | a node consumed `count` items |
  | `{:activation_added, source, token}` | a production's LHS became satisfied |
  | `{:activation_removed, source, token}` | a pending activation was cancelled |
  | `{:activation_fired, source, token, facts}` | a rule fired and concluded `facts`, or an activation cache answered for it |

  `source` is `%{node: node_id, rule: {module, name}}`. It is a map, so a field can be
  added later without changing the shape every listener matches on. `{:propagated, ...}`
  is the exception, and it carries the bare id, because a join has no user-facing name.

  `origin` is a `{module, name}` pair. `{Rete.Session, :insert}` means your own call. Any
  other pair names the rule whose match added or lost the fact. A retraction always names
  a rule, because only truth maintenance retracts. This is what lets a listener reconstruct
  provenance, without reading memory. See `docs/design/observability.md` §1.

  An activation cache can answer for the body of a rule. See `Rete.ActivationCache`. Its
  `:activation_fired` then has `cached: true` in its source, and the body did not run.
  Each fact that the hit inserts has the origin `{module, name, :cached}`. A retraction of
  that fact has the origin `{module, name}`, because it names the rule whose match lost
  the fact. To pair the two events, compare the first two elements. The hit takes its
  place in a cycle as a firing does. A query fires as a rule does. Its `facts` is a list
  that holds its one row.
  """

  @typedoc "Anything a listener chooses to carry between events."
  @type state :: term()

  @typedoc "Which terminal an event came from: its node id and its `{module, name}`."
  @type source :: %{
          required(:node) => term(),
          required(:rule) => {module(), atom()},
          optional(:cached) => true
        }

  @typedoc """
  Where a fact came from, your own call or a rule, or the rule whose match lost it. An
  insertion that an activation cache answered for adds `:cached`. A retraction never does.
  """
  @type origin :: {module(), atom()} | {module(), atom(), :cached}

  @typedoc "An engine event. Match the ones you care about and ignore the rest."
  @type event ::
          {:fire_started}
          | {:fire_finished, non_neg_integer()}
          | {:fact_inserted, term(), origin()}
          | {:fact_retracted, term(), origin()}
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

  Use this for tests that assert on what the engine did, instead of on what it holds. It
  keeps everything, and it grows without bound. Do not leave it attached to a long-lived
  session.
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
      [
        {{Rete.Doc.Orders, :large_order}, [{:flagged, 1, 250}]},
        {{Rete.Doc.Orders, :flagged_for}, [{1, 250}]}
      ]
  """
  @spec by_tag(Rete.Session.t(), atom()) :: [Rete.Listener.event()]
  def by_tag(session, tag), do: session |> events() |> Enum.filter(&(elem(&1, 0) == tag))
end

defmodule Rete.Listener.Trace do
  @moduledoc """
  Writes a readable line per event.

  Attach it to watch a session work. Options are `:device`, which defaults to `:stdio`,
  and `:verbose`, which adds the noisy propagation events.

  A firing that an activation cache answered reads `cached` in place of `fire`. A fact it
  inserted reads `(cached from Rule)` in place of `(from Rule)`.

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

  defp describe({:fire_started}), do: "fire"
  defp describe({:fire_finished, fired}), do: "settled after #{fired} cycles"
  defp describe({:fact_inserted, fact, {Rete.Session, :insert}}), do: "  + #{inspect(fact)}"

  defp describe({:fact_inserted, fact, {module, name, :cached}}),
    do: "  + #{inspect(fact)} (cached from #{rule({module, name})})"

  defp describe({:fact_inserted, fact, origin}),
    do: "  + #{inspect(fact)} (from #{rule(origin)})"

  defp describe({:fact_retracted, fact, origin}),
    do: "  - #{inspect(fact)} (support from #{rule(origin)} gone)"

  defp describe({:activation_added, source, token}),
    do: "  ready  #{rule(source)} #{inspect(token.bindings)}"

  defp describe({:activation_removed, source, token}),
    do: "  cancel #{rule(source)} #{inspect(token.bindings)}"

  defp describe({:activation_fired, %{cached: true} = source, token, facts}),
    do: "  cached #{rule(source)} #{inspect(token.bindings)} -> #{inspect(facts)}"

  defp describe({:activation_fired, source, token, facts}),
    do: "  fire   #{rule(source)} #{inspect(token.bindings)} -> #{inspect(facts)}"

  defp describe({:propagated, op, node, count}),
    do: "    #{op} #{inspect(node)} x#{count}"

  defp describe(other), do: inspect(other)

  defp rule(%{rule: ref}), do: rule(ref)

  # credo:disable-for-next-line Credo.Check.Design.AliasUsage
  defp rule(ref), do: Rete.Network.ref_string(ref)
end
