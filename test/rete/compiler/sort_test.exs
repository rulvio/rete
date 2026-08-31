defmodule Rete.Compiler.SortTest do
  use ExUnit.Case, async: true

  alias Rete.Compiler.Sort
  alias Rete.DSL.Normalize
  alias Rete.DSL.Parser
  alias Rete.IR

  doctest Rete.Compiler.Sort

  # --- helpers ---------------------------------------------------------------

  # Parse from source, the way `defrule` sees it, and normalize: the sort runs
  # on a gate free LHS.
  defp parse(decl) do
    production = Parser.parse_production(__ENV__, Code.string_to_quoted!(decl), nil, :rule)
    %IR.Production{production | lhs: Normalize.normalize_lhs(production.lhs)}
  end

  defp sort(decl), do: decl |> parse() |> Sort.sort()

  # The LHS as a readable shape, so an ordering assertion is one line.
  defp order(decl), do: decl |> sort() |> Map.get(:lhs) |> Enum.map(&label/1)

  defp label(%IR.Fact{type: type}), do: type
  defp label(%IR.Coll{type: type}), do: {:coll, type}
  defp label(%IR.Test{bind: bind}), do: {:test, bind}
  defp label(%IR.Negation{condition: condition}), do: {:not, label(condition)}
  defp label(%IR.CompoundNegation{conditions: conditions}), do: {:not, labels(conditions)}
  defp label({:or, branches}), do: {:or, Enum.map(branches, &labels/1)}

  defp labels(elements), do: Enum.map(elements, &label/1)

  # The whole product of binding classification for one condition, so that two
  # productions can be compared for "the network would be the same".
  defp build(decl), do: Rete.Ruleset.build(__ENV__, Code.string_to_quoted!(decl), nil, :rule)

  defp classified(decl) do
    decl |> build() |> Map.get(:lhs) |> Enum.map(&shape/1)
  end

  defp shape(%IR.Fact{} = fact) do
    %{
      type: fact.type,
      bind: fact.bind,
      join_bind: fact.join_bind,
      new_bind: fact.new_bind,
      alpha: fact.alpha.code,
      join_filter: fact.join_filter && fact.join_filter.code
    }
  end

  # --- stability -------------------------------------------------------------

  describe "an LHS that is already in order" do
    test "is returned untouched" do
      production = parse("r({:threshold, t}, {:order, amt} when amt > t)")

      assert production.lhs == Sort.sort(production).lhs
    end

    test "keeps author order among conditions that are all satisfiable" do
      assert [:a, :b, :c, :d] == order("r({:a, p}, {:b, q}, {:c, s}, {:d, u})")
    end

    test "keeps author order among conditions that all join on the same variable" do
      assert [:user, :order, :invoice] ==
               order("r({:user, id}, {:order, id, amt}, {:invoice, id, n})")
    end

    test "sorting twice is sorting once" do
      once = "r({:order, amt} when amt > t, {:threshold, t})" |> sort()

      assert once.lhs == Sort.sort(once).lhs
    end

    test "only the blocked conditions move, the rest keep their order" do
      # `late` needs `t`. Everything else is satisfiable from the start, so the
      # batch keeps a, b, c together and in order
      assert [:a, :b, :c, :threshold, :late] ==
               order("r({:a, p}, {:late, w} when w > t, {:b, q}, {:c, s}, {:threshold, t})")
    end
  end

  # --- the sort itself -------------------------------------------------------

  describe "a condition is placed after the conditions that bind what it reads" do
    test "one swap" do
      assert [:threshold, :order] == order("r({:order, amt} when amt > t, {:threshold, t})")
    end

    test "a chain that needs a pass per link" do
      assert [:a, :b, :c] ==
               order("r({:c, z} when z > y, {:b, y} when y > x, {:a, x})")
    end

    test "a fact binding counts as bound downstream" do
      # `o` is the whole fact, which the engine puts in the token
      assert [:order, :audit] ==
               order("r({:audit, x} when elem(o, 1) == x, o = {:order, id})")
    end

    test "a pinned value and a module attribute are not needs" do
      assert [:order] == order("r({:order, amt} when amt > 10)")
    end

    test "a discarded variable is not a need, so the guard check reports it later" do
      # nothing can ever bind `_t`, so ordering is not the answer. The message
      # that tells the author to rename it comes from Rete.DSL.Bindings
      assert [:threshold, :order] == order("r({:threshold, _t}, {:order, amt} when amt > _t)")

      assert_raise ArgumentError, ~r/`_t`.*Rename it to `t`/s, fn ->
        build("r({:threshold, _t}, {:order, amt} when amt > _t)")
      end
    end
  end

  # --- collections -----------------------------------------------------------

  describe "a collection is deferred" do
    test "behind a plain condition that was written after it" do
      # written first it would propagate [] before `{:user, id}` is joined
      assert [:user, {:coll, :item}] == order("r(items = [{:item, id}], {:user, id})")
    end

    test "behind every plain condition, not just the ones it needs" do
      assert [:user, :tick, {:coll, :item}] ==
               order("r([{:item, id}], {:user, id}, {:tick})")
    end

    test "but is still placed when only collections remain" do
      assert [{:coll, :a}, {:coll, :b}] == order("r([{:a, x}], [{:b, y}])")
    end

    test "and collections keep author order between themselves" do
      assert [:user, {:coll, :item}, {:coll, :note}] ==
               order("r(items = [{:item, id}], notes = [{:note, id}], {:user, id})")
    end

    test "unless one collection needs what another binds" do
      assert [{:coll, :limit}, {:coll, :order}] ==
               order("r([{:order, amt} when amt > lim], [{:limit, lim}])")
    end
  end

  # --- negations -------------------------------------------------------------

  describe "a negation" do
    test "binds nothing downstream, so a later guard reading it cannot be ordered" do
      error =
        assert_raise ArgumentError, fn ->
          sort("r({:not, [{:threshold, t}]}, {:order, amt} when amt > t)")
        end

      assert error.message =~ "Unbound: `t`"
      assert error.message =~ "A negation binds nothing downstream"
    end

    test "does not require its own pattern variables to be bound upstream" do
      # "there is no order at all" is a legitimate reading, so `x` is
      # existential, not a need
      assert [{:not, :order}, :user] == order("r({:not, [{:order, x}]}, {:user, u})")
    end

    test "is placed after the condition its inner guard reads" do
      assert [:limit, {:not, :order}] ==
               order("r({:not, [{:order, amt} when amt > lim]}, {:limit, lim})")
    end

    test "of a conjunction has its conjunction sorted too" do
      assert [{:not, [:threshold, :order]}] ==
               order("r({:nand, [{:order, amt} when amt > t, {:threshold, t}]})")
    end

    test "of a conjunction needs only what its conjunction cannot bind itself" do
      assert [:limit, {:not, [:threshold, :order]}] ==
               order(
                 "r({:nand, [{:order, amt} when amt > t and amt > lim, {:threshold, t}]}, " <>
                   "{:limit, lim})"
               )
    end
  end

  # --- disjunctions ----------------------------------------------------------

  describe "a disjunction" do
    test "binds only what every branch binds" do
      assert [{:or, [[:gold], [:silver]]}, :order] ==
               order("r({:or, [{:gold, id, tier}, {:silver, id}]}, {:order, id, amt})")
    end

    test "a variable only one branch binds is left to Rete.DSL.Bindings" do
      # no ordering makes `tier` available after the disjunction, and the branch
      # that does bind it is named by the per path check one phase later, so the
      # conditions are handed on in author order rather than reported here
      decl = "r({:or, [{:gold, id, tier}, {:silver, id}]}, {:order, amt} when amt > tier)"

      assert [{:or, [[:gold], [:silver]]}, :order] == order(decl)

      assert_raise ArgumentError, ~r/reads `tier`, which is neither bound/, fn -> build(decl) end
    end

    test "needs whatever its branches cannot bind between them" do
      assert [:limit, {:or, [[:gold], [:silver]]}] ==
               order("r({:or, [{:gold, x} when x > lim, {:silver, x}]}, {:limit, lim})")
    end

    test "has each branch sorted against the bindings where the branch sits" do
      assert [:tick, {:or, [[:threshold, :order], [:silver]]}] ==
               order(
                 "r({:tick}, {:or, [{:and, [{:order, amt} when amt > t, {:threshold, t}]}, " <>
                   "{:silver, x}]})"
               )
    end

    test "with no branch at all is false, needs nothing and binds nothing" do
      assert [{:or, []}, :tick] == order("r({:xor, []}, {:tick})")
    end
  end

  # --- the rule level test ---------------------------------------------------

  describe "the rule level guard" do
    test "stays last, even when a collection is deferred past it" do
      assert [:user, {:coll, :item}, {:test, [:id]}] ==
               order("r([{:item, id}], {:user, id}) when id > 0")
    end

    test "is placed after the conditions it reads, wherever they end up" do
      assert [:threshold, :order, {:test, [:amt]}] ==
               order("r({:order, amt} when amt > t, {:threshold, t}) when amt > 5")
    end

    test "reading a variable nothing binds is left to Rete.DSL.Bindings" do
      # check_test_vars!/2 is checked once per path, so it can say which branch
      # of a disjunction is missing the variable. The sort has no such answer
      assert [:order, {:test, [:amt, :zzz]}] == order("r({:order, amt}) when amt > zzz")

      assert_raise ArgumentError, ~r/`amt > zzz` reads `zzz`, which no condition binds/, fn ->
        build("r({:order, amt}) when amt > zzz")
      end
    end

    test "reading a variable only one branch binds is left to Rete.DSL.Bindings" do
      assert_raise ArgumentError, ~r/reads `tier`, which no condition binds/, fn ->
        build("r({:or, [{:gold, id, tier}, {:silver, id}]}) when tier > 1")
      end
    end
  end

  # --- errors ----------------------------------------------------------------

  describe "an LHS that cannot be ordered" do
    test "raises naming the production, the conditions left and the variables" do
      error =
        assert_raise ArgumentError, fn ->
          sort("r({:tick}, {:order, amt} when amt > t and amt > cap, {:note, n} when n > cap)")
        end

      assert error.message =~ "`defrule r`"
      assert error.message =~ inspect(__MODULE__)
      assert error.message =~ "Unbound: `cap`, `t`"
      assert error.message =~ "{:order, amt} when amt > t and amt > cap - needs `cap`, `t`"
      assert error.message =~ "{:note, n} when n > cap - needs `cap`"
      # the conditions that were placed are not in the list
      refute error.message =~ "{:tick}"
    end

    test "names only the variables that are actually missing" do
      error = assert_raise ArgumentError, fn -> sort("r({:order, amt} when amt > t)") end

      assert error.message =~ "Unbound: `t`"
      refute error.message =~ "`amt`"
    end

    test "reports a collection the same way" do
      error = assert_raise ArgumentError, fn -> sort("r(items = [{:item, id} when id > n])") end

      assert error.message =~ "Unbound: `n`"
      assert error.message =~ "[{:item, id} when id > n] - needs `n`"
    end

    test "a gate that was never normalized raises" do
      production =
        Parser.parse_production(__ENV__, quote(do: r({:or, [{:a, x}, {:b, x}]})), nil, :rule)

      assert_raise ArgumentError, ~r/gate reached condition sorting/, fn ->
        Sort.sort(production)
      end
    end

    test "an unsupported element raises" do
      assert_raise ArgumentError, ~r/unsupported LHS element for condition sorting/, fn ->
        Sort.sort(%IR.Production{name: :r, type: :rule, module: __MODULE__, lhs: [:nonsense]})
      end
    end
  end

  # --- the pipeline ----------------------------------------------------------

  describe "a forward reference compiles" do
    test "and classifies exactly like the same rule written in order" do
      forward = classified("r({:order, amt} when amt > t, {:threshold, t})")
      sorted = classified("r({:threshold, t}, {:order, amt} when amt > t)")

      assert forward == sorted

      assert [
               %{type: :threshold, bind: [:t], join_bind: [], new_bind: [:t]},
               %{type: :order, bind: [:amt], join_bind: [], new_bind: [:amt]}
             ] = forward

      assert [_threshold, %{join_filter: join_filter}] = forward
      assert "join_order_bind_amt_t_expr_" <> _ = Atom.to_string(join_filter)
    end

    test "and the production's :bind is the same either way" do
      assert build("r({:order, amt} when amt > t, {:threshold, t})").bind ==
               build("r({:threshold, t}, {:order, amt} when amt > t)").bind
    end

    test "but a guard variable no condition binds still raises" do
      error = assert_raise ArgumentError, fn -> build("r({:order, amt} when amt > zzz)") end

      assert error.message =~ "`zzz`"
    end
  end
end
