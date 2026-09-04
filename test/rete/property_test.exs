defmodule Rete.PropertyTest do
  @moduledoc """
  Properties over a ruleset that spans every node kind, plus a reference
  implementation of that ruleset to check the engine against.

  Two things make these tests worth more than the example-based suite.

  The first is the **lens**. `Rete.Session.facts/1` is a set, so a node that
  propagates a token it had already propagated collapses into a count bump and
  looks perfect. The corruption only surfaces later, as a fact that survives the
  retraction that should have removed it. Everything here compares
  `session.state.memory` — the fact *multiset*, and beneath it the elements,
  tokens, collection groups and truth-maintenance records.

  Two memories built from the same facts in different orders are not `==`,
  because a node's element list is appended to as facts arrive, and a collection
  gathers in reverse arrival order. `canon/1` sorts every leaf list, and every
  collection a token carries, and nothing else: no entry is dropped and no
  duplicate is collapsed, so a support imbalance still shows. Where the
  comparison can be exact — a round trip on one session, a full drain — it is
  exact. See `Rete.Test.Canon`.

  The second is the **oracle**. `expected/1` computes what the ruleset means over
  a fact multiset, in plain `for` comprehensions, counting one support per match.
  Comparing against a rebuilt session only proves the engine is consistent with
  itself. Comparing against `expected/1` proves it is right. It is what makes
  "support counting" a real property rather than a restatement of the engine.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Rete.Listener.Collect
  alias Rete.Session
  alias Rete.Test.Canon

  # --- the ruleset -----------------------------------------------------------------

  defmodule Everything do
    use Rete.Ruleset

    derive :premium, :customer
    derive :customer, :party

    # join with a cross-condition guard -> ExprJoin
    defrule flagged({:threshold, t}, {:order, cid, amt} when amt > t) do
      {:flagged, cid, amt}
    end

    # a conclusion feeding another rule -> truth maintenance has to cascade
    defrule escalate({:flagged, cid, _amt}) do
      {:escalated, cid}
    end

    # collection, reached through the taxonomy -> Accumulate
    defrule loyalty({:customer, cid}, orders = [{:order, cid, _amt}]) do
      {:loyalty, cid, length(orders)}
    end

    # plain negation -> Negation
    defrule dormant({:customer, cid}, {:not, [{:order, cid, _amt}]}) do
      {:dormant, cid}
    end

    # compound negation -> extracted helper, marker fact, Negation of the marker
    defrule clean({:party, pid}, {:nand, [{:order, pid, _amt}, {:refund, pid}]}) do
      {:clean, pid}
    end

    # disjunction -> two branches re-converging on the order condition
    defrule tagged({:or, [{:gold, cid}, {:silver, cid}]}, {:order, cid, amt}) do
      {:tagged, cid, amt}
    end

    # negation with a cross-condition guard -> NegationJoin. Two caps for one cid
    # put two tokens under one join key that disagree about the same element.
    defrule under({:cap, cid, lim}, {:not, [{:order, cid, amt} when amt > lim]}) do
      {:under, cid, lim}
    end

    # a collection in first position -> anchored on the root token, fires over a
    # session with no facts at all
    defrule refunds(rs = [{:refund, _cid}]) do
      {:refund_count, length(rs)}
    end

    # Two collections sharing `sku`, which is what makes the first one genuinely
    # *group*: several groups under one join key, only one of which changes when
    # an item arrives. A node that re-sends the unchanged groups gives them a
    # second support, and nothing but the counts shows it. `_ref` is discarded,
    # so it neither groups nor binds and two items can share a sku.
    defrule stock({:depot, d}, items = [{:item, d, sku, _ref}], holds = [{:hold, d, sku}]) do
      {:stock, d, sku, length(items), length(holds)}
    end

    defquery flagged_q({:flagged, cid, amt}) do
      {cid, amt}
    end
  end

  # Small on purpose: a universe this size makes two facts collide on a join key,
  # a negation flip on the last element leaving, and a collection group empty and
  # refill, all within a handful of random draws.
  @universe [
    {:threshold, 100},
    {:threshold, 20},
    {:customer, 1},
    {:customer, 2},
    {:premium, 1},
    {:premium, 3},
    {:party, 2},
    {:order, 1, 10},
    {:order, 1, 250},
    {:order, 2, 50},
    {:order, 3, 300},
    {:refund, 1},
    {:refund, 2},
    {:gold, 1},
    {:silver, 1},
    {:silver, 2},
    {:cap, 1, 100},
    {:cap, 1, 1000},
    {:cap, 2, 30},
    {:depot, 1},
    {:depot, 2},
    {:item, 1, :a, 1},
    {:item, 1, :a, 2},
    {:item, 1, :b, 1},
    {:item, 2, :a, 1},
    {:hold, 1, :a},
    {:hold, 1, :c}
  ]

  # The extracted helper's marker type, read off the network rather than spelled
  # out, so renaming the rule or the counter does not silently stop the oracle
  # accounting for markers.
  @marker [Everything]
          |> Rete.Compiler.build()
          |> Map.fetch!(:productions)
          |> Enum.map(& &1.name)
          |> Enum.find(&(to_string(&1) =~ "__neg_"))

  # --- driving the engine ------------------------------------------------------------

  defp build(multiset, concurrency \\ 1) do
    [Everything]
    |> Session.new()
    |> Session.insert(multiset)
    |> Session.fire_rules(concurrency: concurrency)
  end

  # A fresh session that has fired. `refunds` is true of the empty session — a
  # collection in first position with no new variables propagates `[]` — so the
  # baseline a drained session must return to is a fresh session *after*
  # `fire_rules/1`, not before it.
  defp fresh do
    [Everything] |> Session.new() |> Session.fire_rules()
  end

  defp counts(session), do: session.state.memory.facts

  # Deep-sorts every leaf list of the memory, and every collection a token
  # carries. Order of arrival is not part of what a session means, but
  # multiplicity is: nothing here dedups. See `Rete.Test.Canon` for exactly what
  # is normalized away and why that is safe over this fixture.
  #
  # Goes through `Rete.Memory.dump/1` rather than the struct: a bucket keeps
  # retracted items as tombstones until it compacts, so two memories holding
  # exactly the same matches can hold different bucket internals. The dump is
  # the view that means something.
  defp canon(%Session{} = session), do: Canon.dump(session)

  # The exact view: every match, in order, but without the derived state a
  # `Rete.Bucket` carries — its tombstones, and whether its index has been built.
  defp dump(%Session{state: %{memory: memory}}), do: Rete.Memory.dump(memory)

  # --- the oracle ---------------------------------------------------------------------

  # What the ruleset means over a fact multiset: the asserted facts with their
  # multiplicities, plus one support per match of every rule.
  defp expected(multiset) do
    Map.merge(Enum.frequencies(multiset), derived(Enum.uniq(multiset)), fn _f, a, b -> a + b end)
  end

  # The model: one comprehension per rule of the ruleset under test, written out
  # rather than derived, because a model that shared the engine's structure
  # would share its bugs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp derived(set) do
    thresholds = for {:threshold, t} <- set, do: t
    orders = for {:order, c, a} <- set, do: {c, a}
    refunds = for {:refund, c} <- set, do: c
    caps = for {:cap, c, l} <- set, do: {c, l}
    depots = for {:depot, d} <- set, do: d
    items = for {:item, d, s, _ref} <- set, do: {d, s}
    holds = for {:hold, d, s} <- set, do: {d, s}
    branches = for({:gold, c} <- set, do: c) ++ for {:silver, c} <- set, do: c

    # `derive :premium, :customer` and `derive :customer, :party`, so each of
    # these facts is a separate match of the condition written against the
    # ancestor. Two of them for one id is two supports, not one.
    customers = for({:customer, c} <- set, do: c) ++ for {:premium, c} <- set, do: c
    parties = for({:party, c} <- set, do: c) ++ customers

    flagged = for t <- thresholds, {c, a} <- orders, a > t, do: {:flagged, c, a}

    # The helper repeats the negated conjunction's prefix, so one marker per
    # (party fact, order, refund) sharing an id — and the marker carries the id,
    # which is what keeps the negation per-group rather than global.
    markers = for p <- parties, {c, _} <- orders, c == p, r <- refunds, r == p, do: p

    Enum.frequencies(
      flagged ++
        for({:flagged, c, _} <- Enum.uniq(flagged), do: {:escalated, c}) ++
        for(c <- customers, do: {:loyalty, c, Enum.count(orders, &(elem(&1, 0) == c))}) ++
        for(c <- customers, not has_order?(orders, c), do: {:dormant, c}) ++
        for(p <- markers, do: {@marker, %{pid: p}}) ++
        for(p <- parties, p not in markers, do: {:clean, p}) ++
        for(c <- branches, {oc, a} <- orders, oc == c, do: {:tagged, c, a}) ++
        for({c, l} <- caps, not over_cap?(orders, c, l), do: {:under, c, l}) ++
        stock(depots, items, holds) ++
        [{:refund_count, length(refunds)}]
    )
  end

  # A group only exists where a fact created it, and the first collection is the
  # one that creates them: a hold whose sku no item mentions produces nothing.
  # The second collection joins on the sku the first bound, introduces no
  # variable of its own and so propagates `[]` for a group with no holds.
  defp stock(depots, items, holds) do
    for d <- depots,
        sku <- Enum.uniq(for {id, sku} <- items, id == d, do: sku) do
      {:stock, d, sku, Enum.count(items, &(&1 == {d, sku})), Enum.count(holds, &(&1 == {d, sku}))}
    end
  end

  defp has_order?(orders, cid), do: Enum.any?(orders, &(elem(&1, 0) == cid))
  defp over_cap?(orders, cid, lim), do: Enum.any?(orders, fn {c, a} -> c == cid and a > lim end)

  # --- generators -----------------------------------------------------------------------

  defp fact, do: member_of(@universe)
  defp multiset(max \\ 10), do: list_of(fact(), max_length: max)

  # --- the oracle agrees with the engine ---------------------------------------------------

  describe "the reference implementation" do
    property "the engine's fact multiset is exactly what the rules mean" do
      check all(facts <- multiset(), max_runs: 60) do
        assert expected(facts) == counts(build(facts))
      end
    end

    test "the oracle is not vacuous: it disagrees with a session missing a fact" do
      facts = [{:threshold, 20}, {:order, 1, 250}, {:customer, 1}]

      assert expected(facts) == counts(build(facts))
      refute expected(facts) == counts(build(tl(facts)))
    end
  end

  # --- 1. insert/retract symmetry -----------------------------------------------------------

  describe "insert then retract" do
    property "inserting and retracting an extra fact restores the session exactly" do
      check all(facts <- multiset(), extra <- fact(), max_runs: 60) do
        base = build(facts)

        cycled =
          base
          |> Session.insert(extra)
          |> Session.fire_rules()
          |> Session.retract(extra)
          |> Session.fire_rules()

        # Exact, not canonical: the element the extra fact created was stored
        # and then removed, so even arrival order has to come back. Compared as
        # a dump, because a bucket that has taken a retraction carries a
        # tombstone until it compacts — invisible in what the session holds, and
        # pinned separately by the bucket invariant below.
        assert Rete.Memory.dump(base.state.memory) == Rete.Memory.dump(cycled.state.memory)
      end
    end

    property "retracting and restoring a fact the session already holds round trips" do
      check all(facts <- multiset(), facts != [], max_runs: 60) do
        base = build(facts)

        for held <- Enum.uniq(facts) do
          cycled =
            base
            |> Session.retract(held)
            |> Session.fire_rules()
            |> Session.insert(held)
            |> Session.fire_rules()

          # Canonical here: the element was removed from the middle of its list
          # and re-appended, which is a reordering and nothing more.
          assert canon(base) == canon(cycled),
                 "round trip changed the session for #{inspect(held)}"
        end
      end
    end

    property "an extra fact that changes nothing observable still changes nothing internally" do
      # A retraction of something absent must be a genuine no-op, not a
      # propagation that happens to cancel out.
      check all(facts <- multiset(), absent <- fact(), absent not in facts, max_runs: 40) do
        base = build(facts)
        poked = base |> Session.retract(absent) |> Session.fire_rules()

        assert Rete.Memory.dump(base.state.memory) == Rete.Memory.dump(poked.state.memory)
      end
    end
  end

  # --- 2. order independence -------------------------------------------------------------------

  describe "order independence" do
    property "the same facts in any order give the same derived state" do
      check all(facts <- multiset(), shuffles <- list_of(constant(nil), length: 3), max_runs: 40) do
        base = canon(build(facts))

        for _ <- shuffles do
          assert base == canon(build(Enum.shuffle(facts)))
        end
      end
    end

    # Raising :concurrency moves the rule bodies of an activation group onto tasks. What it
    # must not change is the session that results, down to the truth-maintenance ledger.
    # `Everything` spans every node kind, so negation, collections and disjunctions are
    # covered too.
    #
    # It does *not* preserve firing order, and that is a property of batching rather than
    # of this implementation: firing one at a time re-sorts the agenda after every
    # activation, so a rule activated by the conclusion of another can overtake a rule that
    # was already pending. Batching freezes the group, so the new activation waits for the
    # next one. See the pinned example in `Rete.EngineTest`.
    property "firing rule bodies concurrently reaches the same session" do
      check all(facts <- multiset(), concurrency <- integer(2..8), max_runs: 40) do
        assert canon(build(facts)) == canon(build(facts, concurrency))
      end
    end

    property "batch grouping and when rules fire do not matter" do
      check all(facts <- multiset(), size <- integer(1..4), max_runs: 40) do
        # the baseline: all at once, fired once
        base = canon(build(facts))

        # in chunks, firing after each chunk
        assert base == canon(feed(facts, size, :fire_each))

        # in chunks, firing only at the end
        assert base == canon(feed(facts, size, :fire_last))

        # one at a time, firing after each
        assert base == canon(feed(facts, 1, :fire_each))
      end
    end
  end

  defp feed(facts, size, when_to_fire) do
    session =
      facts
      |> Enum.chunk_every(size)
      |> Enum.reduce([Everything] |> Session.new(), fn chunk, session ->
        session = Session.insert(session, chunk)
        if when_to_fire == :fire_each, do: Session.fire_rules(session), else: session
      end)

    Session.fire_rules(session)
  end

  # --- 3. full drain ----------------------------------------------------------------------------

  describe "full drain" do
    property "retracting everything returns the memory to a fresh session's" do
      check all(facts <- multiset(), max_runs: 60) do
        drained =
          facts
          |> build()
          |> then(fn session ->
            Enum.reduce(Enum.shuffle(facts), session, fn f, s ->
              s |> Session.retract(f) |> Session.fire_rules()
            end)
          end)

        # Equality with a fresh session, not "everything is empty": that is what
        # pins "exactly one root token" and "no join key left pointing at an
        # empty map", neither of which an emptiness check can see.
        #
        # Through the dump, which is what `Rete.Memory.dump/1` exists for. The
        # struct additionally carries derived state — a bucket's tombstones and
        # whether its index has been built — and a session that drained something
        # legitimately differs there from one that never held anything.
        assert dump(fresh()) == dump(drained)
      end
    end

    property "retracting everything in one call drains just as completely" do
      check all(facts <- multiset(), max_runs: 40) do
        drained = facts |> build() |> Session.retract(facts) |> Session.fire_rules()

        assert dump(fresh()) == dump(drained)
      end
    end

    test "churning the same facts through the session does not grow any memory" do
      facts = @universe

      Enum.reduce(1..5, fresh(), fn round, session ->
        cycled =
          session
          |> Session.insert(facts)
          |> Session.fire_rules()
          |> Session.retract(facts)
          |> Session.fire_rules()

        assert fresh().state.memory == cycled.state.memory, "memory grew in round #{round}"
        cycled
      end)
    end
  end

  # --- 4. support counting ------------------------------------------------------------------------

  describe "support counting" do
    property "a fact concluded by exactly one match is held exactly once" do
      check all(facts <- multiset(), max_runs: 60) do
        session = build(facts)
        oracle = expected(facts)

        for {f, n} <- counts(session) do
          assert n == Map.fetch!(oracle, f),
                 "#{inspect(f)} is held #{n} times, the rules give it #{Map.fetch!(oracle, f)}"
        end
      end
    end

    property "the fact multiset is the asserted facts plus the truth maintenance ledger" do
      # An independent reading of the same number: every support in `facts` must
      # be an insertion some production is on the hook for. A node that
      # propagated twice would have to forge a ledger entry to pass this.
      check all(facts <- multiset(), max_runs: 60) do
        session = build(facts)
        ledger = ledger(session)

        assert Map.merge(Enum.frequencies(facts), ledger, fn _f, a, b -> a + b end) ==
                 counts(session)
      end
    end

    property "no match ever inserts twice, and no memory holds a duplicate" do
      # The direct form of "a node propagated a token it had already
      # propagated". One match at one production owns one batch of facts. Two
      # batches under one token is the support imbalance itself, before it has
      # had time to disguise itself as a count.
      check all(facts <- multiset(), max_runs: 60) do
        memory =
          facts |> build() |> Map.fetch!(:state) |> Map.fetch!(:memory) |> Rete.Memory.dump()

        for {node_id, by_token} <- memory.insertions, {token, batches} <- by_token do
          assert length(batches) == 1,
                 "node #{inspect(node_id)} inserted #{length(batches)} batches for one match: " <>
                   inspect(token)
        end

        for store <- [memory.elements, memory.tokens],
            {node_id, by_key} <- store,
            {key, list} <- by_key do
          assert list == Enum.uniq(list),
                 "node #{inspect(node_id)} holds a duplicate under #{inspect(key)}"
        end
      end
    end

    property "the inserters index says exactly what the insertion records say" do
      # `inserters` is `insertions` turned around. It is built on first use and
      # maintained in step after that, which means it can drift in a way nothing
      # else notices: the engine reads it only for a conclusion that is already
      # present, so a stale entry stays invisible until the one ruleset that
      # re-concludes something trips over it. Rebuild it the slow way and compare,
      # after retractions have had a chance to leave one behind.
      #
      # `index_inserters/1` returns the memory unchanged when the session already
      # built one, so this checks the *maintained* index wherever the run reached
      # for it, and a fresh build where it never did. `Everything` re-concludes —
      # two thresholds under one order flag the same fact twice — so the
      # maintained path is the usual one here.
      check all(facts <- multiset(), facts != [], max_runs: 60) do
        session = build(facts)

        for dropped <- Enum.uniq(facts) do
          memory =
            session
            |> Session.retract(dropped)
            |> Session.fire_rules()
            |> Map.fetch!(:state)
            |> Map.fetch!(:memory)
            |> Rete.Memory.index_inserters()

          assert rebuilt_inserters(memory) == memory.inserters,
                 "the index disagrees with the records after retracting #{inspect(dropped)}"
        end
      end
    end

    property "an unbuilt index answers the same as a built one" do
      # The fallback path in `Rete.Memory.inserters/2`, which scans `insertions`
      # rather than forcing a build. `Rete.Inspect.derivations/2` takes it, so it
      # has to agree with the index for every fact the session holds.
      check all(facts <- multiset(), facts != [], max_runs: 40) do
        # Matched out rather than fetched, so the struct update below is one the
        # compiler can check: `Map.fetch!/2` gives back `dynamic()`, and
        # `%Rete.Memory{memory | ...}` needs to know it is updating a memory.
        %Session{state: %{memory: %Rete.Memory{} = memory}} = build(facts)
        unbuilt = %Rete.Memory{memory | inserters: nil}
        built = Rete.Memory.index_inserters(unbuilt)

        for fact <- Rete.Memory.facts(memory) do
          assert Enum.sort(Rete.Memory.inserters(unbuilt, fact)) ==
                   Enum.sort(Rete.Memory.inserters(built, fact)),
                 "the scan and the index disagree about #{inspect(fact)}"
        end
      end
    end

    # What `Rete.Memory.inserters/2` used to do on every call: one entry per
    # occurrence of a fact in a batch, so a rule that concluded the same fact twice
    # in one activation counts twice.
    defp rebuilt_inserters(memory) do
      for {node_id, by_token} <- memory.insertions,
          {token, batches} <- by_token,
          batch <- batches,
          fact <- batch,
          reduce: %{} do
        acc ->
          Map.update(acc, fact, %{{node_id, token} => 1}, fn refs ->
            Map.update(refs, {node_id, token}, 1, &(&1 + 1))
          end)
      end
    end

    test "two supports need two retractions, and the first leaves the fact standing" do
      # `{:premium, 1}` and `{:customer, 1}` are two distinct facts, both of
      # which reach `{:customer, cid}` through the taxonomy, so the collection
      # rule matches twice and the conclusion is held twice.
      facts = [{:premium, 1}, {:customer, 1}, {:order, 1, 10}]
      session = build(facts)

      assert %{{:loyalty, 1, 1} => 2} = counts(session)

      session = session |> Session.retract({:premium, 1}) |> Session.fire_rules()
      assert %{{:loyalty, 1, 1} => 1} = counts(session)

      session = session |> Session.retract({:customer, 1}) |> Session.fire_rules()
      refute Map.has_key?(counts(session), {:loyalty, 1, 1})
    end

    test "a disjunction's two branches are two supports, not one" do
      facts = [{:gold, 1}, {:silver, 1}, {:order, 1, 10}]
      session = build(facts)

      assert %{{:tagged, 1, 10} => 2} = counts(session)

      session = session |> Session.retract({:gold, 1}) |> Session.fire_rules()
      assert %{{:tagged, 1, 10} => 1} = counts(session)

      session = session |> Session.retract({:silver, 1}) |> Session.fire_rules()
      refute Map.has_key?(counts(session), {:tagged, 1, 10})
    end
  end

  defp ledger(session) do
    for {_node_id, by_token} <- session.state.memory.insertions,
        {_token, batches} <- by_token,
        batch <- batches,
        f <- batch,
        reduce: %{} do
      acc -> Map.update(acc, f, 1, &(&1 + 1))
    end
  end

  # --- settling is monotone, which is where activation order is visible ----------------------------

  # The settled state cannot see activation order: whatever a rule concludes too
  # early, truth maintenance takes back, and the session ends up in the same
  # place. Every property above is therefore blind to it. What order *is*
  # visible in is the events, and the thing to assert is that nothing was ever
  # concluded and then taken back — which is exactly the guarantee
  # `:internal_salience` buys for an extracted compound negation. Its helper has
  # to fire before the rule that negates its marker, or that rule observes an
  # absence that had merely not been computed yet.
  describe "settling" do
    property "building a session from empty never takes a conclusion back" do
      # A wider multiset than the other properties use, and more runs. The
      # premature conclusion this is looking for needs a party with *both* an
      # order and a refund in the same batch, which a two-fact draw can never
      # produce — and a property that only sometimes reaches the case it is
      # named after is not a test.
      check all(facts <- list_of(fact(), min_length: 6, max_length: 16), max_runs: 150) do
        session =
          [Everything]
          |> Session.new()
          |> Session.with_listener(Collect, [])
          |> Session.insert(facts)
          |> Session.fire_rules()

        assert [] == Collect.by_tag(session, :fact_retracted),
               "a conclusion was fired and then retracted while settling #{inspect(facts)}"
      end
    end

    test "the extracted helper fires before the rule that negates its marker" do
      # Party 2 has both an order and a refund, so `clean` must never fire for
      # it. Its activation is queued before the helper's marker exists, so the
      # only thing that stops it is firing the helper first.
      session =
        [Everything]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert([{:party, 2}, {:order, 2, 50}, {:refund, 2}])
        |> Session.fire_rules()

      refute {:clean, 2} in Session.facts(session)

      # Cancelled while pending, not fired and then taken back.
      assert [] == Collect.by_tag(session, :fact_retracted)
      assert [_ | _] = Collect.by_tag(session, :activation_removed)
    end
  end

  # --- 5. equivalence to a rebuild ---------------------------------------------------------------

  describe "equivalence to a rebuild" do
    property "after any sequence of inserts and retracts the session equals a rebuild" do
      check all(ops <- list_of(op(), max_length: 30), max_runs: 40) do
        {session, multiset} = apply_ops(ops)

        assert canon(build(Enum.shuffle(multiset))) == canon(session)
        assert expected(multiset) == counts(session)
      end
    end

    # Where the caller put its `fire_rules/2` calls is not part of what a session means.
    # One fire at the end must land where a fire after every call lands.
    #
    # This is the only property here that batches a **mixed** sequence. `feed/3` above
    # batches inserts alone, and the walk below fires every step, so neither reaches the
    # queue that `fire_rules/2` coalesces holding both directions for one node. That queue
    # is where merging an op back past its own inverse loses a retraction: the fact leaves
    # working memory, the element stays in the node, and no later fire reaches it.
    property "batching a mixed sequence before one fire equals firing after each call" do
      check all(ops <- list_of(op(), max_length: 30), max_runs: 40) do
        {each, multiset} = apply_ops(ops, :fire_each)
        {last, ^multiset} = apply_ops(ops, :fire_last)

        assert expected(multiset) == counts(last)
        assert canon(each) == canon(last)
        assert canon(build(Enum.shuffle(multiset))) == canon(last)
      end
    end
  end

  defp op do
    one_of([tuple({constant(:insert), fact()}), tuple({constant(:retract), fact()})])
  end

  # `:fire_each` fires after every call, `:fire_last` only at the end. Either way the
  # returned session is settled, so the two are comparable.
  defp apply_ops(ops, when_to_fire \\ :fire_each) do
    {session, multiset} =
      Enum.reduce(ops, {fresh(), []}, fn
        {:insert, f}, {session, multiset} ->
          {session |> Session.insert(f) |> maybe_fire(when_to_fire) |> settled!(), [f | multiset]}

        {:retract, f}, {session, multiset} ->
          # Retracting a fact the session does not hold is a no-op, so the
          # reference multiset has to model that too.
          {session |> Session.retract(f) |> maybe_fire(when_to_fire) |> settled!(),
           List.delete(multiset, f)}
      end)

    {Session.fire_rules(session), multiset}
  end

  defp maybe_fire(session, :fire_each), do: Session.fire_rules(session)
  defp maybe_fire(session, :fire_last), do: session

  # --- settled? answers for the agenda as well as the queue ----------------------------------

  # `Rete.Session.settled?/1` reads the queue alone. Its docstring says why that answers
  # for the agenda too: `fire_loop/4` returns only when the agenda is empty, and every
  # other way out of a fire raises, which throws the state away. So a session a caller can
  # hold never has an empty queue and a waiting activation.
  #
  # Nothing in the engine enforces that. This does. If it ever stops holding, `settled?/1`
  # reports `true` about a session with a rule still to fire, `Rete.Inspect.why_not/2`
  # answers from that session rather than refusing, and a caller who checked before
  # querying is told the session is ready when it is not.
  #
  # Called on every intermediate session the properties below build, settled or not, so it
  # costs no generation of its own.
  defp settled!(%Session{} = session) do
    if Session.settled?(session) do
      assert 0 == Rete.Agenda.size(session.state.agenda),
             "settled?/1 answered true with an activation still on the agenda"
    end

    session
  end

  describe "settled? and the agenda" do
    property "a settled session has an empty agenda, at every point of a mixed sequence" do
      check all(ops <- list_of(op(), max_length: 30), max_runs: 40) do
        # Both policies, because `:fire_last` leaves the session unsettled between calls
        # and `:fire_each` settles it. The invariant is one-directional either way: an
        # unsettled session may hold anything.
        apply_ops(ops, :fire_each)
        apply_ops(ops, :fire_last)
      end
    end

    test "a fresh session is unsettled, and firing it settles both" do
      fresh = Session.new([Everything])

      refute Session.settled?(fresh)

      settled = settled!(Session.fire_rules(fresh))
      assert Session.settled?(settled)
      assert 0 == Rete.Agenda.size(settled.state.agenda)
    end
  end

  # --- the fuzz ------------------------------------------------------------------------------------

  # Worth more than any single property above: a long walk through the state
  # space, checked against a rebuild *and* against the oracle after every step,
  # so a corruption is caught on the operation that caused it rather than
  # whenever it happens to become visible. Seeded, so a failure is reproducible.
  describe "a random walk of a thousand operations" do
    for seed <- [1, 7, 13, 29] do
      test "seed #{seed}: every step agrees with a rebuild and with the rules" do
        walk(unquote(seed), 1_000, 1)
      end

      # The same walk, with a fire every third step instead of every step. The queue that
      # `fire_rules/2` coalesces then holds a run of inserts and retractions for one node,
      # which is the case a fire-per-step walk can never build. It checks only where it
      # fired: between fires the session is behind the multiset on purpose.
      test "seed #{seed}: three operations to a fire agrees just the same" do
        walk(unquote(seed), 1_000, 3)
      end
    end
  end

  defp walk(seed, steps, fire_every) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    {session, multiset} =
      Enum.reduce(1..steps, {fresh(), []}, fn step, {session, multiset} ->
        # Held down to a handful of facts on purpose. The interesting
        # transitions — the last order for a customer leaving, a collection
        # group emptying, a negation flipping — only happen near the edges, and
        # a session carrying a hundred facts almost never reaches one.
        op =
          cond do
            multiset == [] -> :insert
            length(multiset) > 8 -> :retract
            :rand.uniform() < 0.5 -> :retract
            true -> :insert
          end

        {session, multiset} =
          case op do
            :insert ->
              f = Enum.random(@universe)
              {session |> Session.insert(f) |> settled!(), [f | multiset]}

            :retract ->
              f = Enum.random(multiset)
              {session |> Session.retract(f) |> settled!(), List.delete(multiset, f)}
          end

        if rem(step, fire_every) == 0 do
          session = session |> Session.fire_rules() |> settled!()
          context = "seed #{seed}, step #{step}, holding #{inspect(Enum.sort(multiset))}"

          assert expected(multiset) == counts(session), context
          assert canon(build(Enum.shuffle(multiset))) == canon(session), context

          {session, multiset}
        else
          {session, multiset}
        end
      end)

    # And the walk has to be able to end where it started. The last step only fired if
    # `fire_every` divides `steps`, and a session with a queued op is not comparable to a
    # settled one. Firing a settled session costs nothing.
    drained =
      Enum.reduce(multiset, Session.fire_rules(session), fn f, s ->
        s |> Session.retract(f) |> Session.fire_rules()
      end)

    assert dump(fresh()) == dump(drained)
  end

  # --- queries follow the same facts ------------------------------------------------------------------

  describe "queries" do
    property "a query returns exactly the matches the rules give it" do
      check all(facts <- multiset(), max_runs: 40) do
        wanted =
          facts
          |> expected()
          |> Map.keys()
          |> Enum.flat_map(fn
            {:flagged, cid, amt} -> [{cid, amt}]
            _ -> []
          end)
          |> Enum.sort()

        assert wanted == facts |> build() |> Everything.flagged_q() |> Enum.sort()
      end
    end
  end

  # --- the one contract no end-to-end property can reach ---------------------------------------------

  # `Rete.Memory.remove_elements/4` and `remove_tokens/4` report what was *found*
  # rather than what was asked for, and `Rete.Engine.Nodes` propagates only that:
  # a retraction of something never stored produces no downstream work. Nothing
  # above can see the difference, because no reachable state asks a memory to
  # remove something it does not hold — the engine maintains that invariant one
  # level up, and every property in this file passes with the filtering removed.
  #
  # So the contract is pinned here instead, where it can be violated on purpose.
  # It is the last line of defense: if any node ever does start retracting what
  # it never propagated, this is what stops the phantom cascading through every
  # memory below it.
  describe "removing from a memory" do
    property "a memory reports the occurrences it actually held, not the ones asked for" do
      check all(
              stored <- list_of(element(), max_length: 6),
              targets <- list_of(element(), max_length: 6)
            ) do
        memory = Rete.Memory.add_elements(Rete.Memory.new(), :node, %{}, stored)
        {memory, removed} = Rete.Memory.remove_elements(memory, :node, %{}, targets)

        assert removed == found(stored, targets)
        assert Rete.Memory.elements(memory, :node, %{}) == remaining(stored, targets)
      end
    end

    property "tokens obey the same rule" do
      check all(
              stored <- list_of(token(), max_length: 6),
              targets <- list_of(token(), max_length: 6)
            ) do
        memory = Rete.Memory.add_tokens(Rete.Memory.new(), :node, %{}, stored)
        {memory, removed} = Rete.Memory.remove_tokens(memory, :node, %{}, targets)

        assert removed == found(stored, targets)
        assert Rete.Memory.tokens(memory, :node, %{}) == remaining(stored, targets)
      end
    end

    test "a target the memory never held is not reported" do
      memory = Rete.Memory.add_elements(Rete.Memory.new(), :node, %{}, [el(:a)])

      assert {_, [%Rete.Element{fact: :a}]} =
               Rete.Memory.remove_elements(memory, :node, %{}, [el(:a), el(:b)])

      assert {_, []} = Rete.Memory.remove_elements(memory, :node, %{}, [el(:b)])
    end
  end

  # A bucket does not remove anything when it is asked to: it marks the
  # occurrence dead and leaves it in the queue, which is what makes retraction
  # O(1) whatever the bucket holds. The debt is only bounded because compaction
  # clears it once the dead outnumber the living — so that bound is the contract,
  # and without it a long-lived session would grow a queue of tombstones that
  # nothing above `to_list/1` could see.
  describe "a bucket's tombstones" do
    alias Rete.Bucket

    property "never outnumber the living by more than one" do
      check all(ops <- list_of(one_of([{:push, element()}, {:take, element()}]), max_length: 60)) do
        bucket =
          Enum.reduce(ops, Bucket.new(), fn
            {:push, item}, bucket ->
              Bucket.push(bucket, [item])

            {:take, item}, bucket ->
              case Bucket.take(bucket, item) do
                {:ok, bucket} -> bucket
                {:error, bucket} -> bucket
              end
          end)

        live = length(Bucket.to_list(bucket))
        held = :queue.len(bucket.queue)

        assert held <= 2 * live + 1,
               "queue of #{held} holding #{live} live items has not compacted"
      end
    end

    test "are cleared entirely once everything is retracted" do
      bucket = Bucket.new([el(:a), el(:b), el(:c)])

      emptied =
        Enum.reduce([el(:a), el(:b), el(:c)], bucket, fn item, bucket ->
          {:ok, bucket} = Bucket.take(bucket, item)
          bucket
        end)

      assert Bucket.empty?(emptied)
      assert [] == Bucket.to_list(emptied)
      assert [] == :queue.to_list(emptied.queue), "a fully drained bucket still holds tombstones"
    end

    # The subtle one. Equal items are interchangeable in a set and are not in a
    # list: dropping the first `c` of `[c, b, c]` leaves `[b, c]` and dropping
    # the last leaves `[c, b]`. Arrival order retracts the oldest, so this does.
    test "the oldest occurrence is the one that goes" do
      bucket = Bucket.new([el(:c), el(:b), el(:c)])
      {:ok, bucket} = Bucket.take(bucket, el(:c))

      assert [el(:b), el(:c)] == Bucket.to_list(bucket)
    end

    # `pop/1` is the agenda's read. It has to agree with `to_list/1` about which
    # occurrence is next, or a cancelled activation would fire and a live one would
    # not — and it has to discard the tombstones it steps over, or skipping one
    # would be paid for again on the next pop.
    property "popping drains a bucket in exactly the order to_list reports" do
      check all(ops <- list_of(one_of([{:push, element()}, {:take, element()}]), max_length: 60)) do
        bucket =
          Enum.reduce(ops, Bucket.new(), fn
            {:push, item}, bucket ->
              Bucket.push(bucket, [item])

            {:take, item}, bucket ->
              case Bucket.take(bucket, item) do
                {:ok, bucket} -> bucket
                {:error, bucket} -> bucket
              end
          end)

        assert Bucket.to_list(bucket) == drain_bucket(bucket)
      end
    end

    # The index exists only to make `take/2` O(1), so a bucket nothing is ever
    # taken from should not be paying for it. Pinned because the saving is
    # invisible in behavior: an eagerly-indexed bucket answers every question
    # identically, just slower.
    test "the index is not built until something is taken" do
      pushed = Bucket.new([el(:a), el(:b), el(:a)])

      refute pushed.indexed?
      assert %{} == pushed.counts

      {:ok, popped, _} = Bucket.pop(pushed)
      assert el(:a) == popped
      refute pushed.indexed?, "popping built the index"

      {:ok, taken} = Bucket.take(pushed, el(:b))
      assert taken.indexed?
      assert %{el(:a) => 2} == taken.counts
    end

    # A miss is what a cancelled-but-already-fired activation looks like, and it
    # is the call that builds the index. Handing the bucket back on that path is
    # what stops the next miss rebuilding it.
    test "a miss builds the index and hands the bucket back" do
      {:error, indexed} = Bucket.new([el(:a)]) |> Bucket.take(el(:c))

      assert indexed.indexed?
      assert %{el(:a) => 1} == indexed.counts
    end

    # Whether the index was built or not must not change a single answer.
    property "a lazily indexed bucket answers exactly as an eagerly indexed one" do
      check all(ops <- list_of(one_of([{:push, element()}, {:take, element()}]), max_length: 60)) do
        lazy = replay(ops, Bucket.new())

        # Same operations, but with the index forced up front by a take that
        # cannot match anything the generator produces.
        {:error, seeded} = Bucket.take(Bucket.new(), el(:never))
        eager = replay(ops, seeded)

        assert Bucket.to_list(lazy) == Bucket.to_list(eager)
        assert Bucket.size(lazy) == Bucket.size(eager)
        assert drain_bucket(lazy) == drain_bucket(eager)
      end
    end

    test "popping everything leaves no tombstone behind" do
      bucket = Bucket.new([el(:a), el(:b), el(:c)])
      {:ok, bucket} = Bucket.take(bucket, el(:b))

      drained =
        Enum.reduce(1..2, bucket, fn _, bucket ->
          {:ok, _item, rest} = Bucket.pop(bucket)
          rest
        end)

      assert :empty == Bucket.pop(drained)
      assert 0 == Bucket.size(drained)
      assert [] == :queue.to_list(drained.queue)
    end
  end

  defp drain_bucket(bucket, acc \\ []) do
    case Rete.Bucket.pop(bucket) do
      :empty -> Enum.reverse(acc)
      {:ok, item, rest} -> drain_bucket(rest, [item | acc])
    end
  end

  defp replay(ops, bucket) do
    Enum.reduce(ops, bucket, fn
      {:push, item}, bucket ->
        Rete.Bucket.push(bucket, [item])

      {:take, item}, bucket ->
        case Rete.Bucket.take(bucket, item) do
          {:ok, bucket} -> bucket
          {:error, bucket} -> bucket
        end
    end)
  end

  defp el(fact), do: %Rete.Element{fact: fact, bindings: %{}}
  defp element, do: map(member_of([:a, :b, :c]), &el/1)
  defp token, do: map(member_of([:a, :b, :c]), &Rete.Token.extend(%Rete.Token{}, &1, 1, %{}))

  # One occurrence per target that is really there, in the order the targets
  # were given, written independently of how the memory does it.
  defp found(stored, targets), do: elem(take(stored, targets), 1)
  defp remaining(stored, targets), do: elem(take(stored, targets), 0)

  defp take(stored, targets) do
    {rest, taken} =
      Enum.reduce(targets, {stored, []}, fn target, {rest, taken} ->
        if target in rest,
          do: {List.delete(rest, target), [target | taken]},
          else: {rest, taken}
      end)

    {rest, Enum.reverse(taken)}
  end
end
