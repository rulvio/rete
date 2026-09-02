defmodule Rete.DisjunctionTest do
  @moduledoc """
  Disjunctions at scale: many branches, and many disjunctions in one rule.

  The hand-written cases elsewhere cover what a disjunction *means* — a nested
  conjunction, a disjunction of negations, which variables survive. What they
  cannot cover is shape, because a rule wide or deep enough to show it is not
  something anyone writes out by hand. These generate the rule.

  Two claims are pinned here. `Rete.Compiler.BetaGraph` says it never flattens a
  left hand side to disjunctive normal form, because "whole-LHS DNF costs work
  exponential in the number of disjunctions, while fanning out per condition
  costs only linear work" — so the network for d disjunctions has to stay linear
  in d. And `Rete.DSL.Normalize` caps a gate at `max_branches/0`, which nothing
  was checking either way.
  """

  use ExUnit.Case, async: true

  alias Rete.Compiler.BetaGraph
  alias Rete.Session

  @branches Rete.DSL.Normalize.max_branches()

  # One disjunction, `b` branches, all binding `x`.
  defp wide(name, b) do
    branches = for i <- 1..b, do: quote(do: {unquote(:"t#{i}"), x})

    create(name, quote(do: defrule(wide({:or, unquote(branches)}), do: {:hit, x})))
  end

  # `d` disjunctions of `b` branches, in sequence, all joining on `x`.
  defp deep(name, d, b) do
    conds =
      for j <- 1..d do
        branches = for i <- 1..b, do: quote(do: {unquote(:"t#{j}_#{i}"), x})
        quote(do: {:or, unquote(branches)})
      end

    create(name, quote(do: defrule(deep(unquote_splicing(conds)), do: {:hit, x})))
  end

  defp create(name, rule) do
    Module.create(
      name,
      quote(
        do:
          (
            use(Rete.Ruleset)
            unquote(rule)
          )
      ),
      Macro.Env.location(__ENV__)
    )

    name
  end

  defp run(module, facts) do
    [module] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp node_count(module) do
    [module]
    |> Rete.Compiler.build()
    |> Map.fetch!(:graph)
    |> BetaGraph.filter(fn _ -> true end)
    |> length()
  end

  describe "many branches" do
    test "each matching branch is its own support, and they retract one at a time" do
      module = wide(Wide64, 64)

      # Three branches match `x = 1`, one matches `x = 2`.
      session = run(module, [{:t1, 1}, {:t7, 1}, {:t64, 1}, {:t2, 2}])

      assert %{{:hit, 1} => 3, {:hit, 2} => 1} =
               Map.take(session.state.memory.facts, [{:hit, 1}, {:hit, 2}])

      # Dropping one branch leaves the other two holding it up.
      session = session |> Session.retract({:t7, 1}) |> Session.fire_rules()
      assert %{{:hit, 1} => 2} = Map.take(session.state.memory.facts, [{:hit, 1}])

      session =
        session
        |> Session.retract([{:t1, 1}, {:t64, 1}])
        |> Session.fire_rules()

      refute Map.has_key?(session.state.memory.facts, {:hit, 1})
      assert Map.has_key?(session.state.memory.facts, {:hit, 2})
    end

    test "the network grows one node per branch, plus the terminal" do
      assert 65 == node_count(wide(Wide64Shape, 64))
    end
  end

  describe "many disjunctions" do
    # The claim `BetaGraph` makes, at the size where it would show. Eight
    # disjunctions of three branches is 3^8 = 6,561 paths under whole-LHS DNF.
    test "the network stays linear in the number of disjunctions, not exponential" do
      for d <- [1, 2, 4, 8] do
        module = deep(Module.concat(Deep, "D#{d}"), d, 3)

        assert 3 * d + 1 == node_count(module),
               "d = #{d}: three branch nodes per disjunction and one terminal"
      end
    end

    test "matches are still the cross product of the branches that match" do
      # Every branch of all three disjunctions matches x = 1, so the rule holds
      # 2 * 2 * 2 ways. That product is the semantics. Only the *network* is
      # linear.
      module = deep(DeepCross, 3, 2)

      facts =
        for j <- 1..3, i <- 1..2, do: {:"t#{j}_#{i}", 1}

      session = run(module, facts)

      assert %{{:hit, 1} => 8} = Map.take(session.state.memory.facts, [{:hit, 1}])

      # Removing one branch of the first disjunction halves it.
      session = session |> Session.retract({:t1_1, 1}) |> Session.fire_rules()
      assert %{{:hit, 1} => 4} = Map.take(session.state.memory.facts, [{:hit, 1}])
    end
  end

  describe "the branch cap" do
    test "a gate at the limit compiles" do
      assert @branches + 1 == node_count(wide(AtLimit, @branches))
    end

    test "a gate over the limit is refused, naming the limit and a way out" do
      error =
        assert_raise ArgumentError, fn ->
          wide(OverLimit, @branches + 1)
        end

      assert error.message =~ "#{@branches + 1} disjunctive branches"
      assert error.message =~ "over the limit of #{@branches}"
      assert error.message =~ "split the rule"
    end
  end
end
