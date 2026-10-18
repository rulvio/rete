defmodule Rete.Test.Feed do
  @moduledoc """
  Facts that a test can take back, through the public API only.

  A session has no retract. A fact leaves when the match behind it goes. So `put/3` inserts
  `{:fed, ref, fact}`, and the rule here concludes `fact` from it. `withdraw/2` inserts
  `{:withdrawn, ref}`, which the negation reads. The match goes, and truth maintenance
  takes the fact back. Every node below sees the same retraction that it sees for any
  conclusion.

  Build the session with this module after the ruleset under test. A ref that was
  withdrawn stays withdrawn, so give a fact a new ref to put it back.
  """

  use Rete.Ruleset

  alias Rete.Network
  alias Rete.Session
  alias Rete.Test.Canon

  defrule feed({:fed, ref, fact}, {:not, [{:withdrawn, ref}]}), do: fact

  @doc "Puts each fact under a ref that equals the fact."
  @spec put(Session.t(), term() | [term()]) :: Session.t()
  def put(session, facts) do
    Session.insert(session, for(fact <- List.wrap(facts), do: {:fed, fact, fact}))
  end

  @doc "Puts one fact under `ref`. Each ref is one occurrence that a test can take back."
  @spec put(Session.t(), term(), term()) :: Session.t()
  def put(session, ref, fact), do: Session.insert(session, {:fed, ref, fact})

  @doc "Takes back every fact put under each ref. Call `Session.fire_rules/2` after it."
  @spec withdraw(Session.t(), term() | [term()]) :: Session.t()
  def withdraw(session, refs) do
    Session.insert(session, for(ref <- List.wrap(refs), do: {:withdrawn, ref}))
  end

  @doc "The facts of a session, without the facts that this module inserts."
  @spec facts(Session.t()) :: [term()]
  def facts(session), do: session |> Session.facts() |> Enum.reject(&own?/1)

  @doc "The count of each fact a session holds, without the facts this module inserts."
  @spec counts(Session.t()) :: %{term() => pos_integer()}
  def counts(session), do: Map.reject(session.state.memory.facts, fn {fact, _} -> own?(fact) end)

  @doc """
  The truth maintenance records of a session, as `Rete.Test.Canon` sees them, without the
  records of the rule here. That rule keys a record on the ref, so a fact put back under a
  new ref has a new record even where every other rule agrees.
  """
  @spec rule_insertions(Session.t()) :: map()
  def rule_insertions(session) do
    network = Session.network(session)

    session
    |> Canon.dump()
    |> Map.fetch!(:insertions)
    |> Map.reject(fn {id, _} -> Network.node(network, id).module == __MODULE__ end)
  end

  @doc """
  A fired session over the same network that holds only the facts this module put in
  `session`.

  A session that withdrew everything it put should equal this, as `Rete.Test.Canon` sees
  it. Its feed facts arrive in one call with each `{:withdrawn, ref}` first, so the rule
  here never fires.
  """
  @spec residue(Session.t()) :: Session.t()
  def residue(session) do
    # Term order puts every 2-tuple before every 3-tuple, so each withdrawal comes first.
    own = session |> Session.facts() |> Enum.filter(&own?/1) |> Enum.sort()

    session
    |> Session.network()
    |> Session.from_network()
    |> Session.insert(own)
    |> Session.fire_rules()
  end

  defp own?({:fed, _ref, _fact}), do: true
  defp own?({:withdrawn, _ref}), do: true
  defp own?(_fact), do: false
end
