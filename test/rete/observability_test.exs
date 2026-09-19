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

    # Reads the fact those two both conclude, so its match names both as the source.
    defrule vip_reader({:vip, cid}) do
      {:vip_seen, cid}
    end

    defquery flagged_rows({:flagged, cid}), do: cid

    defrule dormant({:cust, cid}, {:not, [{:order, cid, _a}]}) do
      {:dormant, cid}
    end

    defrule clean({:cust, cid}, {:nand, [{:order, cid, _a}, {:refund, cid}]}) do
      {:clean, cid}
    end
  end

  # The two shapes a collection compiles to. A token carries the list each of them handed
  # the rule, so `explain/2` reports both the same way. See `Rete.Memory.groups/3`.
  defmodule Collections do
    use Rete.Ruleset

    # No cross-condition guard, so this compiles to an Accumulate, which stores facts.
    defrule spend({:customer, cid, _name}, orders = [{:order, cid, _amt}]) do
      {:spend, cid, length(orders)}
    end

    # The guard reads `limit` from another condition, so this compiles to an
    # AccumulateJoin, which stores elements and decides membership for each token.
    defrule big(
              {:threshold, limit},
              {:vip, cid, _name},
              orders = [{:sale, cid, amt} when amt > limit]
            ) do
      {:big, cid, length(orders)}
    end
  end

  @facts [{:order, 1, 250}, {:gold, 2}, {:spender, 2}, {:cust, 3}]

  defp session(facts \\ @facts) do
    [Rules] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp plain_collection do
    [Collections]
    |> Session.new()
    |> Session.insert([{:customer, 1, "Ada"}, {:order, 1, 250}, {:order, 1, 40}])
    |> Session.fire_rules()
  end

  defp filtered_collection do
    [Collections]
    |> Session.new()
    |> Session.insert([{:threshold, 100}, {:vip, 1, "Ada"}, {:sale, 1, 250}, {:sale, 1, 40}])
    |> Session.fire_rules()
  end

  # The one match of a rule that fired exactly once.
  defp only_activation(session, ref) do
    %{activations: [activation]} = Inspect.explain(session, ref)
    activation
  end

  # The `{module, name}` of the helper a compound negation generates. `explain/1` leaves it
  # out, so a test that wants it has to read it off the network.
  defp generated_ref(session) do
    session
    |> Session.network()
    |> Rete.Network.beta_nodes()
    |> Enum.find_value(fn node ->
      name = Map.get(node, :name)

      if is_atom(name) and name != nil and to_string(name) =~ "__neg_" do
        {node.module, name}
      end
    end)
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
    test "reports the match a rule fired on and what it concluded" do
      assert %{rule: :flag, module: Rules, type: :rule, activations: [activation]} =
               Inspect.explain(session(), {Rules, :flag})

      assert %{bindings: %{cid: 1, amt: 250}, inserted: [{:flagged, 1}]} = activation
      assert [%{fact: {:order, 1, 250}, origin: :asserted, from: []}] = activation.matches
    end

    # One level of provenance. `:from` names the rule, and you follow that pair to its own
    # entry rather than reading a tree that repeats under everything resting on it.
    test "a derived fact names the rule that concluded it" do
      assert %{activations: [%{matches: [match]}]} =
               Inspect.explain(session(), {Rules, :escalate})

      assert %{fact: {:flagged, 1}, origin: :derived, from: [{Rules, :flag}]} = match
    end

    # The case a lookup returning the *first* support gets wrong, and the reason `:from` is
    # a list rather than one pair.
    test "a fact with two independent supports names both rules" do
      %{activations: activations} = Inspect.explain(session(), {Rules, :vip_gold})
      %{activations: spend} = Inspect.explain(session(), {Rules, :vip_spend})

      assert [{:vip, 2}] == Enum.flat_map(activations, & &1.inserted)
      assert [{:vip, 2}] == Enum.flat_map(spend, & &1.inserted)

      # Read from the other side: whatever matches {:vip, 2} sees both as its source.
      assert %{activations: [%{matches: [match]}]} =
               Inspect.explain(session(), {Rules, :vip_reader})

      assert :derived == match.origin
      assert [{Rules, :vip_gold}, {Rules, :vip_spend}] == Enum.sort(match.from)
    end

    test "a rule that never fired reports no activations" do
      assert %{rule: :flag, activations: []} = Inspect.explain(session([]), {Rules, :flag})
    end

    # The documented limit of reading truth maintenance. A body returning `nil` concludes
    # nothing, so no match rests on a conclusion, and a production keeps no tokens of its
    # own. The firing leaves nothing in memory to report. A listener is what sees it, so
    # this pins both halves: what `explain` cannot say, and what does say it.
    test "a rule that fired and concluded nothing is indistinguishable from one that did not" do
      defmodule Silent do
        use Rete.Ruleset

        defrule quiet({:ping, id}) do
          _ = id
          nil
        end

        defrule loud({:ping, id}), do: {:pong, id}
      end

      session =
        [Silent]
        |> Session.new()
        |> Session.with_listener(Listener.Collect, [])
        |> Session.insert({:ping, 1})
        |> Session.fire_rules()

      assert %{activations: []} = Inspect.explain(session, {Silent, :quiet})
      assert %{activations: [_]} = Inspect.explain(session, {Silent, :loud})

      # It did fire, and the listener is the thing that knows.
      fired =
        session
        |> Listener.Collect.by_tag(:activation_fired)
        |> Enum.map(fn {:activation_fired, source, _token, facts} -> {source.rule, facts} end)

      assert {{Silent, :quiet}, []} in fired
      assert {{Silent, :loud}, [{:pong, 1}]} in fired
    end

    test "a retracted conclusion stops being reported" do
      session = session() |> Session.retract({:order, 1, 250}) |> Session.fire_rules()

      assert %{activations: []} = Inspect.explain(session, {Rules, :flag})
    end

    # A compound negation is implemented with a generated marker fact. It has to be a real
    # fact for the negation to match on, but it is not something the user's rules concluded
    # and must not appear in an explanation.
    test "internal negation markers never appear in an explanation" do
      assert %{activations: [%{matches: matches, inserted: [{:clean, 3}]}]} =
               Inspect.explain(session(), {Rules, :clean})

      assert [{:cust, 3}] == Enum.map(matches, & &1.fact)
    end

    # A generated helper is left out of `explain/1`, and named explicitly it still answers.
    test "a generated helper is reachable by name" do
      session = session([{:cust, 1}, {:order, 1, 10}, {:refund, 1}])

      refute Enum.any?(Inspect.explain(session), &(to_string(&1.rule) =~ "__neg_"))

      assert %{activations: [_ | _]} = Inspect.explain(session, generated_ref(session))
    end

    test "a query reports the matches it holds, and concludes nothing" do
      assert %{type: :query, activations: [activation]} =
               Inspect.explain(session(), {Rules, :flagged_rows})

      assert [] == activation.inserted

      assert [%{fact: {:flagged, 1}, origin: :derived, from: [{Rules, :flag}]}] =
               activation.matches
    end
  end

  # --- explain over the whole session ------------------------------------------------

  describe "explain/1" do
    test "covers every rule and query, sorted, with generated helpers left out" do
      explained = Inspect.explain(session())

      assert Enum.map(explained, & &1.rule) == explained |> Enum.map(& &1.rule) |> Enum.sort()
      assert :flag in Enum.map(explained, & &1.rule)
      assert {:flagged_rows, :query} in Enum.map(explained, &{&1.rule, &1.type})
      refute Enum.any?(explained, &(to_string(&1.rule) =~ "__neg_"))
    end

    test "each entry carries the same shape explain/2 gives for it" do
      session = session()

      for %{rule: rule, module: module} = entry <- Inspect.explain(session) do
        assert entry == Inspect.explain(session, {module, rule})
      end
    end
  end

  # --- why_not -------------------------------------------------------------------------

  describe "why_not/2" do
    test "reports the rule it is about, and the chain its conditions form" do
      assert %{rule: :dormant, module: Rules, chain: steps} =
               Inspect.why_not(session(), {Rules, :dormant})

      assert ["root_join", "negation", "production"] == Enum.map(steps, & &1.kind)
      assert [:cust, :order, nil] == Enum.map(steps, & &1.type)
    end

    # The diagnostic: the left side matched and the right side found nothing.
    test "shows where the chain broke" do
      %{chain: steps} = Inspect.why_not(session([{:cust, 7}]), {Rules, :dormant})
      negation = Enum.find(steps, &(&1.kind == "negation"))

      assert negation.tokens == 1, "the customer condition matched"
      assert negation.elements == 0, "and no order suppressed it"
    end

    test "a terminal reports how many matches it concluded from" do
      %{chain: steps} = Inspect.why_not(session(), {Rules, :flag})
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

    # Both functions refuse the same two mistakes, in the same words.
    test "explain/2 refuses an unknown rule and a bare name the same way" do
      unknown = assert_raise ArgumentError, fn -> Inspect.explain(session(), {Rules, :nope}) end
      bare = assert_raise ArgumentError, fn -> Inspect.explain(session(), :flag) end

      assert unknown.message =~ "no rule or query Rete.ObservabilityTest.Rules.nope"
      assert bare.message =~ "a rule is named by {module, name}"
    end
  end

  # --- why_not over the whole session -------------------------------------------------

  describe "why_not/1" do
    test "covers every rule and query, sorted, with generated helpers left out" do
      chains = Inspect.why_not(session())

      assert Enum.map(chains, & &1.rule) == chains |> Enum.map(& &1.rule) |> Enum.sort()
      assert :dormant in Enum.map(chains, & &1.rule)
      refute Enum.any?(chains, &(to_string(&1.rule) =~ "__neg_"))
    end

    test "each entry carries the same chain why_not/2 gives for it" do
      session = session()

      for %{rule: rule, module: module} = entry <- Inspect.why_not(session) do
        assert entry == Inspect.why_not(session, {module, rule})
      end
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

    # Both read what propagation built. On a session with work still queued that is zero of
    # everything. It reads as "nothing matched" when the truth is "nothing has been matched
    # yet". A diagnostic that lies is worse than one that refuses.
    test "why_not/2 refuses a session with propagation queued" do
      error = assert_raise ArgumentError, fn -> Inspect.why_not(unfired(), {Rules, :flag}) end

      assert error.message =~ "why_not/2 needs a session that you fired"
      assert error.message =~ "propagation operations still queued"
      assert error.message =~ "fire_rules/2"
    end

    # `explain/2` used to answer here, because it read memories that `insert/2` updates at
    # once. It reports activations now, and an activation is something propagation built,
    # so it answers the same way `why_not/2` does.
    test "every arity refuses a session with propagation queued, and names itself" do
      for {called, call} <- [
            {"explain/1", fn -> Inspect.explain(unfired()) end},
            {"explain/2", fn -> Inspect.explain(unfired(), {Rules, :flag}) end},
            {"why_not/1", fn -> Inspect.why_not(unfired()) end},
            {"why_not/2", fn -> Inspect.why_not(unfired(), {Rules, :flag}) end}
          ] do
        error = assert_raise ArgumentError, call
        assert error.message =~ "#{called} needs a session that you fired"
      end
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

    test "explain/2 checks the name before the fire in the same way" do
      error = assert_raise ArgumentError, fn -> Inspect.explain(unfired(), {Rules, :typoo}) end

      assert error.message =~ "no rule or query"
      refute error.message =~ "needs a session that you fired"
    end

    test "both answer once the session is fired" do
      session = Session.fire_rules(unfired())

      assert %{chain: [_ | _]} = Inspect.why_not(session, {Rules, :flag})
      assert %{activations: [_ | _]} = Inspect.explain(session, {Rules, :flag})
    end
  end

  # --- what a collection gathered ----------------------------------------------------------

  # A token records the list the accumulate node handed the rule, so `explain/2` reports a
  # collection per activation. The caller names the rule, and never a node id or a join key.
  describe "a collection in an explanation" do
    # A plain collection stores facts, and a filtered one stores candidates its filter
    # decides per token. The token carries the result either way, so both read alike here.
    test "a plain collection reports the facts it gathered" do
      session = plain_collection()
      activation = only_activation(session, {Collections, :spend})

      assert [%{fact: {:customer, 1, "Ada"}, origin: :asserted}, collection] =
               activation.matches

      assert :gathered == collection.origin
      assert [{:order, 1, 40}, {:order, 1, 250}] == Enum.sort(collection.fact)

      assert [{:order, 1, 40}, {:order, 1, 250}] ==
               collection.members |> Enum.map(& &1.fact) |> Enum.sort()

      assert [{:spend, 1, 2}] == activation.inserted
    end

    # The fact the filter kept out must not appear. Reporting the stored candidates would
    # describe a larger collection than the rule received.
    test "a filtered collection reports only what passed its filter" do
      session = filtered_collection()
      activation = only_activation(session, {Collections, :big})

      collection = Enum.find(activation.matches, &(&1.origin == :gathered))

      assert [{:sale, 1, 250}] == collection.fact
      assert [{:big, 1, 1}] == activation.inserted
    end

    # The case the old node-and-join-key call could not answer. Two thresholds over one
    # customer give two activations under one join key, each seeing a different set. Keyed
    # by the activation, each one reports its own collection instead of their union.
    test "two activations over one join key each report their own collection" do
      session =
        [Collections]
        |> Session.new()
        |> Session.insert([
          {:threshold, 100},
          {:threshold, 200},
          {:vip, 1, "Ada"},
          {:sale, 1, 250},
          {:sale, 1, 150},
          {:sale, 1, 40}
        ])
        |> Session.fire_rules()

      %{activations: activations} = Inspect.explain(session, {Collections, :big})

      gathered =
        for activation <- activations,
            match <- activation.matches,
            match.origin == :gathered,
            do: {activation.bindings.limit, Enum.sort(match.fact)}

      # The activation for 100 gathered 250 and 150. The one for 200 gathered 250 alone.
      # Neither gathered 40, and neither is reported holding the other's members.
      assert [{100, [{:sale, 1, 150}, {:sale, 1, 250}]}, {200, [{:sale, 1, 250}]}] ==
               Enum.sort(gathered)
    end

    # A gathered fact carries its own provenance, so a collection over conclusions reads as
    # a collection over conclusions.
    test "a gathered fact that a rule concluded names that rule" do
      defmodule Gathered do
        use Rete.Ruleset

        defrule flag_it({:raw, cid, amt}) do
          {:big, cid, amt}
        end

        defrule tally({:cust, cid}, bigs = [{:big, cid, _amt}]) do
          {:tally, cid, length(bigs)}
        end
      end

      session =
        [Gathered]
        |> Session.new()
        |> Session.insert([{:cust, 1}, {:raw, 1, 10}, {:raw, 1, 20}])
        |> Session.fire_rules()

      collection =
        session
        |> only_activation({Gathered, :tally})
        |> Map.fetch!(:matches)
        |> Enum.find(&(&1.origin == :gathered))

      assert Enum.all?(collection.members, &(&1.origin == :derived))
      assert [[{Gathered, :flag_it}]] == collection.members |> Enum.map(& &1.from) |> Enum.uniq()
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
