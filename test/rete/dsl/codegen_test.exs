defmodule Rete.DSL.CodegenTest do
  use ExUnit.Case, async: true

  alias Rete.DSL.Codegen
  alias Rete.IR

  # ---------------------------------------------------------------------------
  # Defect 1: facts of arity > 2 did not compile at all.
  # ---------------------------------------------------------------------------

  defmodule ArityCheck do
    use Rete.Ruleset

    defrule r({:user, id, name}) do
      {:seen, id, name}
    end
  end

  # ---------------------------------------------------------------------------
  # Defect 2: a guard reading an upstream binding generated a function with an
  # undefined variable. It must now become an arity 2 join filter instead.
  # ---------------------------------------------------------------------------

  defmodule GuardCheck do
    use Rete.Ruleset

    defrule r({:threshold, t}, {:order, amt} when amt > t) do
      {:flagged, amt}
    end
  end

  # The same second condition written without a guard. Its alpha must be the
  # very same expression as GuardCheck's, which is the point of lifting the
  # guard out: the two share an alpha node.
  defmodule UnguardedCheck do
    use Rete.Ruleset

    defrule r({:order, amt}) do
      {:seen, amt}
    end
  end

  # ---------------------------------------------------------------------------
  # The end to end smoke fixture.
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

  # A module exercising the whole LHS surface at once, used to check that every
  # generated function is callable and that gates reach codegen normalized.
  defmodule Wide do
    use Rete.Ruleset

    @limit 10

    defrule everything(
              %{salience: 3},
              {:tick},
              c = {:customer, cid, name},
              {:order, cid, amt} when amt > 0 and amt > @limit,
              items = [{:item, cid, _sku} when cid > 0],
              {:or, [{:vip, cid}, {:staff, cid}]},
              {:not, [{:banned, cid}]}
            )
            when name != "" do
      {:wide, c, cid, name, amt, length(items)}
    end
  end

  defp production(module, name) do
    Enum.find(module.get_rule_data(), &(&1.name == name))
  end

  defp lhs(module, name), do: production(module, name).lhs
  defp cond_at(module, name, index), do: Enum.at(lhs(module, name), index)

  # ---------------------------------------------------------------------------

  describe "defect 1, facts of any arity" do
    test "a 3-arity fact compiles and produces the right IR" do
      r = production(ArityCheck, :r)

      assert [:id, :name] == r.bind

      assert [%IR.Fact{type: :user, fact_binding: nil, bind: [:id, :name]}] = r.lhs
    end

    test "its alpha is callable, type agnostic and arity strict" do
      alpha = cond_at(ArityCheck, :r, 0).alpha

      assert %IR.Expr{arity: 1, kind: :alpha} = alpha
      assert %{id: 1, name: "a"} == alpha.fun.({:user, 1, "a"})
      # the alpha never checks the type, the alpha index does
      assert %{id: 1, name: "a"} == alpha.fun.({:admin, 1, "a"})
      assert nil == alpha.fun.({:user, 1})
      assert nil == alpha.fun.(:user)
    end

    test "its rhs is the module function and returns the facts to insert" do
      r = production(ArityCheck, :r)

      assert (&ArityCheck.r/2) == r.rhs
      assert {:seen, 1, "a"} == r.rhs.(r.hash, %{id: 1, name: "a"})
    end
  end

  describe "defect 2, cross condition guards" do
    test "the guard lands in an arity 2 join filter, not in the alpha" do
      order = cond_at(GuardCheck, :r, 1)

      assert %IR.Expr{arity: 2, kind: :join_filter} = order.join_filter
      assert "join_order_bind_amt_t_expr_" <> _ = Atom.to_string(order.join_filter.code)

      # an alpha that still held `amt > t` would be named test_fact_...
      assert "fact_order_bind_amt_expr_" <> _ = Atom.to_string(order.alpha.code)
      assert %IR.Expr{arity: 1, kind: :alpha} = order.alpha
    end

    test "the alpha ignores the guard entirely" do
      alpha = cond_at(GuardCheck, :r, 1).alpha

      assert %{amt: 5} == alpha.fun.({:order, 5})
      assert %{amt: -1} == alpha.fun.({:order, -1})
    end

    test "the join filter is callable and returns a boolean" do
      filter = cond_at(GuardCheck, :r, 1).join_filter.fun

      assert is_function(filter, 2)
      assert true == filter.(%{t: 3}, %{amt: 5})
      assert false == filter.(%{t: 5}, %{amt: 5})
      assert false == filter.(%{t: 10}, %{amt: 5})
      # a token or a fact missing the variable is not a match, never a crash
      assert false == filter.(%{}, %{amt: 5})
    end

    test "the guard variables are split across the two sides of the filter" do
      order = cond_at(GuardCheck, :r, 1)

      # t comes from the token, amt from the fact; neither is a hash join key
      assert [] == order.join_bind
      assert [:amt] == order.new_bind
      assert [:t] == cond_at(GuardCheck, :r, 0).new_bind
    end

    test "lifting the guard out makes the alpha shareable with the unguarded form" do
      guarded = cond_at(GuardCheck, :r, 1).alpha
      unguarded = cond_at(UnguardedCheck, :r, 0).alpha

      assert guarded.code == unguarded.code
      assert guarded.name == unguarded.name
    end

    test "the join filter is exposed by get_expr_data/0" do
      codes = Enum.map(GuardCheck.get_expr_data(), fn {code, _fun} -> code end)
      filter = cond_at(GuardCheck, :r, 1).join_filter

      assert filter.code in codes

      assert Enum.any?(GuardCheck.get_expr_data(), fn {code, fun} ->
               code == filter.code and is_function(fun, 2)
             end)
    end
  end

  describe "the demo ruleset" do
    test "taxonomy is recorded in declaration order" do
      assert [{:derive, :premium, :customer}, {:derive, :standard, :customer}] ==
               Demo.get_taxo_data()
    end

    test "every production is present, in source order" do
      assert [:loyalty, :big_order, :dormant, :flagged_for] ==
               Enum.map(Demo.get_rule_data(), & &1.name)

      assert [:rule, :rule, :rule, :query] == Enum.map(Demo.get_rule_data(), & &1.type)
    end

    test "loyalty: options, types and binding classification" do
      loyalty = production(Demo, :loyalty)

      assert [salience: 100] == loyalty.opts
      assert [:cid, :name, :orders] == loyalty.bind

      assert [
               %IR.Fact{
                 type: :customer,
                 fact_binding: nil,
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
             ] = loyalty.lhs
    end

    test "loyalty: the collection introduces no new variable, so it can be empty" do
      # empty collection semantics are decided by :new_bind, see Rete.IR.Coll
      assert [] == cond_at(Demo, :loyalty, 1).new_bind
    end

    test "loyalty: the expressions are callable" do
      [customer, orders] = lhs(Demo, :loyalty)

      assert %{cid: 1, name: "a"} == customer.alpha.fun.({:customer, 1, "a"})
      assert nil == customer.alpha.fun.({:customer, 1})

      # a collection alpha is applied per element, never to the list
      assert %{cid: 1} == orders.alpha.fun.({:order, 1, 30})
      assert nil == orders.alpha.fun.({:order, 1})
    end

    test "loyalty: the rhs receives the collected list" do
      loyalty = production(Demo, :loyalty)

      assert {:loyalty, 1, "a", 2} ==
               loyalty.rhs.(loyalty.hash, %{cid: 1, name: "a", orders: [:o1, :o2]})

      assert {:loyalty, 1, "a", 0} ==
               loyalty.rhs.(loyalty.hash, %{cid: 1, name: "a", orders: []})
    end

    test "big_order: the guard is a join filter" do
      big_order = production(Demo, :big_order)

      assert [:amt, :cid, :t] == big_order.bind

      assert [
               %IR.Fact{type: :threshold, bind: [:t], join_filter: nil},
               %IR.Fact{type: :order, bind: [:amt, :cid], join_bind: [], new_bind: [:amt, :cid]}
             ] = big_order.lhs

      order = Enum.at(big_order.lhs, 1)
      assert %IR.Expr{arity: 2, kind: :join_filter} = order.join_filter

      assert %{amt: 30, cid: 1} == order.alpha.fun.({:order, 1, 30})
      assert true == order.join_filter.fun.(%{t: 10}, %{amt: 30})
      assert false == order.join_filter.fun.(%{t: 100}, %{amt: 30})
    end

    test "big_order: the join filter is shared with GuardCheck's, code for code" do
      assert cond_at(Demo, :big_order, 1).join_filter.code ==
               cond_at(GuardCheck, :r, 1).join_filter.code
    end

    test "dormant: the gate becomes a negation of a single condition" do
      dormant = production(Demo, :dormant)

      assert [:cid] == dormant.bind

      assert [
               %IR.Fact{type: :customer, bind: [:cid], new_bind: [:cid]},
               %IR.Negation{
                 condition: %IR.Fact{
                   type: :order,
                   bind: [:cid],
                   join_bind: [:cid],
                   new_bind: [],
                   join_filter: nil
                 }
               }
             ] = dormant.lhs
    end

    test "dormant: the negated condition's alpha is callable" do
      %IR.Negation{condition: order} = cond_at(Demo, :dormant, 1)

      assert %{cid: 1} == order.alpha.fun.({:order, 1, 30})
      assert nil == order.alpha.fun.({:order, 1})
      assert {:dormant, 1} == Demo.dormant(production(Demo, :dormant).hash, %{cid: 1})
    end

    test "flagged_for: a query is a production with a result body" do
      query = production(Demo, :flagged_for)

      assert :query == query.type
      assert [:amt, :cid] == query.bind
      assert [%IR.Fact{type: :flagged, bind: [:amt, :cid]}] = query.lhs
      assert {1, 30} == query.rhs.(query.hash, %{cid: 1, amt: 30})
    end

    test "every expression the module exposes is captured with its declared arity" do
      exprs = Demo.get_rule_data() |> Enum.flat_map(&IR.exprs/1) |> Enum.uniq_by(& &1.code)

      assert exprs != []

      for %IR.Expr{code: code, arity: arity, fun: fun, kind: kind} <- exprs do
        assert is_atom(code)
        assert kind in [:alpha, :test, :join_filter]
        assert is_function(fun, arity), "#{code} is not a function of arity #{arity}"
      end

      codes = Enum.map(Demo.get_expr_data(), fn {code, _} -> code end)
      assert Enum.sort(codes) == exprs |> Enum.map(& &1.code) |> Enum.sort()
    end

    test "the escaped IR carries no quoted AST" do
      for production <- Demo.get_rule_data() do
        assert nil == production.__ast__

        for condition <- production.lhs do
          for expr <- IR.exprs(condition), do: assert(nil == expr.__ast__)
        end
      end
    end
  end

  describe "the whole LHS surface" do
    test "gates are normalized before binding classification" do
      # {:or, [vip, staff]} fans out; {:not, [banned]} becomes a negation
      assert [
               %IR.Fact{type: :tick, bind: []},
               %IR.Fact{type: :customer, fact_binding: :c, bind: [:cid, :name]},
               %IR.Fact{type: :order, bind: [:amt, :cid]},
               %IR.Coll{type: :item, coll_binding: :items, bind: [:cid]},
               {:or, [[%IR.Fact{type: :vip}], [%IR.Fact{type: :staff}]]},
               %IR.Negation{condition: %IR.Fact{type: :banned}},
               %IR.Test{bind: [:name]}
             ] = lhs(Wide, :everything)
    end

    test "a disjunction's branches are classified against the upstream bindings" do
      {:or, [[vip], [staff]]} = cond_at(Wide, :everything, 4)

      assert [:cid] == vip.join_bind
      assert [] == vip.new_bind
      assert [:cid] == staff.join_bind
    end

    test "a guard over local variables and module attributes stays in the alpha" do
      order = cond_at(Wide, :everything, 2)

      # amt > 0 is local, and amt > @limit reads a module attribute, which is a
      # compile time constant and never a binding, so neither conjunct moves
      assert nil == order.join_filter
      assert "test_fact_order_bind_amt_cid_expr_" <> _ = Atom.to_string(order.alpha.code)
      assert %{amt: 30, cid: 1} == order.alpha.fun.({:order, 1, 30})
      assert nil == order.alpha.fun.({:order, 1, 5})
      assert nil == order.alpha.fun.({:order, 1, 0})
    end

    test "a guarded collection filters per element" do
      items = cond_at(Wide, :everything, 3)

      assert %IR.Coll{coll_binding: :items, join_bind: [:cid], new_bind: []} = items
      assert %{cid: 1} == items.alpha.fun.({:item, 1, "sku"})
      assert nil == items.alpha.fun.({:item, 0, "sku"})
    end

    test "the rule level test is last, arity 1 and returns a boolean" do
      test_node = List.last(lhs(Wide, :everything))

      assert %IR.Test{bind: [:name]} = test_node
      assert %IR.Expr{arity: 1, kind: :test} = test_node.expr
      assert true == test_node.expr.fun.(%{name: "a"})
      assert false == test_node.expr.fun.(%{name: ""})
    end

    test "get_expr_data/0 surfaces alphas, join filters and tests together" do
      kinds =
        Wide.get_rule_data()
        |> Enum.flat_map(&IR.exprs/1)
        |> Enum.map(& &1.kind)
        |> Enum.uniq()
        |> Enum.sort()

      assert [:alpha, :test] == kinds

      codes = Enum.map(Wide.get_expr_data(), fn {code, _} -> code end)
      assert Enum.any?(codes, &String.starts_with?(Atom.to_string(&1), "test_bind_"))
      assert Enum.any?(codes, &String.starts_with?(Atom.to_string(&1), "fact_"))

      join_codes = Enum.map(Demo.get_expr_data(), fn {code, _} -> code end)
      assert Enum.any?(join_codes, &String.starts_with?(Atom.to_string(&1), "join_"))
    end
  end

  describe "a guard that splits in two" do
    defmodule PartialSplit do
      use Rete.Ruleset

      defrule r({:threshold, t}, {:order, amt} when amt > 0 and amt > t) do
        {:flagged, amt}
      end
    end

    test "the local conjunct stays in the alpha and the rest becomes a join filter" do
      order = cond_at(PartialSplit, :r, 1)

      assert "test_fact_order_bind_amt_expr_" <> _ = Atom.to_string(order.alpha.code)
      assert %IR.Expr{arity: 2, kind: :join_filter} = order.join_filter

      # amt > 0 is enforced by the alpha
      assert %{amt: 5} == order.alpha.fun.({:order, 5})
      assert nil == order.alpha.fun.({:order, 0})

      # amt > t is enforced by the join filter, which never sees amt > 0
      assert true == order.join_filter.fun.(%{t: 1}, %{amt: 5})
      assert false == order.join_filter.fun.(%{t: 9}, %{amt: 5})
      assert true == order.join_filter.fun.(%{t: -5}, %{amt: 0})
    end
  end

  describe "expression kinds and their falsy result" do
    test "an alpha returns nil on a mismatch, a test and a join filter return false" do
      assert nil == cond_at(ArityCheck, :r, 0).alpha.fun.(:not_a_tuple)
      assert false == List.last(lhs(Wide, :everything)).expr.fun.(%{})
      assert false == cond_at(GuardCheck, :r, 1).join_filter.fun.(:nope, :nope)
    end
  end

  describe "node sharing" do
    defmodule Shared do
      use Rete.Ruleset

      defrule a({:user, id}, {:order, id, amt}) do
        {:a, id, amt}
      end

      defrule b({:user, id}, {:invoice, id}) do
        {:b, id}
      end
    end

    test "an identical condition in two rules is compiled to one function" do
      [a_user, _] = lhs(Shared, :a)
      [b_user, _] = lhs(Shared, :b)

      assert a_user.alpha.code == b_user.alpha.code
      assert a_user.alpha.fun == b_user.alpha.fun
    end

    test "get_expr_data/0 lists each code exactly once" do
      codes = Enum.map(Shared.get_expr_data(), fn {code, _} -> code end)

      assert codes == Enum.uniq(codes)
      assert 3 == length(codes)
    end
  end

  describe "Rete.Ruleset.build/4, the pipeline without codegen" do
    defp build(source) do
      Rete.Ruleset.build(__ENV__, Code.string_to_quoted!(source), nil, :rule)
    end

    test "it runs parse, normalize and classify, in that order" do
      production = build("r({:customer, cid}, {:not, [{:order, cid}]})")

      assert [
               %IR.Fact{type: :customer, new_bind: [:cid]},
               %IR.Negation{condition: %IR.Fact{type: :order, join_bind: [:cid]}}
             ] = production.lhs
    end

    test "it stops before escaping, so the quoted AST is still there" do
      production = build("r({:threshold, t}, {:order, amt} when amt > t)")

      assert %{decl: _, body: nil, bind: %{}} = production.__ast__
      assert nil == production.rhs

      order = Enum.at(production.lhs, 1)
      assert %IR.Expr{arity: 2, kind: :join_filter, fun: nil} = order.join_filter
      assert [_token_pattern, _fact_pattern] = order.join_filter.__ast__.args
    end

    test "the codes it produces are the codes the compiled module exposes" do
      production = build("r({:threshold, t}, {:order, amt} when amt > t)")
      order = Enum.at(production.lhs, 1)

      assert order.alpha.code == cond_at(GuardCheck, :r, 1).alpha.code
      assert order.join_filter.code == cond_at(GuardCheck, :r, 1).join_filter.code
    end
  end

  describe "naming and hashing helpers" do
    test "expr_code/3 sorts the variables and appends the hash" do
      assert :fact_order_bind_amt_id_expr_7 ==
               Codegen.expr_code([:fact, :order, :bind], [:id, :amt], 7)

      assert :fact_tick_bind_expr_7 == Codegen.expr_code([:fact, :tick, :bind], [], 7)
    end

    test "expr_name/1 wraps a code in double underscores" do
      assert :__fact_tick_bind_expr_7__ == Codegen.expr_name(:fact_tick_bind_expr_7)
    end

    test "type_code/1 strips the Elixir prefix and the dots of a module" do
      assert "order" == Codegen.type_code(:order)
      assert "String_Chars" == Codegen.type_code(String.Chars)
    end

    test "expr_hash/2 ignores metadata and therefore line numbers" do
      a = quote(line: 1, do: {:order, id})
      b = quote(line: 99, do: {:order, id})

      assert Codegen.expr_hash(a, a) == Codegen.expr_hash(b, b)
      assert Codegen.expr_hash(a, a) != Codegen.expr_hash(a, quote(do: {:other, id}))
    end
  end

  describe "Rete aggregation across modules" do
    test "rule, expr and taxonomy data combine" do
      names = Rete.get_rule_data([Demo, ArityCheck]) |> Enum.map(& &1.name)
      assert [:loyalty, :big_order, :dormant, :flagged_for, :r] == names

      assert [{:derive, :premium, :customer}, {:derive, :standard, :customer}] ==
               Rete.get_taxo_data([Demo, ArityCheck])

      codes = Rete.get_expr_data([Demo, GuardCheck]) |> Enum.map(fn {code, _} -> code end)
      assert codes == Enum.uniq(codes)
      # the join filter of the shared `amt > t` guard is deduplicated by code
      assert 1 == Enum.count(codes, &String.starts_with?(Atom.to_string(&1), "join_"))
    end
  end
end
