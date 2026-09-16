defmodule Rete.QueryParamsTest do
  @moduledoc """
  A query's head declares its parameters. They key its matches, and a call names exactly
  them.

  The load-bearing test here is not that a parameterised query is faster. It is that it
  answers with the same rows, in the same order, as filtering a headless query's result in
  Elixir would. The failure mode of a wrong keying is a missing row, which reads as an
  empty result rather than a crash.
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

  # What a headless query plus an Elixir filter answers. This is the reference the keyed
  # query has to match, row for row and in order.
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

  # The parameters key the store, so a partial set is not a narrower lookup — it is a
  # different key nothing is filed under. Answering `[]` there would be silently wrong,
  # which is why each of these raises.
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

    # A map key compares by term, not by `==`. `Session.query/3` says so, because the old
    # filter used `==` and this is the one call that silently changes answer.
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

    # A disjunction binds the union of its branches, so a variable only one branch binds
    # is absent from the other's tokens. Those tokens would key on its absence, and no
    # call could name them. Rejecting it is the only honest answer.
    test "a parameter only some branches of a disjunction bind is refused" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule OptionalParam do
            use Rete.Ruleset

            defquery rows(x)({:or, [{:a, x}, {:b, y}]}), do: {x, y}
          end
        end

      assert error.message =~ "only some branches of its disjunction bind"
      assert error.message =~ "every match carries"
    end

    test "a rule cannot take parameters" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule ParameterisedRule do
            use Rete.Ruleset

            defrule flag(cid)({:rec, cid}), do: {:flagged, cid}
          end
        end

      assert error.message =~ "flag(cid) declares parameters"
      assert error.message =~ "a rule cannot take them"
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

    # `()` and no head at all are the same claim: this query takes no parameters.
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
    # modules whose queries differ only in their head must not share a terminal.
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
      assert error.message =~ "defquery flag(cid)(...)"
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
  end
end
