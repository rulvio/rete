defmodule Rete.QueryParamsTest do
  @moduledoc """
  The head of a query is the argument list of the function it generates. It is a list of
  Elixir patterns, and a call matches them. What the patterns bind keys the matches.

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

  # One set of conditions, read through four head shapes. A head decides what a call
  # writes, and nothing else.
  defmodule Shapes do
    use Rete.Ruleset

    defquery by_pair(cid, tid)({:rec, cid, tid, amt}), do: {cid, tid, amt}
    defquery by_tuple({cid, tid})({:rec, cid, tid, amt}), do: {cid, tid, amt}
    defquery by_map(%{cid: cid, tid: tid})({:rec, cid, tid, amt}), do: {cid, tid, amt}
    defquery by_list(cid: cid, tid: tid)({:rec, cid, tid, amt}), do: {cid, tid, amt}
  end

  defp run(module, facts) do
    [module] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp facts_for(n) do
    for i <- 1..n, do: {:rec, rem(i, 4), rem(i, 3), i}
  end

  # The functions a ruleset exports under the given names. A module exports the generated
  # expression and RHS functions too, and those are not what a caller writes.
  defp arities(module, names) do
    module.__info__(:functions) |> Enum.filter(&(elem(&1, 0) in names)) |> Enum.sort()
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
        assert expected(plain, cid: cid) == Keyed.by_cid(keyed, cid),
               "disagreed on cid: #{cid}"

        for tid <- 0..3 do
          assert expected(plain, cid: cid, tid: tid) ==
                   Keyed.by_pair(keyed, cid, tid),
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

        assert expected(plain, cid: cid) == Keyed.by_cid(keyed, cid)

        assert expected(plain, cid: cid, tid: tid) ==
                 Keyed.by_pair(keyed, cid, tid)
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
        assert expected(plain, cid: cid) == Keyed.by_cid(keyed, cid),
               "disagreed on cid: #{cid}"
      end
    end

    test "a parameter value nothing matches answers empty, not an error" do
      keyed = run(Keyed, facts_for(12))

      assert [] == Keyed.by_cid(keyed, 99)
      assert [] == Keyed.by_pair(keyed, 0, 99)
    end

    test "a headless query still answers in arrival order" do
      facts = [{:rec, 3, 1, 9}, {:rec, 1, 2, 4}, {:rec, 2, 0, 7}]

      assert [{3, 1, 9}, {1, 2, 4}, {2, 0, 7}] == Plain.rows(run(Plain, facts))
    end

    # The head decides the shape of the call, and nothing else. Four heads over the same
    # conditions answer identically.
    test "the shape of the head does not change the answer" do
      session = run(Shapes, facts_for(12))

      rows = Shapes.by_pair(session, 1, 1)

      assert rows == Shapes.by_tuple(session, {1, 1})
      assert rows == Shapes.by_map(session, %{cid: 1, tid: 1})
      assert rows == Shapes.by_list(session, cid: 1, tid: 1)
    end
  end

  # The head is the argument list of the generated function, so a call that does not match
  # it fails the way any other function call fails. Nothing here reaches the engine.
  describe "a call the head does not match" do
    setup do
      %{session: run(Keyed, facts_for(12))}
    end

    # A head of N patterns gives `name/(N+1)`, and nothing else. So a call of the wrong
    # shape does not resolve, and the compiler says so at the call site.
    test "a head of N patterns generates one function, of arity N plus one" do
      assert [by_cid: 2, by_pair: 3] == arities(Keyed, [:by_cid, :by_pair])
      assert [rows: 1] == arities(Plain, [:rows])
    end

    test "a keyword head matches in the order it was declared" do
      session = run(Shapes, facts_for(12))

      assert [_ | _] = Shapes.by_list(session, cid: 1, tid: 1)
      assert_raise FunctionClauseError, fn -> Shapes.by_list(session, tid: 1, cid: 1) end
    end

    test "a map head accepts a call that carries more keys" do
      session = run(Shapes, facts_for(12))

      assert Shapes.by_map(session, %{cid: 1, tid: 1}) ==
               Shapes.by_map(session, %{cid: 1, tid: 1, extra: :ignored})
    end

    test "a tuple head refuses a value of another shape" do
      session = run(Shapes, facts_for(12))

      assert_raise FunctionClauseError, fn -> Shapes.by_tuple(session, {1, 1, 1}) end
    end

    # A map key compares by term, and not by `==`. This is the one call whose answer
    # changes without a message.
    test "a parameter matches by term, so 1.0 is not 1", %{session: session} do
      assert [] == Keyed.by_cid(session, 1.0)
      refute [] == Keyed.by_cid(session, 1)
    end
  end

  # `Rete.Session.query/3` is dispatched by `{module, name}` at run time, so it cannot know
  # the head pattern. It takes the bindings the pattern makes, and it keeps the check that
  # the generated function no longer needs. A partial key is not a more narrow lookup. It
  # is a different key, and nothing is stored under it.
  describe "what Session.query/3 may name" do
    setup do
      %{session: run(Keyed, facts_for(12))}
    end

    test "it takes the bindings, not the head", %{session: session} do
      assert Keyed.by_pair(session, 1, 1) ==
               Session.query(session, {Keyed, :by_pair}, cid: 1, tid: 1)

      shapes = run(Shapes, facts_for(12))

      assert Shapes.by_tuple(shapes, {1, 1}) ==
               Session.query(shapes, {Shapes, :by_tuple}, cid: 1, tid: 1)
    end

    test "every parameter, or it is refused", %{session: session} do
      error =
        assert_raise ArgumentError, fn -> Session.query(session, {Keyed, :by_pair}, cid: 1) end

      assert error.message =~ "takes parameters [:cid, :tid]"
      assert error.message =~ "was given [:cid]"
    end

    test "and nothing beyond them", %{session: session} do
      error =
        assert_raise ArgumentError, fn ->
          Session.query(session, {Keyed, :by_cid}, cid: 1, amt: 3)
        end

      assert error.message =~ "takes parameters [:cid]"
      assert error.message =~ "was given [:amt, :cid]"
    end

    test "a binding the query does not have is refused the same way", %{session: session} do
      error =
        assert_raise ArgumentError, fn -> Session.query(session, {Keyed, :by_cid}, nope: 1) end

      assert error.message =~ "takes parameters [:cid]"
      assert error.message =~ "was given [:nope]"
    end

    test "a parameterised query refuses an empty call", %{session: session} do
      error = assert_raise ArgumentError, fn -> Session.query(session, {Keyed, :by_cid}) end

      assert error.message =~ "takes parameters [:cid]"
      assert error.message =~ "was given []"
    end

    test "a headless query refuses any parameter, and says what to write" do
      session = run(Plain, facts_for(12))

      error = assert_raise ArgumentError, fn -> Session.query(session, {Plain, :rows}, cid: 1) end

      assert error.message =~ "takes no parameters"
      assert error.message =~ "was given [:cid]"
      assert error.message =~ "defquery rows(cid)(...)"
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

    # The head is a pattern, so a repeated variable means what it means in Elixir: the two
    # values have to be equal. It contributes one key, not two.
    test "the same variable twice is an equality constraint" do
      defmodule Repeated do
        use Rete.Ruleset

        defquery rows(cid, cid)({:rec, cid, tid}), do: {cid, tid}
      end

      session = run(Repeated, [{:rec, 1, 7}, {:rec, 2, 8}])

      assert [{1, 7}] == Repeated.rows(session, 1, 1)
      assert_raise FunctionClauseError, fn -> Repeated.rows(session, 1, 2) end
    end

    # A head of literals binds nothing, so it keys on nothing and answers with every match.
    # The argument is an assertion at the call site, and that is all.
    test "a head may bind nothing at all" do
      defmodule LiteralHead do
        use Rete.Ruleset

        defquery rows(:tick)({:rec, cid}), do: cid
      end

      session = run(LiteralHead, [{:rec, 1}, {:rec, 2}])

      assert [1, 2] == LiteralHead.rows(session, :tick)
      assert_raise FunctionClauseError, fn -> LiteralHead.rows(session, :tock) end
    end

    # A head is the argument list of a `def`, so a `_`-prefixed name means there what it
    # means there. It labels a position the query accepts and ignores. It keys nothing, so
    # the head keys on the rest, and the call still has to match the shape.
    test "a discarded name in a head labels a position and keys nothing" do
      defmodule DiscardedHead do
        use Rete.Ruleset

        defquery rows({_cid, tid})({:rec, cid, tid, amt}), do: {cid, tid, amt}
      end

      session = run(DiscardedHead, [{:rec, 1, 5, 10}, {:rec, 2, 5, 20}, {:rec, 1, 6, 30}])

      # Keyed on `tid` alone, so the first element of the call is a label and not a key.
      assert [{1, 5, 10}, {2, 5, 20}] == DiscardedHead.rows(session, {1, 5})
      assert DiscardedHead.rows(session, {1, 5}) == DiscardedHead.rows(session, {99, 5})
      assert [{1, 6, 30}] == DiscardedHead.rows(session, {1, 6})

      # The shape still has to match, because the head is still a pattern.
      assert_raise FunctionClauseError, fn -> DiscardedHead.rows(session, 5) end
    end

    # A head of nothing but discarded names keys on nothing, in the way a head of literals
    # does. The arity is what the caller sees.
    test "a head of discarded names alone takes arguments and keys on nothing" do
      defmodule AllDiscarded do
        use Rete.Ruleset

        defquery rows(_cid, _)({:rec, cid}), do: cid
      end

      session = run(AllDiscarded, [{:rec, 1}, {:rec, 2}])

      assert [rows: 3] == arities(AllDiscarded, [:rows])
      assert [1, 2] == AllDiscarded.rows(session, :anything, :at_all)
    end

    # A head is an argument list, so a default means there what it means in any `def`. It
    # gives the query a second arity, and the default value keys the matches.
    test "a head pattern may carry a default" do
      defmodule DefaultHead do
        use Rete.Ruleset

        defquery rows(cid \\ 1)({:rec, cid, amt}), do: {cid, amt}
      end

      session = run(DefaultHead, [{:rec, 1, 10}, {:rec, 2, 20}])

      assert [rows: 1, rows: 2] == arities(DefaultHead, [:rows])
      assert [{1, 10}] == DefaultHead.rows(session)
      assert DefaultHead.rows(session) == DefaultHead.rows(session, 1)
      assert [{2, 20}] == DefaultHead.rows(session, 2)
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

      assert [{1, 5}] == GuardedHead.rows(session, 1)
    end

    test "a head survives a leading options map" do
      defmodule OptionsHead do
        use Rete.Ruleset

        defquery rows(cid)(%{salience: 10}, {:rec, cid, amt}), do: {cid, amt}
      end

      session = run(OptionsHead, [{:rec, 1, 5}, {:rec, 2, 9}])

      assert [{1, 5}] == OptionsHead.rows(session, 1)
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

  # A head guard is a test on the left hand side, and nothing else. That is sound because a
  # query is read by term equality. The guard holds of an argument exactly when it holds of
  # the binding that the argument matches. So the store holds no match the guard rejects,
  # and a call that names a rejected value finds nothing.
  describe "a head guard" do
    defmodule Guarded do
      use Rete.Ruleset

      defquery big(cid, amt when amt > 1000)({:sale, cid, amt}), do: {cid, amt}
      defquery ordered(cid, tid when cid < tid)({:rec, cid, tid, amt}), do: {cid, tid, amt}

      defquery both(cid when is_integer(cid), tid when tid > 0)({:rec, cid, tid, amt}),
        do: {cid, tid, amt}
    end

    @sales [{:sale, 1, 5_000}, {:sale, 1, 5}, {:sale, 2, 9_000}]

    # `[]` and not a raise. The guard pruned the store, so the call asks a key that holds
    # nothing, which is the same answer a value nothing matches gets.
    test "a call it does not hold for answers empty" do
      session = run(Guarded, @sales)

      assert [{1, 5_000}] == Guarded.big(session, 1, 5_000)
      assert [] == Guarded.big(session, 1, 5)
    end

    # The store is the only thing the guard acts on, so the two paths into it cannot
    # disagree. Neither one carries the guard itself.
    test "it prunes the store, so Session.query/3 agrees" do
      session = run(Guarded, @sales)

      assert [{1, 5_000}] == Session.query(session, {Guarded, :big}, cid: 1, amt: 5_000)
      assert [] == Session.query(session, {Guarded, :big}, cid: 1, amt: 5)
      assert Guarded.big(session, 1, 5) == Session.query(session, {Guarded, :big}, cid: 1, amt: 5)
    end

    test "a guard on the last pattern may read an earlier one" do
      session = run(Guarded, [{:rec, 1, 2, 10}, {:rec, 3, 2, 30}])

      assert [{1, 2, 10}] == Guarded.ordered(session, 1, 2)
      assert [] == Guarded.ordered(session, 3, 2)
    end

    # The guards above all read one condition, so they lift into an alpha. This one reads
    # two, so `Rete.DSL.Bindings` has to leave it as a join filter. That is the other half
    # of the split, and a head guard reaches it by the same path a rule level guard does.
    test "a head guard that reads two conditions becomes a join filter" do
      defmodule JoinGuard do
        use Rete.Ruleset

        defquery pair(cid, tid when cid < tid)({:a, cid}, {:b, tid}), do: {cid, tid}
      end

      session = run(JoinGuard, [{:a, 1}, {:a, 5}, {:b, 3}, {:b, 9}])

      assert [{1, 3}] == JoinGuard.pair(session, 1, 3)
      assert [{5, 9}] == JoinGuard.pair(session, 5, 9)
      assert [] == JoinGuard.pair(session, 5, 3)
      assert [] == Session.query(session, {JoinGuard, :pair}, cid: 5, tid: 3)
    end

    # A head guard sits with the rest of the left hand side, so a gate downstream of it
    # does not change what it does.
    test "a head guard coexists with a negation and with a collection" do
      defmodule GatedGuard do
        use Rete.Ruleset

        defquery open(cid when cid > 0)({:a, cid}, {:not, [{:blocked, cid}]}), do: cid
        defquery sized(cid when cid > 0)({:a, cid}, xs = [{:b, cid, _n}]), do: {cid, length(xs)}
      end

      session = run(GatedGuard, [{:a, 1}, {:a, 2}, {:blocked, 2}, {:b, 1, 10}, {:b, 1, 20}])

      assert [1] == GatedGuard.open(session, 1)
      assert [] == GatedGuard.open(session, 2)
      assert [{1, 2}] == GatedGuard.sized(session, 1)
    end

    test "two guards both apply" do
      session = run(Guarded, [{:rec, 1, 2, 10}, {:rec, 1, 0, 20}])

      assert [{1, 2, 10}] == Guarded.both(session, 1, 2)
      assert [] == Guarded.both(session, 1, 0)
      assert [] == Guarded.both(session, :nope, 2)
    end

    # The point of keeping the guard off the generated clause. A test on the left hand side
    # is a compiled function, so it may call anything. A guard on a clause may not, and this
    # declaration would not compile.
    test "a head guard may be any expression, and not only a valid Elixir guard" do
      defmodule RichGuard do
        use Rete.Ruleset

        defquery named(name when String.length(name) > 3)({:user, name, id}), do: {name, id}
      end

      session = run(RichGuard, [{:user, "Ada", 1}, {:user, "Grace", 2}])

      assert [{"Grace", 2}] == RichGuard.named(session, "Grace")
      assert [] == RichGuard.named(session, "Ada")
    end

    test "a head guard and a rule level guard coexist" do
      defmodule TwoGuards do
        use Rete.Ruleset

        defquery rows(cid when cid > 0)({:rec, cid, amt}) when amt > 1, do: {cid, amt}
      end

      session = run(TwoGuards, [{:rec, 1, 0}, {:rec, 1, 5}, {:rec, 2, 9}])

      assert [{1, 5}] == TwoGuards.rows(session, 1)
      assert [] == TwoGuards.rows(session, 0)
    end

    # A head guard constrains the call, so it reads only what the head binds. The rule
    # level guard is the one that reads the rest.
    test "a guard that reads a binding the head does not make is refused" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule OutsideGuard do
            use Rete.Ruleset

            defquery rows(cid when amt > 1)({:rec, cid, amt}), do: {cid, amt}
          end
        end

      assert error.message =~ "the head guard of rows reads [:amt]"
      assert error.message =~ "which the head does not bind"
      assert error.message =~ "`defquery rows(cid)(...) when amt > 1`"
    end

    # A `_`-prefixed name is discarded by the pattern that writes it, so moving the guard
    # to the conditions would fail there too. The message has to name the real mistake.
    test "a guard reading a discarded name says to rename it" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule DiscardedGuard do
            use Rete.Ruleset

            defquery rows(_cid when _cid > 0)({:rec, _cid}), do: 1
          end
        end

      assert error.message =~ "starts with `_` is discarded"
      assert error.message =~ "Rename `_cid` to `cid`"
      refute error.message =~ "write a rule level guard"
    end

    # The guard becomes a test on the left hand side, so the check that a variable is
    # bound on every path reports it. It has to call it a head guard, because a head guard
    # cannot move onto a condition the way a rule level guard can.
    test "a guard on a variable only some disjunction branches bind names the head" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule OptionalGuard do
            use Rete.Ruleset

            defquery rows(x when x > 0)({:or, [{:a, x}, {:b, y}]}), do: {x, y}
          end
        end

      assert error.message =~ "the head guard `x > 0` reads `x`"
      assert error.message =~ "A head guard keys the matches of the query"
      assert error.message =~ "write one query for each branch"
      refute error.message =~ "rule level guard"
    end

    # And the rule level guard keeps its own wording, which points at the condition.
    test "the same guard written after the conditions still reads as a rule level guard" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule OptionalRuleGuard do
            use Rete.Ruleset

            defquery rows({:or, [{:a, x}, {:b, y}]}) when x > 0, do: {x, y}
          end
        end

      assert error.message =~ "the rule level guard `x > 0` reads `x`"
      assert error.message =~ "put such a guard on the condition"
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

      assert [{1, 5}] == MetaQuery.rows(session, 1)
      assert [production] = Rete.get_rule_data([MetaQuery])
      assert :internal == Keyword.get(production.opts, :meta)
    end
  end

  # `index/2` was how 0.6 declared a second keying. The head is the only keying now, so the
  # macro exists purely to say what to write instead. "undefined function index/2" would
  # not, which is why it was kept rather than deleted.
  describe "the index/2 declaration that a head replaced" do
    test "it names the head to write in its place" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule Legacy do
            use Rete.Ruleset

            index(:rows, [:cid])

            defquery rows(cid)({:rec, cid, amt}), do: {cid, amt}
          end
        end

      assert error.message =~ "index :rows, [:cid] is no longer a declaration"
      assert error.message =~ "`defquery rows(cid)(<conditions>)`"
      assert error.message =~ "there is no second index to declare"
    end

    test "a bare key is named the same way as a list of them" do
      error =
        assert_raise ArgumentError, fn ->
          defmodule LegacyBare do
            use Rete.Ruleset

            index(:rows, :cid)

            defquery rows(cid)({:rec, cid, amt}), do: {cid, amt}
          end
        end

      assert error.message =~ "`defquery rows(cid)(<conditions>)`"
    end
  end
end
