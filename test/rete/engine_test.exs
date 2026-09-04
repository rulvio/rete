defmodule Rete.EngineTest do
  use ExUnit.Case, async: true

  alias Rete.Listener.Collect
  alias Rete.Session
  alias Rete.Test.Canon

  defp run(mod, facts) do
    mod |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp derived(session, tag) do
    session
    |> Session.facts()
    |> Enum.filter(&(is_tuple(&1) and elem(&1, 0) == tag))
    |> Enum.sort()
  end

  # --- joins ---------------------------------------------------------------------

  describe "joins" do
    defmodule Joins do
      use Rete.Ruleset

      defrule pair({:customer, cid, name}, {:order, cid, amt}) do
        {:pair, name, amt}
      end
    end

    test "a shared variable joins two conditions" do
      session =
        run([Joins], [
          {:customer, 1, "Ada"},
          {:customer, 2, "Bo"},
          {:order, 1, 10},
          {:order, 2, 20}
        ])

      assert [{:pair, "Ada", 10}, {:pair, "Bo", 20}] == derived(session, :pair)
    end

    test "facts that do not share the join key do not pair" do
      session = run([Joins], [{:customer, 1, "Ada"}, {:order, 99, 10}])
      assert [] == derived(session, :pair)
    end

    test "a join produces one match per combination" do
      session =
        run([Joins], [{:customer, 1, "Ada"}, {:order, 1, 10}, {:order, 1, 20}])

      assert [{:pair, "Ada", 10}, {:pair, "Ada", 20}] == derived(session, :pair)
    end

    defmodule NoKey do
      use Rete.Ruleset

      defrule product({:a, x}, {:b, y}) do
        {:product, x, y}
      end
    end

    # A later condition sharing no variable is a cartesian product, not a fresh
    # start. Getting this wrong makes the second condition manufacture matches of
    # its own and lose the first condition's bindings entirely.
    test "a later condition with no shared variable is a cartesian product" do
      session = run([NoKey], [{:a, 1}, {:a, 2}, {:b, :x}, {:b, :y}])

      assert [
               {:product, 1, :x},
               {:product, 1, :y},
               {:product, 2, :x},
               {:product, 2, :y}
             ] == derived(session, :product)
    end
  end

  # --- guards and salience ----------------------------------------------------------

  describe "guards" do
    defmodule Guards do
      use Rete.Ruleset

      defrule local({:order, amt} when amt > 100) do
        {:big, amt}
      end

      defrule cross({:threshold, t}, {:score, s} when s > t) do
        {:over, s}
      end
    end

    test "a guard over the condition's own variables filters at the alpha" do
      session = run([Guards], [{:order, 50}, {:order, 500}])
      assert [{:big, 500}] == derived(session, :big)
    end

    test "a guard reading an upstream variable filters at the join" do
      session = run([Guards], [{:threshold, 10}, {:score, 5}, {:score, 50}])
      assert [{:over, 50}] == derived(session, :over)
    end
  end

  describe "salience" do
    defmodule Salience do
      use Rete.Ruleset

      defrule low(%{salience: 1}, {:go, _}) do
        {:step, :low}
      end

      defrule high(%{salience: 100}, {:go, _}) do
        {:step, :high}
      end

      defrule mid(%{salience: 50}, {:go, _}) do
        {:step, :mid}
      end
    end

    # Read the firing order rather than the agenda. Nothing propagates until
    # `fire_rules/2`, so there is no pre-fire agenda to inspect. Salience promises
    # an order of firing anyway.
    test "higher salience fires first" do
      order =
        [Salience]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:go, 1})
        |> Session.fire_rules()
        |> Collect.by_tag(:activation_fired)
        |> Enum.map(fn {:activation_fired, source, _token, _facts} -> elem(source.rule, 1) end)

      assert [:high, :mid, :low] == order
    end
  end

  # --- propagation order ------------------------------------------------------------

  describe "join groups" do
    defmodule Groups do
      use Rete.Ruleset

      # `{:tick}` binds nothing, so every seed token sits under one join key
      # there and the tick joins all of them in a single propagation. Those
      # tokens then reach the `:sink` join with a *different* key each, which is
      # what makes one batch split into many groups.
      defrule pair({:seed, x}, {:tick}, {:sink, x}) do
        {:paired, x}
      end
    end

    defp fired_order(n) do
      seeds = for i <- 1..n, do: {:seed, i}
      sinks = for i <- 1..n, do: {:sink, i}

      [Groups]
      |> Session.new()
      |> Session.with_listener(Collect, [])
      |> Session.insert(seeds ++ sinks)
      |> Session.insert({:tick})
      |> Session.fire_rules()
      |> Collect.by_tag(:activation_fired)
      |> Enum.map(fn {:activation_fired, _source, token, _facts} -> token.bindings[:x] end)
    end

    # Groups come out of a map, and Elixir iterates a map of up to 32 keys in
    # term order and a larger one in an internal hash order. Taking that order
    # would mean a rule firing its matches in a different sequence as soon as a
    # node saw its 33rd join key — a behavior change triggered by data volume,
    # on a session that is otherwise deterministic.
    test "matches fire in arrival order however many join keys there are" do
      assert Enum.to_list(1..5) == fired_order(5)
      assert Enum.to_list(1..40) == fired_order(40), "order changed past the 32 key boundary"
    end

    test "the same facts always fire in the same order" do
      assert fired_order(40) == fired_order(40)
    end
  end

  describe "arrival order across two parents" do
    defmodule TwoParents do
      use Rete.Ruleset

      # Both branches match every `{:n, _}` here, and they are different alpha
      # expressions, so one fact produces two elements that re-converge on one
      # terminal. This is the only shape where a rule's matches reach the agenda
      # by more than one route within a single insert call.
      defrule hit({:or, [{:n, x} when x > 0, {:n, x} when x < 100]}) do
        {:hit, x}
      end
    end

    # `Rete.Engine.coalesce/1` merges the ops of one call that go the same way to
    # the same node, so a node sees a batch rather than one element per call.
    # That fixes the order here: all of one branch, then all of the other. Before
    # it was fact-major — both branches of the first fact, then both of the
    # second — which is just as defensible, and is the order this used to have.
    #
    # This is pinned rather than left to the suite because the suite stayed green
    # through the change: nothing else looks at the sequence, only at what the
    # session settles to, and both orders settle to the same facts.
    test "one fact reaching a rule twice fires branch by branch, not fact by fact" do
      fired =
        [TwoParents]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert([{:n, 5}, {:n, 6}])
        |> Session.fire_rules()
        |> Collect.by_tag(:activation_fired)
        |> Enum.map(fn {:activation_fired, _source, token, _facts} -> token.bindings.x end)

      assert [5, 6, 5, 6] == fired
    end

    # The promise that did not change, and the one rules actually rest on.
    test "a rule's own matches still arrive in fact order" do
      assert Enum.to_list(1..40) == fired_order(40)
    end
  end

  # --- taxonomy -----------------------------------------------------------------------

  describe "taxonomy" do
    defmodule Taxo do
      use Rete.Ruleset

      derive :premium, :customer
      derive :customer, :party

      defrule any_party({:party, id}) do
        {:party_seen, id}
      end

      defrule only_premium({:premium, id}) do
        {:premium_seen, id}
      end
    end

    test "a fact reaches conditions written against its ancestors" do
      session = run([Taxo], [{:premium, 1}])

      assert [{:party_seen, 1}] == derived(session, :party_seen)
      assert [{:premium_seen, 1}] == derived(session, :premium_seen)
    end

    test "a fact does not reach conditions written against its descendants" do
      session = run([Taxo], [{:party, 1}])

      assert [{:party_seen, 1}] == derived(session, :party_seen)
      assert [] == derived(session, :premium_seen)
    end
  end

  # --- negation --------------------------------------------------------------------------

  describe "negation" do
    defmodule Neg do
      use Rete.Ruleset

      defrule dormant({:customer, cid}, {:not, [{:order, cid}]}) do
        {:dormant, cid}
      end
    end

    test "a token passes while nothing matches" do
      session = run([Neg], [{:customer, 1}, {:customer, 2}, {:order, 1}])
      assert [{:dormant, 2}] == derived(session, :dormant)
    end

    test "the negation is scoped to its binding group" do
      session = run([Neg], [{:customer, 1}, {:customer, 2}, {:order, 2}])
      assert [{:dormant, 1}] == derived(session, :dormant)
    end

    test "inserting a matching fact suppresses an already fired conclusion" do
      session =
        [Neg]
        |> Session.new()
        |> Session.insert([{:customer, 1}])
        |> Session.fire_rules()

      assert [{:dormant, 1}] == derived(session, :dormant)

      session = session |> Session.insert({:order, 1}) |> Session.fire_rules()
      assert [] == derived(session, :dormant)
    end

    test "retracting the last matching fact releases the token again" do
      session = run([Neg], [{:customer, 1}, {:order, 1}])
      assert [] == derived(session, :dormant)

      session = session |> Session.retract({:order, 1}) |> Session.fire_rules()
      assert [{:dormant, 1}] == derived(session, :dormant)
    end

    test "one of two matching facts leaving does not release the token" do
      session = run([Neg], [{:customer, 1}, {:order, 1}, {:order, 1}])
      session = session |> Session.retract({:order, 1}) |> Session.fire_rules()

      # The fact was inserted twice, so one retraction leaves it present.
      assert [] == derived(session, :dormant)
    end
  end

  # --- collections -----------------------------------------------------------------------

  describe "collections" do
    defmodule Coll do
      use Rete.Ruleset

      defrule tally({:customer, cid}, orders = [{:order, cid, _amt}]) do
        {:tally, cid, length(orders)}
      end
    end

    test "a collection gathers every matching fact" do
      session = run([Coll], [{:customer, 1}, {:order, 1, 10}, {:order, 1, 20}])
      assert [{:tally, 1, 2}] == derived(session, :tally)
    end

    # The locked empty-collection rule: no new variables means one group, which
    # exists whether or not a fact ever landed in it.
    test "a collection binding no new variables fires with an empty list" do
      session = run([Coll], [{:customer, 1}])
      assert [{:tally, 1, 0}] == derived(session, :tally)
    end

    test "adding a fact replaces the previous collection rather than adding to it" do
      session = run([Coll], [{:customer, 1}, {:order, 1, 10}])
      assert [{:tally, 1, 1}] == derived(session, :tally)

      session = session |> Session.insert({:order, 1, 20}) |> Session.fire_rules()
      assert [{:tally, 1, 2}] == derived(session, :tally)
    end

    test "removing a fact shrinks the collection" do
      session = run([Coll], [{:customer, 1}, {:order, 1, 10}, {:order, 1, 20}])
      session = session |> Session.retract({:order, 1, 20}) |> Session.fire_rules()

      assert [{:tally, 1, 1}] == derived(session, :tally)
    end

    defmodule Grouped do
      use Rete.Ruleset

      # `day` is matched by a second collection, so it is a real join and groups
      # the first one. A plain condition matching `day` would sort *before* the
      # collection and make it an ordinary join key instead, and a `day` read
      # only by the right hand side is local to the collection and rejected —
      # see Rete.DSL.Bindings.mark_inert/1.
      defrule per_day(
                {:customer, cid},
                orders = [{:order, cid, day, _amt}],
                notes = [{:note, cid, day}]
              ) do
        {:per_day, cid, length(orders), length(notes)}
      end
    end

    test "a collection binding a new variable groups by it" do
      session =
        run([Grouped], [
          {:customer, 1},
          {:order, 1, :mon, 10},
          {:order, 1, :mon, 20},
          {:order, 1, :tue, 30}
        ])

      # One activation per day, and the second collection is empty on both.
      assert [{:per_day, 1, 1, 0}, {:per_day, 1, 2, 0}] == derived(session, :per_day)
    end

    # A group only exists where a fact created it, so there is no empty group.
    test "a grouping collection does not fire with an empty list" do
      session = run([Grouped], [{:customer, 1}])
      assert [] == derived(session, :per_day)
    end

    # Changing one group must leave the others untouched. A node that re-sends
    # every group on every change gives the unchanged ones a second support, and
    # the facts look right until something is retracted and refuses to go.
    test "changing one group does not re-send the others" do
      session =
        run([Grouped], [
          {:customer, 1},
          {:order, 1, :mon, 10},
          {:order, 1, :tue, 20}
        ])

      assert [{:per_day, 1, 1, 0}] == derived(session, :per_day)

      session = session |> Session.insert({:order, 1, :mon, 30}) |> Session.fire_rules()
      assert [{:per_day, 1, 1, 0}, {:per_day, 1, 2, 0}] == derived(session, :per_day)

      # Tuesday was never touched, so one retraction has to remove it.
      session = session |> Session.retract({:order, 1, :tue, 20}) |> Session.fire_rules()
      assert [{:per_day, 1, 2, 0}] == derived(session, :per_day)
    end

    defmodule Ordered do
      use Rete.Ruleset

      defrule seq({:customer, cid}, os = [{:order, cid, _amt}]) do
        {:seq, cid, Enum.map(os, fn {_, _, amt} -> amt end)}
      end
    end

    # A collection gathers in **reverse arrival order** and does not sort. So a rule
    # that puts its collection into a conclusion, rather than reducing it to
    # something order-insensitive, produces a different fact for a different feed.
    # `docs/dsl.md` says a rule may not depend on the gathered order for exactly
    # this reason — sort in the right hand side if the order matters.
    #
    # The engine used to sort internally, which made such a rule stable by accident
    # and cost O(k) on every member change to do it, because the position had to be
    # found by walking. Nothing in the contract asked for it. Prepending is O(1) and
    # shares the whole tail. See `Rete.Memory.add_to_group/5`.
    test "a collection gathers in reverse arrival order, and does not sort" do
      forwards =
        run([Ordered], [{:customer, 1}, {:order, 1, 10}, {:order, 1, 20}, {:order, 1, 30}])

      backwards =
        run([Ordered], [{:customer, 1}, {:order, 1, 30}, {:order, 1, 20}, {:order, 1, 10}])

      assert [{:seq, 1, [30, 20, 10]}] == derived(forwards, :seq)
      assert [{:seq, 1, [10, 20, 30]}] == derived(backwards, :seq)
    end

    # The membership is a function of the fact set even though the order is not, so
    # a rule that reduces its collection to something order-insensitive — which is
    # what `docs/dsl.md` tells you to do — is order independent after all.
    test "what a collection holds does not depend on the order it was fed" do
      forwards =
        run([Ordered], [{:customer, 1}, {:order, 1, 10}, {:order, 1, 20}, {:order, 1, 30}])

      backwards =
        run([Ordered], [{:customer, 1}, {:order, 1, 30}, {:order, 1, 20}, {:order, 1, 10}])

      sorted = fn session ->
        for {:seq, cid, amts} <- derived(session, :seq), do: {cid, Enum.sort(amts)}
      end

      assert [{1, [10, 20, 30]}] == sorted.(forwards)
      assert sorted.(forwards) == sorted.(backwards)
    end

    # A member taken out and put back comes back at the **front**, not where it
    # was, because a collection gathers in arrival order. So the round trip
    # restores the membership and not the sequence, and a rule that puts its
    # collection into a conclusion sees that conclusion change. Pinned here so the
    # behavior is written down where someone will meet it, not so it is defended:
    # the sequence was never something a rule was entitled to.
    test "retracting and reinserting a collection member moves it to the front" do
      base = run([Ordered], [{:customer, 1}, {:order, 1, 10}, {:order, 1, 20}, {:order, 1, 30}])

      cycled =
        base
        |> Session.retract({:order, 1, 20})
        |> Session.fire_rules()
        |> Session.insert({:order, 1, 20})
        |> Session.fire_rules()

      assert [{:seq, 1, [30, 20, 10]}] == derived(base, :seq)
      assert [{:seq, 1, [20, 30, 10]}] == derived(cycled, :seq)

      # The conclusion is a different term, which is the whole point: a rule that
      # puts its collection into a fact is not order independent, and `docs/dsl.md`
      # says not to write one. What must still hold is everything else — the group
      # holds the same members, there is still exactly one `:seq`, and the round
      # trip left no support behind.
      assert Canon.dump(base).accum == Canon.dump(cycled).accum

      assert [{1, [10, 20, 30]}] ==
               for({:seq, cid, amts} <- derived(cycled, :seq), do: {cid, Enum.sort(amts)})

      assert base.state.memory.facts |> Map.values() |> Enum.sort() ==
               cycled.state.memory.facts |> Map.values() |> Enum.sort()
    end
  end

  # --- guarded negation and guarded collections ---------------------------------------------

  describe "guarded negation" do
    defmodule GuardedNeg do
      use Rete.Ruleset

      defrule ok({:limit, lim}, {:cust, cid}, {:not, [{:order, cid, amt} when amt > lim]}) do
        {:ok, cid}
      end
    end

    # Whether an element counts as a match depends on the token, so unlike a
    # plain negation the answer differs per token under one join key.
    test "only an element passing the filter suppresses its token" do
      session =
        run([GuardedNeg], [
          {:limit, 100},
          {:cust, 1},
          {:cust, 2},
          {:order, 1, 50},
          {:order, 2, 500}
        ])

      assert [{:ok, 1}] == derived(session, :ok)
    end

    test "retracting the suppressing element releases only its own token" do
      session =
        run([GuardedNeg], [
          {:limit, 100},
          {:cust, 1},
          {:cust, 2},
          {:order, 1, 500},
          {:order, 2, 900}
        ])

      assert [] == derived(session, :ok)

      session = session |> Session.retract({:order, 1, 500}) |> Session.fire_rules()
      assert [{:ok, 1}] == derived(session, :ok)
    end

    test "adding a non matching element does not suppress" do
      session = run([GuardedNeg], [{:limit, 100}, {:cust, 1}])
      assert [{:ok, 1}] == derived(session, :ok)

      session = session |> Session.insert({:order, 1, 50}) |> Session.fire_rules()
      assert [{:ok, 1}] == derived(session, :ok)
    end

    defmodule PerTokenLimit do
      use Rete.Ruleset

      # The limit comes from the token, so two tokens under the same join key
      # can disagree about whether the very same element matches.
      defrule ok({:tag, cid, lim}, {:not, [{:order, cid, amt} when amt > lim]}) do
        {:ok, cid, lim}
      end
    end

    # The sharpest form of "release only what was suppressed": both tokens share
    # the join key %{cid: 1}, one is suppressed and one is not, and only the
    # suppressed one may be released. Re-sending the other gives it a second
    # support that no retraction will clear.
    test "two tokens under one join key are released independently" do
      session =
        run([PerTokenLimit], [
          {:tag, 1, 100},
          {:tag, 1, 1000},
          {:order, 1, 500}
        ])

      assert [{:ok, 1, 1000}] == derived(session, :ok)

      session = session |> Session.retract({:order, 1, 500}) |> Session.fire_rules()
      assert [{:ok, 1, 100}, {:ok, 1, 1000}] == derived(session, :ok)

      # If the lim=1000 token had been re-sent it would survive this.
      session = session |> Session.retract({:tag, 1, 1000}) |> Session.fire_rules()
      assert [{:ok, 1, 100}] == derived(session, :ok)
    end

    # A retraction must release the tokens that were suppressed and *only* those.
    # Re-sending one that was already through duplicates its support, and the
    # symptom is invisible in the facts: the conclusion then survives the
    # retraction that should have removed it.
    test "a retraction does not re-send a token that was already through" do
      session =
        run([GuardedNeg], [
          {:limit, 100},
          {:cust, 1},
          {:cust, 2},
          {:order, 1, 500},
          {:order, 2, 50}
        ])

      # cust 2's order is under the limit, so cust 2 is already through.
      assert [{:ok, 2}] == derived(session, :ok)

      session = session |> Session.retract({:order, 1, 500}) |> Session.fire_rules()
      assert [{:ok, 1}, {:ok, 2}] == derived(session, :ok)

      # If cust 2 had been re-sent it would now have two supports and survive.
      session = session |> Session.retract({:cust, 2}) |> Session.fire_rules()
      assert [{:ok, 1}] == derived(session, :ok)
    end
  end

  describe "guarded collections" do
    defmodule GuardedColl do
      use Rete.Ruleset

      defrule over({:limit, lim}, {:cust, cid}, os = [{:order, cid, ref, amt} when amt > lim]) do
        {:over, cid, Enum.sort(Enum.map(os, fn {_, _, r, _} -> r end))}
      end
    end

    # `ref` and `amt` are bound by the collection's pattern and by nothing
    # else's, so both are *inert*: local to the collection, grouping nothing.
    # The node's `:new_bind` is therefore `[]` and it gathers one list per
    # `cid`, filtered by the join guard — not one singleton group per `ref`.
    # See the `Rete.IR.Coll` section of docs/design/ir.md.
    test "the filter decides membership per token" do
      session =
        run([GuardedColl], [
          {:limit, 100},
          {:cust, 1},
          {:order, 1, :a, 50},
          {:order, 1, :b, 500}
        ])

      assert [{:over, 1, [:b]}] == derived(session, :over)
    end
  end

  # --- gates end to end -------------------------------------------------------------------

  describe "compound negation" do
    defmodule Nand do
      use Rete.Ruleset

      defrule clean({:cust, cid}, {:nand, [{:order, cid}, {:refund, cid}]}) do
        {:clean, cid}
      end
    end

    # "no cid has BOTH" - not "(no orders) or (no refunds)", which is what de
    # Morgan would have given and which is false here.
    test "a negated conjunction is scoped to its binding group" do
      session =
        run([Nand], [
          {:cust, 1},
          {:cust, 2},
          {:cust, 3},
          {:order, 1},
          {:refund, 1},
          {:order, 2}
        ])

      assert [{:clean, 2}, {:clean, 3}] == derived(session, :clean)
    end

    # The marker is a real fact — the negation node matches on it — but it is how
    # the engine expresses a negated conjunction, not something the user's rules
    # concluded. A tuple named after a generated rule has no business in the
    # public fact list.
    test "the extracted marker does not leak into the public fact list" do
      session = run([Nand], [{:cust, 1}, {:order, 1}, {:refund, 1}])

      assert [{:cust, 1}, {:order, 1}, {:refund, 1}] == Enum.sort(Session.facts(session))

      # It is still a fact internally, which is what makes the negation work.
      assert Enum.any?(session.state.memory.facts, fn {fact, _count} ->
               is_tuple(fact) and to_string(elem(fact, 0)) =~ "__neg_"
             end)
    end

    test "completing the conjunction suppresses the conclusion" do
      session = run([Nand], [{:cust, 1}, {:order, 1}])
      assert [{:clean, 1}] == derived(session, :clean)

      session = session |> Session.insert({:refund, 1}) |> Session.fire_rules()
      assert [] == derived(session, :clean)

      session = session |> Session.retract({:refund, 1}) |> Session.fire_rules()
      assert [{:clean, 1}] == derived(session, :clean)
    end
  end

  describe "disjunction" do
    defmodule Or do
      use Rete.Ruleset

      defrule tagged({:or, [{:gold, cid}, {:silver, cid}]}, {:order, cid, amt}) do
        {:tagged, cid, amt}
      end
    end

    test "either branch satisfies the rule and neither invents matches" do
      session =
        run([Or], [
          {:gold, 1},
          {:silver, 2},
          {:bronze, 3},
          {:order, 1, 10},
          {:order, 2, 20},
          {:order, 3, 30}
        ])

      assert [{:tagged, 1, 10}, {:tagged, 2, 20}] == derived(session, :tagged)
    end

    test "a fact matching both branches does not double the conclusion" do
      session = run([Or], [{:gold, 1}, {:silver, 1}, {:order, 1, 10}])

      assert [{:tagged, 1, 10}] == derived(session, :tagged)

      # Two branches matched, so the conclusion has two supports and needs both
      # to go before it does.
      session = session |> Session.retract({:gold, 1}) |> Session.fire_rules()
      assert [{:tagged, 1, 10}] == derived(session, :tagged)

      session = session |> Session.retract({:silver, 1}) |> Session.fire_rules()
      assert [] == derived(session, :tagged)
    end
  end

  # --- deferred propagation ----------------------------------------------------------------

  describe "insert and retract queue work rather than doing it" do
    defmodule Deferred do
      use Rete.Ruleset

      defrule flag({:cust, id}, {:order, id, amt} when amt > 10), do: {:flagged, id, amt}
      defquery flagged({:flagged, id, amt}), do: {id, amt}
    end

    test "an unfired session holds facts and no matches" do
      session = Session.new([Deferred]) |> Session.insert([{:cust, 1}, {:order, 1, 250}])

      assert [{:cust, 1}, {:order, 1, 250}] == session |> Session.facts() |> Enum.sort()
      assert %{} == session.state.memory.tokens
      assert %{} == session.state.memory.elements
      assert 0 == Rete.Agenda.size(session.state.agenda)
      assert [] == Deferred.flagged(session)
      refute Session.settled?(session)

      assert [{1, 250}] == session |> Session.fire_rules() |> Deferred.flagged()
    end

    # The check a caller makes for itself, now that `pending/1` is gone. A query cannot
    # raise on an unfired session, because `[]` is a true answer about one. So this is
    # the only way to tell "no match" apart from "not matched yet".
    test "settled?/1 separates an unfired session from a settled one" do
      # Unsettled before any insert: `new/1` queues the root token for the first fire.
      fresh = Session.new([Deferred])
      refute Session.settled?(fresh)
      assert Session.settled?(Session.fire_rules(fresh))

      queued = Session.insert(fresh, {:cust, 1})
      refute Session.settled?(queued)
      assert Session.settled?(Session.fire_rules(queued))

      # A retraction queues work of its own, so firing once is not enough forever.
      retracted = queued |> Session.fire_rules() |> Session.retract({:cust, 1})
      refute Session.settled?(retracted)
      assert Session.settled?(Session.fire_rules(retracted))
    end

    # A duplicate bumps a count and queues nothing, so it cannot unsettle a session that
    # was already settled. The `:fact_duplicated` event says the same thing to a listener.
    test "settled?/1 stays true when an insert queues nothing" do
      settled =
        Session.new([Deferred]) |> Session.insert({:cust, 1}) |> Session.fire_rules()

      assert Session.settled?(Session.insert(settled, {:cust, 1}))
      refute Session.settled?(Session.insert(settled, {:cust, 2}))
    end

    # `docs/design/engine.md` §2 claims this. The queued insert and the queued retract keep
    # the order they arrived in, so they cancel when they drain. This compares the memory
    # struct, not the facts: a leftover element or token would not appear in `facts/1`.
    test "an insert and a retract queued together drain to a net no-op" do
      cancelled =
        Session.new([Deferred])
        |> Session.insert([{:cust, 1}, {:order, 1, 250}])
        |> Session.retract({:order, 1, 250})
        |> Session.fire_rules()

      never = Session.new([Deferred]) |> Session.insert({:cust, 1}) |> Session.fire_rules()

      assert never.state.memory == cancelled.state.memory
      assert [] == Deferred.flagged(cancelled)
    end

    # The test above does not exercise the merge window. It queues one op of each
    # direction, and a window only matters where a direction repeats around the other one.
    # These three tests do that, in the two arrangements and in the shape a caller writes.
    #
    # Each compares against the same calls with a fire after every one of them. That is the
    # reference: batching call boundaries must not change where the session lands. The
    # memory struct is the lens, because a stranded element or a phantom conclusion is
    # exactly the failure that `facts/1` alone can miss.
    test "insert, retract and insert of one fact across calls settles as one insert does" do
      churned =
        Session.new([Deferred])
        |> Session.insert({:cust, 1})
        |> Session.insert({:order, 1, 250})
        |> Session.retract({:order, 1, 250})
        |> Session.insert({:order, 1, 250})
        |> Session.fire_rules()

      straight =
        Session.new([Deferred])
        |> Session.insert([{:cust, 1}, {:order, 1, 250}])
        |> Session.fire_rules()

      assert straight.state.memory == churned.state.memory
      assert [{1, 250}] == Deferred.flagged(churned)

      # And the fact really is held once, not twice: one retraction empties it.
      emptied =
        churned |> Session.retract([{:cust, 1}, {:order, 1, 250}]) |> Session.fire_rules()

      assert [] == Session.facts(emptied)

      assert ([Deferred] |> Session.new() |> Session.fire_rules()).state.memory ==
               emptied.state.memory
    end

    # The mirror of the test above, and the arrangement that a merge over the whole queue
    # gets wrong. `right_retract[f], right[f], right_retract[f]` merged on direction alone
    # becomes `right_retract[f, f], right[f]`. The node then holds one element and removes
    # one, because `Rete.Memory.remove_elements/4` drops a retraction of what it does not
    # hold — and the insert that follows puts the element back for good. The fact is gone
    # from working memory, the element is not, and no later fire reaches it, because the
    # queue is empty and `settled?/1` answers `true`.
    #
    # The merge window is what stops it: a node's batch closes as soon as the opposite
    # direction reaches that node.
    test "retract, insert and retract of one fact across calls empties the session" do
      settled =
        Session.new([Deferred])
        |> Session.insert([{:cust, 1}, {:order, 1, 250}])
        |> Session.fire_rules()

      batched =
        settled
        |> Session.retract({:order, 1, 250})
        |> Session.insert({:order, 1, 250})
        |> Session.retract({:order, 1, 250})
        |> Session.fire_rules()

      stepwise =
        settled
        |> Session.retract({:order, 1, 250})
        |> Session.fire_rules()
        |> Session.insert({:order, 1, 250})
        |> Session.fire_rules()
        |> Session.retract({:order, 1, 250})
        |> Session.fire_rules()

      assert [{:cust, 1}] == Session.facts(batched)
      assert [] == Deferred.flagged(batched)
      assert stepwise.state.memory == batched.state.memory

      # Down to the element the join holds, which is where the stranding would show.
      assert ([Deferred]
              |> Session.new()
              |> Session.insert({:cust, 1})
              |> Session.fire_rules()).state.memory ==
               batched.state.memory
    end

    # The realistic shape: a value that changes twice, written as retract-then-insert, all
    # batched before one fire. Two of those in a row put a repeated direction on each side
    # of the other one, so this is the arrangement above wearing ordinary clothes.
    #
    # `{:flagged, 1, 200}` is what a bad merge leaves behind. Its supporting order is not in
    # working memory, and nothing ever takes it back.
    test "a batched update loop concludes only from the value the session ends on" do
      base = Session.new([Deferred]) |> Session.insert({:cust, 1}) |> Session.fire_rules()

      update = fn session ->
        session
        |> Session.retract({:order, 1, 100})
        |> Session.insert({:order, 1, 200})
        |> Session.retract({:order, 1, 200})
        |> Session.insert({:order, 1, 300})
      end

      first = base |> Session.insert({:order, 1, 100}) |> Session.fire_rules()

      batched = first |> update.() |> Session.fire_rules()

      stepwise =
        first
        |> Session.retract({:order, 1, 100})
        |> Session.fire_rules()
        |> Session.insert({:order, 1, 200})
        |> Session.fire_rules()
        |> Session.retract({:order, 1, 200})
        |> Session.fire_rules()
        |> Session.insert({:order, 1, 300})
        |> Session.fire_rules()

      assert [{:cust, 1}, {:flagged, 1, 300}, {:order, 1, 300}] ==
               batched |> Session.facts() |> Enum.sort()

      assert [{1, 300}] == Deferred.flagged(batched)
      assert stepwise.state.memory == batched.state.memory
    end

    # Feeds a fresh session, then fires it with a listener attached. Returns the settled
    # session and the batches each node was handed, which is the only place coalescing is
    # visible. A timing assertion would say the same thing unreliably.
    defp fed(feed) do
      session =
        [Deferred] |> Session.new() |> then(feed) |> Session.with_listener(Collect, [])

      settled = Session.fire_rules(session)

      batches =
        for {:propagated, op, node, count} <- Collect.by_tag(settled, :propagated),
            do: {op, node, count}

      {settled, batches}
    end

    # A fire coalesces the queue before it drains. So facts fed one call at a time reach
    # a node as one batch, exactly as if they arrived in a single call.
    #
    # The memory assertion alone does not test coalescing. These are 25 inserts of one
    # direction, so merging them changes how many calls a node gets and nothing else — the
    # feed settles the same with `coalesce_queue/1` deleted. Only the `:propagated` events
    # show the difference: 25 calls of one element each, instead of one call of 25.
    test "many insert calls settle and propagate the same as one batched call" do
      # Every amount is over the rule's threshold of 10, so all 25 match.
      orders = for i <- 1..25, do: {:order, 1, 100 + i}

      {batched, batched_ops} = fed(&Session.insert(&1, [{:cust, 1} | orders]))

      {one_at_a_time, drip_ops} =
        fed(fn session ->
          Enum.reduce(orders, Session.insert(session, {:cust, 1}), &Session.insert(&2, &1))
        end)

      assert batched.state.memory == one_at_a_time.state.memory
      assert Deferred.flagged(batched) == Deferred.flagged(one_at_a_time)
      assert 25 == length(Deferred.flagged(batched))

      assert batched_ops == drip_ops

      # The same claim stated on its own, so a failure names the property rather than a
      # difference between two lists: the orders enter the alpha network as one call of
      # 25, not 25 calls of one. Most of the other events are the 25 conclusions, which
      # the fire loop propagates one activation at a time whichever way the facts arrived.
      assert 1 == Enum.count(drip_ops, &match?({:right, _node, 25}, &1))
    end

    # A query and no rule, so a fire propagates the churn and nothing else. Every
    # `:propagated` event below is therefore one of these calls, with no conclusions in
    # between to read past.
    defmodule QueryOnly do
      use Rete.Ruleset

      defquery orders({:order, id, amt}), do: {id, amt}
    end

    # The merge window, stated where it is the only thing visible. A retraction splits the
    # inserts around it into two batches, and the inserts on each side still merge. Every
    # arrangement here settles the same, so the events are the only evidence that the
    # window exists at all.
    #
    # Read the counts: `2, 1, 2` is the window holding. `4, 1` is a merge on direction
    # alone, which puts every insert before the retraction whatever the caller wrote.
    test "a retraction splits the inserts around it, and each side still merges" do
      churned =
        [QueryOnly]
        |> Session.new()
        |> Session.fire_rules()
        |> Session.insert({:order, 1, 100})
        |> Session.insert({:order, 1, 200})
        |> Session.retract({:order, 1, 100})
        |> Session.insert({:order, 1, 300})
        |> Session.insert({:order, 1, 400})
        |> Session.with_listener(Collect, [])
        |> Session.fire_rules()

      assert [
               {:right, 2},
               {:right_retract, 1},
               {:right, 2},
               {:left, 2},
               {:left_retract, 1},
               {:left, 2}
             ] ==
               for(
                 {:propagated, op, _node, count} <- Collect.by_tag(churned, :propagated),
                 do: {op, count}
               )

      assert [{1, 200}, {1, 300}, {1, 400}] == churned |> QueryOnly.orders() |> Enum.sort()
    end
  end

  # --- the beta root -----------------------------------------------------------------------

  # Nothing binds before the first condition, so a rule that opens with a
  # negation, a collection or a test has no element to build its first token
  # from. Classic Rete seeds the beta root with one empty token, and every node
  # that needs a left input before any fact exists takes it from there. Without
  # it these rules are dead: they never fire, and nothing says so.
  describe "the root token" do
    defmodule LeadNeg do
      use Rete.Ruleset

      defrule alarm({:not, [{:silenced, _}]}, {:event, id}) do
        {:alarm, id}
      end

      defrule alarm2({:event, id}, {:not, [{:silenced, _}]}) do
        {:alarm2, id}
      end
    end

    test "a leading negation is the same rule as a trailing one" do
      session = run([LeadNeg], [{:event, 1}])

      assert [{:alarm, 1}] == derived(session, :alarm)
      assert [{:alarm2, 1}] == derived(session, :alarm2)
    end

    test "a leading negation is suppressed and released like any other" do
      session = run([LeadNeg], [{:event, 1}, {:silenced, :all}])
      assert [] == derived(session, :alarm)

      session = session |> Session.retract({:silenced, :all}) |> Session.fire_rules()
      assert [{:alarm, 1}] == derived(session, :alarm)
    end

    test "a leading negation round trips through insert and retract" do
      base = run([LeadNeg], [{:event, 1}])

      cycled =
        base
        |> Session.insert({:silenced, :all})
        |> Session.fire_rules()
        |> Session.retract({:silenced, :all})
        |> Session.fire_rules()

      assert base.state.memory == cycled.state.memory
    end

    defmodule LeadColl do
      use Rete.Ruleset

      defrule count(os = [{:o, _x}]) do
        {:count, length(os)}
      end

      defquery all(os = [{:o, _x}]) do
        os
      end
    end

    test "a rule whose only condition is a collection fires with the collection" do
      session = run([LeadColl], [{:o, 1}, {:o, 2}])

      assert [{:count, 2}] == derived(session, :count)

      # Sorted: the gathered order is not a contract, and the engine gathers in
      # reverse arrival order. What is being asserted is that both facts landed in
      # the one collection.
      assert [[{:o, 1}, {:o, 2}]] == session |> LeadColl.all() |> Enum.map(&Enum.sort/1)
    end

    # The case that forces the root token to be planted when the state is built
    # rather than on the first unit of propagation: nothing is ever inserted, so
    # nothing ever propagates, and the rule is still true of the empty session.
    test "a collection only rule fires over a session with no facts at all" do
      session = [LeadColl] |> Session.new() |> Session.fire_rules()

      assert [{:count, 0}] == Session.facts(session)
      assert [[]] == LeadColl.all(session)
    end

    # The collection binds no new variable, so by the locked rule it has one
    # group and that group still exists with nothing in it.
    test "a collection with no members left still fires with an empty list" do
      session = run([LeadColl], [{:o, 1}])
      assert [{:count, 1}] == derived(session, :count)

      session = session |> Session.retract({:o, 1}) |> Session.fire_rules()
      assert [{:count, 0}] == derived(session, :count)
    end

    defmodule LeadNand do
      use Rete.Ruleset

      # Extraction rewrites this into a helper plus `{:not, [marker]}`, so the
      # negating rule opens with a negation whatever the author wrote.
      defrule clean({:nand, [{:order, id}, {:refund, id}]}) do
        {:clean, :nobody}
      end
    end

    test "a rule whose only condition is a compound negation fires" do
      session = run([LeadNand], [{:order, 1}])
      assert [{:clean, :nobody}] == derived(session, :clean)

      session = session |> Session.insert({:refund, 1}) |> Session.fire_rules()
      assert [] == derived(session, :clean)

      session = session |> Session.retract({:refund, 1}) |> Session.fire_rules()
      assert [{:clean, :nobody}] == derived(session, :clean)
    end

    defmodule LeadXor do
      use Rete.Ruleset

      defrule odd({:xor, [{:p, i}, {:q, i}]}) do
        {:odd, i}
      end
    end

    # Normalization expands a xor into `or(and(p, not q), and(not p, q))`, so its
    # second branch opens with a negation. An unseeded root makes the whole
    # branch dead and silently degrades the gate to "p and not q".
    test "an xor is symmetric in its two branches" do
      assert [{:odd, 1}] == derived(run([LeadXor], [{:p, 1}]), :odd)
      assert [{:odd, 1}] == derived(run([LeadXor], [{:q, 1}]), :odd)
      assert [] == derived(run([LeadXor], [{:p, 1}, {:q, 1}]), :odd)
    end

    # The root token is permanent, but everything built on top of it is not.
    test "a rule opening with a negation drains its memories" do
      session = run([LeadNeg], [{:event, 1}, {:silenced, :all}])

      emptied =
        session
        |> Session.retract([{:event, 1}, {:silenced, :all}])
        |> Session.fire_rules()

      memory = emptied.state.memory

      assert %{} == memory.facts
      assert %{} == memory.elements, "elements left behind"
      assert %{} == memory.accum, "collection groups left behind"
      assert %{} == memory.insertions, "truth maintenance records left behind"

      # The root token is the one thing that stays, so "drained" is exactly "the
      # memory a settled empty session holds". That also pins how many root tokens
      # there are, which a "they are all empty tokens" check cannot see.
      #
      # Fired, not fresh: `new/1` queues the root token, and the first fire plants
      # it. So an unfired session has no tokens to compare against.
      settled = [LeadNeg] |> Session.new() |> Session.fire_rules()
      assert settled.state.memory == memory
    end

    # A production with no conditions at all is the degenerate case of everything
    # above. Its terminal hangs straight off the beta root, so the seeded token is
    # its whole match. That gives it exactly one activation, on the first fire, and
    # nothing a user can retract supports it.
    defmodule NoLhs do
      use Rete.Ruleset

      defrule startup do
        {:started, :once}
      end

      defrule salient(%{salience: 100}) do
        {:phase, :init}
      end

      defrule downstream({:phase, :init}) do
        {:phase, :ready}
      end

      defquery constant do
        :constant
      end
    end

    # `new/1` queues the root token, and the first fire propagates it. So a session
    # nobody has fired holds no facts and no activations. The rule still fires when
    # nobody inserts anything.
    test "a rule with no conditions queues nothing until the first fire" do
      fresh = Session.new([NoLhs])

      assert [] == Session.facts(fresh)
      assert 0 == Rete.Agenda.size(fresh.state.agenda)

      assert [{:started, :once}] == fresh |> Session.fire_rules() |> derived(:started)
    end

    test "a rule with no conditions fires exactly once, whatever is inserted" do
      session = run([NoLhs], [{:order, 1}, {:order, 2}, {:order, 3}])

      assert [{:started, :once}] == derived(session, :started)

      assert 1 ==
               session
               |> Rete.Inspect.fired()
               |> Enum.count(&(&1.rule == :startup))
    end

    # Its support is the root token, which no retraction reaches. So the one thing
    # that empties every other conclusion leaves this one standing.
    test "a conclusion with no conditions survives retracting every fact" do
      session = run([NoLhs], [{:order, 1}])

      emptied = session |> Session.retract({:order, 1}) |> Session.fire_rules()

      assert [{:started, :once}] == derived(emptied, :started)

      assert [%{origin: :derived, bindings: %{}, supports: []}] =
               Rete.Inspect.explain(emptied, {:started, :once})
    end

    test "a rule with no conditions honors salience and feeds rules below it" do
      session = [NoLhs] |> Session.new() |> Session.fire_rules()

      assert [{:phase, :init}, {:phase, :ready}] == derived(session, :phase)
    end

    # A query reads propagated state, so it answers nothing until the first fire.
    # After that the root token is its whole match, and no fact can add to or take
    # from that.
    test "a query with no conditions answers one row in every fired session" do
      assert [] == NoLhs.constant(Session.new([NoLhs]))

      assert [:constant] == [NoLhs] |> Session.new() |> Session.fire_rules() |> NoLhs.constant()

      loaded = run([NoLhs], [{:order, 1}, {:order, 2}])
      assert [:constant] == NoLhs.constant(loaded)

      emptied = loaded |> Session.retract([{:order, 1}, {:order, 2}]) |> Session.fire_rules()
      assert [:constant] == NoLhs.constant(emptied)
    end

    test "a query with no conditions binds nothing, so any filter is rejected" do
      session = [NoLhs] |> Session.new() |> Session.fire_rules()

      assert [:constant] == NoLhs.constant(session, [])

      assert_raise ArgumentError, ~r/binds \[\], and was given \[:id\]/, fn ->
        NoLhs.constant(session, id: 1)
      end
    end
  end

  # --- collection-local variables --------------------------------------------------------

  describe "a collection variable nothing else matches on is local to it" do
    defmodule Local do
      use Rete.Ruleset

      # `amt` is read only by the collection's own guard, so it constrains which
      # orders are gathered and does not group them. Before this rule existed
      # the collection grouped by `amt` and yielded one singleton group per
      # distinct amount, which is never what anyone means by a guarded
      # collection.
      defrule over({:limit, lim}, {:cust, cid}, os = [{:order, cid, amt} when amt > lim]) do
        {:over, cid, length(os)}
      end
    end

    test "a guarded collection gathers every matching fact" do
      session =
        run([Local], [
          {:limit, 100},
          {:cust, 1},
          {:order, 1, 50},
          {:order, 1, 500},
          {:order, 1, 900}
        ])

      assert [{:over, 1, 2}] == derived(session, :over)
    end

    # A local variable means one group, so the empty-collection rule applies.
    test "a guarded collection with no matches still fires with an empty list" do
      session = run([Local], [{:limit, 100}, {:cust, 1}, {:order, 1, 50}])
      assert [{:over, 1, 0}] == derived(session, :over)
    end

    test "it round trips and drains" do
      facts = [{:limit, 100}, {:cust, 1}, {:order, 1, 500}]
      session = run([Local], facts)

      emptied =
        Enum.reduce(facts, session, fn fact, s ->
          s |> Session.retract(fact) |> Session.fire_rules()
        end)

      assert Session.new([Local]).state.memory == emptied.state.memory
    end

    test "reading a local variable outside the collection is a compile error" do
      source = """
      defmodule Rete.EngineTest.ReadsLocal do
        use Rete.Ruleset

        defrule per_day({:cust, cid}, os = [{:order, cid, day, _a}]) do
          {:per_day, cid, day, length(os)}
        end
      end
      """

      error = assert_raise ArgumentError, fn -> Code.compile_string(source) end

      assert error.message =~ "reads `day`, which is local to the collection"
      assert error.message =~ "Enum.group_by/2"
    end
  end

  # --- truth maintenance ----------------------------------------------------------------

  describe "truth maintenance" do
    defmodule Chain do
      use Rete.Ruleset

      defrule a_to_b({:a, x}) do
        {:b, x}
      end

      defrule b_to_c({:b, x}) do
        {:c, x}
      end

      defrule c_to_d({:c, x}) do
        {:d, x}
      end
    end

    test "conclusions chain" do
      session = run([Chain], [{:a, 1}])

      assert [{:b, 1}] == derived(session, :b)
      assert [{:c, 1}] == derived(session, :c)
      assert [{:d, 1}] == derived(session, :d)
    end

    test "retracting the support retracts the whole chain" do
      session = run([Chain], [{:a, 1}])
      session = session |> Session.retract({:a, 1}) |> Session.fire_rules()

      assert [] == Session.facts(session)
    end

    defmodule TwoSupports do
      use Rete.Ruleset

      defrule from_x({:x, id}) do
        {:derived, id}
      end

      defrule from_y({:y, id}) do
        {:derived, id}
      end
    end

    # Two rules independently concluding the same thing is not the same as one
    # rule concluding it twice. Removing one support must leave the fact standing.
    test "a fact with two supports survives losing one" do
      session = run([TwoSupports], [{:x, 1}, {:y, 1}])
      assert [{:derived, 1}] == derived(session, :derived)

      session = session |> Session.retract({:x, 1}) |> Session.fire_rules()
      assert [{:derived, 1}] == derived(session, :derived)

      session = session |> Session.retract({:y, 1}) |> Session.fire_rules()
      assert [] == derived(session, :derived)
    end

    test "a retraction before firing means the rule never fires" do
      session =
        [Chain]
        |> Session.new()
        |> Session.insert({:a, 1})
        |> Session.retract({:a, 1})
        |> Session.fire_rules()

      assert [] == Session.facts(session)
    end
  end

  # --- support has to be well founded, not just counted --------------------------------------

  describe "self supporting conclusions" do
    defp memories(session) do
      memory = session.state.memory
      Map.take(memory, [:facts, :elements, :tokens, :accum, :insertions, :inserters])
    end

    defmodule Symmetric do
      use Rete.Ruleset

      defrule symmetric({:edge, a, b}) do
        {:edge, b, a}
      end
    end

    # `{:edge, 2, 1}` is concluded from `{:edge, 1, 2}` and then concludes it
    # right back. Counting that as a support gives the user's own fact a second
    # one, and the count can never reach zero again.
    test "a conclusion that re-derives its premise does not support it" do
      session = run([Symmetric], [{:edge, 1, 2}])

      assert [{:edge, 1, 2}, {:edge, 2, 1}] == session |> Session.facts() |> Enum.sort()
      assert %{{:edge, 1, 2} => 1, {:edge, 2, 1} => 1} == session.state.memory.facts
    end

    test "retracting the only asserted fact empties every memory" do
      session = run([Symmetric], [{:edge, 1, 2}])
      session = session |> Session.retract({:edge, 1, 2}) |> Session.fire_rules()

      assert [] == Session.facts(session)

      assert %{
               facts: %{},
               elements: %{},
               tokens: %{},
               accum: %{},
               insertions: %{},
               inserters: nil
             } ==
               memories(session)
    end

    defmodule Idem do
      use Rete.Ruleset

      defrule idem({:a, x}) do
        {:a, x}
      end
    end

    # The degenerate case: a rule concluding exactly what it matched. One
    # insertion must still take one retraction.
    test "a rule concluding its own premise leaves it singly held" do
      session = run([Idem], [{:a, 1}])
      assert %{{:a, 1} => 1} == session.state.memory.facts

      session = session |> Session.retract({:a, 1}) |> Session.fire_rules()
      assert [] == Session.facts(session)
    end

    defmodule Cycle do
      use Rete.Ruleset

      defrule a_to_b({:a, x}) do
        {:b, x}
      end

      defrule b_to_c({:b, x}) do
        {:c, x}
      end

      defrule c_to_a({:c, x}) do
        {:a, x}
      end
    end

    # Not a special case of one or two steps: the support of a match is
    # everything it rests on, however far back that goes.
    test "a longer derivation cycle is not self supporting either" do
      session = run([Cycle], [{:a, 1}])

      assert %{{:a, 1} => 1, {:b, 1} => 1, {:c, 1} => 1} == session.state.memory.facts

      session = session |> Session.retract({:a, 1}) |> Session.fire_rules()

      assert [] == Session.facts(session)

      assert %{
               facts: %{},
               elements: %{},
               tokens: %{},
               accum: %{},
               insertions: %{},
               inserters: nil
             } ==
               memories(session)
    end

    defmodule Mirror do
      use Rete.Ruleset

      defrule mirror({:seed, x}) do
        {:mirror, x}
      end
    end

    # The other side of the same coin: a conclusion the rule does *not* rest on
    # is a genuine second support, even when the fact is already there. Rejecting
    # it would be as wrong as counting a circular one.
    test "a conclusion the user also asserted still has two supports" do
      session = run([Mirror], [{:seed, 1}, {:mirror, 1}])
      assert %{{:seed, 1} => 1, {:mirror, 1} => 2} == session.state.memory.facts

      session = session |> Session.retract({:mirror, 1}) |> Session.fire_rules()
      assert [{:mirror, 1}, {:seed, 1}] == session |> Session.facts() |> Enum.sort()

      session = session |> Session.retract({:seed, 1}) |> Session.fire_rules()
      assert [] == Session.facts(session)
    end

    # A collection match rests on every fact it gathered, not on the list.
    defmodule Gathered do
      use Rete.Ruleset

      defrule regather({:batch, id}, items = [{:item, id, _n}]) do
        for {:item, _, n} <- items, do: {:item, id, n}
      end
    end

    test "a collection re-concluding one of its own members does not support it" do
      session = run([Gathered], [{:batch, 1}, {:item, 1, 10}])
      assert %{{:batch, 1} => 1, {:item, 1, 10} => 1} == session.state.memory.facts

      session = session |> Session.retract([{:batch, 1}, {:item, 1, 10}]) |> Session.fire_rules()

      assert [] == Session.facts(session)

      assert %{
               facts: %{},
               elements: %{},
               tokens: %{},
               accum: %{},
               insertions: %{},
               inserters: nil
             } ==
               memories(session)
    end
  end

  # --- the invariants that catch most engine bugs -------------------------------------------

  describe "invariants" do
    defmodule Everything do
      use Rete.Ruleset

      derive :premium, :customer

      defrule loyalty({:customer, cid}, orders = [{:order, cid, _amt}]) do
        {:loyalty, cid, length(orders)}
      end

      defrule flagged({:threshold, t}, {:order, cid, amt} when amt > t) do
        {:flagged, cid, amt}
      end

      defrule dormant({:customer, cid}, {:not, [{:order, cid, _}]}) do
        {:dormant, cid}
      end

      defrule escalate({:flagged, cid, _}) do
        {:escalated, cid}
      end
    end

    @facts [
      {:threshold, 100},
      {:premium, 1},
      {:customer, 2},
      {:order, 1, 250},
      {:order, 1, 50},
      {:order, 2, 10}
    ]

    # The single most valuable property: inserting then retracting a fact must
    # return the session to exactly the state it was in before. Any node that
    # retracts something other than what it propagated shows up here.
    test "insert then retract restores the previous derived state" do
      base = run([Everything], @facts)
      before = Enum.sort(Session.facts(base))

      for extra <- [{:order, 1, 999}, {:customer, 3}, {:premium, 4}, {:order, 3, 5}] do
        after_cycle =
          base
          |> Session.insert(extra)
          |> Session.fire_rules()
          |> Session.retract(extra)
          |> Session.fire_rules()
          |> Session.facts()
          |> Enum.sort()

        assert before == after_cycle, "round trip changed the session for #{inspect(extra)}"
      end
    end

    # A Rete network's conclusions are a function of the facts, not of the order
    # they arrived in. Order dependence usually means a node is propagating from
    # what it was handed rather than from what its memory holds.
    test "the derived state does not depend on insertion order" do
      expected = @facts |> then(&run([Everything], &1)) |> Session.facts() |> Enum.sort()

      for permutation <- [
            Enum.reverse(@facts),
            Enum.sort(@facts),
            Enum.sort_by(@facts, &:erlang.phash2/1)
          ] do
        assert expected ==
                 permutation |> then(&run([Everything], &1)) |> Session.facts() |> Enum.sort()
      end
    end

    test "inserting facts one at a time matches inserting them together" do
      together = run([Everything], @facts)

      separately =
        Enum.reduce(@facts, Session.new([Everything]), fn fact, session ->
          session |> Session.insert(fact) |> Session.fire_rules()
        end)

      assert Enum.sort(Session.facts(together)) == Enum.sort(Session.facts(separately))
    end

    test "retracting everything empties the session" do
      session = run([Everything], @facts)

      emptied =
        Enum.reduce(@facts, session, fn fact, session ->
          session |> Session.retract(fact) |> Session.fire_rules()
        end)

      assert [] == Session.facts(emptied)
    end

    # Facts alone are too weak a lens. An over-propagating node inserts a token
    # that was already there, the duplicate fact collapses into a count bump, and
    # `facts/1` looks perfect — while a token sits stranded in beta memory that
    # nothing will ever retract. Emptying the session has to empty *everything*.
    test "retracting everything drains every memory, not just the facts" do
      session = run([Everything], @facts)

      emptied =
        Enum.reduce(@facts, session, fn fact, session ->
          session |> Session.retract(fact) |> Session.fire_rules()
        end)

      memory = emptied.state.memory

      # Exactly empty, not "empty once the bookkeeping is stripped". A node id
      # or a join key left pointing at an empty map is a leak: both hold binding
      # *values*, so they grow with entity cardinality and nothing ever reads
      # them again.
      assert %{} == memory.facts
      assert %{} == memory.elements, "elements left behind"
      assert %{} == memory.tokens, "tokens left behind"
      assert %{} == memory.accum, "collection groups left behind"
      assert %{} == memory.insertions, "truth maintenance records left behind"
    end

    # The leak the previous test used to hide: the innermost group was dropped
    # and the join key holding it was not, so every customer ever seen left an
    # empty entry behind. Facts and tokens drain, so only the accum map shows it,
    # and only across repeated churn.
    defmodule Churn do
      use Rete.Ruleset

      # Two collections sharing `day`, so the first genuinely groups by it —
      # which is what puts entries in the accum map to leak in the first place.
      defrule per_day(
                {:customer, cid},
                orders = [{:order, cid, day, _amt}],
                notes = [{:note, cid, day}]
              ) do
        {:per_day, cid, length(orders), length(notes)}
      end
    end

    test "churning entities through a grouping collection does not grow accum" do
      customers = for cid <- 1..10, do: {:customer, cid}
      orders = for cid <- 1..10, do: {:order, cid, :mon, cid}

      Enum.reduce(1..3, Session.new([Churn]), fn round, session ->
        session =
          session
          |> Session.insert(customers ++ orders)
          |> Session.fire_rules()
          |> Session.retract(customers ++ orders)
          |> Session.fire_rules()

        assert %{} == session.state.memory.accum, "accum grew in round #{round}"
        assert %{} == session.state.memory.facts, "facts left over in round #{round}"
        session
      end)
    end

    # Every fact, not just an added one: an imbalance created while building the
    # fixture only shows up when the fact that caused it is the one taken away.
    test "removing and restoring any single fact round trips" do
      base = run([Everything], @facts)
      before = Enum.sort(Session.facts(base))

      for fact <- @facts do
        restored =
          base
          |> Session.retract(fact)
          |> Session.fire_rules()
          |> Session.insert(fact)
          |> Session.fire_rules()
          |> Session.facts()
          |> Enum.sort()

        assert before == restored, "round trip changed the session for #{inspect(fact)}"
      end
    end

    # The counts themselves, not their shadow in `facts/1`. A fact propagated
    # twice needs two retractions to disappear, which is the observable symptom
    # of a node that sent a token it had already sent.
    test "one retraction is enough to remove a singly supported conclusion" do
      session = run([Everything], @facts)

      for {fact, count} <- session.state.memory.facts do
        assert count == 1, "#{inspect(fact)} is held #{count} times, expected once"
      end
    end

    test "the agenda is empty once rules have fired" do
      assert 0 == [Everything] |> run(@facts) |> then(&Rete.Agenda.size(&1.state.agenda))
    end
  end

  # --- duplicates ------------------------------------------------------------------------------

  describe "duplicate facts" do
    defmodule Dup do
      use Rete.Ruleset

      defrule seen({:thing, x}) do
        {:seen, x}
      end
    end

    test "inserting the same fact twice does not double its matches" do
      session = run([Dup], [{:thing, 1}, {:thing, 1}])
      assert [{:seen, 1}] == derived(session, :seen)
    end

    test "one retraction of a twice inserted fact leaves it present" do
      session = run([Dup], [{:thing, 1}, {:thing, 1}])
      session = session |> Session.retract({:thing, 1}) |> Session.fire_rules()

      assert [{:seen, 1}] == derived(session, :seen)

      session = session |> Session.retract({:thing, 1}) |> Session.fire_rules()
      assert [] == Session.facts(session)
    end

    test "retracting a fact that was never inserted does nothing" do
      session = run([Dup], [{:thing, 1}])

      assert session |> Session.retract({:thing, 99}) |> Session.fire_rules() |> Session.facts() ==
               Session.facts(session)
    end
  end

  # --- queries -----------------------------------------------------------------------------------

  describe "queries" do
    defmodule Queries do
      use Rete.Ruleset

      defrule flag({:order, cid, amt} when amt > 100) do
        {:flagged, cid, amt}
      end

      defquery flagged_for({:flagged, cid, amt}) do
        {cid, amt}
      end

      # The body decides the shape, so a query can return something that is in
      # no binding at all.
      defquery summary({:flagged, cid, amt}) do
        %{customer: cid, doubled: amt * 2}
      end
    end

    # The body is the point of a query. Returning the raw bindings instead would
    # make it dead code.
    test "a query returns what its body computes, not the bindings" do
      session = run([Queries], [{:order, 1, 250}, {:order, 2, 50}])

      assert [{1, 250}] == Queries.flagged_for(session)
      assert [%{customer: 1, doubled: 500}] == Queries.summary(session)
    end

    test "one result per match" do
      session = run([Queries], [{:order, 1, 250}, {:order, 1, 900}, {:order, 2, 300}])

      assert [{1, 250}, {1, 900}, {2, 300}] == Queries.flagged_for(session)
    end

    # No declaration: anything the left hand side binds can be constrained.
    test "any binding can be filtered on, as a keyword list or a map" do
      session = run([Queries], [{:order, 1, 250}, {:order, 1, 900}, {:order, 2, 300}])

      assert [{1, 250}, {1, 900}] == Queries.flagged_for(session, cid: 1)
      assert [{1, 250}] == Queries.flagged_for(session, cid: 1, amt: 250)
      assert [{2, 300}] == Queries.flagged_for(session, %{cid: 2})
      assert [] == Queries.flagged_for(session, cid: 99)
    end

    # Filtering happens on the bindings, before the body runs, which is what
    # makes a filter name a variable rather than a shape of the result.
    test "a filter names a binding even when the body hides it" do
      session = run([Queries], [{:order, 1, 250}, {:order, 2, 300}])

      assert [%{customer: 1, doubled: 500}] == Queries.summary(session, amt: 250)
    end

    test "a query reflects retraction" do
      session = run([Queries], [{:order, 1, 250}])
      assert [_] = Queries.flagged_for(session)

      session = session |> Session.retract({:order, 1, 250}) |> Session.fire_rules()
      assert [] == Queries.flagged_for(session)
    end

    # The query the generated function delegates to, for a query chosen at
    # runtime rather than written down.
    test "a query can be addressed by {module, name}" do
      session = run([Queries], [{:order, 1, 250}])

      assert [{1, 250}] == Session.query(session, {Queries, :flagged_for})
      assert [{1, 250}] == Session.query(session, {Queries, :flagged_for}, cid: 1)
    end

    test "an unknown query is an error naming what is available" do
      session = run([Queries], [])

      error =
        assert_raise ArgumentError, fn -> Session.query(session, {Queries, :nope}) end

      assert error.message =~ "no query Rete.EngineTest.Queries.nope"
      assert error.message =~ "Rete.EngineTest.Queries.flagged_for"
    end

    # A query in a module the session was never built from reads as a typo
    # unless the error says which rulesets are actually in there.
    test "a query from a module not in the session names the modules that are" do
      session = run([Queries], [])

      error =
        assert_raise ArgumentError, fn -> Session.query(session, {Elsewhere, :flagged_for}) end

      assert error.message =~ "no query Elsewhere.flagged_for"
      assert error.message =~ "Elsewhere contributed nothing to this session"
      assert error.message =~ "built from [Rete.EngineTest.Queries]"
    end

    # A bare name was how this worked before queries were module scoped, so the
    # error has to teach the new form rather than complain about a tuple.
    test "a bare query name is an error pointing at the module that defines it" do
      session = run([Queries], [])

      error = assert_raise ArgumentError, fn -> Session.query(session, :flagged_for) end

      assert error.message =~ "a query is named by {module, name}"
      assert error.message =~ "Rete.EngineTest.Queries.flagged_for(session, filters)"
      assert error.message =~ "{Rete.EngineTest.Queries, :flagged_for}"
    end

    test "a bare name nothing defines says so rather than guessing" do
      session = run([Queries], [])

      error = assert_raise ArgumentError, fn -> Session.query(session, :nope) end

      assert error.message =~ "No query of that name is defined here"
      assert error.message =~ "Rete.EngineTest.Queries.flagged_for"
    end

    # A filter naming something the query does not bind would silently match
    # nothing, which reads as "no results" rather than "you typoed".
    test "filtering on something the query does not bind is an error" do
      session = run([Queries], [])

      error =
        assert_raise ArgumentError, fn -> Queries.flagged_for(session, bogus: 1) end

      assert error.message =~ "binds [:amt, :cid]"
      assert error.message =~ "was given [:bogus]"
    end
  end

  # --- what a right hand side may return ------------------------------------------------------------

  describe "a right hand side that does not return facts" do
    defmodule Returns do
      use Rete.Ruleset

      # The classic: a body ending in Enum.each returns :ok.
      defrule oops({:go, x}) do
        Enum.each([x], fn _ -> :noop end)
      end

      defrule nothing({:quiet, _x}) do
        nil
      end

      defrule empty({:hush, _x}) do
        []
      end

      # A conditional that only sometimes concludes: the nil is dropped, the
      # rest is inserted.
      defrule some({:mixed, x}) do
        [{:kept, x}, if(x > 100, do: {:big, x})]
      end
    end

    # Without this the error comes from Rete.Taxonomy several frames down, names
    # the value and not the rule, and leaves you searching a ruleset for it.
    test "the error names the rule, its module and the match" do
      error =
        assert_raise ArgumentError, fn ->
          [Returns] |> Session.new() |> Session.insert({:go, 1}) |> Session.fire_rules()
        end

      assert error.message =~ "Rete.EngineTest.Returns.oops returned :ok, which is not a fact"
      assert error.message =~ "It fired on %{x: 1}"
      assert error.message =~ "tagged tuple"

      assert error.message =~ "cannot determine the fact type of :ok",
             "the original error should survive"
    end

    # Concluding nothing is ordinary, not an error: a rule may hold only under
    # conditions its body checks.
    test "nil and an empty list conclude nothing without raising" do
      session = run([Returns], [{:quiet, 1}, {:hush, 2}])

      assert [{:hush, 2}, {:quiet, 1}] == session |> Session.facts() |> Enum.sort()
    end

    test "a nil inside a returned list is dropped and the rest inserted" do
      session = run([Returns], [{:mixed, 5}, {:mixed, 500}])

      assert [{:big, 500}, {:kept, 5}, {:kept, 500}] ==
               derived(session, :big) ++ derived(session, :kept)
    end

    # The check runs per fact, so an offender among good facts is still caught.
    test "one bad fact among good ones is caught and named" do
      defmodule Mixed do
        use Rete.Ruleset

        defrule half({:go, x}) do
          [{:fine, x}, :not_a_fact]
        end
      end

      error =
        assert_raise ArgumentError, fn ->
          [Mixed] |> Session.new() |> Session.insert({:go, 1}) |> Session.fire_rules()
        end

      assert error.message =~ "half returned :not_a_fact"
    end
  end

  # --- the loop guard ------------------------------------------------------------------------------

  describe "runaway rules" do
    defmodule Oscillate do
      use Rete.Ruleset

      defrule grow({:counter, n}) do
        {:counter, n + 1}
      end
    end

    test "a ruleset that never settles raises instead of spinning" do
      error =
        assert_raise RuntimeError, fn ->
          [Oscillate]
          |> Session.new()
          |> Session.insert({:counter, 0})
          |> Session.fire_rules(max_cycles: 50)
        end

      assert error.message =~ "without the agenda emptying"
      assert error.message =~ "grow"
    end

    # Both lists in the message are cut to five. A cut that says nothing reads as
    # the whole story, and "still pending: 5 activations" is a very different
    # problem from five hundred.
    test "a truncated list says how much it left out" do
      defmodule Fanout do
        use Rete.Ruleset

        defrule grow({:counter, n}) do
          {:counter, n + 1}
        end

        # Piles up activations that never get a turn, so the agenda is long.
        defrule note({:counter, n}) do
          {:noted, n}
        end
      end

      error =
        assert_raise RuntimeError, fn ->
          [Fanout]
          |> Session.new()
          |> Session.insert({:counter, 0})
          |> Session.fire_rules(max_cycles: 30)
        end

      assert error.message =~ ~r/Still pending \(5 of \d+ activations\)/
      assert 5 == error.message |> String.split("Still pending") |> List.last() |> pending_lines()
    end

    defp pending_lines(tail) do
      tail
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "  Rete.EngineTest.Fanout."))
    end

    defmodule Bounded do
      use Rete.Ruleset

      # Bound by a fact rather than a literal, so the depth can be set per test.
      defrule step({:limit, limit}, {:n, i} when i < limit) do
        {:n, i + 1}
      end
    end

    # The guard is opt-in. A count cannot separate a runaway from a large
    # settling pass, so any default eventually raises on correct code — and a
    # rules engine that stops part way through settling has returned an answer
    # that is wrong, not late. 20,000 activations would have tripped both of the
    # defaults this has had.
    test "a long settling pass is not capped by default" do
      session =
        [Bounded]
        |> Session.new()
        |> Session.insert([{:limit, 20_000}, {:n, 0}])
        |> Session.fire_rules()

      assert {:n, 20_000} in Session.facts(session)
    end

    test "max_cycles: :infinity says the default out loud" do
      session =
        [Bounded]
        |> Session.new()
        |> Session.insert([{:limit, 5_000}, {:n, 0}])
        |> Session.fire_rules(max_cycles: :infinity)

      assert {:n, 5_000} in Session.facts(session)
    end

    # `fired >= nil` is false for every integer under Erlang term order, so an
    # unrecognized value would quietly mean :infinity — the guard silently off,
    # which is worse than either setting.
    test "an unrecognized max_cycles is rejected rather than read as no cap" do
      for bad <- [nil, -1, 1.5, "100"] do
        error =
          assert_raise ArgumentError, fn ->
            [Oscillate]
            |> Session.new()
            |> Session.insert({:counter, 0})
            |> Session.fire_rules(max_cycles: bad)
          end

        assert error.message =~ "must be a non-negative integer or :infinity"
        assert error.message =~ inspect(bad)
      end
    end

    # And says nothing when there is nothing to say.
    test "a short list is reported without a count" do
      error =
        assert_raise RuntimeError, fn ->
          [Oscillate]
          |> Session.new()
          |> Session.insert({:counter, 0})
          |> Session.fire_rules(max_cycles: 2)
        end

      assert error.message =~ "Still pending:"
      refute error.message =~ "of 1 activations"
    end

    # The message is only useful if it names something. A cap checked against the
    # count alone raises with an empty "still pending" list, which reads as a
    # runaway ruleset and is nothing of the kind.
    test "the error names a rule that really is still pending" do
      error =
        assert_raise RuntimeError, fn ->
          [Oscillate]
          |> Session.new()
          |> Session.insert({:counter, 0})
          |> Session.fire_rules(max_cycles: 1)
        end

      assert error.message =~ "grow"
    end

    defmodule Settles do
      use Rete.Ruleset

      defrule one({:go}) do
        {:done}
      end

      defrule two({:done}) do
        {:finished}
      end
    end

    # `max_cycles: n` permits n activations. A ruleset that fires exactly n and
    # then settles has not run away.
    test "a ruleset that fires exactly max_cycles activations settles" do
      session =
        [Settles]
        |> Session.new()
        |> Session.insert({:go})
        |> Session.fire_rules(max_cycles: 2)

      assert [{:done}, {:finished}, {:go}] == session |> Session.facts() |> Enum.sort()
      assert 0 == Rete.Agenda.size(session.state.agenda)
    end

    test "a single activation fires under a cap of one" do
      session =
        [Settles]
        |> Session.new()
        |> Session.insert({:done})
        |> Session.fire_rules(max_cycles: 1)

      assert [{:done}, {:finished}] == session |> Session.facts() |> Enum.sort()
    end

    # Nothing pending is nothing to run away from, whatever the cap.
    test "a cap of zero is fine when there is nothing to fire" do
      session = [Settles] |> Session.new() |> Session.fire_rules(max_cycles: 0)

      assert [] == Session.facts(session)
    end

    test "a cap of zero with an activation waiting raises" do
      assert_raise RuntimeError, ~r/Still pending:\n  Rete.EngineTest.Settles.one %\{\}/, fn ->
        [Settles] |> Session.new() |> Session.insert({:go}) |> Session.fire_rules(max_cycles: 0)
      end
    end
  end

  # --- sessions are values ----------------------------------------------------------------------------

  describe "immutability" do
    defmodule Simple do
      use Rete.Ruleset

      defrule echo({:in, x}) do
        {:out, x}
      end
    end

    test "an operation does not change the session it was given" do
      base = Session.new([Simple]) |> Session.insert({:in, 1}) |> Session.fire_rules()
      _other = base |> Session.insert({:in, 2}) |> Session.fire_rules()

      assert [{:out, 1}] == derived(base, :out)
    end

    test "two sessions over one network are independent" do
      network = Rete.Compiler.build([Simple])

      a = network |> Session.from_network() |> Session.insert({:in, :a}) |> Session.fire_rules()
      b = network |> Session.from_network() |> Session.insert({:in, :b}) |> Session.fire_rules()

      assert [{:out, :a}] == derived(a, :out)
      assert [{:out, :b}] == derived(b, :out)
    end
  end

  # --- concurrency -----------------------------------------------------------------

  describe "concurrency" do
    defmodule Slow do
      use Rete.Ruleset

      defrule work({:job, id}) do
        Process.sleep(20)
        {:done, id}
      end
    end

    defmodule Chained do
      use Rete.Ruleset

      defrule a({:seed, n}), do: {:middle, n}
      defrule b({:middle, n}), do: {:leaf, n}
      defrule c({:other, n}), do: {:tail, n}
    end

    defmodule Boom do
      use Rete.Ruleset

      defrule burst({:go, n}), do: {:out, div(10, n)}
      defrule thrown({:toss, n}), do: throw({:nope, n})
    end

    defmodule Spin do
      use Rete.Ruleset

      defrule grow({:counter, n}), do: {:counter, n + 1}
    end

    defmodule Cancel do
      use Rete.Ruleset

      # Both sit at salience 0, so both land in one activation group. `veto`'s conclusion
      # retracts the match behind `act`.
      defrule veto({:trigger, n}), do: {:blocked, n}
      defrule act({:task, n}, {:not, [{:blocked, n}]}), do: {:acted, n}
    end

    defp jobs(n), do: Enum.map(1..n, &{:job, &1})

    test "the bodies of one group run at once" do
      base = [Slow] |> Session.new() |> Session.insert(jobs(16))

      {serial_us, serial} = :timer.tc(fn -> Session.fire_rules(base, concurrency: 1) end)
      {parallel_us, parallel} = :timer.tc(fn -> Session.fire_rules(base, concurrency: 16) end)

      # 16 bodies sleeping 20 ms: ~320 ms one at a time, ~20 ms at once.
      assert serial_us > 250_000
      assert parallel_us < serial_us / 4
      assert derived(serial, :done) == derived(parallel, :done)
    end

    test "concurrency: 1 is the default and fires one body at a time" do
      base = [Slow] |> Session.new() |> Session.insert(jobs(4))

      {default_us, _} = :timer.tc(fn -> Session.fire_rules(base) end)
      {explicit_us, _} = :timer.tc(fn -> Session.fire_rules(base, concurrency: 1) end)

      assert default_us > 60_000
      assert explicit_us > 60_000
    end

    # Firing one at a time re-sorts the agenda after every activation, so `b`, activated by
    # `a`'s conclusion, overtakes the already pending `c`. A group is popped whole, so under
    # concurrency `b` waits for the next group. The session that results is identical, and
    # `Rete.Listener` reports the order the bodies actually ran in either way.
    test "a group is frozen when popped, so firing order can differ from sequential" do
      facts = [{:seed, 1}, {:other, 1}]

      order = fn concurrency ->
        [Chained]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert(facts)
        |> Session.fire_rules(concurrency: concurrency)
        |> Collect.by_tag(:activation_fired)
        |> Enum.map(fn {_tag, source, _token, _facts} -> elem(source.rule, 1) end)
      end

      assert [:a, :b, :c] == order.(1)
      assert [:a, :c, :b] == order.(4)

      same = fn concurrency ->
        [Chained]
        |> Session.new()
        |> Session.insert(facts)
        |> Session.fire_rules(concurrency: concurrency)
        |> Session.facts()
        |> Enum.sort()
      end

      assert same.(1) == same.(4)
    end

    test "a body that raises reports the same error whether or not it is concurrent" do
      for concurrency <- [1, 4] do
        assert_raise ArithmeticError, fn ->
          [Boom]
          |> Session.new()
          |> Session.insert([{:go, 0}])
          |> Session.fire_rules(concurrency: concurrency)
        end
      end
    end

    # The generated `__rhs_<name>__` frame is what names the rule, so a task must not
    # swallow the stacktrace and leave an opaque exit behind.
    test "a raising body still names its rule in the stacktrace from a task" do
      stacktrace =
        try do
          [Boom]
          |> Session.new()
          |> Session.insert([{:go, 0}])
          |> Session.fire_rules(concurrency: 4)

          flunk("expected the body to raise")
        rescue
          ArithmeticError -> __STACKTRACE__
        end

      assert Enum.any?(stacktrace, fn {mod, fun, _arity, _loc} ->
               mod == Boom and fun == :__rhs_burst__
             end)
    end

    test "a body that throws propagates the throw, concurrent or not" do
      for concurrency <- [1, 4] do
        thrown =
          catch_throw(
            [Boom]
            |> Session.new()
            |> Session.insert([{:toss, 7}])
            |> Session.fire_rules(concurrency: concurrency)
          )

        assert thrown == {:nope, 7}
      end
    end

    test "a body that outruns :timeout names its rule" do
      error =
        assert_raise RuntimeError, fn ->
          [Slow]
          |> Session.new()
          |> Session.insert(jobs(2))
          |> Session.fire_rules(concurrency: 2, timeout: 5)
        end

      assert error.message =~ "Rete.EngineTest.Slow.work did not finish"
      assert error.message =~ ":timeout"
    end

    # A cycle is one pass of the fire loop, so a group is one cycle however many
    # activations it holds. Raising :concurrency must not consume the allowance faster —
    # it fires the same work in fewer, larger cycles.
    test "max_cycles counts cycles, so a whole group is one of them" do
      base = [Chained] |> Session.new() |> Session.insert(Enum.map(1..500, &{:other, &1}))

      # 500 activations of one rule: 500 cycles one at a time, a single cycle as a group.
      assert_raise RuntimeError, ~r/fired 10 cycles/, fn ->
        Session.fire_rules(base, max_cycles: 10, concurrency: 1)
      end

      session = Session.fire_rules(base, max_cycles: 10, concurrency: 8)

      assert length(derived(session, :tail)) == 500
    end

    test "a runaway is still caught under concurrency" do
      for concurrency <- [1, 8] do
        assert_raise RuntimeError, ~r/fired 20 cycles/, fn ->
          [Spin]
          |> Session.new()
          |> Session.insert({:counter, 0})
          |> Session.fire_rules(max_cycles: 20, concurrency: concurrency)
        end
      end
    end

    # An activation stays on the agenda until its own conclusions are applied, so a
    # conclusion applied earlier in the cycle still cancels it. Taking the whole group off
    # up front left the retraction nothing to cancel, and `{:acted, 1}` was inserted
    # against a token that no longer existed — a fact no retraction could take back.
    test "an activation cancelled within its own group does not fire" do
      facts = [{:trigger, 1}, {:task, 1}]

      settled = fn concurrency ->
        [Cancel]
        |> Session.new()
        |> Session.insert(facts)
        |> Session.fire_rules(concurrency: concurrency)
      end

      for concurrency <- [1, 8] do
        session = settled.(concurrency)

        assert [] == derived(session, :acted)
        assert [{:blocked, 1}] == derived(session, :blocked)
      end
    end

    test "a cancelled group still drains completely on retraction" do
      facts = [{:trigger, 1}, {:task, 1}]

      for concurrency <- [1, 8] do
        drained =
          [Cancel]
          |> Session.new()
          |> Session.insert(facts)
          |> Session.fire_rules(concurrency: concurrency)
          |> Session.retract(facts)
          |> Session.fire_rules(concurrency: concurrency)

        assert [] == Session.facts(drained)
        assert %{} == Rete.Memory.dump(drained.state.memory).facts
      end
    end

    test "an unusable concurrency or timeout is rejected rather than coerced" do
      cases = [
        {:concurrency, 0, "must be a positive integer"},
        {:concurrency, -1, "must be a positive integer"},
        {:concurrency, nil, "must be a positive integer"},
        {:concurrency, 1.5, "must be a positive integer"},
        {:timeout, 0, "must be a positive integer or :infinity"},
        {:timeout, nil, "must be a positive integer or :infinity"},
        {:timeout, "5", "must be a positive integer or :infinity"}
      ]

      for {opt, bad, expected} <- cases do
        error =
          assert_raise ArgumentError, fn ->
            [Slow] |> Session.new() |> Session.insert(jobs(1)) |> Session.fire_rules([{opt, bad}])
          end

        assert error.message =~ expected
        assert error.message =~ inspect(bad)
      end
    end
  end
end
