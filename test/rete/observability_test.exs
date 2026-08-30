defmodule Rete.ObservabilityTest do
  use ExUnit.Case, async: true

  alias Rete.Inspect
  alias Rete.Listener
  alias Rete.Session

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
      assert {:derived, _} = inserted[{:flagged, 1}]
      assert {:derived, _} = inserted[{:escalated, 1}]
    end

    test "a retraction cascade is visible as derived retractions" do
      retracted =
        observed()
        |> Session.retract({:order, 1, 250})
        |> Session.fire_rules()
        |> Listener.Collect.by_tag(:fact_retracted)
        |> Map.new(fn {:fact_retracted, fact, origin} -> {fact, origin} end)

      assert :asserted == retracted[{:order, 1, 250}]
      assert {:derived, _} = retracted[{:flagged, 1}]
      assert {:derived, _} = retracted[{:escalated, 1}]
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

    defp flagged?({:activation_fired, _node, _token, facts}), do: {:flagged, 1} in facts

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

    # Beta memory is arrival ordered, so without a deterministic sort the same
    # facts inserted in a different order would answer the same query in a
    # different order. The order itself is not a contract; varying with
    # insertion order is a trap.
    test "does not vary with the order facts were inserted in" do
      answer = fn facts ->
        [Ordered]
        |> Session.new()
        |> Session.insert(facts)
        |> Session.fire_rules()
        |> Ordered.flagged()
      end

      base = answer.([{:o, 1, 20}, {:o, 2, 30}, {:o, 3, 40}])

      assert base == answer.([{:o, 3, 40}, {:o, 1, 20}, {:o, 2, 30}])
      assert base == answer.([{:o, 2, 30}, {:o, 3, 40}, {:o, 1, 20}])
      assert 3 == length(base)
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
