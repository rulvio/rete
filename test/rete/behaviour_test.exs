defmodule Rete.BehaviourTest do
  @moduledoc """
  Behaviours mined from Clara's ~8,000 lines of accumulated behavioural tests.

  Organised by what a rules engine has to *do*, not by the Clara file the case
  came from. Each test says what it protects; where a case exists to guard a
  specific historical defect, the Clara issue number is named so the intent
  survives.

  What was deliberately left out, and why:

    * **The accumulator library** (`min`/`max`/`sum`/`distinct`/`all`, initial
      values, `convert-return-fn`, `retract-fn`, "false as a reduced value").
      This engine is collect-all only by an explicit user decision, so most of
      `test_accumulation.clj` describes machinery that does not exist. Only the
      retraction and re-accumulation cases are mined, and they are here.
    * **Unconditional insert and RHS retract** (`insert-unconditional!`,
      `retract!`, `duplicate-reasons-for-retraction-test`). Logical inserts
      only; there is nothing to test.
    * **`:no-loop`** and Clara's `:cancelling` fire mode. Neither exists.
    * **ClojureScript, Java interop, durability, session/compiler caching,
      loading rules from namespaces or EDN.** Out of scope entirely.
    * **`:exists`.** Clara desugars it to an accumulator plus a test. Rather
      than adding syntax, "existence" below tests what `{:not, [{:not, [x]}]}`
      actually does and what to write instead.
    * **`[:not [:test ...]]`.** A bare guard is not an LHS element in this DSL,
      so a negated test has no spelling.
    * **Compile-time binding errors** (`test-unbound-bindings`,
      `test-malformed-binding`, `test-unmatched-nested-binding`). Ported
      already and exhaustively, in `test/rete/dsl/bindings_test.exs`.
    * **Identity vs equality** (`test-identical-facts`, Clara issue 35). The
      BEAM has no fact identity distinct from equality: two equal terms *are*
      the same fact, and this engine says so by making facts a multiset.
  """

  use ExUnit.Case, async: true

  alias Rete.Listener.Collect
  alias Rete.Session

  defp run(mod, facts) do
    [mod] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp sorted_leaves(by_node) do
    Map.new(by_node, fn {node, by_key} ->
      {node, Map.new(by_key, fn {key, items} -> {key, Enum.sort(items)} end)}
    end)
  end

  defp tagged(session, tag) do
    session
    |> Session.facts()
    |> Enum.filter(&(is_tuple(&1) and elem(&1, 0) == tag))
    |> Enum.sort()
  end

  # The facts each firing concluded, in the order the rules ran. Needs a
  # `Rete.Listener.Collect` attached.
  defp fired(session) do
    session
    |> Collect.by_tag(:activation_fired)
    |> Enum.map(fn {:activation_fired, _source, _token, facts} -> facts end)
  end

  # Retract everything one fact at a time, the way a caller would.
  defp drain(session, facts) do
    Enum.reduce(facts, session, fn fact, s ->
      s |> Session.retract(fact) |> Session.fire_rules()
    end)
  end

  # --- the fact lifecycle -------------------------------------------------------------

  describe "insert and retract" do
    defmodule Lifecycle do
      use Rete.Ruleset

      defrule cold({:temp, t, _loc} when t < 20) do
        {:cold, t}
      end

      defquery cold_q({:cold, t}) do
        t
      end
    end

    # clara test_simple_rules/test-noop-retraction. Retracting something the
    # session never held must not disturb what it does hold — in particular it
    # must not decrement a *different* fact that happens to share a join key.
    test "retracting a fact that was never inserted changes nothing" do
      session =
        [Lifecycle]
        |> Session.new()
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.retract({:temp, 15, "MCI"})
        |> Session.fire_rules()

      assert [10] == Lifecycle.cold_q(session)
      assert %{{:temp, 10, "MCI"} => 1, {:cold, 10} => 1} == session.state.memory.facts
    end

    # clara test_truth_maintenance/test-cancelled-activation. A net-zero pair of
    # operations before `fire_rules/2` must leave no trace: not a fact, and not
    # a firing. Checking facts alone cannot see the difference between "never
    # fired" and "fired and was taken back".
    test "insert then retract before firing means the rule never runs at all" do
      session =
        [Lifecycle]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.retract({:temp, 10, "MCI"})
        |> Session.fire_rules()

      assert [] == Session.facts(session)
      assert [] == Collect.by_tag(session, :activation_fired)

      # The activation really was queued and then cancelled, rather than never
      # having been created — otherwise this test would pass on an engine that
      # simply ignores the insert.
      tags = session |> Collect.events() |> Enum.map(&elem(&1, 0))
      assert :activation_added in tags
      assert :activation_removed in tags
    end

    test "the same session with no retraction does fire, as a control" do
      session =
        [Lifecycle]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.fire_rules()

      assert [_] = Collect.by_tag(session, :activation_fired)
    end

    # clara test_rules/test-stored-insertion-retraction-ordering. Operations
    # queued before a fire are applied in the order they were given, so a
    # retraction of an absent fact followed by its insertion leaves the fact
    # present. An engine that sorted retractions ahead of insertions — an
    # attractive optimisation — would silently swallow it.
    test "a retraction before the matching insertion does not cancel it" do
      retract_first =
        [Lifecycle]
        |> Session.new()
        |> Session.retract({:temp, 10, "MCI"})
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.fire_rules()

      insert_first =
        [Lifecycle]
        |> Session.new()
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.retract({:temp, 10, "MCI"})
        |> Session.fire_rules()

      assert [10] == Lifecycle.cold_q(retract_first)
      assert [] == Lifecycle.cold_q(insert_first)
    end

    # The same, with two distinct facts interleaved in one batch: whichever was
    # inserted last is the one that survives, per fact rather than per batch.
    test "insertions and retractions of different facts do not interfere" do
      session =
        [Lifecycle]
        |> Session.new()
        |> Session.insert({:temp, -10, "MCI"})
        |> Session.retract({:temp, 10, "MCI"})
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.retract({:temp, -10, "MCI"})
        |> Session.fire_rules()

      assert [10] == Lifecycle.cold_q(session)
    end

    # clara test_rules/test-multi-insert-retract. A duplicate inserted and then
    # retracted within one batch nets to the original single occurrence.
    test "a duplicate inserted and retracted in one batch leaves one occurrence" do
      session =
        [Lifecycle]
        |> Session.new()
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.retract({:temp, 10, "MCI"})
        |> Session.fire_rules()

      assert %{{:temp, 10, "MCI"} => 1, {:cold, 10} => 1} == session.state.memory.facts
    end
  end

  # --- joins --------------------------------------------------------------------------

  describe "join keys" do
    defmodule Joins do
      use Rete.Ruleset

      defquery same({:temp, t}, {:wind, t}) do
        t
      end
    end

    # clara test_bindings/test-nil-binding. `nil` is a perfectly good value to
    # join on. An engine that treats a `nil` binding as "no binding" — easy to
    # do when the alpha's failure value and a legitimate result are confused —
    # either drops the match or joins it to everything.
    test "nil is a join value like any other" do
      session = run(Joins, [{:temp, nil}, {:wind, nil}, {:wind, 1}])

      assert [nil] == Joins.same(session)
    end

    test "nil does not join to a non-nil value" do
      session = run(Joins, [{:temp, nil}, {:wind, 1}])

      assert [] == Joins.same(session)
    end

    defmodule Typed do
      use Rete.Ruleset

      defquery both(%{__type__: :outer_a, x: x}, %{__type__: :outer_b, x: x}) do
        x
      end
    end

    # clara test_bindings/test-record-equality-semantics, issue 393. Join keys
    # are compared as whole terms, so two values that differ only in their type
    # tag are different keys. Comparing them field-wise — which is what the JVM
    # does to records, and what Clara had to work around — would join them.
    test "join values of different types with equal fields do not join" do
      inner_a = %{__type__: :inner_a, n: 1}
      inner_b = %{__type__: :inner_b, n: 1}

      session =
        run(Typed, [
          %{__type__: :outer_a, x: inner_a},
          %{__type__: :outer_b, x: inner_a},
          %{__type__: :outer_b, x: inner_b}
        ])

      assert [^inner_a] = Typed.both(session)
    end

    defmodule WholeFact do
      use Rete.Ruleset

      defquery wrapped(t = {:temp, _v}, {:wind, t}) do
        t
      end
    end

    # clara test_bindings/test-join-with-fact-binding. A fact binding is an
    # ordinary value once it is in the token, so a later condition may join on
    # the whole fact. This only works if the binding is put in the token under
    # the same key the join reads.
    test "a whole bound fact can be the join key of a later condition" do
      assert [] == WholeFact.wrapped(run(WholeFact, [{:temp, 10}, {:wind, {:temp, 20}}]))

      assert [{:temp, 10}] ==
               WholeFact.wrapped(run(WholeFact, [{:temp, 10}, {:wind, {:temp, 10}}]))
    end

    defmodule SelfJoin do
      use Rete.Ruleset

      defquery pairs({:temp, t1}, {:temp, t2}) when t1 < t2 do
        {t1, t2}
      end
    end

    # clara test_rules/test-simple-test. Two conditions of the same type join
    # every element against every element, including a fact against itself; the
    # rule level guard is what makes the pair strict. Both halves matter — an
    # engine that skips the self-pair gets the right answer here for the wrong
    # reason and the wrong answer for `t1 <= t2`.
    test "a condition repeated joins the type against itself, filtered by the guard" do
      session = run(SelfJoin, [{:temp, 15}, {:temp, 10}, {:temp, 80}])

      assert [{10, 15}, {10, 80}, {15, 80}] ==
               session |> SelfJoin.pairs() |> Enum.sort()
    end

    defmodule TermOrder do
      use Rete.Ruleset

      defquery over({:wind, w}, {:temp, t} when t > w) do
        t
      end
    end

    # Clara's test-local-scope-visible-in-join-filter expects an exception here:
    # on the JVM `nil > 10` throws, and Clara catches it to report the bindings.
    # Elixir has a total ordering over terms, so the comparison is defined and
    # an atom sorts above every number. That is genuine Elixir semantics rather
    # than an engine decision, and this pins it so nobody "fixes" it into a
    # runtime error later.
    test "a guard comparing mixed types follows Elixir's term ordering rather than raising" do
      session = run(TermOrder, [{:wind, 10}, {:temp, nil}])

      assert [nil] == TermOrder.over(session)
    end

    defmodule Issue433 do
      use Rete.Ruleset

      defrule from_customer({:customer, cid}, {:order, cid, amt}) do
        {:customer_order, cid, amt}
      end

      defrule from_vendor({:vendor, cid}, {:order, cid, amt}) do
        {:vendor_order, cid, amt}
      end
    end

    # Clara issue 433, stated behaviourally. The two `{:order, cid, amt}`
    # conditions are byte identical but sit under different parents; sharing the
    # node would let a vendor token join elements that only ever belonged to the
    # customer chain.
    test "an identical second condition under a different first does not leak matches" do
      session = run(Issue433, [{:vendor, 1}, {:order, 1, 10}])

      assert [] == tagged(session, :customer_order)
      assert [{:vendor_order, 1, 10}] == tagged(session, :vendor_order)
    end
  end

  # --- queries ------------------------------------------------------------------------

  describe "queries" do
    defmodule QueryRules do
      use Rete.Ruleset

      defquery no_cold({:not, [{:cold, _}]}) do
        :none
      end

      defquery temps({:temp, t}) do
        t
      end

      defrule derive_temp({:seed, x}) do
        {:temp, x}
      end
    end

    # clara test_negation/test-simple-negation queries a session that was never
    # fired and expects an answer. Propagation happens on insert; only the right
    # hand sides wait for `fire_rules/2`. So a query is a window onto the
    # network's current state, not onto the last settled one.
    test "a query answers before any rule has fired" do
      session = [QueryRules] |> Session.new()
      assert [:none] == QueryRules.no_cold(session)

      session = Session.insert(session, {:cold, 1})
      assert [] == QueryRules.no_cold(session)

      session = Session.retract(session, {:cold, 1})
      assert [:none] == QueryRules.no_cold(session)
    end

    # The corollary: a query run before firing does *not* see what the pending
    # activations would conclude. This is the documented "what was true before
    # they fired" reading, and it is what makes batching facts meaningful.
    test "a query before firing does not see conclusions still on the agenda" do
      session = [QueryRules] |> Session.new() |> Session.insert([{:temp, 1}, {:seed, 9}])

      assert [1] == QueryRules.temps(session)

      assert [1, 9] ==
               session |> Session.fire_rules() |> QueryRules.temps() |> Enum.sort()
    end

    # clara test_negation/test-simple-negation, the partial-retraction case.
    # Removing one of two blocking facts must not release the negation.
    test "a negation stays blocked while any matching fact remains" do
      session =
        [QueryRules]
        |> Session.new()
        |> Session.insert([{:cold, 10}, {:cold, 15}])
        |> Session.retract({:cold, 10})
        |> Session.fire_rules()

      assert [] == QueryRules.no_cold(session)

      session = session |> Session.retract({:cold, 15}) |> Session.fire_rules()
      assert [:none] == QueryRules.no_cold(session)
    end
  end

  # --- existence ----------------------------------------------------------------------

  describe "existence" do
    defmodule DoubleNegation do
      use Rete.Ruleset

      defrule has_order({:cust, cid}, {:not, [{:not, [{:order, cid, _amt}]}]}) do
        {:has_order, cid}
      end
    end

    defmodule NonEmpty do
      use Rete.Ruleset

      defrule has_order({:cust, cid}, orders = [{:order, cid, _amt}]) when orders != [] do
        {:has_order, cid}
      end
    end

    # There is no `:exists`, and `{:not, [{:not, [x]}]}` is **not** a
    # substitute. `Rete.DSL.Normalize` collapses `not(not(x))` to `x` — which is
    # right propositionally and wrong existentially: `x` binds and produces one
    # match per fact, where existence produces at most one. The fact set hides
    # the difference (equal facts collapse), so the assertion has to be on the
    # support count.
    test "a double negation collapses to the condition and matches once per fact" do
      session = run(DoubleNegation, [{:cust, 1}, {:order, 1, 10}, {:order, 1, 20}])

      assert [{:has_order, 1}] == tagged(session, :has_order)
      assert 2 == session.state.memory.facts[{:has_order, 1}]
    end

    # A non-empty collection is the spelling that does mean "exists": one group
    # per token, so exactly one match however many facts are in it.
    test "a guarded collection gives true existence semantics" do
      session = run(NonEmpty, [{:cust, 1}, {:order, 1, 10}, {:order, 1, 20}, {:cust, 2}])

      assert [{:has_order, 1}] == tagged(session, :has_order)
      assert 1 == session.state.memory.facts[{:has_order, 1}]
    end

    defmodule ExistsGates do
      use Rete.Ruleset

      defrule any_cw(cws = [{:cw, _t, _w}]) when cws != [] do
        {:exists, :cw}
      end

      defrule any_cold(temps = [{:temp, t} when t < 20]) when temps != [] do
        {:exists, :cold}
      end

      defrule either({:or, [{:exists, :cw}, {:exists, :cold}]}) do
        {:either}
      end

      defrule both({:and, [{:exists, :cw}, {:exists, :cold}]}) do
        {:both}
      end
    end

    # clara test_negation/test-exists-inside-boolean-conjunction-and-disjunction.
    # Existence has to be a rule of its own here — a collection cannot be a gate
    # argument that also gates — and once it is a fact, the gates compose over
    # it exactly as Clara's `:exists` does under `:or` and `:and`.
    test "existence expressed as a rule composes under the gates" do
      assert [] == tagged(run(ExistsGates, []), :either)
      assert [] == tagged(run(ExistsGates, []), :both)

      one = run(ExistsGates, [{:cw, 10, 10}])
      assert [{:either}] == tagged(one, :either)
      assert [] == tagged(one, :both)

      other = run(ExistsGates, [{:temp, 10}])
      assert [{:either}] == tagged(other, :either)
      assert [] == tagged(other, :both)

      session = run(ExistsGates, [{:cw, 10, 10}, {:temp, 10}, {:temp, 15}])
      assert [{:both}] == tagged(session, :both)

      # Both branches of the `or` hold, so `{:either}` has two supports and
      # needs both to go — and the second `{:temp, 15}` adds neither, because
      # existence is per token rather than per fact.
      assert 2 == session.state.memory.facts[{:either}]
    end
  end

  # --- negation -----------------------------------------------------------------------

  describe "negation and truth maintenance together" do
    defmodule NegTms do
      use Rete.Ruleset

      defrule make_hot({:wind, _s}) do
        {:temp, 100}
      end

      defrule not_hot({:not, [{:temp, t} when t > 80]}) do
        {:cold, 0}
      end

      defquery colds({:cold, c}) do
        c
      end
    end

    # clara test_negation/test-negation-truth-maintenance. The fact that blocks
    # the negation is itself a conclusion, so the whole loop has to close: an
    # external insert derives it, which retracts the negation's conclusion; an
    # external retract undoes the derivation, which releases the negation again.
    test "a conclusion that blocks another rule's negation retracts it, and gives it back" do
      base = [NegTms] |> Session.new() |> Session.fire_rules()
      assert [0] == NegTms.colds(base)

      blocked = base |> Session.insert({:wind, 100}) |> Session.fire_rules()
      assert [] == NegTms.colds(blocked)

      released = blocked |> Session.retract({:wind, 100}) |> Session.fire_rules()
      assert [0] == NegTms.colds(released)

      # And the whole round trip is exact, not merely equivalent in its facts.
      assert base.state.memory == released.state.memory
    end

    defmodule Cascade do
      use Rete.Ruleset

      defrule lousy({:not, [{:hot, _t}]}) do
        {:lousy}
      end

      defrule downstream({:lousy}) do
        {:first}
      end

      defquery lousy_q({:lousy}) do
        :ok
      end

      defquery first_q({:first}) do
        :ok
      end
    end

    # clara test_rules/test-external-activation-of-negation-condition-triggering-retraction.
    # Blocking a negation from outside has to retract not only the rule's own
    # conclusion but everything downstream concluded it.
    test "blocking a negation retracts the conclusion and everything derived from it" do
      base = [Cascade] |> Session.new() |> Session.fire_rules()
      assert [:ok] == Cascade.lousy_q(base)
      assert [:ok] == Cascade.first_q(base)

      blocked = base |> Session.insert({:hot, 100}) |> Session.fire_rules()
      assert [] == Cascade.lousy_q(blocked)
      assert [] == Cascade.first_q(blocked)
      assert %{{:hot, 100} => 1} == blocked.state.memory.facts
    end

    defmodule Issue67 do
      use Rete.Ruleset

      defquery cold_not_windy({:temp, t} when t < 20, {:not, [{:wind, _s, _loc}]}) do
        t
      end
    end

    # Clara issue 67. The blocking fact arrives and leaves before any token ever
    # reaches the negation, so the node's element memory has to be genuinely
    # empty afterwards rather than merely marked as changed.
    test "a fact inserted and retracted before any token exists leaves no residue" do
      session =
        [Issue67]
        |> Session.new()
        |> Session.insert({:wind, 30, "MCI"})
        |> Session.retract({:wind, 30, "MCI"})
        |> Session.fire_rules()
        |> Session.insert({:temp, 10})
        |> Session.fire_rules()

      assert [10] == Issue67.cold_not_windy(session)
    end

    defmodule NegOrGuard do
      use Rete.Ruleset

      # `c < t or c < 0` mixes a token variable and a local one inside an `or`,
      # so guard splitting cannot decompose it and the whole thing becomes the
      # negation node's join filter.
      defrule colder({:temp, t}, {:not, [{:cold, c} when c < t or c < 0]}) do
        {:found, t}
      end

      defquery found({:found, t}) do
        t
      end
    end

    # clara test_rules/test-negation-with-extracted-test, the whole ordering
    # matrix in one table. A guarded negation has four ways to be wrong — left
    # before right, right before left, partial retraction, and violation after
    # the token was already through — and every one of them has bitten Clara.
    test "a guarded negation gives the same answer whatever order facts arrive in" do
      steps = fn ops ->
        Enum.reduce(ops, Session.new([NegOrGuard]), fn
          {:insert, fact}, s -> Session.insert(s, fact)
          {:retract, fact}, s -> Session.retract(s, fact)
          :fire, s -> Session.fire_rules(s)
        end)
        |> NegOrGuard.found()
      end

      # No token at all, so nothing to release.
      assert [] == steps.([{:insert, {:cold, 11}}, :fire])

      # A non-matching element never blocks, whichever side arrives first.
      assert [10] == steps.([{:insert, {:temp, 10}}, {:insert, {:cold, 11}}, :fire])
      assert [10] == steps.([{:insert, {:cold, 11}}, {:insert, {:temp, 10}}, :fire])
      assert [10] == steps.([{:insert, {:temp, 10}}, :fire])

      # A matching element blocks, whichever side arrives first.
      assert [] == steps.([{:insert, {:cold, 9}}, {:insert, {:temp, 10}}, :fire])
      assert [] == steps.([{:insert, {:temp, 10}}, {:insert, {:cold, 9}}, :fire])

      # Removing the blocker releases the token.
      assert [10] ==
               steps.([
                 {:insert, {:cold, 9}},
                 {:insert, {:temp, 10}},
                 :fire,
                 {:retract, {:cold, 9}},
                 :fire
               ])

      # ...but only when the last occurrence goes.
      assert [] ==
               steps.([
                 {:insert, {:cold, 9}},
                 {:insert, {:cold, 9}},
                 {:insert, {:temp, 10}},
                 :fire,
                 {:retract, {:cold, 9}},
                 :fire
               ])

      # A violation arriving after the rule already fired takes it back.
      assert [] ==
               steps.([
                 {:insert, {:cold, 11}},
                 {:insert, {:temp, 10}},
                 :fire,
                 {:insert, {:cold, 9}},
                 :fire
               ])
    end

    # The sharpest form of the same rule. Both tokens live under the join key
    # `%{}` — the negation joins on nothing — and the filter suppresses one and
    # not the other. Releasing the suppressed one must leave the other exactly
    # as it was: re-sending it would give it a second support, which the fact
    # list cannot show and which no retraction will ever clear.
    test "releasing a suppressed token does not re-send one that was already through" do
      session = run(NegOrGuard, [{:temp, 10}, {:temp, 5}, {:cold, 9}])

      # 9 < 10 suppresses the first; 9 < 5 and 9 < 0 are both false, so the
      # second is through already.
      assert [{:found, 5}] == tagged(session, :found)
      assert 1 == session.state.memory.facts[{:found, 5}]

      session = session |> Session.retract({:cold, 9}) |> Session.fire_rules()
      assert [{:found, 5}, {:found, 10}] == tagged(session, :found)
      assert 1 == session.state.memory.facts[{:found, 5}]

      # If the second token had been re-sent it would survive this.
      session = session |> Session.retract({:temp, 5}) |> Session.fire_rules()
      assert [{:found, 10}] == tagged(session, :found)
    end

    defmodule NestedNeg do
      use Rete.Ruleset

      # not( temp(loc) and not( cold(value) ) ) — a negation nested inside a
      # compound negation, joined to a binding from before the negation.
      defrule ok({:wind, loc}, {:not, [{:temp, loc, tv}, {:not, [{:cold, tv}]}]}) do
        {:ok, loc}
      end
    end

    # clara test_negation/test-complex-negation, `nested-negation-with-prior-bindings`.
    # The extracted helper's marker has to carry `loc`, or the negation stops
    # asking "for this location" and starts asking "anywhere" — Clara issue 304.
    test "a negation nested in a compound negation stays scoped to its binding group" do
      # Inner negation holds (no cold at 10), so the conjunction holds, so the
      # outer negation does not.
      assert [] == tagged(run(NestedNeg, [{:wind, "MCI"}, {:temp, "MCI", 10}, {:cold, 20}]), :ok)

      # Inner negation fails, so the conjunction fails, so the outer holds.
      assert [{:ok, "MCI"}] ==
               tagged(run(NestedNeg, [{:wind, "MCI"}, {:temp, "MCI", 10}, {:cold, 10}]), :ok)

      # Issue 304 proper: MCI is suppressed and ORD is not, in one session.
      session =
        run(NestedNeg, [
          {:wind, "MCI"},
          {:temp, "MCI", 10},
          {:cold, 20},
          {:wind, "ORD"},
          {:temp, "ORD", 20}
        ])

      assert [{:ok, "ORD"}] == tagged(session, :ok)
    end

    test "a nested compound negation drains completely" do
      facts = [
        {:wind, "MCI"},
        {:temp, "MCI", 10},
        {:cold, 20},
        {:wind, "ORD"},
        {:temp, "ORD", 20}
      ]

      emptied = NestedNeg |> run(facts) |> drain(facts)

      assert Session.new([NestedNeg]).state.memory == emptied.state.memory
    end

    defmodule GlobalNand do
      use Rete.Ruleset

      # The conjunction joins on `oid`, which no ancestor binds, so the marker
      # carries nothing and the negation really is global.
      defrule clean({:cust, cid}, {:nand, [{:order, oid}, {:refund, oid}]}) do
        {:clean, cid}
      end
    end

    # The other half of issue 304: when the negated conjunction shares no
    # variable with what precedes it, "no match anywhere" is the correct
    # reading, and one matching pair must suppress *every* customer.
    test "a compound negation sharing no ancestor binding suppresses globally" do
      assert [] ==
               tagged(
                 run(GlobalNand, [{:cust, 1}, {:cust, 2}, {:order, 7}, {:refund, 7}]),
                 :clean
               )

      assert [{:clean, 1}, {:clean, 2}] ==
               tagged(
                 run(GlobalNand, [{:cust, 1}, {:cust, 2}, {:order, 7}, {:refund, 8}]),
                 :clean
               )
    end

    defmodule OrOfNegations do
      use Rete.Ruleset

      defrule lousy(
                {:temp, t},
                {:or, [{:not, [{:cold, c} when c > t]}, {:not, [{:hot, h} when h > t]}]}
              ) do
        {:lousy, t}
      end
    end

    # clara test_rules/test-extra-right-activations-with-disjunction-of-negations.
    # While one branch's negation holds, piling more facts onto the *other*
    # branch must change nothing. An engine that re-sends the surviving branch's
    # token on every right activation of the failing one accumulates supports
    # the retraction will never clear.
    test "extra facts blocking one branch of a disjunction of negations change nothing" do
      session = run(OrOfNegations, [{:hot, 100}, {:temp, -100}])
      assert [{:lousy, -100}] == tagged(session, :lousy)
      assert 1 == session.state.memory.facts[{:lousy, -100}]

      session = session |> Session.insert({:hot, 120}) |> Session.fire_rules()
      assert [{:lousy, -100}] == tagged(session, :lousy)
      assert 1 == session.state.memory.facts[{:lousy, -100}]

      # Blocking the other branch too finally removes it, and one retraction is
      # enough — which is only true if the support count never drifted.
      session = session |> Session.insert({:cold, 5}) |> Session.fire_rules()
      assert [] == tagged(session, :lousy)
    end

    test "a disjunction of negations drains after that churn" do
      facts = [{:hot, 100}, {:temp, -100}, {:hot, 120}, {:cold, 5}]
      emptied = OrOfNegations |> run(facts) |> drain(facts)

      assert Session.new([OrOfNegations]).state.memory == emptied.state.memory
    end

    defmodule CollInNegation do
      use Rete.Ruleset

      # The negation's join filter reads `temps`, a collection binding from the
      # token rather than a plain value.
      defquery all_small(temps = [{:temp, _v}], {:not, [{:temp, v} when v < length(temps)]}) do
        temps
      end
    end

    # clara test_rules/test-accum-result-in-negation, adapted: an aggregate
    # computed to the left of a negation must be visible to the negation's
    # filter, or the negation silently tests against a missing key and never
    # blocks.
    test "a negation's filter can read a collection binding from the token" do
      assert [[temp: 5, temp: 7]] ==
               CollInNegation.all_small(run(CollInNegation, [{:temp, 5}, {:temp, 7}]))

      assert [] == CollInNegation.all_small(run(CollInNegation, [{:temp, 1}, {:temp, 7}]))
    end
  end

  # --- disjunction --------------------------------------------------------------------

  describe "disjunction" do
    defmodule NestedAnd do
      use Rete.Ruleset

      defquery find(
                 tmp = {:temp, t, loc},
                 {:or,
                  [
                    {:and, [w = {:wind, _s, loc}, c = {:cold, t}]},
                    cw = {:cw, t, ws} when ws > 50
                  ]}
               ) do
        {tmp, w, c, cw}
      end
    end

    # clara test_rules/test-multi-conditions-with-nested-conjunction-inside-disjunction.
    # Each branch fans out from the shared prefix and carries its own bindings;
    # a fact set satisfying both yields one match per branch, not one merged
    # match and not a cross product.
    test "a conjunction nested in a disjunction contributes one match per branch" do
      session =
        run(NestedAnd, [
          {:temp, 10, "MCI"},
          {:cold, 10},
          {:wind, 50, "MCI"},
          {:cw, 10, 80}
        ])

      # The body returns {tmp, w, c, cw}, so the branch that ran shows in which
      # of those are filled.
      assert [
               {{:temp, 10, "MCI"}, nil, nil, {:cw, 10, 80}},
               {{:temp, 10, "MCI"}, {:wind, 50, "MCI"}, {:cold, 10}, nil}
             ] == Enum.sort(NestedAnd.find(session))
    end

    # Only what every branch binds survives a disjunction. A variable the branch
    # that ran does not bind is `nil` in the right hand side rather than a value
    # carried over from the other branch — and, more importantly, it is not in
    # the token, so a later condition cannot accidentally join on it.
    test "a branch contributes only its own bindings" do
      session = run(NestedAnd, [{:temp, 10, "MCI"}, {:cw, 10, 80}])

      assert [{{:temp, 10, "MCI"}, nil, nil, {:cw, 10, 80}}] == NestedAnd.find(session)
    end
  end

  # --- collections: retraction and re-accumulation --------------------------------------

  describe "collections under retraction" do
    defmodule CollJoin do
      use Rete.Ruleset

      defquery hashed({:temp, t}, cs = [{:cold, t}]) do
        cs
      end

      defquery filtered({:temp, t}, cs = [{:cold, c} when c <= t]) do
        cs
      end
    end

    # clara test_accumulation/test-accumulator-right-retract-before-matching-tokens-exist,
    # for both node kinds. Candidates arriving before any token exists are held
    # unreduced; a retraction has to remove them from that holding area too, or
    # the first token to arrive collects a ghost.
    test "an element retracted before any token exists is not collected" do
      for query <- [:hashed, :filtered] do
        session =
          [CollJoin]
          |> Session.new()
          |> Session.insert({:cold, 10})
          |> Session.retract({:cold, 10})
          |> Session.insert({:temp, 10})
          |> Session.fire_rules()

        assert [[]] == Session.query(session, {CollJoin, query}),
               "#{query} collected a retracted candidate"
      end
    end

    defmodule CollSum do
      use Rete.Ruleset

      defquery gathered(ts = [{:temp, _v, _loc}]) do
        ts
      end
    end

    # clara test_accumulation/test-retract-fact-never-inserted-from-accum. The
    # retracted fact was never inserted but lands in the same binding group as
    # one that was. Removing "the group" rather than "this element" empties it.
    test "retracting a never inserted fact does not disturb the group it would land in" do
      session =
        [CollSum]
        |> Session.new()
        |> Session.insert({:temp, 10, "LAX"})
        |> Session.retract({:temp, 10, "MCI"})
        |> Session.fire_rules()

      assert [[{:temp, 10, "LAX"}]] == CollSum.gathered(session)
    end

    defmodule CollThreshold do
      use Rete.Ruleset

      defrule coldest({:threshold, limit}, ts = [{:temp, v, _loc} when v < limit]) do
        case ts do
          [] -> []
          _ -> {:cold, ts |> Enum.map(fn {_, v, _} -> v end) |> Enum.max()}
        end
      end

      defquery cold({:cold, v}) do
        v
      end
    end

    # clara test_accumulation/test-accumulator-with-test-join-retract-accumulated-use-new-result.
    # Retracting and re-adding within one batch exercises the intermediate
    # memory state: the group is reduced, emptied, and reduced again before
    # anything downstream ever sees it.
    test "a member retracted and re-added before firing gives the final result" do
      session =
        [CollThreshold]
        |> Session.new()
        |> Session.insert([{:threshold, 20}, {:temp, 10, "MCI"}])
        |> Session.retract({:temp, 10, "MCI"})
        |> Session.insert({:temp, 10, "MCI"})
        |> Session.fire_rules()

      assert [10] == CollThreshold.cold(session)
      assert 1 == session.state.memory.facts[{:cold, 10}]
    end

    defmodule CollDownstream do
      use Rete.Ruleset

      defrule create_cold(cws = [{:cw, _t}]) do
        for {:cw, t} <- cws, do: {:cold, t}
      end

      defrule temp_from_cold({:cold, t}) do
        {:derived_temp, t}
      end

      defquery colds({:cold, t}) do
        t
      end

      defquery temps({:derived_temp, t}) do
        t
      end
    end

    # clara test_accumulation/test-retract-of-fact-matching-accumulator-causes-downstream-retraction.
    # A collection's conclusions are re-derived wholesale on every change, so
    # the *downstream* rule has to see a retraction and an insertion rather than
    # accumulating both generations.
    test "changing a collection member updates direct and downstream conclusions alike" do
      base = run(CollDownstream, [{:cw, 10}, {:cw, 20}])

      assert [10, 20] == base |> CollDownstream.colds() |> Enum.sort()
      assert [10, 20] == base |> CollDownstream.temps() |> Enum.sort()

      removed = base |> Session.retract({:cw, 10}) |> Session.fire_rules()
      assert [20] == CollDownstream.colds(removed)
      assert [20] == CollDownstream.temps(removed)

      added = base |> Session.insert({:cw, 15}) |> Session.fire_rules()
      assert [10, 15, 20] == added |> CollDownstream.colds() |> Enum.sort()
      assert [10, 15, 20] == added |> CollDownstream.temps() |> Enum.sort()

      # Every conclusion rests on exactly one match, so nothing accumulated.
      for {fact, count} <- added.state.memory.facts do
        assert 1 == count, "#{inspect(fact)} is held #{count} times"
      end
    end

    defmodule PerTokenColl do
      use Rete.Ruleset

      # The limit comes from the token, so two tokens under the same join key
      # disagree about which elements they can see.
      defrule over({:tag, cid, lim}, os = [{:order, cid, amt} when amt > lim]) do
        {:over, cid, lim, length(os)}
      end
    end

    # clara test_accumulation/test-accum-without-change-in-result-no-downstream-propagation.
    # An element that changes one token's collection and not another's may only
    # disturb the one it changed. Retracting and re-sending the unchanged token
    # nets to the same facts, so this can only be seen in what actually ran.
    test "an element visible to one token only does not re-fire the others" do
      base =
        [PerTokenColl]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert([{:tag, 1, 100}, {:tag, 1, 1000}])
        |> Session.fire_rules()

      assert [{:over, 1, 100, 0}, {:over, 1, 1000, 0}] == tagged(base, :over)
      assert 2 == length(fired(base))

      # 500 is over 100 and under 1000, so only the first token's list changes.
      session = base |> Session.insert({:order, 1, 500}) |> Session.fire_rules()

      assert [{:over, 1, 100, 1}, {:over, 1, 1000, 0}] == tagged(session, :over)

      assert [[{:over, 1, 100, 0}], [{:over, 1, 1000, 0}], [{:over, 1, 100, 1}]] ==
               fired(session)
    end

    defmodule CollDup do
      use Rete.Ruleset

      defquery gathered(os = [{:o, _x}]) do
        os
      end
    end

    # Facts are a multiset for retraction, but the network sees one element per
    # distinct fact — an equal insert bumps a count rather than propagating. So
    # a collection holds a duplicated fact once, and it takes two retractions to
    # get it out.
    test "a fact inserted twice appears once in a collection and needs two retractions" do
      gathered = fn s ->
        [os] = CollDup.gathered(s)
        Enum.sort(os)
      end

      session = run(CollDup, [{:o, 1}, {:o, 1}, {:o, 2}])

      assert [{:o, 1}, {:o, 2}] == gathered.(session)
      assert 2 == session.state.memory.facts[{:o, 1}]

      session = session |> Session.retract({:o, 1}) |> Session.fire_rules()
      assert [{:o, 1}, {:o, 2}] == gathered.(session)

      session = session |> Session.retract({:o, 1}) |> Session.fire_rules()
      assert [{:o, 2}] == gathered.(session)
    end

    defmodule CollAncestor do
      use Rete.Ruleset

      derive :array_list, :list
      derive :linked_list, :list

      defquery lists(ls = [{:list, _n}]) do
        ls
      end
    end

    # clara test_rules/test-alpha-batching-with-multiple-ancestors, issue 257.
    # Two distinct fact types reaching one condition through a common ancestor
    # must land in the same group, not in one group each.
    test "a collection over an ancestor type gathers every descendant together" do
      session = run(CollAncestor, [{:array_list, 1}, {:linked_list, 2}])

      # Sorted, because the order of a gathered list is not part of the contract.
      assert [gathered] = CollAncestor.lists(session)
      assert [{:array_list, 1}, {:linked_list, 2}] == Enum.sort(gathered)
    end

    defmodule TestAfterColl do
      use Rete.Ruleset

      defrule restricted({:city, loc}, ts = [{:temp, loc, _v}]) when loc == "LHR" do
        {:cold, length(ts)}
      end

      defquery cold({:cold, n}) do
        n
      end
    end

    # clara test_bindings/test-accumulator-before-equality-test-in-test-node,
    # issue 357. A rule level guard sorted after a collection still runs, and
    # still gates.
    test "a rule level guard after a collection is evaluated" do
      assert [] == TestAfterColl.cold(run(TestAfterColl, [{:city, "LGW"}, {:temp, "LGW", 0}]))

      assert [1] ==
               TestAfterColl.cold(run(TestAfterColl, [{:city, "LHR"}, {:temp, "LHR", 0}]))
    end
  end

  # --- truth maintenance ----------------------------------------------------------------

  describe "truth maintenance" do
    defmodule TwoEqual do
      use Rete.Ruleset

      # One match concludes the same fact twice, so it takes two retractions to
      # remove — and both must go when the match does.
      defrule two({:temp, t, _loc}) do
        [{:cold, t}, {:cold, t}]
      end
    end

    # clara test_truth_maintenance/test-retraction-of-equal-elements. Two
    # supports concluded two colds each, so four. Removing one support must
    # remove exactly its two, even though all four are equal.
    test "equal facts concluded by one match are held and released together" do
      session = run(TwoEqual, [{:temp, 50, "LAX"}, {:temp, 50, "MCI"}])
      assert 4 == session.state.memory.facts[{:cold, 50}]

      session = session |> Session.retract({:temp, 50, "MCI"}) |> Session.fire_rules()
      assert 2 == session.state.memory.facts[{:cold, 50}]

      session = session |> Session.retract({:temp, 50, "LAX"}) |> Session.fire_rules()
      assert [] == Session.facts(session)
      assert Session.new([TwoEqual]).state.memory == session.state.memory
    end

    defmodule Tiered do
      use Rete.Ruleset

      defrule r1({:first}) do
        [{:second}, {:second}]
      end

      defrule r2({:second}) do
        {:third}
      end
    end

    # clara test_truth_maintenance/test-tiered-identical-insertions-with-retractions.
    # A duplicated premise is one element in the network and two occurrences in
    # the multiset, so the first retraction changes nothing downstream and the
    # second takes the entire tier with it.
    test "a duplicated premise supports one derivation tier, released only at the last copy" do
      session = run(Tiered, [{:first}, {:first}])
      assert %{{:first} => 2, {:second} => 2, {:third} => 1} == session.state.memory.facts

      session = session |> Session.retract({:first}) |> Session.fire_rules()
      assert %{{:first} => 1, {:second} => 2, {:third} => 1} == session.state.memory.facts

      session = session |> Session.retract({:first}) |> Session.fire_rules()
      assert Session.new([Tiered]).state.memory == session.state.memory
    end

    defmodule Downstream do
      use Rete.Ruleset

      defrule cold({:cw, t, _w}) do
        {:cold, t}
      end

      defquery colds({:cold, t}) do
        t
      end
    end

    # clara test_truth_maintenance/test-duplicate-insertions-with-only-one-removed
    # and test-remove-pending-activation-with-equal-previous-insertion (issue
    # 250). Both are the same shape: an equal fact arrives while a conclusion
    # already rests on one, and one occurrence then leaves. The conclusion has
    # to survive, with its support unchanged.
    test "removing one occurrence of a duplicated premise leaves the conclusion standing" do
      session =
        [Downstream]
        |> Session.new()
        |> Session.insert({:cw, 10, 10})
        |> Session.insert({:cw, 10, 10})
        |> Session.fire_rules()
        |> Session.retract({:cw, 10, 10})
        |> Session.fire_rules()

      assert [10] == Downstream.colds(session)
      assert %{{:cw, 10, 10} => 1, {:cold, 10} => 1} == session.state.memory.facts
    end

    test "an equal fact arriving and leaving after the rule fired changes nothing" do
      base = run(Downstream, [{:cw, 10, 10}])

      cycled =
        base
        |> Session.insert({:cw, 10, 10})
        |> Session.retract({:cw, 10, 10})
        |> Session.fire_rules()

      assert [10] == Downstream.colds(cycled)
      assert base.state.memory == cycled.state.memory
    end

    defmodule Many do
      use Rete.Ruleset

      defrule fan({:temp, t}) do
        for i <- 0..999, do: {:cold, t - i}
      end

      defquery colds({:cold, t}) do
        t
      end
    end

    # clara test_truth_maintenance/test-retracting-many-logical-insertions-for-same-rule.
    # One match supporting a thousand facts, all retracted at once. Clara's
    # version guards against a StackOverflowError from lazily stacked
    # retractions; this engine's flat work queue is what makes it a non-event,
    # and the point of the test is to keep it that way.
    test "one match may support a thousand facts, and give them all back" do
      session = run(Many, [{:temp, 10}])
      assert 1000 == length(Many.colds(session))

      session = session |> Session.retract({:temp, 10}) |> Session.fire_rules()
      assert [] == Many.colds(session)
      assert Session.new([Many]).state.memory == session.state.memory
    end

    defmodule Deep do
      use Rete.Ruleset

      defrule step({:n, i} when i < 200) do
        {:n, i + 1}
      end
    end

    # A two hundred step cascade in a single fire. The flat propagation loop is
    # supposed to make depth free; a recursive one would be at risk here and a
    # cascade is exactly what a rules engine does for a living.
    test "a long derivation cascade settles in one fire" do
      session = run(Deep, [{:n, 0}])

      assert 201 == length(Session.facts(session))
      assert [] == Session.pending(session)

      session = session |> Session.retract({:n, 0}) |> Session.fire_rules()
      assert Session.new([Deep]).state.memory == session.state.memory
    end
  end

  # --- salience must not change the answer ------------------------------------------------

  describe "salience is scheduling, not semantics" do
    # clara test_rules/test-negation-with-complex-retractions. `first_to_second`
    # concludes the fact that blocks `blocked`, whose conclusion in turn blocks
    # the query — a doubly blocked chain. Firing it in the easiest order, the
    # hardest order, and no particular order must all settle in the same place;
    # if truth maintenance is incomplete, only the easy order looks right.
    defmodule NoSalience do
      use Rete.Ruleset

      defrule first_to_second({:first}) do
        {:second}
      end

      defrule blocked({:not, [{:second}]}, {:first}) do
        [{:fourth}, {:third}]
      end

      defquery double_blocked({:not, [{:second}]}, {:not, [{:third}]}, f = {:fourth}) do
        f
      end
    end

    defmodule BestOrder do
      use Rete.Ruleset

      defrule first_to_second(%{salience: 2}, {:first}) do
        {:second}
      end

      defrule blocked(%{salience: 1}, {:not, [{:second}]}, {:first}) do
        [{:fourth}, {:third}]
      end

      defquery double_blocked({:not, [{:second}]}, {:not, [{:third}]}, f = {:fourth}) do
        f
      end
    end

    defmodule WorstOrder do
      use Rete.Ruleset

      defrule first_to_second(%{salience: -2}, {:first}) do
        {:second}
      end

      defrule blocked(%{salience: -1}, {:not, [{:second}]}, {:first}) do
        [{:fourth}, {:third}]
      end

      defquery double_blocked({:not, [{:second}]}, {:not, [{:third}]}, f = {:fourth}) do
        f
      end
    end

    @orders [NoSalience, BestOrder, WorstOrder]

    test "a doubly blocked chain settles identically at every salience arrangement" do
      for mod <- @orders do
        # Control: with nothing to block it, the query matches.
        unblocked = run(mod, [{:fourth}])
        assert [{:fourth}] == Session.query(unblocked, {mod, :double_blocked}), inspect(mod)

        session = run(mod, [{:first}, {:fourth}])
        assert [] == Session.query(session, {mod, :double_blocked}), inspect(mod)

        assert [{:first}, {:fourth}, {:second}] == session |> Session.facts() |> Enum.sort(),
               inspect(mod)
      end
    end

    test "the doubly blocked chain drains at every salience arrangement" do
      facts = [{:first}, {:fourth}]

      for mod <- @orders do
        emptied = mod |> run(facts) |> drain(facts)
        assert Session.new([mod]).state.memory == emptied.state.memory, inspect(mod)
      end
    end

    # clara test_truth_maintenance/test-retract-inserted-during-rule, issue 54.
    # The collection fires with `[]` before the facts exist, then has to take
    # that conclusion back when they arrive. Clara found this order dependent,
    # so both orders and both saliences are checked.
    defmodule HistoryDefault do
      use Rete.Ruleset

      defrule create({:seed}) do
        [{:temp, 20}, {:temp, 25}, {:temp, 30}]
      end

      defrule history(ts = [{:temp, _t}]) do
        {:history, Enum.sort(ts)}
      end
    end

    defmodule HistoryLowSalience do
      use Rete.Ruleset

      defrule create({:seed}) do
        [{:temp, 20}, {:temp, 25}, {:temp, 30}]
      end

      defrule history(%{salience: -10}, ts = [{:temp, _t}]) do
        {:history, Enum.sort(ts)}
      end
    end

    defmodule HistoryHighSalience do
      use Rete.Ruleset

      defrule history(%{salience: 10}, ts = [{:temp, _t}]) do
        {:history, Enum.sort(ts)}
      end

      defrule create({:seed}) do
        [{:temp, 20}, {:temp, 25}, {:temp, 30}]
      end
    end

    test "a collection that fired empty takes it back when facts arrive" do
      expected = {:history, [temp: 20, temp: 25, temp: 30]}

      for mod <- [HistoryDefault, HistoryLowSalience, HistoryHighSalience] do
        session = run(mod, [{:seed}])

        # Exactly one history fact, singly held: the empty one is gone rather
        # than merely outnumbered.
        assert [expected] == tagged(session, :history), inspect(mod)
        assert 1 == session.state.memory.facts[expected], inspect(mod)
      end
    end

    defmodule NegationChurn do
      use Rete.Ruleset

      defrule coldest(%{salience: 5}, cws = [{:cw, _t}]) do
        case cws do
          [] -> []
          _ -> {:cold, cws |> Enum.map(fn {_, t} -> t end) |> Enum.min()}
        end
      end

      defrule no_cold(%{salience: 6}, {:not, [{:cold, _t}]}) do
        {:hot, 100}
      end

      defrule first_cw(%{salience: -1}, {:first}) do
        {:cw, 20}
      end

      defrule second_cw(%{salience: -2}, {:second}) do
        {:cw, 10}
      end

      defquery hot({:hot, t}) do
        t
      end
    end

    # clara test_rules/test-negation-of-changing-result-from-accumulator-in-fire-rules.
    # The negation is satisfied, then violated, then violated by a *different*
    # fact, all within one `fire_rules/2` call as the salience groups drain. The
    # session must settle on the truth, not on whichever state it passed through.
    test "a negation that flips repeatedly inside one fire cycle settles correctly" do
      session = run(NegationChurn, [{:first}, {:second}])

      assert [] == NegationChurn.hot(session)

      assert [{:first}, {:second}, {:cold, 10}, {:cw, 10}, {:cw, 20}] ==
               session |> Session.facts() |> Enum.sort()
    end
  end

  # --- when rules run ----------------------------------------------------------------------

  describe "firing" do
    defmodule FireOrder do
      use Rete.Ruleset

      defrule a({:cold, _t}) do
        {:fired, :a}
      end

      defrule b({:cold, _t}) do
        {:fired, :b}
      end

      defrule c({:cold, _t}) do
        {:fired, :c}
      end
    end

    # clara test_rules/test-rule-order-respected. Salience decides first; among
    # equals, the order the rules were declared in. Not a semantic guarantee —
    # the previous section pins that salience cannot change the answer — but a
    # predictable one, which is what makes a trace readable.
    test "rules of equal salience fire in declaration order" do
      session =
        [FireOrder]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:cold, 1})
        |> Session.fire_rules()

      assert [[{:fired, :a}], [{:fired, :b}], [{:fired, :c}]] == fired(session)
    end

    # clara test_rules/test-mark-as-fired. An activation is consumed when it
    # fires; a second `fire_rules/2` over an unchanged session does nothing.
    test "firing twice does not run the same activation again" do
      session =
        [FireOrder]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:cold, 1})
        |> Session.fire_rules()

      assert 3 == length(fired(session))
      assert 3 == session |> Session.fire_rules() |> fired() |> length()
    end

    test "retracting and reinserting the premise produces a new activation" do
      session =
        [FireOrder]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:cold, 1})
        |> Session.fire_rules()
        |> Session.retract({:cold, 1})
        |> Session.insert({:cold, 1})
        |> Session.fire_rules()

      assert 6 == length(fired(session))
    end

    defmodule SalienceOrder do
      use Rete.Ruleset

      # Declared deliberately out of salience order, so declaration order alone
      # cannot produce the expected answer.
      defrule mid(%{salience: 50}, {:temp, _t}) do
        {:fired, 50}
      end

      defrule low(%{salience: -50}, {:temp, _t}) do
        {:fired, -50}
      end

      defrule high(%{salience: 100}, {:temp, _t}) do
        {:fired, 100}
      end

      defrule default({:temp, _t}) do
        {:fired, 0}
      end
    end

    # clara test_rules/test-salience, minus the pluggable sort and grouping
    # functions Clara allows and this engine does not. Descending salience,
    # default 0, negative salience last.
    test "rules fire in descending salience order" do
      session =
        [SalienceOrder]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:temp, 10})
        |> Session.fire_rules()

      assert [[{:fired, 100}], [{:fired, 50}], [{:fired, 0}], [{:fired, -50}]] == fired(session)
    end

    defmodule HelperSalience do
      use Rete.Ruleset

      defrule clean({:cust, cid}, {:nand, [{:order, cid}, {:refund, cid}]}) do
        {:clean, cid}
      end
    end

    # A compound negation compiles to a helper production plus a plain negation
    # of its marker, and the helper carries an internal salience so it runs
    # first. Without that the negating rule observes an absence that has merely
    # not been computed yet: it fires, concludes, and truth maintenance takes it
    # straight back. The end state is right either way, so only the trace shows
    # it — and a spurious firing is a side effect a user's rule would have run.
    test "an extracted negation helper fires before the rule that negates it" do
      session =
        [HelperSalience]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert([{:cust, 1}, {:order, 1}, {:refund, 1}])
        |> Session.fire_rules()

      assert [] == tagged(session, :clean)

      # Exactly one firing — the helper's — and nothing was ever taken back.
      assert 1 == length(fired(session))
      assert [] == Collect.by_tag(session, :fact_retracted)
    end

    defmodule SameLhs do
      use Rete.Ruleset

      defrule a({:t, x}) do
        {:a, x}
      end

      defrule b({:t, x}) do
        {:b, x}
      end
    end

    # clara test_rules/test-multiple-rules-same-fact and
    # test-multiple-equiv-rhs-different-metadata (PR 145). Two rules with an
    # identical left hand side share every node up to the terminal and still get
    # a terminal each, so both right hand sides run.
    test "two rules with the same left hand side both fire" do
      session = run(SameLhs, [{:t, 1}])

      assert [{:a, 1}, {:b, 1}, {:t, 1}] == session |> Session.facts() |> Enum.sort()
    end
  end

  # --- gates -------------------------------------------------------------------------------

  describe "gate truth tables" do
    defmodule Gates do
      use Rete.Ruleset

      defrule and_r({:c, i}, {:and, [{:p, i}, {:q, i}]}) do
        {:and, i}
      end

      defrule nor_r({:c, i}, {:nor, [{:p, i}, {:q, i}]}) do
        {:nor, i}
      end

      defrule xnor_r({:c, i}, {:xnor, [{:p, i}, {:q, i}]}) do
        {:xnor, i}
      end

      defrule xor3_r({:c, i}, {:xor, [{:p, i}, {:q, i}, {:r, i}]}) do
        {:xor3, i}
      end
    end

    # Clara has no `xor`/`xnor`/`nor` to inherit a convention from, so this is
    # the table `Rete.DSL.Normalize` documents, checked end to end rather than
    # at the IR. The three-argument `xor` is the interesting row: "exactly one",
    # not odd parity, so all three true is false.
    test "the gates behave as documented, per binding group" do
      table = [
        {[], [nor: 1], [xnor: 1], [], []},
        {[{:p, 1}], [], [], [], [xor3: 1]},
        {[{:q, 1}], [], [], [], [xor3: 1]},
        {[{:p, 1}, {:q, 1}], [], [xnor: 1], [and: 1], []},
        {[{:p, 1}, {:r, 1}], [], [], [], []},
        {[{:p, 1}, {:q, 1}, {:r, 1}], [], [xnor: 1], [and: 1], []}
      ]

      for {extra, nor, xnor, conj, xor3} <- table do
        session = run(Gates, [{:c, 1} | extra])
        label = inspect(extra)

        assert nor == tagged(session, :nor), "nor for #{label}"
        assert xnor == tagged(session, :xnor), "xnor for #{label}"
        assert conj == tagged(session, :and), "and for #{label}"
        assert xor3 == tagged(session, :xor3), "xor for #{label}"
      end
    end
  end

  # --- taxonomy ------------------------------------------------------------------------------

  describe "taxonomy" do
    defmodule CommonAncestor do
      use Rete.Ruleset

      derive :type1, :marker
      derive :type2, :marker

      defquery markers(m = {:marker}) do
        m
      end
    end

    # clara test_rules/test-retract-diff-types-equal-fields-common-ancestor-type.
    # Two facts of different types reach one condition through a shared
    # ancestor. They are distinct facts, so retracting one — twice, to be sure —
    # must never touch the other. Clara needed this because the JVM compares
    # records field-wise; here the risk is a retraction keyed on the condition
    # rather than on the fact.
    test "retracting one descendant type does not retract its sibling" do
      base = run(CommonAncestor, [{:type1}, {:type2}])

      assert [{:type1}, {:type2}] == base |> CommonAncestor.markers() |> Enum.sort()

      once = base |> Session.retract({:type1}) |> Session.fire_rules()
      twice = once |> Session.retract({:type1}) |> Session.fire_rules()

      assert [{:type2}] == CommonAncestor.markers(once)
      assert [{:type2}] == CommonAncestor.markers(twice)
      assert once.state.memory == twice.state.memory
    end
  end

  # --- the invariants, over everything at once -------------------------------------------------

  describe "invariants over a ruleset using every feature" do
    defmodule Everything do
      use Rete.Ruleset

      derive :premium, :customer

      defrule loyalty({:customer, cid}, orders = [{:order, cid, _amt}]) do
        {:loyalty, cid, length(orders)}
      end

      defrule flagged({:threshold, t}, {:order, cid, amt} when amt > t) do
        {:flagged, cid, amt}
      end

      defrule dormant({:customer, cid}, {:not, [{:order, cid, _amt}]}) do
        {:dormant, cid}
      end

      defrule clean({:customer, cid}, {:nand, [{:order, cid, _amt}, {:refund, cid}]}) do
        {:clean, cid}
      end

      defrule tagged({:or, [{:gold, cid}, {:silver, cid}]}, {:order, cid, amt}) do
        {:tagged, cid, amt}
      end

      defrule escalate({:flagged, cid, _amt}) do
        {:escalated, cid}
      end
    end

    @facts [
      {:threshold, 100},
      {:premium, 1},
      {:customer, 2},
      {:gold, 1},
      {:silver, 2},
      {:order, 1, 250},
      {:order, 1, 50},
      {:order, 2, 10},
      {:refund, 1}
    ]

    defp everything, do: run(Everything, @facts)

    # A Rete network's conclusions are a function of the facts. This is checked
    # over a ruleset combining a collection, a negation, a compound negation, a
    # disjunction, a taxonomy and a derived-fact chain, because order dependence
    # tends to live where two of those meet.
    test "the derived state does not depend on insertion order" do
      base = everything()
      expected = base |> Session.facts() |> Enum.sort()

      permutations = [
        Enum.reverse(@facts),
        Enum.sort(@facts),
        Enum.sort_by(@facts, &:erlang.phash2/1)
      ]

      for permutation <- permutations do
        session = run(Everything, permutation)

        assert expected == session |> Session.facts() |> Enum.sort()

        # Sharper than the fact list: the support counts and the truth
        # maintenance records have to match too, or one order built an
        # imbalance the fact list cannot show.
        #
        # `memory.tokens` is deliberately *not* compared. Beta memory keeps the
        # token list for a join key in arrival order, so two orders that agree
        # on every match still disagree on the order of the list holding them —
        # which also makes the order of `Session.query/3` results depend on
        # insertion history. See the note reported alongside this suite; the
        # sets agree, only their order does not.
        expected = Rete.Memory.dump(base.state.memory)
        actual = Rete.Memory.dump(session.state.memory)

        assert expected.facts == actual.facts
        assert expected.accum == actual.accum
        assert expected.insertions == actual.insertions
        assert sorted_leaves(expected.tokens) == sorted_leaves(actual.tokens)
      end
    end

    test "inserting one at a time matches inserting together" do
      together = everything()

      separately =
        Enum.reduce(@facts, Session.new([Everything]), fn fact, session ->
          session |> Session.insert(fact) |> Session.fire_rules()
        end)

      assert Enum.sort(Session.facts(together)) == Enum.sort(Session.facts(separately))
      assert together.state.memory.facts == separately.state.memory.facts
    end

    # Every fact, not just an added one: an imbalance built while assembling the
    # fixture only shows when the fact that caused it is the one taken away.
    test "removing and restoring any single fact restores the derived state" do
      base = everything()
      expected = base |> Session.facts() |> Enum.sort()

      for fact <- @facts do
        restored =
          base
          |> Session.retract(fact)
          |> Session.fire_rules()
          |> Session.insert(fact)
          |> Session.fire_rules()

        assert expected == restored |> Session.facts() |> Enum.sort(),
               "round trip changed the session for #{inspect(fact)}"

        # Not the whole memory: retracting and reinserting a fact moves its
        # token to the end of the arrival-ordered list under its join key, so
        # `memory` is not restored byte for byte even though every match is.
        # Everything that carries meaning is compared.
        assert base.state.memory.facts == restored.state.memory.facts,
               "support counts changed for #{inspect(fact)}"

        assert base.state.memory.accum == restored.state.memory.accum,
               "collection groups changed for #{inspect(fact)}"

        assert base.state.memory.insertions == restored.state.memory.insertions,
               "truth maintenance records changed for #{inspect(fact)}"
      end
    end

    test "adding and removing a fact the fixture never had restores the derived state" do
      base = everything()
      expected = base |> Session.facts() |> Enum.sort()

      for extra <- [{:order, 3, 5}, {:customer, 3}, {:premium, 4}, {:refund, 2}, {:gold, 2}] do
        cycled =
          base
          |> Session.insert(extra)
          |> Session.fire_rules()
          |> Session.retract(extra)
          |> Session.fire_rules()

        assert expected == cycled |> Session.facts() |> Enum.sort(),
               "round trip changed the session for #{inspect(extra)}"

        assert Rete.Memory.dump(base.state.memory) == Rete.Memory.dump(cycled.state.memory),
               "memory changed for #{inspect(extra)}"
      end
    end

    # The invariant that catches leaks nothing else can see: a drained session
    # must equal a *fresh* one, which pins both "everything went" and "exactly
    # one root token".
    test "retracting everything returns the memory a fresh session starts with" do
      emptied = everything() |> drain(@facts)

      assert [] == Session.facts(emptied)
      assert [] == Session.pending(emptied)
      assert Session.new([Everything]).state.memory == emptied.state.memory
    end

    # Churn, because a leak that costs one map entry per entity is invisible in
    # a single pass and unbounded over a long-lived session.
    test "repeated churn does not grow any memory" do
      fresh = Session.new([Everything]).state.memory

      Enum.reduce(1..3, Session.new([Everything]), fn round, session ->
        settled =
          session
          |> Session.insert(@facts)
          |> Session.fire_rules()
          |> drain(@facts)

        assert fresh == settled.state.memory, "memory grew in round #{round}"
        settled
      end)
    end

    # Only the compound negation's marker is concluded twice here — customer 1
    # has two orders and a refund, so the helper matches twice. Everything else
    # rests on exactly one match, and a count above one anywhere else is a node
    # that propagated something it had already propagated.
    test "no conclusion has more support than the matches behind it" do
      session = everything()

      marker? = fn
        fact when is_tuple(fact) and tuple_size(fact) == 2 ->
          fact |> elem(0) |> to_string() =~ "__neg_"

        _ ->
          false
      end

      duplicated =
        for {fact, count} <- session.state.memory.facts, count != 1, do: {fact, count}

      assert [{marker, 2}] = duplicated
      assert marker?.(marker), "#{inspect(marker)} is held twice and is not a negation marker"
      assert %{cid: 1} == elem(marker, 1)
    end
  end
end
