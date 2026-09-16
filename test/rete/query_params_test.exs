defmodule Rete.QueryParamsTest do
  @moduledoc """
  The head of a query declares its parameters. They key its matches, and a call names
  exactly those parameters.

  The most important test here is not that a query with a head is faster. It is that the
  query answers with the same rows, in the same order, as a filter in Elixir on the result
  of a query with no head. An incorrect keying gives a missing row. This looks like an
  empty result, and not like a failure.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Rete.Session

  defmodule Plain do
    use Rete.Ruleset

    defquery rows({:rec, cid, tid, amt}), do: {cid, tid, amt}
  end

  defmodule Keyed do
    use Rete.Ruleset

    defquery by_cid(cid)({:rec, cid, tid, amt}), do: {cid, tid, amt}
    defquery by_pair(cid, tid)({:rec, cid, tid, amt}), do: {cid, tid, amt}
  end

  defp run(module, facts) do
    [module] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp facts_for(n) do
    for i <- 1..n, do: {:rec, rem(i, 4), rem(i, 3), i}
  end

  # The answer from a query with no head, plus a filter in Elixir. The keyed query must
  # match this answer, row for row, and in the same order.
  defp expected(session, keys) do
    session
    |> Plain.rows()
    |> Enum.filter(fn {cid, tid, _amt} ->
      Enum.all?(keys, fn
        {:cid, value} -> cid == value
        {:tid, value} -> tid == value
      end)
    end)
  end

  describe "a parameter never changes an answer" do
    test "every parameter value agrees with filtering the headless query" do
      facts = facts_for(60)
      plain = run(Plain, facts)
      keyed = run(Keyed, facts)

      for cid <- 0..4 do
        assert expected(plain, cid: cid) == Keyed.by_cid(keyed, cid: cid),
               "disagreed on cid: #{cid}"

        for tid <- 0..3 do
          assert expected(plain, cid: cid, tid: tid) ==
                   Keyed.by_pair(keyed, cid: cid, tid: tid),
                 "disagreed on cid: #{cid}, tid: #{tid}"
        end
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
        keyed = run(Keyed, facts)

        assert expected(plain, cid: cid) == Keyed.by_cid(keyed, cid: cid)

        assert expected(plain, cid: cid, tid: tid) ==
                 Keyed.by_pair(keyed, cid: cid, tid: tid)
      end
    end

    test "and keeps agreeing after retraction" do
      facts = facts_for(30)
      dropped = Enum.take_every(facts, 3)

      drop = fn session ->
        session |> Session.retract(dropped) |> Session.fire_rules()
      end

      plain = Plain |> run(facts) |> drop.()
      keyed = Keyed |> run(facts) |> drop.()

      for cid <- 0..4 do
        assert expected(plain, cid: cid) == Keyed.by_cid(keyed, cid: cid),
               "disagreed on cid: #{cid}"
      end
    end

    test "a parameter value nothing matches answers empty, not an error" do
      keyed = run(Keyed, facts_for(12))

      assert [] == Keyed.by_cid(keyed, cid: 99)
      assert [] == Keyed.by_pair(keyed, cid: 0, tid: 99)
    end

    test "a headless query still answers in arrival order" do
      facts = [{:rec, 3, 1, 9}, {:rec, 1, 2, 4}, {:rec, 2, 0, 7}]

      assert [{3, 1, 9}, {1, 2, 4}, {2, 0, 7}] == Plain.rows(run(Plain, facts))
    end

    test "parameter order in the call does not matter" do
      keyed = run(Keyed, facts_for(12))

      assert Keyed.by_pair(keyed, cid: 1, tid: 1) == Keyed.by_pair(keyed, tid: 1, cid: 1)
    end

    test "a map of parameters reads the same as a keyword list" do
      keyed = run(Keyed, facts_for(12))

      assert Keyed.by_cid(keyed, cid: 1) == Keyed.by_cid(keyed, %{cid: 1})
    end
  end

  # The parameters key the store. A partial set is thus not a more narrow lookup. It is a
  # different key, and nothing is stored under it. An answer of `[]` would be incorrect,
  # so each of these raises an error.
  describe "what a call may name" do
    setup do
      %{session: run(Keyed, facts_for(12))}
    end

    test "every parameter, or it is refused", %{session: session} do
      error = assert_raise ArgumentError, fn -> Keyed.by_pair(session, cid: 1) end

      assert error.message =~ "takes parameters [:cid, :tid]"
      assert error.message =~ "was given [:cid]"
    end

    test "and nothing beyond them", %{session: session} do
      error = assert_raise ArgumentError, fn -> Keyed.by_cid(session, cid: 1, amt: 3) end

      assert error.message =~ "takes parameters [:cid]"
      assert error.message =~ "was given [:amt, :cid]"
    end

    test "a binding the query does not have is refused the same way", %{session: session} do
      error = assert_raise ArgumentError, fn -> Keyed.by_cid(session, nope: 1) end

      assert error.message =~ "takes parameters [:cid]"
      assert error.message =~ "was given [:nope]"
    end

    test "a parameterised query refuses an empty call", %{session: session} do
      error = assert_raise ArgumentError, fn -> Keyed.by_cid(session) end

      assert error.message =~ "takes parameters [:cid]"
      assert error.message =~ "was given []"
    end

    test "a headless query refuses any parameter, and says what to write" do
      session = run(Plain, facts_for(12))

      error = assert_raise ArgumentError, fn -> Plain.rows(session, cid: 1) end

      assert error.message =~ "takes no parameters"
      assert error.message =~ "was given [:cid]"
      assert error.message =~ "defquery rows(cid)(...)"
    end

    # A map key compares by term, and not by `==`. `Session.query/3` records this, because
    # the old filter used `==`. This is the one call whose answer changes without a
    # message.
    test "a parameter matches by term, so 1.0 is not 1", %{session: session} do
      assert [] == Keyed.by_cid(session, cid: 1.0)
      refute [] == Keyed.by_cid(session, cid: 1)
    end
  end

  describe "declaring a head" do
    test "a parameter has to be something the query binds" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule UnknownParam do
            use Rete.Ruleset

            defquery rows(nope)({:rec, cid}), do: cid
          end
        end

      assert error.message =~ "defquery rows(nope) names [:nope]"
      assert error.message =~ "It binds [:cid]"
    end

    # A disjunction binds the union of its branches. A variable that only one branch binds
    # is thus absent from the tokens of the other branch. Those tokens would key on its
    # absence, and no call could name them. To reject it is the only correct answer.
    test "a parameter only some branches of a disjunction bind is refused" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule OptionalParam do
            use Rete.Ruleset

            defquery rows(x)({:or, [{:a, x}, {:b, y}]}), do: {x, y}
          end
        end

      assert error.message =~ "only some branches of its disjunction bind"
      assert error.message =~ "every match must carry it"
    end

    test "a rule cannot take parameters" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule ParameterisedRule do
            use Rete.Ruleset

            defrule flag(cid)({:rec, cid}), do: {:flagged, cid}
          end
        end

      assert error.message =~ "flag(cid) gives a rule a head"
      assert error.message =~ "a rule cannot take parameters"
    end

    # `defrule r()(...)` declares no parameters, so the engine could accept it. But it has
    # the shape of a query. A person who intended a query would then believe that they had
    # written one.
    test "a rule cannot carry an empty head either" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule EmptyHeadRule do
            use Rete.Ruleset

            defrule flag()({:rec, cid}), do: {:flagged, cid}
          end
        end

      assert error.message =~ "flag() gives a rule a head"
    end

    test "the same parameter twice is an error" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule Repeated do
            use Rete.Ruleset

            defquery rows(cid, cid)({:rec, cid, tid}), do: {cid, tid}
          end
        end

      assert error.message =~ "repeats cid"
    end

    test "a head takes variables, not values" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule LiteralHead do
            use Rete.Ruleset

            defquery rows(1)({:rec, cid}), do: cid
          end
        end

      assert error.message =~ "takes a bare variable in its head, got: 1"
    end

    # `()` and no head make the same statement: this query takes no parameters.
    test "an empty head is a query with no parameters" do
      defmodule EmptyHead do
        use Rete.Ruleset

        defquery rows()({:rec, cid}), do: cid
      end

      session = run(EmptyHead, [{:rec, 1}, {:rec, 2}])

      assert [1, 2] == EmptyHead.rows(session)
    end

    test "a head survives a rule level guard" do
      defmodule GuardedHead do
        use Rete.Ruleset

        defquery rows(cid)({:rec, cid, amt}) when amt > 1, do: {cid, amt}
      end

      session = run(GuardedHead, [{:rec, 1, 0}, {:rec, 1, 5}, {:rec, 2, 9}])

      assert [{1, 5}] == GuardedHead.rows(session, cid: 1)
    end

    test "a head survives a leading options map" do
      defmodule OptionsHead do
        use Rete.Ruleset

        defquery rows(cid)(%{salience: 10}, {:rec, cid, amt}), do: {cid, amt}
      end

      session = run(OptionsHead, [{:rec, 1, 5}, {:rec, 2, 9}])

      assert [{1, 5}] == OptionsHead.rows(session, cid: 1)
    end

    # The head is part of the declaration, so it is part of the production hash. Two
    # modules with queries that differ only in the head must not share a terminal.
    test "a changed head changes the module version" do
      defmodule VersionA do
        use Rete.Ruleset

        defquery rows({:rec, cid, amt}), do: {cid, amt}
      end

      defmodule VersionB do
        use Rete.Ruleset

        defquery rows(cid)({:rec, cid, amt}), do: {cid, amt}
      end

      refute VersionA.get_version() == VersionB.get_version()
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
      assert error.message =~ "takes [:salience, :internal_salience, :generated, :meta]"
      refute error.message =~ "defquery"
    end

    # A leading map literal is the options map unless it carries `__type__`. A map fact
    # pattern that omits its type is therefore refused as an options map. The parser's own
    # "declare its type with __type__" message cannot be reached in first position, but the
    # same pattern one slot later does produce it. The error must name both readings.
    # Otherwise the message depends on where the condition appears.
    test "a first position map fact pattern that forgot __type__ is told so" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule Untyped do
            use Rete.Ruleset

            defrule flag(%{cid: cid}), do: {:flagged, cid}
          end
        end

      assert error.message =~ "sets [:cid]"
      assert error.message =~ "__type__"
    end

    # `:meta` is the one option the engine never reads. A ruleset author uses it to
    # attach their own data, read back later through `Rete.get_rule_data/1`.
    test "a meta option is not interpreted, and passes through unchanged" do
      defmodule Meta do
        use Rete.Ruleset

        defrule flag(%{salience: 10, meta: %{owner: "team-x"}}, {:rec, cid}) do
          {:flagged, cid}
        end
      end

      assert [production] = Rete.get_rule_data([Meta])
      assert %{owner: "team-x"} == Keyword.get(production.opts, :meta)
    end

    test "a meta option combines with a query's head" do
      defmodule MetaQuery do
        use Rete.Ruleset

        defquery rows(cid)(%{meta: :internal}, {:rec, cid, amt}), do: {cid, amt}
      end

      session = run(MetaQuery, [{:rec, 1, 5}, {:rec, 2, 9}])

      assert [{1, 5}] == MetaQuery.rows(session, cid: 1)
      assert [production] = Rete.get_rule_data([MetaQuery])
      assert :internal == Keyword.get(production.opts, :meta)
    end
  end
end
