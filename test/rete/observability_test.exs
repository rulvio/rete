defmodule Rete.ObservabilityTest do
  use ExUnit.Case, async: true

  alias Rete.Inspect
  alias Rete.Listener
  alias Rete.Session

  doctest Rete.Inspect

  defmodule Rules do
    use Rete.Ruleset

    defrule flag({:order, cid, amt} when amt > 100) do
      {:flagged, cid}
    end

    defrule escalate({:flagged, cid}) do
      {:escalated, cid}
    end

    # Two rules concluding the same fact, so it has two independent supports.
    defrule vip_gold({:gold, cid}) do
      {:vip, cid}
    end

    defrule vip_spend({:spender, cid}) do
      {:vip, cid}
    end

    defrule dormant({:cust, cid}, {:not, [{:order, cid, _a}]}) do
      {:dormant, cid}
    end

    defrule clean({:cust, cid}, {:nand, [{:order, cid, _a}, {:refund, cid}]}) do
      {:clean, cid}
    end
  end

  @facts [{:order, 1, 250}, {:gold, 2}, {:spender, 2}, {:cust, 3}]

  defp session(facts \\ @facts) do
    [Rules] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp observed(facts \\ @facts) do
    [Rules]
    |> Session.new()
    |> Session.with_listener(Listener.Collect, [])
    |> Session.insert(facts)
    |> Session.fire_rules()
  end

  # --- listeners ------------------------------------------------------------------

  describe "listeners" do
    test "a listener sees the whole lifecycle" do
      tags = observed() |> Listener.Collect.events() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      for tag <- [
            :fact_inserted,
            :activation_added,
            :activation_fired,
            :fire_started,
            :fire_finished
          ] do
        assert tag in tags, "no #{tag} event"
      end
    end

    # The distinction that makes provenance reconstructable from events alone.
    test "an inserted fact is asserted and a concluded one is derived" do
      inserted =
        observed()
        |> Listener.Collect.by_tag(:fact_inserted)
        |> Map.new(fn {:fact_inserted, fact, origin} -> {fact, origin} end)

      assert :asserted == inserted[{:order, 1, 250}]
      assert {:derived, %{rule: {Rules, :flag}}} = inserted[{:flagged, 1}]
      assert {:derived, %{rule: {Rules, :escalate}}} = inserted[{:escalated, 1}]
    end

    test "a retraction cascade is visible as derived retractions" do
      retracted =
        observed()
        |> Session.retract({:order, 1, 250})
        |> Session.fire_rules()
        |> Listener.Collect.by_tag(:fact_retracted)
        |> Map.new(fn {:fact_retracted, fact, origin} -> {fact, origin} end)

      assert :asserted == retracted[{:order, 1, 250}]
      assert {:derived, %{rule: {Rules, :flag}}} = retracted[{:flagged, 1}]
      assert {:derived, %{rule: {Rules, :escalate}}} = retracted[{:escalated, 1}]
    end

    test "a duplicate insert is reported and propagates nothing" do
      session =
        [Rules]
        |> Session.new()
        |> Session.with_listener(Listener.Collect, [])
        |> Session.insert([{:order, 1, 250}, {:order, 1, 250}])
        |> Session.fire_rules()

      assert [{:fact_duplicated, {:order, 1, 250}}] ==
               Listener.Collect.by_tag(session, :fact_duplicated)

      assert 1 == session |> Listener.Collect.by_tag(:activation_fired) |> Enum.count(&flagged?/1)
    end

    defp flagged?({:activation_fired, _source, _token, facts}), do: {:flagged, 1} in facts

    # A pending activation cancelled before it fires never runs, and that is
    # observable rather than merely invisible.
    test "an activation cancelled before firing is reported as removed, not fired" do
      session =
        [Rules]
        |> Session.new()
        |> Session.with_listener(Listener.Collect, [])
        |> Session.insert({:order, 1, 250})
        |> Session.retract({:order, 1, 250})
        |> Session.fire_rules()

      assert [] == Listener.Collect.by_tag(session, :activation_fired)
      assert [_ | _] = Listener.Collect.by_tag(session, :activation_removed)
    end

    test "several listeners each keep their own state" do
      defmodule CountFires do
        @behaviour Rete.Listener
        @impl true
        def handle_event({:activation_fired, _, _, _}, n), do: n + 1
        def handle_event(_event, n), do: n
      end

      session =
        [Rules]
        |> Session.new()
        |> Session.with_listener(Listener.Collect, [])
        |> Session.with_listener(CountFires, 0)
        |> Session.insert(@facts)
        |> Session.fire_rules()

      fired = length(Listener.Collect.by_tag(session, :activation_fired))
      assert fired == Session.listener_state(session, CountFires)
      assert fired > 0
    end

    # A listener is handed an event and its own state, with no way to reach the
    # network, so a bare node id would be an integer it could not resolve.
    test "every activation event names the rule, not just the node" do
      session =
        [Rules]
        |> Session.new()
        |> Session.with_listener(Listener.Collect, [])
        |> Session.insert({:order, 1, 250})
        |> Session.retract({:order, 1, 250})
        |> Session.insert({:order, 2, 900})
        |> Session.fire_rules()

      for tag <- [:activation_added, :activation_removed, :activation_fired] do
        events = Listener.Collect.by_tag(session, tag)
        assert events != [], "no #{tag} event to check"

        for event <- events do
          assert %{node: node, rule: {Rules, name}} = elem(event, 1)
          assert is_integer(node), "the node id is kept alongside the rule"
          assert name in [:flag, :escalate, :vip_gold, :vip_spend, :dormant, :clean]
        end
      end
    end

    test "an unattached listener has no state" do
      assert nil == Session.listener_state(session(), Listener.Collect)
    end

    # Listening must not change what the engine concludes.
    test "attaching a listener does not change the outcome" do
      assert Enum.sort(Session.facts(session())) == Enum.sort(Session.facts(observed()))
    end
  end

  # --- explanations ------------------------------------------------------------------

  describe "explain/2" do
    test "walks a derivation chain down to the asserted facts" do
      assert [%{fact: {:escalated, 1}, origin: :derived, rule: :escalate, supports: [flagged]}] =
               Inspect.explain(session(), {:escalated, 1})

      assert %{fact: {:flagged, 1}, origin: :derived, rule: :flag, supports: [order]} = flagged
      assert %{fact: {:order, 1, 250}, origin: :asserted, supports: []} = order
    end

    # The case a lookup that returns the *first* support gets wrong, and the
    # reason this returns a list at all.
    test "reports every independent support separately" do
      supports = Inspect.explain(session(), {:vip, 2})

      assert [:vip_gold, :vip_spend] == supports |> Enum.map(& &1.rule) |> Enum.sort()

      assert [{:gold, 2}, {:spender, 2}] ==
               supports |> Enum.flat_map(& &1.supports) |> Enum.map(& &1.fact) |> Enum.sort()
    end

    test "an asserted fact has no supports" do
      assert [%{origin: :asserted, rule: nil, supports: []}] =
               Inspect.explain(session(), {:order, 1, 250})
    end

    test "a fact the session does not hold is reported as unknown" do
      assert [%{origin: :unknown}] = Inspect.explain(session(), {:nope, 99})
    end

    test "a retracted conclusion stops being explainable" do
      session = session() |> Session.retract({:order, 1, 250}) |> Session.fire_rules()
      assert [%{origin: :unknown}] = Inspect.explain(session, {:escalated, 1})
    end

    # A compound negation is implemented with a generated marker fact. It has to
    # be a real fact for the negation to match on, but it is not something the
    # user's rules concluded and must not appear in an explanation.
    test "internal negation markers never appear in an explanation" do
      assert [%{fact: {:clean, 3}, rule: :clean, supports: supports}] =
               Inspect.explain(session(), {:clean, 3})

      assert [{:cust, 3}] == Enum.map(supports, & &1.fact)
    end

    test "a collection contributes its members, not the list" do
      defmodule Coll do
        use Rete.Ruleset

        defrule tally({:cust, cid}, os = [{:order, cid, _a}]) do
          {:tally, cid, length(os)}
        end
      end

      session =
        [Coll]
        |> Session.new()
        |> Session.insert([{:cust, 1}, {:order, 1, 10}, {:order, 1, 20}])
        |> Session.fire_rules()

      assert [%{supports: supports}] = Inspect.explain(session, {:tally, 1, 2})

      assert [{:cust, 1}, {:order, 1, 10}, {:order, 1, 20}] ==
               supports |> Enum.map(& &1.fact) |> Enum.sort()
    end
  end

  # --- fired ------------------------------------------------------------------------

  describe "fired/2" do
    test "reports the rule, its match and what it inserted" do
      fired = Inspect.fired(session())

      assert %{
               rule: :flag,
               module: Rules,
               bindings: %{cid: 1, amt: 250},
               inserted: [{:flagged, 1}]
             } in fired
    end

    # Two rulesets may each define a :flag. The bare name stays, so a caller
    # matching on it still works, and the module says which one this was.
    test "reports the module the rule was defined in" do
      assert Enum.all?(Inspect.fired(session()), &(&1.module == Rules))
    end

    test "generated negation helpers are hidden unless asked for" do
      # The helper only inserts its marker when the negated conjunction actually
      # matches, so this needs a customer with both an order and a refund.
      session = session([{:cust, 1}, {:order, 1, 10}, {:refund, 1}])

      refute Enum.any?(Inspect.fired(session), &(to_string(&1.rule) =~ "__neg_"))

      assert Enum.any?(
               Inspect.fired(session, generated: true),
               &(to_string(&1.rule) =~ "__neg_")
             )
    end

    test "a rule whose conclusion was retracted no longer appears" do
      session = session() |> Session.retract({:order, 1, 250}) |> Session.fire_rules()
      refute Enum.any?(Inspect.fired(session), &(&1.rule == :flag))
    end
  end

  # --- why_not -------------------------------------------------------------------------

  describe "why_not/2" do
    test "reports the chain a rule's conditions form" do
      steps = Inspect.why_not(session(), {Rules, :dormant})

      assert ["root_join", "negation", "production"] == Enum.map(steps, & &1.kind)
      assert [:cust, :order, nil] == Enum.map(steps, & &1.type)
    end

    # The diagnostic: the left side matched and the right side found nothing.
    test "shows where the chain broke" do
      steps = Inspect.why_not(session([{:cust, 7}]), {Rules, :dormant})
      negation = Enum.find(steps, &(&1.kind == "negation"))

      assert negation.tokens == 1, "the customer condition matched"
      assert negation.elements == 0, "and no order suppressed it"
    end

    test "a terminal reports how many matches it concluded from" do
      steps = Inspect.why_not(session(), {Rules, :flag})
      terminal = List.last(steps)

      assert "production" == terminal.kind
      assert terminal.activations == 1
    end

    test "an unknown rule is an error listing what exists" do
      error = assert_raise ArgumentError, fn -> Inspect.why_not(session(), {Rules, :nope}) end

      assert error.message =~ "no rule or query Rete.ObservabilityTest.Rules.nope"
      assert error.message =~ "Rete.ObservabilityTest.Rules.flag"
      refute error.message =~ "__neg_", "generated helpers should not be suggested"
    end

    test "a bare rule name is an error teaching the qualified form" do
      error = assert_raise ArgumentError, fn -> Inspect.why_not(session(), :flag) end

      assert error.message =~ "a rule is named by {module, name}"
      assert error.message =~ "Rete.ObservabilityTest.Rules.flag"
    end
  end

  # --- a listener attached at construction misses nothing -----------------------------------

  describe "a listener sees activations for rules true of the empty session" do
    defmodule RootSeeded do
      use Rete.Ruleset

      # Both are true of the empty session, so the root token activates both. Nothing
      # a caller inserts does.
      defrule startup, do: {:started, :once}
      defrule quiet({:not, [{:noise, _}]}), do: {:silence, :ok}
    end

    # This is the defect that motivated deferring propagation. When `Session.new/1`
    # propagated, it created these activations before any listener could exist.
    # `Rete.Engine.State` starts with none, and `with_listener/3` only attaches
    # afterward. A listener then saw `:activation_fired` for a rule it never saw added.
    test "an activation from the root token is announced to a listener" do
      added =
        [RootSeeded]
        |> Session.new()
        |> Session.with_listener(Listener.Collect, [])
        |> Session.fire_rules()
        |> Listener.Collect.by_tag(:activation_added)
        |> Enum.map(fn {_tag, source, _token} -> elem(source.rule, 1) end)
        |> Enum.sort()

      assert [:quiet, :startup] == added
    end

    test "every fired rule was announced as added first" do
      events =
        [RootSeeded]
        |> Session.new()
        |> Session.with_listener(Listener.Collect, [])
        |> Session.fire_rules()
        |> Listener.Collect.events()

      added = for {:activation_added, s, _} <- events, do: elem(s.rule, 1)
      fired = for {:activation_fired, s, _, _} <- events, do: elem(s.rule, 1)

      assert fired != []
      assert Enum.all?(fired, &(&1 in added)), "fired without a matching :activation_added"
    end
  end

  # --- inspecting a session that has not been fired ----------------------------------------

  describe "the tools that need a settled session" do
    defp unfired, do: [Rules] |> Session.new() |> Session.insert(@facts)

    # These two read what propagation built. On a session with work still queued that is
    # zero of everything. It reads as "nothing matched" when the truth is "nothing has been
    # matched yet". A diagnostic that lies is worse than one that refuses.
    test "why_not/2 refuses a session with propagation queued" do
      error = assert_raise ArgumentError, fn -> Inspect.why_not(unfired(), {Rules, :flag}) end

      assert error.message =~ "why_not/2 needs a session that you fired"
      assert error.message =~ "propagation operations still queued"
      assert error.message =~ "fire_rules/2"
    end

    test "collection/3 refuses a session with propagation queued" do
      error = assert_raise ArgumentError, fn -> Inspect.collection(unfired(), 1, %{}) end

      assert error.message =~ "collection/3 needs a session that you fired"
    end

    # A session that fired and was then inserted into is refused too. Its counts are real,
    # and they describe a network the newest facts have not reached, which is the same
    # failure wearing plausible numbers.
    test "why_not/2 refuses a session that fired and was then inserted into" do
      stale = unfired() |> Session.fire_rules() |> Session.insert({:order, 9, 400})

      refute Session.settled?(stale)

      assert_raise ArgumentError, ~r/needs a session that you fired/, fn ->
        Inspect.why_not(stale, {Rules, :flag})
      end
    end

    # The name is checked before the fire is. Whether a rule exists does not depend on
    # whether anything propagated, and a typo is the more actionable of the two errors.
    # Reporting "you did not fire" here would send the caller to fix the wrong thing.
    test "why_not/2 reports an unknown rule before it reports an unfired session" do
      error = assert_raise ArgumentError, fn -> Inspect.why_not(unfired(), {Rules, :typoo}) end

      assert error.message =~ "no rule or query"
      refute error.message =~ "needs a session that you fired"
    end

    # The control, and the reason the split is deliberate rather than blanket. Both read
    # memories that `insert/2` updates at once, so both are already correct here.
    test "explain/2 and fired/2 answer on an unfired session" do
      session = unfired()

      assert [%{origin: :asserted}] = Inspect.explain(session, {:order, 1, 250})
      assert [] == Inspect.fired(session)
    end

    # What "answer at any point" does and does not promise. A queued retract takes the
    # fact out of working memory and leaves the conclusion resting on it, so `explain/2`
    # names a support the session no longer holds. `origin: :unknown` is the documented
    # word for exactly that, so the answer is true of the session as it stands. It stops
    # being true on the next fire, which is why the moduledoc says to fire first for a
    # settled provenance graph.
    test "explain/2 reports a support that a queued retract already removed" do
      queued =
        [Rules]
        |> Session.new()
        |> Session.insert(@facts)
        |> Session.fire_rules()
        |> Session.retract({:order, 1, 250})

      assert {:flagged, 1} in Session.facts(queued)
      refute {:order, 1, 250} in Session.facts(queued)

      assert [%{origin: :derived, supports: [%{fact: {:order, 1, 250}, origin: :unknown}]}] =
               Inspect.explain(queued, {:flagged, 1})

      # And the next fire settles it: the conclusion goes with its support.
      settled = Session.fire_rules(queued)
      refute {:flagged, 1} in Session.facts(settled)
    end

    test "both answer once the session is fired" do
      session = Session.fire_rules(unfired())

      assert [_ | _] = Inspect.why_not(session, {Rules, :flag})
      assert [] == Inspect.collection(session, 1, %{})
    end
  end

  # --- ordering guarantees ------------------------------------------------------------------

  describe "query row order" do
    defmodule Ordered do
      use Rete.Ruleset

      defrule flag({:o, cid, amt} when amt > 10) do
        {:flagged, cid, amt}
      end

      defquery flagged({:flagged, cid, amt}) do
        {cid, amt}
      end
    end

    # Beta memory is arrival ordered, and a query hands its matches back as it
    # finds them. So rows come out in the order the facts arrived.
    #
    # The engine used to sort every result, so that one fact set always answered
    # the same way. `Rete.Session.query/3` has always called the order
    # unspecified, so nothing could rely on that, and it cost O(n log n) per
    # call. Same shape as sorting a collection's members, removed for the same
    # reason.
    test "follows the order the facts arrived in" do
      answer = fn facts ->
        [Ordered]
        |> Session.new()
        |> Session.insert(facts)
        |> Session.fire_rules()
        |> Ordered.flagged()
      end

      assert [{1, 20}, {2, 30}, {3, 40}] == answer.([{:o, 1, 20}, {:o, 2, 30}, {:o, 3, 40}])
      assert [{3, 40}, {1, 20}, {2, 30}] == answer.([{:o, 3, 40}, {:o, 1, 20}, {:o, 2, 30}])
    end

    # What is still true, and what a caller can actually rely on: the same facts
    # in the same order always answer the same way, and the rows are the same
    # set however they were fed.
    test "the same feed always answers the same way, and the set never varies" do
      answer = fn facts ->
        [Ordered]
        |> Session.new()
        |> Session.insert(facts)
        |> Session.fire_rules()
        |> Ordered.flagged()
      end

      facts = [{:o, 1, 20}, {:o, 2, 30}, {:o, 3, 40}]

      assert answer.(facts) == answer.(facts)

      assert Enum.sort(answer.(facts)) ==
               Enum.sort(answer.([{:o, 2, 30}, {:o, 3, 40}, {:o, 1, 20}]))
    end
  end

  # --- the loop guard ---------------------------------------------------------------------

  describe "runaway rules" do
    defmodule Oscillate do
      use Rete.Ruleset

      defrule grow({:counter, n}) do
        {:counter, n + 1}
      end
    end

    test "the error names the rules that kept firing" do
      error =
        assert_raise RuntimeError, fn ->
          [Oscillate]
          |> Session.new()
          |> Session.insert({:counter, 0})
          |> Session.fire_rules(max_cycles: 20)
        end

      assert error.message =~ "Fired most:"
      assert error.message =~ "grow"
      assert error.message =~ "concludes something its own left hand side matches on"
    end

    # A cascade that settles is not a runaway, however long it is.
    test "a long but terminating cascade does not raise" do
      defmodule Countdown do
        use Rete.Ruleset

        defrule step({:n, i} when i < 40) do
          {:n, i + 1}
        end
      end

      session =
        [Countdown]
        |> Session.new()
        |> Session.insert({:n, 0})
        |> Session.fire_rules(max_cycles: 40)

      assert {:n, 40} in Session.facts(session)
    end
  end
end
