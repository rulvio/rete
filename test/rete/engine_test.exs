defmodule Rete.EngineTest do
  use ExUnit.Case, async: true

  alias Rete.Session

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

    test "higher salience fires first" do
      session = Session.new([Salience]) |> Session.insert({:go, 1})

      order = session |> Session.pending() |> Enum.map(& &1.salience)
      assert [100, 50, 1] == order
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

    # A collection is a function of the facts in it, like everything else a Rete
    # network concludes. Storing members in arrival order makes `hd`, `Enum.at`
    # and `List.first` depend on the order the session was fed, and makes a
    # retract-and-reinsert cycle change a conclusion — which the round trip
    # invariant cannot see while every collection rule only takes `length`.
    test "a collection is ordered by its facts, not by when they arrived" do
      forwards =
        run([Ordered], [{:customer, 1}, {:order, 1, 10}, {:order, 1, 20}, {:order, 1, 30}])

      backwards =
        run([Ordered], [{:customer, 1}, {:order, 1, 30}, {:order, 1, 20}, {:order, 1, 10}])

      assert [{:seq, 1, [10, 20, 30]}] == derived(forwards, :seq)
      assert derived(forwards, :seq) == derived(backwards, :seq)
    end

    test "retracting and reinserting a collection member restores the collection" do
      base = run([Ordered], [{:customer, 1}, {:order, 1, 10}, {:order, 1, 20}, {:order, 1, 30}])

      cycled =
        base
        |> Session.retract({:order, 1, 10})
        |> Session.fire_rules()
        |> Session.insert({:order, 1, 10})
        |> Session.fire_rules()

      assert derived(base, :seq) == derived(cycled, :seq)
      assert base.state.memory == cycled.state.memory
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
    # See the `Rete.IR.Coll` section of docs/design/w1-ir.md.
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
      assert [[{:o, 1}, {:o, 2}]] == LeadColl.all(session)
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
      # memory a session starts with". That also pins how many root tokens there
      # are, which a "they are all empty tokens" check cannot see.
      assert Session.new([LeadNeg]).state.memory == memory
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
      Map.take(memory, [:facts, :elements, :tokens, :accum, :insertions])
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

      assert %{facts: %{}, elements: %{}, tokens: %{}, accum: %{}, insertions: %{}} ==
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

      assert %{facts: %{}, elements: %{}, tokens: %{}, accum: %{}, insertions: %{}} ==
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

      assert %{facts: %{}, elements: %{}, tokens: %{}, accum: %{}, insertions: %{}} ==
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
      assert [] == [Everything] |> run(@facts) |> Session.pending()
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
      assert [] == Session.pending(session)
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
end
