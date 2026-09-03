defmodule ReteBindingsTestOrder do
  @moduledoc false
  defstruct [:id, :amount]
end

defmodule Rete.DSL.BindingsTest do
  use ExUnit.Case, async: true

  alias Rete.DSL.Bindings
  alias Rete.DSL.Parser
  alias Rete.IR

  doctest Rete.DSL.Bindings

  @limit 10

  # --- helpers ---------------------------------------------------------------

  # Parse from source, the way `defrule` sees it: `quote` tags variables with
  # the caller module as their context while source AST has a nil context.
  defp parse(decl) do
    Parser.parse_production(__ENV__, Code.string_to_quoted!(decl), nil, :rule)
  end

  defp classify(decl) when is_binary(decl), do: Bindings.classify(__ENV__, parse(decl))
  defp classify(%IR.Production{} = production), do: Bindings.classify(__ENV__, production)

  defp element(source), do: Parser.parse_element(__ENV__, Code.string_to_quoted!(source))

  defp guard(source), do: Code.string_to_quoted!(source)

  defp at(production, index), do: Enum.at(production.lhs, index)

  defp put_lhs(%IR.Production{} = production, lhs), do: %IR.Production{production | lhs: lhs}

  # Evaluates an expression the way `Parser.expr_defs/1` emits it, so that the
  # behavior under test is the behavior that will be compiled into the module.
  defp fun(%IR.Expr{arity: 1, __ast__: %{args: args, body: body}}) do
    eval(
      quote do
        fn value ->
          case value do
            unquote(args) -> unquote(body)
            _ -> nil
          end
        end
      end
    )
  end

  defp fun(%IR.Expr{arity: 2, __ast__: %{args: [left, right], body: body}}) do
    eval(
      quote do
        fn l, r ->
          case {l, r} do
            {unquote(left), unquote(right)} -> unquote(body)
            _ -> false
          end
        end
      end
    )
  end

  defp eval(ast) do
    {value, _} = Code.eval_quoted(ast)
    value
  end

  # --- alpha only guards -----------------------------------------------------

  describe "guards that only read the condition's own variables" do
    test "stay in the alpha and produce no join filter" do
      fact = classify("r({:order, id, amt} when amt > 0)") |> at(0)

      assert nil == fact.join_filter
      assert "test_fact_order_bind_amt_id_expr_" <> _ = Atom.to_string(fact.alpha.code)
      assert %{id: 1, amt: 5} == fun(fact.alpha).({:order, 1, 5})
      assert nil == fun(fact.alpha).({:order, 1, 0})
    end

    test "leave the alpha expression byte identical" do
      parsed = parse("r({:order, id, amt} when amt > 0)") |> at(0)
      classified = classify("r({:order, id, amt} when amt > 0)") |> at(0)

      assert parsed.alpha == classified.alpha
      assert parsed.__ast__ == classified.__ast__
    end

    test "a guard over several own variables is still local" do
      fact = classify("r({:order, low, high} when low < high)") |> at(0)

      assert nil == fact.join_filter
      assert %{low: 1, high: 2} == fun(fact.alpha).({:order, 1, 2})
      assert nil == fun(fact.alpha).({:order, 2, 1})
    end

    test "a guard on a condition that is itself a join stays local" do
      # `id` is a join key here, but the condition's own pattern binds it, so
      # the alpha can evaluate the guard on a single fact.
      production = classify("r({:customer, id}, {:order, id} when id > 0)")

      assert %IR.Fact{join_bind: [:id], new_bind: [], join_filter: nil} = at(production, 1)
      assert %{id: 1} == fun(at(production, 1).alpha).({:order, 1})
      assert nil == fun(at(production, 1).alpha).({:order, 0})
    end
  end

  # --- guards that reach upstream --------------------------------------------

  describe "guards that read an upstream variable" do
    setup do
      production = classify("r({:threshold, t}, {:order, amt} when amt > t)")
      {:ok, production: production, order: at(production, 1)}
    end

    test "move wholly to an arity 2 join filter", %{order: order} do
      assert %IR.Expr{arity: 2} = order.join_filter
      assert :"__#{order.join_filter.code}__" == order.join_filter.name
      assert "join_order_bind_amt_t_expr_" <> _ = Atom.to_string(order.join_filter.code)

      join = fun(order.join_filter)
      assert true == join.(%{t: 5}, %{amt: 10})
      assert false == join.(%{t: 5}, %{amt: 5})
    end

    test "the join filter always returns a boolean", %{order: order} do
      join = fun(order.join_filter)

      assert false == join.(%{t: 5}, %{})
      assert false == join.(%{}, %{amt: 10})
    end

    test "leave an unguarded alpha behind", %{order: order} do
      assert "fact_order_bind_amt_expr_" <> _ = Atom.to_string(order.alpha.code)
      assert nil == order.__ast__.guard
      assert %{amt: 1} == fun(order.alpha).({:order, 1})
    end

    test "the stripped alpha is shared with the same condition written unguarded" do
      guarded = classify("r({:threshold, t}, {:order, amt} when amt > t)") |> at(1)
      plain = classify("r({:order, amt})") |> at(0)

      assert plain.alpha.code == guarded.alpha.code
      assert plain.alpha.name == guarded.alpha.name
      assert plain.alpha.__ast__ == guarded.alpha.__ast__
    end

    test "the upstream variable is not a join key of the condition", %{production: production} do
      # `t` is only read by the guard, it is not part of the order pattern, so
      # it cannot be a hash join key: the filter has to run at the beta node.
      assert %IR.Fact{bind: [:amt], join_bind: [], new_bind: [:amt]} = at(production, 1)
    end
  end

  # --- guards over the condition's own fact binding ---------------------------

  # The fact binding is the alpha's argument, so a guard over it is local. It
  # used to be classified as upstream and lifted into an arity 2 filter that
  # destructured it from the token side, where it can never appear, so the
  # filter was always false and the rule could never fire.
  describe "guards that read the condition's own fact binding" do
    test "stay in the alpha, which matches the binding against the whole fact" do
      fact = classify("r(f = {:order, amt} when elem(f, 1) > 100)") |> at(0)

      assert nil == fact.join_filter
      assert [] == fact.join_bind
      assert [:amt] == fact.new_bind
      assert %{amt: 200} == fun(fact.alpha).({:order, 200})
      assert nil == fun(fact.alpha).({:order, 5})
    end

    test "mix with the pattern's own variables" do
      fact = classify("r(f = {:order, amt} when amt > 0 and elem(f, 0) == :order)") |> at(0)

      assert nil == fact.join_filter
      assert %{amt: 5} == fun(fact.alpha).({:order, 5})
      assert nil == fun(fact.alpha).({:order, 0})
      assert nil == fun(fact.alpha).({:payment, 5})
    end

    test "the fact binding is still neither a join key nor a new binding" do
      production = classify("r({:threshold, t}, f = {:order, amt} when elem(f, 1) > t)")
      order = at(production, 1)

      assert [:amt] == order.bind
      assert [] == order.join_bind
      assert [:amt] == order.new_bind
    end

    test "a cross condition guard reads the fact binding from the fact side" do
      production = classify("r({:threshold, t}, f = {:order, amt} when elem(f, 1) > t)")
      order = at(production, 1)

      # The alpha has to surface the fact binding: the fact side of a join
      # filter only ever sees the bindings map the alpha returned.
      assert %{amt: 5, f: {:order, 5}} == fun(order.alpha).({:order, 5})

      join = fun(order.join_filter)
      assert true == join.(%{t: 1}, %{f: {:order, 5}})
      assert false == join.(%{t: 9}, %{f: {:order, 5}})
    end

    test "classifying twice is still idempotent" do
      once = classify("r({:threshold, t}, f = {:order, amt} when elem(f, 1) > t)")
      twice = Bindings.classify(__ENV__, once)

      assert once.lhs == twice.lhs
    end

    test "a collection cannot guard on its own collection binding" do
      # The alpha of a collection runs per element, so the list does not exist
      # yet. There is nowhere correct to evaluate such a guard.
      assert_raise ArgumentError, ~r/the collection binding/, fn ->
        classify("r(orders = [{:order, amt}] when length(orders) > 2)")
      end
    end
  end

  # --- conjunct by conjunct splitting ----------------------------------------

  describe "splitting a top level and chain" do
    test "each conjunct goes to its own side" do
      production = classify("r({:threshold, t}, {:order, id, amt} when amt > 0 and amt > t)")
      order = at(production, 1)

      alpha = fun(order.alpha)
      assert %{id: 1, amt: 5} == alpha.({:order, 1, 5})
      assert nil == alpha.({:order, 1, 0})

      join = fun(order.join_filter)
      assert true == join.(%{t: 3}, %{amt: 5})
      assert false == join.(%{t: 7}, %{amt: 5})

      assert "test_fact_order_bind_amt_id_expr_" <> _ = Atom.to_string(order.alpha.code)
      assert "join_order_bind_amt_t_expr_" <> _ = Atom.to_string(order.join_filter.code)
    end

    # The split is a prefix, not a filter: the alpha stops at the first
    # cross condition conjunct. `id != nil` is local but sits after `amt > t`,
    # and hoisting it over would run it earlier than the guard says to.
    test "a three conjunct chain splits at the first remote conjunct" do
      {alpha, join} =
        Bindings.split_guard(guard("amt > 0 and amt > t and id != nil"), [:id, :amt])

      assert "amt > 0" == Macro.to_string(alpha)
      assert "amt > t && id != nil" == Macro.to_string(join)
    end

    test "nested and chains are flattened before splitting" do
      {alpha, join} = Bindings.split_guard(guard("(a > 1 and b > t) and c > 2"), [:a, :b, :c])

      assert "a > 1" == Macro.to_string(alpha)
      assert "b > t && c > 2" == Macro.to_string(join)
    end

    test "&& chains split too" do
      {alpha, join} = Bindings.split_guard(guard("a > 1 && a > t"), [:a])

      assert "a > 1" == Macro.to_string(alpha)
      assert "a > t" == Macro.to_string(join)
    end

    # Rejoining an `&&` chain with a strict `and` turns a guard over a truthy
    # value into a BadBooleanError, so splitting the guard would change its
    # meaning - and only when it happens to be split.
    test "an all && chain is rejoined with &&" do
      {alpha, join} = Bindings.split_guard(guard("flag && amt > 0 && amt > t"), [:flag, :amt])

      assert "flag && amt > 0" == Macro.to_string(alpha)
      assert "amt > t" == Macro.to_string(join)
    end

    test "a split && guard still accepts a truthy value" do
      production = classify("r({:limit, t}, {:order, flag, amt} when flag && amt > 0 && amt > t)")
      order = at(production, 1)

      assert %{flag: "yes", amt: 5} == fun(order.alpha).({:order, "yes", 5})
      assert nil == fun(order.alpha).({:order, nil, 5})
      assert nil == fun(order.alpha).({:order, "yes", 0})
      assert true == fun(order.join_filter).(%{t: 1}, %{amt: 5})
    end

    test "a mixed and/&& chain keeps each conjunct's own operator" do
      {alpha, join} = Bindings.split_guard(guard("a > 1 && b and c > t"), [:a, :b, :c])

      assert "a > 1 && b" == Macro.to_string(alpha)
      assert "c > t" == Macro.to_string(join)
    end

    # A guard whose *first* conjunct is cross condition has no local prefix, so
    # nothing stays in the alpha and the guard moves across whole.
    test "a guard that opens with a remote conjunct moves across entirely" do
      {alpha, join} = Bindings.split_guard(guard("a > t and b && c > 1"), [:b, :c])

      assert nil == alpha
      assert "(a > t and b) && c > 1" == Macro.to_string(join)
    end

    test "an and whose predecessor was lifted out is rejoined with &&" do
      {alpha, join} = Bindings.split_guard(guard("flag && amt > t and amt > 0"), [:flag, :amt])

      assert "flag" == Macro.to_string(alpha)
      assert "amt > t && amt > 0" == Macro.to_string(join)
    end

    test "a mixed chain split in the middle still accepts a truthy value" do
      production =
        classify("r({:limit, t}, {:order, flag, amt} when flag && amt > t and amt > 0)")

      order = at(production, 1)

      # Only `flag` is left in the alpha: `amt > 0` sits after `amt > t` and
      # cannot be hoisted over it, so it is checked at the join instead.
      assert %{flag: "yes", amt: 5} == fun(order.alpha).({:order, "yes", 5})
      assert nil == fun(order.alpha).({:order, nil, 5})
      assert %{flag: "yes", amt: 0} == fun(order.alpha).({:order, "yes", 0})

      assert true == fun(order.join_filter).(%{t: 1}, %{amt: 5})
      assert false == fun(order.join_filter).(%{t: 9}, %{amt: 5})
      assert false == fun(order.join_filter).(%{t: -1}, %{amt: 0})
    end

    # The conjuncts before it are all still there, so this `and` is the one the
    # guard was written with and keeps its strictness.
    test "an and with an intact prefix keeps its operator" do
      {alpha, join} = Bindings.split_guard(guard("a > 1 and b > 2 and c > t"), [:a, :b, :c])

      assert "a > 1 and b > 2" == Macro.to_string(alpha)
      assert "c > t" == Macro.to_string(join)
    end

    # No local prefix, so the whole chain is lifted and keeps its shape.
    test "a local conjunct between two remote ones is not hoisted out" do
      {alpha, join} = Bindings.split_guard(guard("a > t and b > 1 and a > u"), [:b])

      assert nil == alpha
      assert "a > t and b > 1 and a > u" == Macro.to_string(join)
    end

    test "an underscore prefixed upstream variable is lifted like any other" do
      {alpha, join} = Bindings.split_guard(guard("amt > 0 and amt > _t"), [:amt])

      assert "amt > 0" == Macro.to_string(alpha)
      assert "amt > _t" == Macro.to_string(join)
    end

    test "an all local chain is returned untouched" do
      original = guard("a > 1 and b > 2")
      assert {^original, nil} = Bindings.split_guard(original, [:a, :b])
    end

    test "an all remote chain leaves no alpha guard" do
      {alpha, join} = Bindings.split_guard(guard("a > t and a > u"), [:a])

      assert nil == alpha
      assert "a > t and a > u" == Macro.to_string(join)
    end
  end

  describe "guards that cannot be decomposed" do
    test "an or mixing local and upstream variables goes wholly to the join filter" do
      production = classify("r({:threshold, t}, {:order, amt} when amt > 100 or amt > t)")
      order = at(production, 1)

      assert "fact_order_bind_amt_expr_" <> _ = Atom.to_string(order.alpha.code)

      join = fun(order.join_filter)
      assert true == join.(%{t: 1000}, %{amt: 200})
      assert true == join.(%{t: 1}, %{amt: 2})
      assert false == join.(%{t: 1000}, %{amt: 2})
    end

    test "a single expression touching both sides goes to the join filter" do
      {alpha, join} = Bindings.split_guard(guard("amt > t + 1"), [:amt])

      assert nil == alpha
      assert "amt > t + 1" == Macro.to_string(join)
    end

    test "a not over a mixed conjunction is not decomposed" do
      {alpha, join} = Bindings.split_guard(guard("not (amt > 0 and amt > t)"), [:amt])

      assert nil == alpha
      assert "not (amt > 0 and amt > t)" == Macro.to_string(join)
    end

    test "an or of purely local terms still stays in the alpha" do
      original = guard("amt > 100 or amt < 0")
      assert {^original, nil} = Bindings.split_guard(original, [:amt])
    end
  end

  # --- join_bind / new_bind ---------------------------------------------------

  describe "join_bind and new_bind" do
    setup do
      production =
        classify("""
        r({:customer, cid, name},
          {:order, cid, amt},
          items = [{:item, cid, sku}],
          {:ship, sku, amt})
        """)

      {:ok, production: production}
    end

    test "the first condition introduces everything", %{production: production} do
      assert %IR.Fact{bind: [:cid, :name], join_bind: [], new_bind: [:cid, :name]} =
               at(production, 0)
    end

    test "a later condition splits on what is already bound", %{production: production} do
      assert %IR.Fact{bind: [:amt, :cid], join_bind: [:cid], new_bind: [:amt]} =
               at(production, 1)
    end

    test "a collection classifies like a fact and the list binding is neither",
         %{production: production} do
      assert %IR.Coll{
               coll_binding: :items,
               bind: [:cid, :sku],
               join_bind: [:cid],
               new_bind: [:sku]
             } = at(production, 2)
    end

    test "a condition can be a pure join", %{production: production} do
      assert %IR.Fact{bind: [:amt, :sku], join_bind: [:amt, :sku], new_bind: []} =
               at(production, 3)
    end

    test "join_bind ++ new_bind is always exactly bind", %{production: production} do
      for condition <- production.lhs,
          match?(%struct{} when struct in [IR.Fact, IR.Coll], condition) do
        assert condition.bind == Enum.sort(condition.join_bind ++ condition.new_bind)
        assert [] == condition.join_bind -- condition.bind
        assert [] == condition.new_bind -- condition.bind
        assert [] == Enum.filter(condition.join_bind, &(&1 in condition.new_bind))
      end
    end

    test "a fact binding is visible to later conditions" do
      production = classify("r(f = {:a, x}, {:b, f, y})")

      assert %IR.Fact{fact_binding: :f, new_bind: [:x]} = at(production, 0)
      assert %IR.Fact{bind: [:f, :y], join_bind: [:f], new_bind: [:y]} = at(production, 1)
    end

    test "a collection binding is visible to later conditions" do
      production = classify("r(xs = [{:a, x}], {:b, xs, y})")

      # `x` is matched by no other condition, so it is local to the collection:
      # it constrains what is gathered and binds nothing. The collection binding
      # `xs` is what escapes.
      assert %IR.Coll{coll_binding: :xs, bind: [:x], new_bind: [], inert: [:x]} =
               at(production, 0)

      assert %IR.Fact{join_bind: [:xs], new_bind: [:y]} = at(production, 1)
    end

    test "a repeated variable in one pattern is a single new binding" do
      production = classify("r({:pair, x, x})")
      assert %IR.Fact{bind: [:x], join_bind: [], new_bind: [:x]} = at(production, 0)
    end

    test "struct and tagged map conditions classify the same way" do
      production =
        classify("r(%{__type__: :customer, id: cid}, %ReteBindingsTestOrder{id: cid, amount: a})")

      assert %IR.Fact{type: :customer, join_bind: [], new_bind: [:cid]} = at(production, 0)

      assert %IR.Fact{type: ReteBindingsTestOrder, join_bind: [:cid], new_bind: [:a]} =
               at(production, 1)
    end
  end

  describe "empty collection semantics depend on new_bind" do
    test "a collection introducing no variable propagates the empty list" do
      production = classify("r({:customer, cid}, orders = [{:order, cid}])")
      assert %IR.Coll{bind: [:cid], join_bind: [:cid], new_bind: []} = at(production, 1)
    end

    # Only a *real join* makes a collection variable participate, and the sort
    # defers collections, so a plain condition matching the variable ends up
    # before it and makes it a join key. Two collections is the shape where one
    # genuinely groups.
    test "a collection introducing a variable groups by it when another collection joins on it" do
      production =
        classify(
          "r({:customer, cid}, orders = [{:order, cid, amt}], notes = [{:note, cid, amt}])"
        )

      assert %IR.Coll{join_bind: [:cid], new_bind: [:amt], inert: []} = at(production, 1)
      assert %IR.Coll{join_bind: [:amt, :cid], new_bind: [], inert: []} = at(production, 2)
    end

    test "a collection variable nothing else matches on is local, so the collection is not grouped" do
      production = classify("r({:customer, cid}, orders = [{:order, cid, amt}])")

      assert %IR.Coll{bind: [:amt, :cid], join_bind: [:cid], new_bind: [], inert: [:amt]} =
               at(production, 1)
    end

    test "a plain condition matching the variable makes it a join key, not a grouping variable" do
      production = classify("r({:customer, cid}, {:pick, amt}, orders = [{:order, cid, amt}])")

      assert %IR.Coll{join_bind: [:amt, :cid], new_bind: [], inert: []} = at(production, 2)
    end

    test "a collection guard reaching upstream still becomes a join filter" do
      production = classify("r({:threshold, t}, orders = [{:order, amt} when amt > t])")
      coll = at(production, 1)

      assert "fact_order_bind_amt_expr_" <> _ = Atom.to_string(coll.alpha.code)
      assert %IR.Expr{arity: 2} = coll.join_filter
      assert true == fun(coll.join_filter).(%{t: 1}, %{amt: 2})
      assert false == fun(coll.join_filter).(%{t: 2}, %{amt: 1})
    end
  end

  # --- compile time values ----------------------------------------------------

  describe "pinned values and module attributes are not bindings" do
    test "a module attribute in a guard keeps the guard local" do
      assert 10 == @limit

      production = classify("r({:threshold, t}, {:order, amt} when amt > @limit)")
      order = at(production, 1)

      assert nil == order.join_filter
      assert [:amt] == order.bind
      assert [:amt] == order.new_bind
      assert "test_fact_order_bind_amt_expr_" <> _ = Atom.to_string(order.alpha.code)
    end

    test "a module attribute mixed with an upstream variable splits correctly" do
      production =
        classify("r({:threshold, t}, {:order, amt} when amt > @limit and amt > t)")

      order = at(production, 1)

      assert "test_fact_order_bind_amt_expr_" <> _ = Atom.to_string(order.alpha.code)
      assert "join_order_bind_amt_t_expr_" <> _ = Atom.to_string(order.join_filter.code)
      assert {:if, _, [join_guard, _]} = order.join_filter.__ast__.body
      assert "amt > t" == Macro.to_string(join_guard)
    end

    test "the attribute is not counted as a guard variable" do
      resolved = guard("amt > @limit")
      assert [:amt] == Bindings.guard_vars(resolved)
      assert {^resolved, nil} = Bindings.split_guard(resolved, [:amt])
    end

    # Pinning an upstream variable is the explicit spelling of the join this DSL
    # already does implicitly when a variable is shared between conditions, so
    # it has to produce the same join key. This previously asserted `bind: []`,
    # which only looked right because nothing compiled the generated function:
    # the pin survived into the alpha and `defrule` failed with
    # `undefined variable ^amt`.
    test "a pinned upstream variable is a join key" do
      production = classify("r({:threshold, amt}, {:order, ^amt})")

      assert %IR.Fact{bind: [:amt], new_bind: [:amt]} = at(production, 0)
      assert %IR.Fact{bind: [:amt], join_bind: [:amt], new_bind: []} = at(production, 1)
    end

    test "a pinned value in a guard is not a guard variable" do
      pinned = guard("amt > ^t")

      assert [:amt] == Bindings.guard_vars(pinned)
      assert {^pinned, nil} = Bindings.split_guard(pinned, [:amt])
    end
  end

  # --- negation ---------------------------------------------------------------

  describe "negation" do
    # The parser does not build negations yet, so assemble the LHS by hand the
    # way gate normalization will.
    defp with_negation do
      production = parse("r({:customer, cid}, {:refund, amt, rid})")
      [customer, refund] = production.lhs
      negated = %IR.Negation{condition: element("{:order, cid, amt}")}

      classify(put_lhs(production, [customer, negated, refund]))
    end

    test "variables inside a negation do not escape to later conditions" do
      [_customer, negation, refund] = with_negation().lhs

      assert %IR.Negation{condition: %IR.Fact{join_bind: [:cid], new_bind: [:amt]}} = negation

      # `amt` was only ever seen inside the negation, so `refund` introduces it.
      assert %IR.Fact{bind: [:amt, :rid], join_bind: [], new_bind: [:amt, :rid]} = refund
    end

    test "the negated condition is still classified against upstream bindings" do
      [_customer, negation, _refund] = with_negation().lhs
      assert [:cid] == negation.condition.join_bind
    end

    test "a guard inside a negation still splits" do
      production = parse("r({:threshold, t})")
      negated = %IR.Negation{condition: element("{:order, amt} when amt > 0 and amt > t")}
      [_threshold, negation] = classify(put_lhs(production, production.lhs ++ [negated])).lhs

      assert "test_fact_order_bind_amt_expr_" <> _ =
               Atom.to_string(negation.condition.alpha.code)

      assert true == fun(negation.condition.join_filter).(%{t: 1}, %{amt: 2})
    end
  end

  # --- tests and disjunctions -------------------------------------------------

  describe "tests bind nothing" do
    test "a rule level guard becomes a trailing test and adds no bindings" do
      production = classify("r({:order, amt}) when amt > 0")

      assert [%IR.Fact{new_bind: [:amt]}, %IR.Test{bind: [:amt]}] = production.lhs
    end

    test "a test in the middle of the lhs does not bind for what follows" do
      production = parse("r({:a, x}, {:b, y})")
      [a, b] = production.lhs
      test_node = element("{:ignored, z}")

      # A Test never reaches this phase carrying new variables, but make sure a
      # variable only a test reads is not treated as bound downstream.
      test_node = %IR.Test{bind: [:z], expr: test_node.alpha, __ast__: %{guard: nil, bind: %{}}}

      [_a, _test, b] = classify(put_lhs(production, [a, test_node, b])).lhs
      assert %IR.Fact{join_bind: [], new_bind: [:y]} = b
    end
  end

  describe "disjunctions" do
    defp with_or do
      production = parse("r({:c, x, y})")
      [tail] = production.lhs

      branches =
        {:or, [[element("{:a, x, y}")], [element("{:b, x, z}")]]}

      classify(put_lhs(production, [branches, tail]))
    end

    test "each branch is classified against the bindings before the disjunction" do
      [{:or, [[a, _], [b, _]]}] = with_or().lhs

      assert %IR.Fact{join_bind: [], new_bind: [:x, :y]} = a
      assert %IR.Fact{join_bind: [], new_bind: [:x, :z]} = b
    end

    test "a tail that classifies differently per branch is absorbed into the branches" do
      # `y` is bound by the first branch only, so on that path `{:c, x, y}` is a
      # pure join and on the other it introduces `y`. One shared classification
      # cannot say both.
      [{:or, [[_a, first], [_b, second]]}] = with_or().lhs

      assert %IR.Fact{type: :c, join_bind: [:x, :y], new_bind: []} = first
      assert %IR.Fact{type: :c, join_bind: [:x], new_bind: [:y]} = second
    end

    test "a branch sees what came before the disjunction" do
      production = parse("r({:seed, x})")
      branches = {:or, [[element("{:a, x, y}")], [element("{:b, x, z}")]]}
      [_seed, {:or, [[a], [b]]}] = classify(put_lhs(production, production.lhs ++ [branches])).lhs

      assert %IR.Fact{join_bind: [:x], new_bind: [:y]} = a
      assert %IR.Fact{join_bind: [:x], new_bind: [:z]} = b
    end

    # This is the confirmed defect: the intersection of the branch bound sets is
    # the right answer for "what is guaranteed bound afterwards" but the wrong
    # one for join keys, and taking it dropped `id` from join_bind entirely,
    # turning the join into a cartesian product on the branch that binds it.
    test "a variable bound by one branch is still a join key on that branch" do
      production = parse("r({:login, id, ts})")
      [login] = production.lhs
      branches = {:or, [[element("{:user, id}")], [element("{:override, :all}")]]}

      assert [{:or, [[user, on_user], [override, on_override]]}] =
               classify(put_lhs(production, [branches, login])).lhs

      assert %IR.Fact{type: :user, join_bind: [], new_bind: [:id]} = user
      assert %IR.Fact{type: :login, join_bind: [:id], new_bind: [:ts]} = on_user

      assert %IR.Fact{type: :override, bind: [], join_bind: [], new_bind: []} = override
      assert %IR.Fact{type: :login, join_bind: [], new_bind: [:id, :ts]} = on_override
    end

    test "branches that classify the tail the same way keep the lhs flat" do
      production = parse("r({:login, id, ts})")
      [login] = production.lhs
      branches = {:or, [[element("{:user, id}")], [element("{:admin, id}")]]}

      assert [{:or, [[_user], [_admin]]}, tail] =
               classify(put_lhs(production, [branches, login])).lhs

      assert %IR.Fact{type: :login, join_bind: [:id], new_bind: [:ts]} = tail
    end

    test "an empty disjunction leaves the rest of the lhs alone" do
      production = parse("r({:a, x}, {:b, x, y})")
      [a, b] = production.lhs

      assert [{:or, []}, _a, _b] = classify(put_lhs(production, [{:or, []}, a, b])).lhs
    end

    # Asserted on the guard rather than on a real blow up, so the suite stays
    # fast: 600 branches whose tails differ already exceed the element budget.
    test "specialization that would explode raises instead" do
      production = parse("r({:t, x})")
      [tail] = production.lhs
      binds_x = [element("{:a, x}")]
      binds_nothing = [element("{:b}")]
      branches = {:or, [binds_x | for(_ <- 1..600, do: binds_nothing)]}

      assert_raise ArgumentError, ~r/more than the 1024 allowed/, fn ->
        classify(put_lhs(production, [branches, tail]))
      end
    end
  end

  # --- generated code ---------------------------------------------------------

  describe "the split guard compiles" do
    test "a cross condition guard produces a module that compiles and runs" do
      # This is confirmed defect 2: before splitting, the guard was inlined into
      # the arity 1 alpha, which referred to a variable that pattern never binds.
      production = classify("r({:threshold, t}, {:order, id, amt} when amt > 0 and amt > t)")

      module = :"Elixir.ReteBindingsGen#{System.unique_integer([:positive])}"

      Module.create(
        module,
        quote do
          (unquote_splicing(Parser.expr_defs(production)))
        end,
        Macro.Env.location(__ENV__)
      )

      order = at(production, 1)

      assert %{id: 1, amt: 5} == apply(module, order.alpha.name, [{:order, 1, 5}])
      assert nil == apply(module, order.alpha.name, [{:order, 1, 0}])
      assert true == apply(module, order.join_filter.name, [%{t: 3}, %{amt: 5}])
      assert false == apply(module, order.join_filter.name, [%{t: 9}, %{amt: 5}])
    end
  end

  # --- filter_vars, guard_vars, errors ----------------------------------------

  describe "filter_vars/1" do
    test "reports the variables that force a join filter" do
      fact = element("{:order, id, amt} when amt > 0 and amt > t and id == c")
      assert [:c, :t] == Bindings.filter_vars(fact)
    end

    test "is empty for a purely local guard" do
      assert [] == Bindings.filter_vars(element("{:order, amt} when amt > 0"))
    end

    test "is empty for an unguarded condition" do
      assert [] == Bindings.filter_vars(element("{:order, amt}"))
    end
  end

  describe "guard_vars/1" do
    # A `_`-prefixed name is a real Elixir binding, the prefix only silences the
    # unused-variable warning. Dropping it made `amt > _limit` look local, so it
    # was inlined into the arity 1 alpha where `_limit` is not in scope.
    test "counts underscore prefixed variables" do
      assert [:_limit, :amt] == Bindings.guard_vars(guard("amt > _limit"))
    end

    test "ignores the anonymous underscore" do
      assert [:amt] == Bindings.guard_vars(guard("amt > 0 and match?(_, amt)"))
    end

    test "ignores function calls" do
      assert [:name] == Bindings.guard_vars(guard("is_binary(name) and byte_size(name) > 0"))
    end

    test "is empty for no guard" do
      assert [] == Bindings.guard_vars(nil)
    end
  end

  # Until W2 sorts conditions topologically, a guard may only read what is
  # already bound. Relaxing this is a change to check_guard_vars!/3 alone.
  describe "guard variables that are bound nowhere" do
    test "a condition written before the one that binds its guard variable raises" do
      assert_raise ArgumentError, ~r/reads `t`, which is neither bound/, fn ->
        classify("r({:order, amt} when amt > t, {:threshold, t})")
      end
    end

    test "the same rule in the right order compiles" do
      production = classify("r({:threshold, t}, {:order, amt} when amt > t)")

      assert %IR.Expr{arity: 2} = at(production, 1).join_filter
    end

    test "a misspelled variable raises" do
      assert_raise ArgumentError, ~r/reads `amount`/, fn ->
        classify("r({:order, amt} when amount > 0)")
      end
    end

    test "the message names the condition" do
      assert_raise ArgumentError, ~r/guard of `\{:order, amt\}`/, fn ->
        classify("r({:order, amt} when amt > t)")
      end
    end

    test "a variable bound only inside a negation is not available downstream" do
      production = parse("r({:threshold, t})")
      negated = %IR.Negation{condition: element("{:cap, cap}")}
      order = element("{:order, amt} when amt > cap")

      assert_raise ArgumentError, ~r/reads `cap`/, fn ->
        classify(put_lhs(production, production.lhs ++ [negated, order]))
      end
    end
  end

  describe "errors" do
    test "a gate reaching this phase raises" do
      production = parse("r({:or, [{:a, x}, {:b, x}]})")

      assert_raise ArgumentError, ~r/gate reached binding classification/, fn ->
        classify(production)
      end
    end

    test "an escaped condition raises" do
      production = parse("r({:order, amt})")
      %IR.Fact{} = fact = at(production, 0)
      stripped = %IR.Fact{fact | __ast__: nil}

      assert_raise ArgumentError, ~r/must run before Rete.IR.escape\/1/, fn ->
        classify(put_lhs(production, [stripped]))
      end
    end
  end

  # --- idempotence -------------------------------------------------------------

  describe "classify/2" do
    test "is idempotent" do
      once = classify("r({:threshold, t}, {:order, id, amt} when amt > 0 and amt > t)")
      twice = Bindings.classify(__ENV__, once)

      assert once.lhs == twice.lhs
    end

    test "leaves the rest of the production alone" do
      parsed = parse("r(%{salience: 3}, {:order, amt} when amt > 0)")
      classified = classify(parsed)

      assert parsed.name == classified.name
      assert parsed.opts == classified.opts
      assert parsed.bind == classified.bind
      assert parsed.hash == classified.hash
      assert parsed.module == classified.module
      assert parsed.__ast__ == classified.__ast__
    end
  end
end
