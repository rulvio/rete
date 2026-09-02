defmodule Rete.QueryIndexTest do
  @moduledoc """
  `Rete.Ruleset.index/2` declares how a query's matches are bucketed. It changes how many
  matches a filter considers, and nothing else.

  So the load-bearing test here is not that an index is faster. It is that one ruleset
  declared twice, with indexes and without, answers every filter identically — same rows,
  same order. The failure mode of a wrong index is a missing row, which reads as an empty
  result rather than a crash.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Rete.Inspect
  alias Rete.Session

  defmodule Plain do
    use Rete.Ruleset

    defquery rows({:rec, cid, tid, amt}), do: {cid, tid, amt}
  end

  defmodule Indexed do
    use Rete.Ruleset

    defquery rows({:rec, cid, tid, amt}), do: {cid, tid, amt}

    index :rows, [:cid]
    index :rows, [:cid, :tid]
  end

  defp run(module, facts) do
    [module] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp facts_for(n) do
    for i <- 1..n, do: {:rec, rem(i, 4), rem(i, 3), i}
  end

  # Every subset of what the query binds, so both the indexed and the unindexed paths are
  # exercised, and so is a filter that matches no declared index.
  defp filter_sets(cid, tid, amt) do
    [
      [],
      [cid: cid],
      [tid: tid],
      [amt: amt],
      [cid: cid, tid: tid],
      [cid: cid, amt: amt],
      [tid: tid, amt: amt],
      [cid: cid, tid: tid, amt: amt],
      [cid: 99],
      [cid: cid, tid: 99]
    ]
  end

  describe "an index never changes an answer" do
    test "every filter shape agrees with the unindexed query, rows and order" do
      facts = facts_for(60)
      plain = run(Plain, facts)
      indexed = run(Indexed, facts)

      for filters <- filter_sets(2, 1, 30) do
        assert Plain.rows(plain, filters) == Indexed.rows(indexed, filters),
               "disagreed on #{inspect(filters)}"
      end
    end

    property "and agrees over any fact set, fed in any order" do
      check all(
              n <- integer(1..40),
              shuffle? <- boolean(),
              cid <- integer(0..4),
              tid <- integer(0..3),
              max_runs: 40
            ) do
        facts = facts_for(n)
        facts = if shuffle?, do: Enum.shuffle(facts), else: facts

        plain = run(Plain, facts)
        indexed = run(Indexed, facts)

        for filters <- filter_sets(cid, tid, 7) do
          assert Plain.rows(plain, filters) == Indexed.rows(indexed, filters),
                 "disagreed on #{inspect(filters)} over #{inspect(facts)}"
        end
      end
    end

    test "and keeps agreeing after retraction" do
      facts = facts_for(30)
      dropped = Enum.take_every(facts, 3)

      drop = fn session ->
        session |> Session.retract(dropped) |> Session.fire_rules()
      end

      plain = Plain |> run(facts) |> drop.()
      indexed = Indexed |> run(facts) |> drop.()

      for filters <- filter_sets(2, 1, 30) do
        assert Plain.rows(plain, filters) == Indexed.rows(indexed, filters),
               "disagreed on #{inspect(filters)}"
      end
    end
  end

  # Agreement alone cannot tell a working index from one nothing reaches: both answer
  # correctly, and the second is merely as slow as before. `Rete.Inspect.query_plan/3` is
  # what makes the choice observable, and these are what would fail if the lookup quietly
  # stopped happening.
  describe "which index a call reaches for" do
    setup do
      %{session: run(Indexed, facts_for(12))}
    end

    test "an exact filter uses the index of that name", %{session: session} do
      assert {:index, [:cid]} == Inspect.query_plan(session, {Indexed, :rows}, cid: 1)
    end

    test "a filter over two bindings uses the composite index", %{session: session} do
      assert {:index, [:cid, :tid]} ==
               Inspect.query_plan(session, {Indexed, :rows}, cid: 1, tid: 2)
    end

    # Two declared sets are subsets of these filters. The larger one narrows further.
    test "the widest usable index wins", %{session: session} do
      assert {:index, [:cid, :tid]} ==
               Inspect.query_plan(session, {Indexed, :rows}, cid: 1, tid: 2, amt: 3)

      assert {:index, [:cid]} == Inspect.query_plan(session, {Indexed, :rows}, cid: 1, amt: 3)
    end

    test "a filter no index covers scans", %{session: session} do
      assert :scan == Inspect.query_plan(session, {Indexed, :rows}, amt: 3)
      assert :scan == Inspect.query_plan(session, {Indexed, :rows}, tid: 2)
      assert :scan == Inspect.query_plan(session, {Indexed, :rows})
    end

    test "a query with no index always scans" do
      session = run(Plain, facts_for(12))

      assert :scan == Inspect.query_plan(session, {Plain, :rows}, cid: 1)
    end

    test "an unknown filter is still refused", %{session: session} do
      assert_raise ArgumentError, fn ->
        Inspect.query_plan(session, {Indexed, :rows}, nope: 1)
      end
    end
  end

  describe "which index a filter uses" do
    # A filter naming more than an index does still use it, then applies the rest to the
    # bucket. The result has to match the bucket's contents narrowed, not the bucket.
    test "a filter wider than an index uses it and still applies the rest" do
      session = run(Indexed, facts_for(60))

      assert Indexed.rows(session, cid: 2, amt: 30) ==
               Plain.rows(run(Plain, facts_for(60)), cid: 2, amt: 30)

      assert [{2, 0, 30}] == Indexed.rows(session, cid: 2, amt: 30)
    end

    test "a filter naming nothing indexed still answers" do
      session = run(Indexed, facts_for(60))

      assert Plain.rows(run(Plain, facts_for(60)), amt: 30) == Indexed.rows(session, amt: 30)
    end

    test "an unfiltered query still answers in arrival order" do
      facts = [{:rec, 3, 1, 9}, {:rec, 1, 2, 4}, {:rec, 2, 0, 7}]

      assert [{3, 1, 9}, {1, 2, 4}, {2, 0, 7}] == Indexed.rows(run(Indexed, facts))
    end
  end

  describe "declaring an index" do
    test "the name has to be a query this module defines" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule NoSuchQuery do
            use Rete.Ruleset

            defquery rows({:rec, cid}), do: cid

            index :nope, [:cid]
          end
        end

      assert error.message =~ "index :nope names nothing"
      assert error.message =~ "Defined: :rows"
    end

    test "a rule cannot be indexed" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule IndexedRule do
            use Rete.Ruleset

            defrule flag({:rec, cid}), do: {:flagged, cid}

            index :flag, [:cid]
          end
        end

      assert error.message =~ "index :flag names a rule"
      assert error.message =~ "only a query is filtered"
    end

    test "a key has to be something the query binds" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule UnknownKey do
            use Rete.Ruleset

            defquery rows({:rec, cid}), do: cid

            index :rows, [:cid, :nope]
          end
        end

      assert error.message =~ "names [:nope]"
      assert error.message =~ "It binds [:cid]"
    end

    test "the same index twice is an error, whatever order its keys are written in" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule Repeated do
            use Rete.Ruleset

            defquery rows({:rec, cid, tid}), do: {cid, tid}

            index :rows, [:cid, :tid]
            index :rows, [:tid, :cid]
          end
        end

      assert error.message =~ "is already declared"
    end

    test "an empty key list is an error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule EmptyKeys do
            use Rete.Ruleset

            defquery rows({:rec, cid}), do: cid

            index :rows, []
          end
        end

      assert error.message =~ "names no bindings"
    end

    # Order-independent, like `derive/2`. Both are resolved at `@before_compile`.
    test "an index may be declared before the query it names" do
      defmodule DeclaredFirst do
        use Rete.Ruleset

        index :rows, [:cid]

        defquery rows({:rec, cid, _tid, _amt}), do: cid
      end

      session = run(DeclaredFirst, [{:rec, 1, 0, 5}, {:rec, 2, 0, 6}])

      assert [1] == DeclaredFirst.rows(session, cid: 1)
    end
  end

  describe "the options map" do
    test "an unknown key is refused rather than ignored" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule Misspelled do
            use Rete.Ruleset

            defrule flag(%{saliance: 10}, {:rec, cid}), do: {:flagged, cid}
          end
        end

      assert error.message =~ "sets [:saliance]"
      assert error.message =~ "index :flag"
    end
  end
end
