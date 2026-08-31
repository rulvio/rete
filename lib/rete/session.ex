defmodule Rete.Session do
  @moduledoc """
  The public API: a session is an immutable value.

  Every operation returns a new session rather than changing the one you passed,
  so a session can be held, compared, kept as a checkpoint and shared across
  processes without coordination. The compiled network inside it is shared, not
  copied — only the working memory differs between two sessions built from the
  same rules.

      session =
        Rete.Session.new([MyRuleset])
        |> Rete.Session.insert([{:customer, 1, "Ada"}, {:order, 1, 250}])
        |> Rete.Session.fire_rules()

      Rete.Session.facts(session)
      MyRuleset.flagged_for(session, cid: 1)

  ## Insert, retract, and what a rule may do

  Facts you insert are yours: they stay until you retract them. Facts a *rule*
  concludes are logical — the engine holds them exactly as long as the match
  behind them holds, and takes them back when it stops holding.

  That is why a rule's right hand side only ever inserts. It says what follows
  from a match, and keeping that true as facts change is the engine's job. There
  is no unconditional insert and no right-hand-side retract, so a session cannot
  end up asserting something whose support has gone.

  Nor can a conclusion hold itself up. A rule that concludes something its own
  match already rests on does not give it a second support, so retracting what
  you inserted really does empty the session — see the truth maintenance section
  of `Rete.Engine` for what that costs.

  Retracting a fact therefore does more than remove it: anything concluded from
  it goes too, and anything concluded from *that*, until the session settles.

  ## When rules run

  Nothing fires until `fire_rules/2`. Inserting only propagates matches through
  the network and queues the activations, so a batch of facts can be inserted
  and reasoned about together rather than each one triggering a cascade of its
  own. Querying a session that has pending activations tells you what was true
  before they fired.
  """

  alias Rete.Compiler
  alias Rete.Engine
  alias Rete.Engine.State
  alias Rete.Network

  @type t :: %__MODULE__{state: State.t()}

  defstruct [:state]

  @doc """
  Builds a session from ruleset modules.

  Options are passed to `Rete.Compiler.build/2`; `:fact_type_fn` is the useful
  one, and it defaults to struct, tagged tuple and tagged map.

  Compiling the network is the expensive part, so a long-lived application
  should do it once — see `from_network/1`.
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
  Inserts facts, returning a new session.

  Accepts one fact or a list. Inserting a fact equal to one already present
  bumps its count rather than duplicating its matches, so a later retraction of
  one occurrence leaves the other standing.
  """
  @spec insert(t(), term() | [term()]) :: t()
  def insert(session, facts), do: update(session, &Engine.insert(&1, List.wrap(facts)))

  @doc """
  Retracts facts, returning a new session.

  Anything concluded from them is retracted too, transitively. Retracting a fact
  that is not present does nothing.
  """
  @spec retract(t(), term() | [term()]) :: t()
  def retract(session, facts), do: update(session, &Engine.retract(&1, List.wrap(facts)))

  @doc """
  Fires rules until the agenda is empty, returning a new session.

  Options:

    * `:max_cycles` — how many activations one call may fire. `:infinity` by
      default: the engine runs to quiescence, and an oscillating ruleset spins
      rather than raising. Give it an integer to bound the call — a ruleset that
      exceeds it raises with the rules that fired most, and one that fires the
      whole allowance and then settles is fine. See the loop guard section of
      `Rete.Engine` for how to pick one and what it costs.
  """
  @spec fire_rules(t(), keyword()) :: t()
  def fire_rules(session, opts \\ []), do: update(session, &Engine.fire_rules(&1, opts))

  @doc """
  Runs a query by `{module, name}`: one result per match, computed by its body.

      Rete.Session.query(session, {MyRuleset, :flagged_for}, cid: 1)
      #=> [{1, 250}]

  **Usually you would not write this.** `defquery flagged_for(...)` defines
  `flagged_for/2` in its own module, so the same call reads:

      MyRuleset.flagged_for(session, cid: 1)
      session |> MyRuleset.flagged_for(cid: 1)

  which is a plain function call the compiler checks. This is the form to reach
  for when the query is decided at runtime rather than written down.

  A query is addressed by module and name together because a bare name belongs
  to no one: two rulesets composed into one session may each define a
  `:summary`, and the pair is what tells them apart.

  `filters` narrows the matches by equality on the *bindings*, before the body
  runs, and may name any variable the left hand side binds — there is no
  separate parameter declaration. A keyword list or a map both work. Naming
  something the query does not bind raises, rather than quietly answering `[]`.

  Reads the session as it stands: a query answered while activations are still
  pending reports what was true before they fired.

  Row order is **unspecified**. It does not vary with the order the facts were
  inserted in, so a given set of facts always answers the same way, but sort the
  result if you need a particular order.
  """
  @spec query(t(), {module(), atom()}, keyword() | %{atom() => term()}) :: [term()]
  def query(%__MODULE__{state: state}, ref, filters \\ []),
    do: Engine.query(state, ref, filters)

  @doc """
  Every fact the session holds, inserted or concluded.

  Unordered: a session is a set of facts, not a sequence, and depending on the
  order would be depending on an implementation detail.
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

  The listener sees every event from now on, and its accumulated state is read
  back with `listener_state/2`. Attaching several is fine; they see events in
  the order they were attached.

      session
      |> Rete.Session.with_listener(Rete.Listener.Collect, [])
      |> Rete.Session.insert(facts)
      |> Rete.Session.fire_rules()
      |> Rete.Listener.Collect.events()
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
