defmodule Rete.RulesetTest.Big do
  @moduledoc false
  def over?(amt), do: amt > 100
end

defmodule Rete.RulesetTest.Small do
  @moduledoc false
  def over?(amt), do: amt < 0
end

defmodule Rete.RulesetTest do
  use ExUnit.Case, async: true

  alias Rete.IR

  # ---------------------------------------------------------------------------
  # The W1 acceptance fixture, verbatim.
  # ---------------------------------------------------------------------------

  defmodule Demo do
    use Rete.Ruleset

    derive(:premium, :customer)
    derive(:standard, :customer)

    defrule loyalty(
              %{salience: 100},
              {:customer, cid, name},
              orders = [{:order, cid, _amt}]
            ) do
      {:loyalty, cid, name, length(orders)}
    end

    defrule big_order({:threshold, t}, {:order, cid, amt} when amt > t) do
      {:flagged, cid, amt}
    end

    defrule dormant({:customer, cid, _}, {:not, [{:order, cid, _}]}) do
      {:dormant, cid}
    end

    defquery flagged_for({:flagged, cid, amt}) do
      {cid, amt}
    end
  end

  # ---------------------------------------------------------------------------
  # :bind used to be computed from the raw declaration, before normalization and
  # before classification, so it swept up variables the engine never binds and
  # the RHS could not be called at all.
  # ---------------------------------------------------------------------------

  defmodule Bindings do
    use Rete.Ruleset

    defrule dormant({:customer, cid}, {:not, [{:order, cid, amt}]}) do
      {:dormant, cid}
    end

    defrule branchy({:customer, cid}, {:or, [{:gold, cid, tier}, {:silver, cid}]}) do
      {:tagged, cid}
    end

    defrule either({:or, [{:user, id}, {:admin, level}]}) do
      {:seen, id, level}
    end

    defrule nandy({:customer, cid}, {:nand, [{:order, cid, x}, {:refund, cid, x}]}) do
      {:clean, cid}
    end

    defrule guarded({:limit, t}, {:order, amt}) when amt > t and amt > 0 do
      {:over, amt}
    end

    # Both branches bind the same variables, so the tail is classified once and
    # the lhs stays flat.
    defrule shared_tail(
              {:or, [{:gold, id}, {:silver, id}]},
              {:login, id, ts}
            ) do
      {:in, id, ts}
    end

    # The branches bind different variables, so the tail is absorbed into them
    # and `tier` is only bound on one path.
    defrule absorbed_tail(
              {:or, [{:gold, id, tier}, {:silver, id}]},
              {:login, id, ts}
            ) do
      {:in, id, ts, tier}
    end
  end

  # The same rule as Demo's `big_order`, in another module: two conditions with
  # the same code must be the same expression, whichever module compiled them.
  defmodule DemoTwin do
    use Rete.Ruleset

    defrule big_order({:threshold, t}, {:order, cid, amt} when amt > t) do
      {:flagged, cid, amt}
    end
  end

  # ---------------------------------------------------------------------------
  # Two rulesets whose guards are the same source text but call different
  # modules through the same alias.
  # ---------------------------------------------------------------------------

  defmodule AliasA do
    use Rete.Ruleset
    alias Rete.RulesetTest.Big, as: Limit

    defrule r({:order, amt} when Limit.over?(amt)) do
      {:a, amt}
    end
  end

  defmodule AliasB do
    use Rete.Ruleset
    alias Rete.RulesetTest.Small, as: Limit

    defrule r({:order, amt} when Limit.over?(amt)) do
      {:b, amt}
    end
  end

  defp production(module, name), do: Enum.find(module.get_rule_data(), &(&1.name == name))
  defp lhs(module, name), do: production(module, name).lhs
  defp cond_at(module, name, index), do: Enum.at(lhs(module, name), index)

  # ---------------------------------------------------------------------------

  describe ":bind is recomputed from the classified lhs" do
    test "a negation binds nothing downstream, so the rhs is callable" do
      dormant = production(Bindings, :dormant)

      assert [:cid] == dormant.bind
      assert {:dormant, 1} == dormant.rhs.(dormant.hash, %{cid: 1})
    end

    test "a disjunction only guarantees what every branch binds" do
      branchy = production(Bindings, :branchy)

      assert [:cid, :tier] == branchy.bind
      assert {[:cid], [:tier]} == IR.lhs_bindings(branchy.lhs)

      # the silver branch never binds :tier, and the rule still fires
      assert {:tagged, 1} == branchy.rhs.(branchy.hash, %{cid: 1})
      assert {:tagged, 1} == branchy.rhs.(branchy.hash, %{cid: 1, tier: :gold})
    end

    test "a per-branch binding the rhs reads is nil on the branches that do not bind it" do
      either = production(Bindings, :either)

      assert [:id, :level] == either.bind
      assert {[], [:id, :level]} == IR.lhs_bindings(either.lhs)

      assert {:seen, 7, nil} == either.rhs.(either.hash, %{id: 7})
      assert {:seen, nil, :root} == either.rhs.(either.hash, %{level: :root})
      assert {:seen, 7, :root} == either.rhs.(either.hash, %{id: 7, level: :root})
    end

    test "a compound negation binds nothing downstream" do
      nandy = production(Bindings, :nandy)

      assert [:cid] == nandy.bind
      assert {:clean, 3} == nandy.rhs.(nandy.hash, %{cid: 3})
    end

    test "a rule level guard reads variables, it does not bind them" do
      guarded = production(Bindings, :guarded)

      assert [:amt, :t] == guarded.bind
      assert %IR.Test{bind: [:amt, :t]} = List.last(guarded.lhs)
      assert {:over, 30} == guarded.rhs.(guarded.hash, %{amt: 30, t: 10})
    end

    test "branches binding the same variables keep the lhs flat" do
      shared = production(Bindings, :shared_tail)

      assert [{:or, [[_gold], [_silver]]}, %IR.Fact{type: :login}] = shared.lhs
      assert [:id, :ts] == shared.bind
      assert {[:id, :ts], []} == IR.lhs_bindings(shared.lhs)
      assert {:in, 1, 2} == shared.rhs.(shared.hash, %{id: 1, ts: 2})
    end

    test "an absorbed tail leaves only the divergent variable optional" do
      absorbed = production(Bindings, :absorbed_tail)

      assert [{:or, [[_gold, _login], [_silver, _login2]]}] = absorbed.lhs
      assert [:id, :tier, :ts] == absorbed.bind
      assert {[:id, :ts], [:tier]} == IR.lhs_bindings(absorbed.lhs)

      assert {:in, 1, 2, nil} == absorbed.rhs.(absorbed.hash, %{id: 1, ts: 2})
      assert {:in, 1, 2, :g} == absorbed.rhs.(absorbed.hash, %{id: 1, ts: 2, tier: :g})
    end

    test "a guaranteed binding is destructured in the head, so a hole raises" do
      either = production(Bindings, :either)
      shared = production(Bindings, :shared_tail)

      # :id and :ts are on every path of shared_tail, so a token without them is
      # a bug in the engine and must not fire the rule silently
      assert_raise FunctionClauseError, fn -> shared.rhs.(shared.hash, %{}) end

      # :either guarantees nothing, so it accepts any token
      assert {:seen, nil, nil} == either.rhs.(either.hash, %{})
    end

    test "the __ast__ bind map is narrowed to the recomputed bind" do
      production =
        Rete.Ruleset.build(
          __ENV__,
          Code.string_to_quoted!("r({:customer, cid}, {:not, [{:order, cid, amt}]})"),
          nil,
          :rule
        )

      assert [:cid] == production.bind
      assert [:cid] == production.__ast__.bind |> Map.keys() |> Enum.sort()
    end
  end

  # ---------------------------------------------------------------------------

  describe "a `_`-prefixed variable is never a binding, in any position" do
    defp build(decl) do
      Rete.Ruleset.build(__ENV__, Code.string_to_quoted!(decl), nil, :rule)
    end

    test "it is not in :bind, so it is not in the alpha's bindings map either" do
      production = build("r({:order, cid, _amt})")

      assert [:cid] == production.bind
      assert [:cid] == hd(production.lhs).bind
    end

    test "a guard reading one is an error naming the variable to rename" do
      # it is discarded by the pattern, so it is in no bindings map and in no
      # token; inlining it into the alpha would only trade this for Elixir's
      # own "the underscored variable is used after being set" warning
      message = ~r/`_amt`.*starts with `_` is discarded.*Rename it to `amt`/s

      assert_raise ArgumentError, message, fn -> build("r({:order, _amt} when _amt > 0)") end

      assert_raise ArgumentError, message, fn ->
        build("r({:threshold, t}, {:order, _amt} when _amt > t)")
      end
    end

    test "a guard reading an upstream one is the same error" do
      assert_raise ArgumentError, ~r/`_t`.*Rename it to `t`/s, fn ->
        build("r({:threshold, _t}, {:order, amt} when amt > _t)")
      end
    end
  end

  # ---------------------------------------------------------------------------

  # A rule level guard has exactly the defect a per condition guard had: the
  # variables it reads come from the token and nowhere else, so one that no
  # condition binds is a key the generated test function never sees. It used to
  # compile to a function whose fallback clause returns false, and the rule
  # silently never fired.
  describe "a rule level guard may only read variables its path binds" do
    test "a variable no condition binds is a compile error naming it" do
      message = ~r/`amt > zzz` reads `zzz`, which no condition binds/

      assert_raise ArgumentError, message, fn -> build("r({:order, amt}) when amt > zzz") end
    end

    test "a variable bound only inside a negation is a compile error" do
      # the negation matches no fact, so `amt` is in no token downstream
      assert_raise ArgumentError, ~r/reads `amt`, which no condition binds/, fn ->
        build("r({:customer, cid}, {:not, [{:order, cid, amt}]}) when amt > 0")
      end
    end

    test "an underscored variable is the same error, with the rename hint" do
      # without the check this is an `undefined variable \"_t\"` compile error
      # pointing at the generated function, with no hint of which rule it is
      assert_raise ArgumentError, ~r/`_t`.*Rename it to `t`/s, fn ->
        build("r({:threshold, _t}, {:order, amt}) when amt > _t")
      end
    end

    test "a variable only one branch of a disjunction binds is checked per path" do
      # the guard is absorbed into both branches; it cannot be evaluated on the
      # silver one, so it belongs on the gold condition instead
      assert_raise ArgumentError, ~r/reads `tier`, which no condition binds/, fn ->
        build("r({:or, [{:gold, id, tier}, {:silver, id}]}) when tier > 1")
      end

      production = build("r({:or, [{:gold, id, tier} when tier > 1, {:silver, id}]})")
      assert [:id, :tier] == production.bind
    end

    test "a variable every branch binds is fine, and so is the pinned and literal case" do
      production = build("r({:or, [{:gold, id}, {:silver, id}]}) when id > 1")

      assert [:id] == production.bind
      assert %IR.Test{bind: [:id]} = List.last(production.lhs)
    end
  end

  # ---------------------------------------------------------------------------

  describe "the W1 acceptance fixture" do
    test "every production expanded, in source order, with its options" do
      assert [:loyalty, :big_order, :dormant, :flagged_for] ==
               Enum.map(Demo.get_rule_data(), & &1.name)

      assert [:rule, :rule, :rule, :query] == Enum.map(Demo.get_rule_data(), & &1.type)
      assert [salience: 100] == production(Demo, :loyalty).opts
      assert [] == production(Demo, :big_order).opts

      assert [{:derive, :premium, :customer}, {:derive, :standard, :customer}] ==
               Demo.get_taxo_data()
    end

    test "loyalty: the collection joins on cid and introduces nothing, so it may be empty" do
      assert [:cid, :name, :orders] == production(Demo, :loyalty).bind

      assert [
               %IR.Fact{
                 type: :customer,
                 bind: [:cid, :name],
                 join_bind: [],
                 new_bind: [:cid, :name],
                 join_filter: nil
               },
               %IR.Coll{
                 type: :order,
                 coll_binding: :orders,
                 bind: [:cid],
                 join_bind: [:cid],
                 new_bind: [],
                 join_filter: nil
               }
             ] = lhs(Demo, :loyalty)
    end

    test "big_order: the guard is wholly lifted into a join filter" do
      big_order = production(Demo, :big_order)

      assert [:amt, :cid, :t] == big_order.bind

      assert [
               %IR.Fact{type: :threshold, bind: [:t], new_bind: [:t], join_filter: nil},
               %IR.Fact{type: :order, bind: [:amt, :cid], join_bind: [], new_bind: [:amt, :cid]}
             ] = big_order.lhs

      order = Enum.at(big_order.lhs, 1)

      # the alpha half is empty, so the alpha is the very expression the same
      # condition would produce written without a guard - no `test_` prefix
      assert "fact_order_bind_amt_cid_expr_" <> _ = Atom.to_string(order.alpha.code)

      assert %IR.Expr{arity: 2, kind: :join_filter} = order.join_filter
      assert true == order.join_filter.fun.(%{t: 10}, %{amt: 30})
      assert false == order.join_filter.fun.(%{t: 100}, %{amt: 30})
    end

    test "dormant: the gate becomes a negation of one condition, bound on cid" do
      assert [:cid] == production(Demo, :dormant).bind

      assert [
               %IR.Fact{type: :customer, bind: [:cid], join_bind: [], new_bind: [:cid]},
               %IR.Negation{
                 condition: %IR.Fact{
                   type: :order,
                   bind: [:cid],
                   join_bind: [:cid],
                   new_bind: [],
                   join_filter: nil
                 }
               }
             ] = lhs(Demo, :dormant)
    end

    test "flagged_for: a query is a production whose body computes a result" do
      query = production(Demo, :flagged_for)

      assert :query == query.type
      assert [:amt, :cid] == query.bind
      assert {1, 30} == query.rhs.(query.hash, %{cid: 1, amt: 30})
    end

    test "every generated function is callable at its documented arity" do
      for production <- Demo.get_rule_data() do
        assert is_function(production.rhs, 2)

        for %IR.Expr{code: code, arity: arity, kind: kind, fun: fun} <- IR.exprs(production) do
          assert kind in [:alpha, :test, :join_filter]
          assert is_function(fun, arity), "#{code} is not a function of arity #{arity}"
        end
      end
    end

    test "every rhs is callable with exactly the bindings its lhs produces" do
      for production <- Demo.get_rule_data() do
        {guaranteed, optional} = IR.lhs_bindings(production.lhs)

        assert Enum.sort(guaranteed ++ optional) == production.bind

        bindings = Map.new(production.bind, &{&1, []})
        assert production.rhs.(production.hash, bindings)

        # the guaranteed half on its own is enough to call it
        assert production.rhs.(production.hash, Map.new(guaranteed, &{&1, []}))
      end
    end

    test "every expression of the fixture computes what its kind promises" do
      [customer, orders] = lhs(Demo, :loyalty)

      assert %{cid: 1, name: "ann"} == customer.alpha.fun.({:customer, 1, "ann"})
      assert nil == customer.alpha.fun.({:customer, 1})

      # a collection alpha runs per candidate element, so it binds the element's
      # variables; `_amt` is discarded, leaving only the join variable
      assert %{cid: 1} == orders.alpha.fun.({:order, 1, 50})

      [_customer, %IR.Negation{condition: order}] = lhs(Demo, :dormant)
      assert %{cid: 7} == order.alpha.fun.({:order, 7, 3})

      loyalty = production(Demo, :loyalty)

      assert {:loyalty, 1, "ann", 2} ==
               loyalty.rhs.(loyalty.hash, %{cid: 1, name: "ann", orders: [:a, :b]})
    end

    test "the escaped ir carries no quoted ast" do
      for production <- Demo.get_rule_data() do
        assert nil == production.__ast__

        for %IR.Expr{__ast__: ast} <- IR.exprs(production) do
          assert nil == ast
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  describe "a production needs a body" do
    test "a rule without one names the rule, instead of the generated function" do
      # it used to emit `def bodiless(hash, bindings)` with no body, so the
      # module failed to compile with "implementation not provided for
      # predefined def bodiless/2"
      assert_raise ArgumentError, ~r/`defrule bodiless` has no body/, fn ->
        Code.compile_string("""
        defmodule Rete.RulesetTest.Bodiless do
          use Rete.Ruleset
          defrule bodiless({:order, amt})
        end
        """)
      end
    end

    test "and so does a query" do
      assert_raise ArgumentError, ~r/`defquery bodiless` has no body/, fn ->
        Code.compile_string("""
        defmodule Rete.RulesetTest.BodilessQuery do
          use Rete.Ruleset
          defquery bodiless({:order, amt}) when amt > 0
        end
        """)
      end
    end
  end

  # ---------------------------------------------------------------------------

  describe "the module level accessors" do
    test "get_expr_data/0 surfaces every expression, including a compound negation's" do
      inner =
        Bindings
        |> cond_at(:nandy, 1)
        |> Map.fetch!(:conditions)
        |> Enum.map(& &1.alpha.code)

      codes = Enum.map(Bindings.get_expr_data(), fn {code, _fun} -> code end)

      assert 2 == length(inner)
      assert [] == inner -- codes
    end

    test "get_expr_data/0 covers every expression of the module, deduplicated" do
      exprs =
        Demo.get_rule_data()
        |> Enum.flat_map(&IR.exprs/1)
        |> Enum.map(& &1.code)
        |> Enum.uniq()

      codes = Enum.map(Demo.get_expr_data(), fn {code, _fun} -> code end)

      assert Enum.sort(exprs) == Enum.sort(codes)
      assert codes == Enum.uniq(codes)
    end

    test "get_version/0 is a hash of the module, its rules and its taxonomy" do
      assert Demo.get_version() ==
               :erlang.phash2([Demo, Demo.get_rule_data(), Demo.get_taxo_data()])

      assert Demo.get_version() != Bindings.get_version()
    end

    test "Rete aggregates the accessors across modules" do
      assert Demo.get_rule_data() ++ Bindings.get_rule_data() ==
               Rete.get_rule_data([Demo, Bindings])

      assert Demo.get_taxo_data() == Rete.get_taxo_data([Demo, Bindings])

      codes =
        [Demo, Bindings] |> Rete.get_expr_data() |> Enum.map(fn {code, _fun} -> code end)

      assert codes == Enum.uniq(codes)
    end

    test "an identical rule in another module shares its expression codes" do
      # node sharing across modules is what makes Rete.get_expr_data/1's dedup
      # by code both useful and safe
      mine = production(Demo, :big_order) |> IR.exprs() |> Enum.map(& &1.code) |> Enum.sort()

      theirs =
        production(DemoTwin, :big_order) |> IR.exprs() |> Enum.map(& &1.code) |> Enum.sort()

      assert mine == theirs

      merged = [Demo, DemoTwin] |> Rete.get_expr_data() |> Enum.map(&elem(&1, 0))
      demo = Demo.get_expr_data() |> Enum.map(&elem(&1, 0))

      assert merged == demo
    end

    # Two modules aliasing the same name to different modules used to hash to
    # the same expression code, so Rete.get_expr_data/1 collapsed them and one
    # ruleset silently ran the other's guard.
    test "an alias is resolved before hashing, so it cannot collide across modules" do
      [a] = AliasA.get_rule_data()
      [b] = AliasB.get_rule_data()

      assert hd(a.lhs).alpha.code != hd(b.lhs).alpha.code
      assert %{amt: 500} == hd(a.lhs).alpha.fun.({:order, 500})
      assert nil == hd(b.lhs).alpha.fun.({:order, 500})

      assert 2 == length(Rete.get_expr_data([AliasA, AliasB]))
    end
  end
end
