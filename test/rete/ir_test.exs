defmodule Rete.IRTest do
  use ExUnit.Case, async: true

  alias Rete.IR

  doctest Rete.IR

  defp fact(bind, opts \\ []) do
    %IR.Fact{type: :t, bind: bind, fact_binding: opts[:fact_binding]}
  end

  # ---------------------------------------------------------------------------
  # bound_vars/1
  # ---------------------------------------------------------------------------

  describe "bound_vars/1" do
    test "a fact binds its pattern variables and its fact binding" do
      assert [:id] == IR.bound_vars(fact([:id]))
      assert [:id, :f] == IR.bound_vars(fact([:id], fact_binding: :f))
    end

    test "a collection binds its pattern variables and the collected list" do
      assert [:id] == IR.bound_vars(%IR.Coll{bind: [:id]})
      assert [:id, :c] == IR.bound_vars(%IR.Coll{bind: [:id], coll_binding: :c})
    end

    # Regression: a Test's :bind is what its guard READS. Returning it here made
    # every consumer believe a rule level guard introduced its variables, which
    # is what put :amt in the RHS head of a rule whose only :amt was in a guard.
    test "a test binds nothing: its :bind is what the guard reads" do
      assert [] == IR.bound_vars(%IR.Test{bind: [:amt]})
    end

    test "neither kind of negation binds anything downstream" do
      assert [] == IR.bound_vars(%IR.Negation{condition: fact([:id])})
      assert [] == IR.bound_vars(%IR.CompoundNegation{conditions: [fact([:id]), fact([:x])]})
    end
  end

  # ---------------------------------------------------------------------------
  # lhs_bindings/1
  # ---------------------------------------------------------------------------

  describe "lhs_bindings/1" do
    test "a plain sequence guarantees everything it binds" do
      assert {[:amt, :id], []} == IR.lhs_bindings([fact([:id]), fact([:amt])])
    end

    test "a negation contributes nothing" do
      lhs = [fact([:cid]), %IR.Negation{condition: fact([:amt, :cid])}]
      assert {[:cid], []} == IR.lhs_bindings(lhs)
    end

    test "a compound negation contributes nothing" do
      lhs = [fact([:cid]), %IR.CompoundNegation{conditions: [fact([:x]), fact([:y])]}]
      assert {[:cid], []} == IR.lhs_bindings(lhs)
    end

    test "a rule level test contributes nothing" do
      assert {[:id], []} == IR.lhs_bindings([fact([:id]), %IR.Test{bind: [:id, :other]}])
    end

    test "a disjunction guarantees the intersection and offers the union" do
      lhs = [{:or, [[fact([:id, :tier])], [fact([:id])]]}]
      assert {[:id], [:tier]} == IR.lhs_bindings(lhs)
    end

    test "a variable already bound stays guaranteed through a disjunction" do
      lhs = [fact([:id]), {:or, [[fact([:tier])], [fact([])]]}]
      assert {[:id], [:tier]} == IR.lhs_bindings(lhs)
    end

    test "branches may nest, as they do after binding classification absorbs a tail" do
      inner = {:or, [[fact([:a])], [fact([:b])]]}
      lhs = [{:or, [[fact([:id]), inner], [fact([:id]), fact([:a]), fact([:b])]]}]

      assert {[:id], [:a, :b]} == IR.lhs_bindings(lhs)
    end

    test "an empty disjunction is false, so it binds nothing and does not crash" do
      assert {[:id], []} == IR.lhs_bindings([fact([:id]), {:or, []}])
    end

    test "the two halves are disjoint and together are the production's :bind" do
      lhs = [fact([:cid]), {:or, [[fact([:tier])], [fact([:rank])]]}]
      {guaranteed, optional} = IR.lhs_bindings(lhs)

      assert [] == Enum.filter(guaranteed, &(&1 in optional))
      assert [:cid, :rank, :tier] == Enum.sort(guaranteed ++ optional)
    end
  end
end
