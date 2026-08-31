defmodule Rete.Session do
  @moduledoc """
  A session is an immutable value: every operation returns a new one.

  A session can be held, compared, kept as a checkpoint and sent between processes. The
  compiled network inside it is shared rather than copied, so two sessions built from the
  same rules differ only in their working memory.

  Facts you insert stay until you retract them. Facts a *rule* concludes are logical: the
  engine holds them while the match behind them holds. That is why a rule's right hand
  side only inserts, and why retracting removes anything concluded from a fact too,
  transitively. Nothing fires until `fire_rules/2`.

  The examples here run against this ruleset:

      defmodule Rete.Doc.Orders do
        use Rete.Ruleset

        derive :premium, :customer

        defrule large_order({:customer, cid}, {:order, cid, amt} when amt > 100) do
          {:flagged, cid, amt}
        end

        defquery flagged_for({:flagged, cid, amt}), do: {cid, amt}
      end

      iex> alias Rete.Session
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> Session.facts(session) |> Enum.sort()
      [{:customer, 1}, {:flagged, 1, 250}, {:order, 1, 250}]
      iex> Rete.Doc.Orders.flagged_for(session, cid: 1)
      [{1, 250}]

  See `docs/dsl.md` for writing rules and `docs/design/w3-engine.md` §8 for truth
  maintenance.
  """

  alias Rete.Compiler
  alias Rete.Engine
  alias Rete.Engine.State
  alias Rete.Network

  @type t :: %__MODULE__{state: State.t()}

  defstruct [:state]

  @doc """
  Builds a session from ruleset modules.

  Options go to `Rete.Compiler.build/2`. Compiling the network is the expensive part, so
  a long-lived application should do it once and use `from_network/1`.

      iex> Rete.Session.new([Rete.Doc.Orders]) |> Rete.Session.facts()
      []
  """
  @spec new([module()], keyword()) :: t()
  def new(modules, opts \\ []) when is_list(modules) do
    modules |> Compiler.build(opts) |> from_network()
  end

  @doc """
  Builds an empty session over an already compiled network.

  The network is immutable, so one can back any number of independent sessions.
  """
  @spec from_network(Network.t()) :: t()
  def from_network(%Network{} = network), do: %__MODULE__{state: Engine.new(network)}

  @doc """
  Inserts one fact or a list of them, returning a new session.

  Facts are a multiset. Inserting a fact equal to one already present bumps its count
  instead of duplicating its matches, so retracting one occurrence leaves the other.

      iex> alias Rete.Session
      iex> session = Session.new([Rete.Doc.Orders]) |> Session.insert({:customer, 1})
      iex> Session.facts(session)
      [{:customer, 1}]
  """
  @spec insert(t(), term() | [term()]) :: t()
  def insert(session, facts), do: update(session, &Engine.insert(&1, List.wrap(facts)))

  @doc """
  Retracts one fact or a list of them, returning a new session.

  Anything concluded from them is retracted too, transitively. Retracting a fact that is
  not present does nothing.

      iex> alias Rete.Session
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      ...>   |> Session.retract({:customer, 1})
      iex> Session.facts(session)
      [{:order, 1, 250}]
  """
  @spec retract(t(), term() | [term()]) :: t()
  def retract(session, facts), do: update(session, &Engine.retract(&1, List.wrap(facts)))

  @doc """
  Fires rules until the agenda is empty, returning a new session.

  Options:

    * `:max_cycles` — how many activations one call may fire. `:infinity` by default: the
      engine runs to quiescence, and an oscillating ruleset spins rather than raising.
      Give it an integer to bound the call. A ruleset that exceeds it raises with the
      rules that fired most. One that fires the whole allowance and then settles is fine.
      See `docs/design/w5-observability.md` §3 for how to pick a number.

  Inserting queues activations. Firing runs them and leaves the agenda empty.

      iex> alias Rete.Session
      iex> queued =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      iex> length(Session.pending(queued))
      1
      iex> Session.pending(Session.fire_rules(queued))
      []
  """
  @spec fire_rules(t(), keyword()) :: t()
  def fire_rules(session, opts \\ []), do: update(session, &Engine.fire_rules(&1, opts))

  @doc """
  Runs a query by `{module, name}`: one result per match, computed by its body.

  **Usually you would not write this.** `defquery flagged_for(...)` defines
  `flagged_for/2` in its own module, so the same call reads
  `Rete.Doc.Orders.flagged_for(session, cid: 1)`, which the compiler checks. Reach for
  this form when the query is decided at runtime.

  A query is addressed by module and name together because two rulesets composed into one
  session may each define a `:summary`.

  `filters` narrows the matches by equality on the *bindings*, before the body runs. It
  may name any variable the left hand side binds, as a keyword list or a map. There is no
  separate parameter declaration. Naming something the query does not bind raises rather
  than answering `[]`.

  Row order is **unspecified**. It does not vary with insertion order, so a given set of
  facts always answers the same way, but sort the result if you need an order.

      iex> alias Rete.Session
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> Session.query(session, {Rete.Doc.Orders, :flagged_for}, cid: 1)
      [{1, 250}]
  """
  @spec query(t(), {module(), atom()}, keyword() | %{atom() => term()}) :: [term()]
  def query(%__MODULE__{state: state}, ref, filters \\ []),
    do: Engine.query(state, ref, filters)

  @doc """
  Every fact the session holds, inserted or concluded.

  Unordered. A session is a set of facts, not a sequence.
  """
  @spec facts(t()) :: [term()]
  def facts(%__MODULE__{state: state}), do: Engine.facts(state)

  @doc """
  The activations waiting to fire, most salient first.

  Empty after `fire_rules/2` unless a rule inserted something during it.
  """
  @spec pending(t()) :: [Rete.Activation.t()]
  def pending(%__MODULE__{state: state}), do: Rete.Agenda.to_list(state.agenda)

  @doc """
  Attaches a listener, returning a new session.

  The listener sees every event from now on. Read what it accumulated with
  `listener_state/2`. Attaching several is fine, and they see events in attachment order.

      iex> alias Rete.Session
      iex> Session.new([Rete.Doc.Orders])
      ...> |> Session.with_listener(Rete.Listener.Collect, [])
      ...> |> Session.insert({:customer, 1})
      ...> |> Rete.Listener.Collect.by_tag(:fact_inserted)
      [{:fact_inserted, {:customer, 1}, :asserted}]
  """
  @spec with_listener(t(), module(), term()) :: t()
  def with_listener(session, module, init \\ nil),
    do: update(session, &Engine.with_listener(&1, module, init))

  @doc """
  What a listener has accumulated, or `nil` if it is not attached.
  """
  @spec listener_state(t(), module()) :: term()
  def listener_state(%__MODULE__{state: state}, module),
    do: Engine.listener_state(state, module)

  @doc """
  The compiled network behind a session.
  """
  @spec network(t()) :: Network.t()
  def network(%__MODULE__{state: state}), do: state.network

  defp update(%__MODULE__{state: state}, fun), do: %__MODULE__{state: fun.(state)}
end
