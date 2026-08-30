defmodule ReteParserTestOrder do
  @moduledoc false
  defstruct [:id, :amount]
end

defmodule Rete.DSL.ParserTest do
  use ExUnit.Case, async: true

  alias Rete.DSL.Parser
  alias Rete.IR

  defmodule Rules do
    use Rete.Ruleset

    # --- arity ------------------------------------------------------------

    defrule nullary({:tick}) do
      {:ticked}
    end

    defrule unary({:user, id}) do
      {:seen, id}
    end

    defrule ternary({:user, id, name}) do
      {:seen, id, name}
    end

    defrule quinary({:point, a, b, c, d}) do
      {:point, a, b, c, d}
    end

    defrule ignored_args({:order, id, _amount}) do
      {:seen, id}
    end

    # --- structs ----------------------------------------------------------

    defrule struct_cond(%ReteParserTestOrder{id: id, amount: amount}) do
      {:struct_order, id, amount}
    end

    defrule struct_bound_guarded(order = %ReteParserTestOrder{id: id} when id > 10) do
      {:big, order, id}
    end

    # `id` is local to the collection - no other condition matches on it - so it
    # is still bound by the pattern (the alpha returns it) but the right hand
    # side may not read it. See Rete.DSL.Bindings.mark_inert/1.
    defrule struct_coll(orders = [%ReteParserTestOrder{id: id}]) do
      {:orders, length(orders)}
    end

    # --- tagged maps ------------------------------------------------------

    defrule map_cond(%{__type__: :order, id: id}) do
      {:map_order, id}
    end

    defrule map_bound_guarded(order = %{__type__: :order, id: id} when id > 10) do
      {:big, order, id}
    end

    defrule map_coll(orders = [%{__type__: :order, id: id} when id > 0]) do
      {:orders, length(orders)}
    end

    # --- n-arity in every position ---------------------------------------

    defrule nary_bound(user = {:user, id, name}) do
      {:bound, user, id, name}
    end

    defrule nary_guarded({:user, id, name} when id > 0 and name != "") do
      {:guarded, id, name}
    end

    defrule nary_bound_guarded(user = {:user, id, name} when id > 0) do
      {:bound_guarded, user, id, name}
    end

    defrule nary_coll(users = [{:user, id, name}]) do
      {:coll, length(users)}
    end

    defrule nary_coll_guarded(users = [{:user, id, name} when id > 0]) do
      {:coll, length(users)}
    end

    defrule unary_coll(ticks = [{:tick}]) do
      {:ticks, length(ticks)}
    end

    defrule nary_gate({:or, [{:user, id, name}, {:admin, id, name, _level}]}) do
      {:principal, id, name}
    end

    defrule nested_gate({:and, [{:user, id}, {:not, [%ReteParserTestOrder{id: id}]}]}) do
      {:orderless, id}
    end

    # --- mixed ------------------------------------------------------------

    defrule partial_rhs({:user, id, name}) do
      {:seen, id}
    end

    defrule mixed(
              %{salience: 7},
              {:customer, cid, name},
              %ReteParserTestOrder{id: cid, amount: amount},
              items = [%{__type__: :item, order: cid}]
            )
            when amount > 0 do
      {:loyalty, cid, name, amount, length(items)}
    end
  end

  defp production(name) do
    Enum.find(Rules.get_rule_data(), &(&1.name == name))
  end

  defp lhs(name), do: production(name).lhs
  defp cond_at(name, index), do: Enum.at(lhs(name), index)
  defp alpha(name, index \\ 0), do: cond_at(name, index).alpha.fun
  defp code(name, index \\ 0), do: cond_at(name, index).alpha.code

  describe "tuple fact patterns of any arity" do
    test "1-arity tuple binds nothing and matches any 1-tuple" do
      assert %IR.Fact{type: :tick, bind: [], fact_binding: nil} = cond_at(:nullary, 0)
      assert %{} == alpha(:nullary).({:tick})
      # the alpha never checks the type, the alpha index does
      assert %{} == alpha(:nullary).({:tock})
      assert nil == alpha(:nullary).({:tick, 1})
      assert nil == alpha(:nullary).(:tick)
    end

    test "2-arity tuple" do
      assert %IR.Fact{type: :user, bind: [:id]} = cond_at(:unary, 0)
      assert %{id: 1} == alpha(:unary).({:user, 1})
      assert nil == alpha(:unary).({:user, 1, "a"})
    end

    test "3-arity tuple" do
      assert %IR.Fact{type: :user, bind: [:id, :name]} = cond_at(:ternary, 0)
      assert %{id: 1, name: "a"} == alpha(:ternary).({:user, 1, "a"})
      assert nil == alpha(:ternary).({:user, 1})
    end

    test "5-arity tuple" do
      assert %IR.Fact{type: :point, bind: [:a, :b, :c, :d]} = cond_at(:quinary, 0)
      assert %{a: 1, b: 2, c: 3, d: 4} == alpha(:quinary).({:point, 1, 2, 3, 4})
    end

    test "underscore prefixed variables are not bindings" do
      assert %IR.Fact{type: :order, bind: [:id]} = cond_at(:ignored_args, 0)
      assert %{id: 1} == alpha(:ignored_args).({:order, 1, 99})
      assert [:id] == production(:ignored_args).bind
    end
  end

  describe "struct fact patterns" do
    test "the type is the module and the alpha does not check __struct__" do
      assert %IR.Fact{type: ReteParserTestOrder, bind: [:amount, :id]} = cond_at(:struct_cond, 0)
      assert %{id: 1, amount: 5} == alpha(:struct_cond).(%ReteParserTestOrder{id: 1, amount: 5})
      assert %{id: 1, amount: 5} == alpha(:struct_cond).(%{id: 1, amount: 5})
      assert nil == alpha(:struct_cond).({:order, 1, 5})
    end

    test "the expression code uses the module name without the Elixir prefix" do
      assert "fact_ReteParserTestOrder_bind_amount_id_expr_" <>
               _ = Atom.to_string(code(:struct_cond))
    end

    test "fact binding plus guard" do
      assert %IR.Fact{type: ReteParserTestOrder, fact_binding: :order, bind: [:id]} =
               cond_at(:struct_bound_guarded, 0)

      assert %{id: 11} == alpha(:struct_bound_guarded).(%ReteParserTestOrder{id: 11})
      assert nil == alpha(:struct_bound_guarded).(%ReteParserTestOrder{id: 10})

      assert "test_fact_ReteParserTestOrder_bind_id_expr_" <> _ =
               Atom.to_string(code(:struct_bound_guarded))
    end

    test "inside a collection" do
      assert %IR.Coll{type: ReteParserTestOrder, coll_binding: :orders, bind: [:id]} =
               cond_at(:struct_coll, 0)

      assert %{id: 3} == alpha(:struct_coll).(%ReteParserTestOrder{id: 3})
    end
  end

  describe "tagged map fact patterns" do
    test "the type is the __type__ atom and the key is dropped from the pattern" do
      assert %IR.Fact{type: :order, bind: [:id]} = cond_at(:map_cond, 0)
      assert %{id: 1} == alpha(:map_cond).(%{__type__: :order, id: 1})
      # the alpha never checks the type, the alpha index does
      assert %{id: 1} == alpha(:map_cond).(%{__type__: :other, id: 1})
      assert %{id: 1} == alpha(:map_cond).(%{id: 1})
      assert nil == alpha(:map_cond).(%{amount: 1})
    end

    test "fact binding plus guard" do
      assert %IR.Fact{type: :order, fact_binding: :order, bind: [:id]} =
               cond_at(:map_bound_guarded, 0)

      assert %{id: 11} == alpha(:map_bound_guarded).(%{__type__: :order, id: 11})
      assert nil == alpha(:map_bound_guarded).(%{__type__: :order, id: 10})
    end

    test "inside a guarded collection" do
      assert %IR.Coll{type: :order, coll_binding: :orders, bind: [:id]} = cond_at(:map_coll, 0)
      assert %{id: 1} == alpha(:map_coll).(%{__type__: :order, id: 1})
      assert nil == alpha(:map_coll).(%{__type__: :order, id: 0})
    end
  end

  describe "n-arity tuples in every position" do
    test "fact binding" do
      assert %IR.Fact{type: :user, fact_binding: :user, bind: [:id, :name]} =
               cond_at(:nary_bound, 0)

      assert %{id: 1, name: "a"} == alpha(:nary_bound).({:user, 1, "a"})
      assert [:id, :name, :user] == Enum.sort(production(:nary_bound).bind)
    end

    test "per condition guard" do
      assert %IR.Fact{type: :user, fact_binding: nil, bind: [:id, :name]} =
               cond_at(:nary_guarded, 0)

      assert %{id: 1, name: "a"} == alpha(:nary_guarded).({:user, 1, "a"})
      assert nil == alpha(:nary_guarded).({:user, 0, "a"})
      assert nil == alpha(:nary_guarded).({:user, 1, ""})
    end

    test "fact binding and per condition guard" do
      assert %IR.Fact{type: :user, fact_binding: :user, bind: [:id, :name]} =
               cond_at(:nary_bound_guarded, 0)

      assert %{id: 1, name: "a"} == alpha(:nary_bound_guarded).({:user, 1, "a"})
      assert nil == alpha(:nary_bound_guarded).({:user, 0, "a"})
    end

    test "collection" do
      assert %IR.Coll{type: :user, coll_binding: :users, bind: [:id, :name]} =
               cond_at(:nary_coll, 0)

      assert %{id: 1, name: "a"} == alpha(:nary_coll).({:user, 1, "a"})
    end

    test "guarded collection" do
      assert %IR.Coll{type: :user, coll_binding: :users, bind: [:id, :name]} =
               cond_at(:nary_coll_guarded, 0)

      assert %{id: 1, name: "a"} == alpha(:nary_coll_guarded).({:user, 1, "a"})
      assert nil == alpha(:nary_coll_guarded).({:user, 0, "a"})
    end

    test "1-arity collection" do
      assert %IR.Coll{type: :tick, coll_binding: :ticks, bind: []} = cond_at(:unary_coll, 0)
      assert %{} == alpha(:unary_coll).({:tick})
    end

    # Gates are parsed here into %IR.Gate{} placeholders, but the compiled
    # module runs the whole pipeline, so what get_rule_data/0 exposes is the
    # normalized form. Assert the parser output on a directly parsed element and
    # the normalized output on the module.
    test "inside a gate" do
      assert %IR.Gate{gate: :or, args: [user, admin]} =
               element("{:or, [{:user, id, name}, {:admin, id, name, _level}]}")

      assert %IR.Fact{type: :user, bind: [:id, :name]} = user
      assert %IR.Fact{type: :admin, bind: [:id, :name]} = admin

      assert {:or, [[user], [admin]]} = cond_at(:nary_gate, 0)
      assert %{id: 1, name: "a"} == user.alpha.fun.({:user, 1, "a"})
      assert %{id: 1, name: "a"} == admin.alpha.fun.({:admin, 1, "a", :root})
    end

    test "gate code is the nested structural id" do
      %IR.Gate{code: code} = element("{:or, [{:user, id, name}, {:admin, id, name, _level}]}")
      assert [:or, user_code, admin_code] = code
      assert "fact_user_bind_id_name_expr_" <> _ = Atom.to_string(user_code)
      assert "fact_admin_bind_id_name_expr_" <> _ = Atom.to_string(admin_code)
    end

    test "nested gates keep struct conditions" do
      assert %IR.Gate{gate: :and, args: [user, inner]} =
               element("{:and, [{:user, id}, {:not, [%ReteParserTestOrder{id: id}]}]}")

      assert %IR.Fact{type: :user, bind: [:id]} = user
      assert %IR.Gate{gate: :not, args: [%IR.Fact{type: ReteParserTestOrder}]} = inner

      assert [
               %IR.Fact{type: :user, bind: [:id]},
               %IR.Negation{condition: %IR.Fact{type: ReteParserTestOrder}}
             ] = lhs(:nested_gate)
    end
  end

  describe "production shape" do
    test "options, ordering, rule level guard and rhs" do
      mixed = production(:mixed)

      assert :rule == mixed.type
      assert [salience: 7] == mixed.opts
      assert Rules == mixed.module
      assert is_integer(mixed.hash)
      assert nil == mixed.__ast__
      assert [:amount, :cid, :items, :name] == Enum.sort(mixed.bind)

      assert [
               %IR.Fact{type: :customer, bind: [:cid, :name]},
               %IR.Fact{type: ReteParserTestOrder, bind: [:amount, :cid]},
               %IR.Coll{type: :item, coll_binding: :items, bind: [:cid]},
               %IR.Test{bind: [:amount]}
             ] = mixed.lhs

      test_node = Enum.at(mixed.lhs, 3)
      assert true == test_node.expr.fun.(%{amount: 1})
      assert false == test_node.expr.fun.(%{amount: 0})

      assert (&Rules.__rhs_mixed__/2) == mixed.rhs

      assert {:loyalty, 1, "a", 2, 0} ==
               mixed.rhs.(mixed.hash, %{cid: 1, name: "a", amount: 2, items: []})
    end

    test "the rhs destructures every binding even when the body ignores some" do
      partial = production(:partial_rhs)

      assert [:id, :name] == partial.bind
      assert {:seen, 1} == partial.rhs.(partial.hash, %{id: 1, name: "a"})
    end

    # The parser itself leaves these to Rete.DSL.Bindings; the compiled module
    # runs that phase too, so this has to be asserted on parser output.
    test "join filter and binding classification are left for the later phases" do
      for source <- [
            "r({:user, id, name})",
            "r(u = {:user, id} when id > 0)",
            "r(users = [{:user, id, name}])",
            "r({:threshold, t}, {:order, amt} when amt > t)"
          ] do
        production =
          Parser.parse_production(__ENV__, Code.string_to_quoted!(source), nil, :rule)

        for %struct{} = condition <- production.lhs, struct in [IR.Fact, IR.Coll] do
          assert nil == condition.join_filter
          assert nil == condition.join_bind
          assert nil == condition.new_bind
        end
      end
    end

    test "expressions are shared by code and every one is captured" do
      expr_data = Rules.get_expr_data()

      assert Enum.all?(expr_data, fn {code, fun} ->
               is_atom(code) and is_function(fun, 1)
             end)

      codes = Enum.map(expr_data, fn {code, _} -> code end)
      assert codes == Enum.uniq(codes)

      # nary_bound and nary_bound_guarded share nothing, but nary_coll and
      # nary_bound share the plain {:user, id, name} alpha
      assert code(:nary_bound) == code(:nary_coll)
      assert code(:nary_bound) != code(:nary_bound_guarded)
    end

    test "identical conditions in different rules yield the same function" do
      assert alpha(:nary_bound) == alpha(:nary_coll)
    end
  end

  describe "compile_pattern/2" do
    test "rejects a map pattern without __type__" do
      assert_raise ArgumentError, ~r/must declare its type with __type__/, fn ->
        Parser.compile_pattern(__ENV__, quote(do: %{id: id}))
      end
    end

    test "rejects a non literal __type__" do
      assert_raise ArgumentError, ~r/must be a literal atom/, fn ->
        Parser.compile_pattern(__ENV__, quote(do: %{__type__: t, id: id}))
      end
    end

    test "rejects an unsupported condition" do
      assert_raise ArgumentError, ~r/unsupported condition/, fn ->
        Parser.compile_pattern(__ENV__, quote(do: [1, 2, 3]))
      end
    end
  end

  describe "parse_element/2" do
    # `quote` tags variables with the caller module as their context, while the
    # AST a macro receives from source has a nil context. Parse from source so
    # that these tests see exactly what `defrule` sees.
    defp element(source), do: Parser.parse_element(__ENV__, Code.string_to_quoted!(source))

    test "rejects binding an element inside a collection" do
      assert_raise ArgumentError, ~r/collection element cannot be bound/, fn ->
        element("[f = {:order, id}]")
      end
    end

    test "rejects binding a gate" do
      assert_raise ArgumentError, ~r/cannot be bound to a variable/, fn ->
        element("g = {:or, [{:a, x}, {:b, x}]}")
      end
    end

    test "an outer guard on a collection is combined with the inner one" do
      coll = element("[{:order, id} when id > 0] when id < 10")
      assert %IR.Coll{type: :order, bind: [:id]} = coll
      assert {:and, _, [_inner, _outer]} = coll.__ast__.guard
    end

    test "keeps the raw pattern and guard AST for the later phases" do
      fact = element("f = {:order, id, amt} when amt > limit")

      assert %IR.Fact{type: :order, fact_binding: :f, bind: [:amt, :id]} = fact
      assert {:{}, _, [:order, {:id, _, _}, {:amt, _, _}]} = fact.__ast__.pattern
      assert {:>, _, [{:amt, _, _}, {:limit, _, _}]} = fact.__ast__.guard
      assert [:amt, :id] == fact.__ast__.bind |> Map.keys() |> Enum.sort()
      assert %{args: args, body: _} = fact.alpha.__ast__
      assert {:{}, _, [{:_, _, _}, {:id, _, _}, {:amt, _, _}]} = args
    end
  end
end
