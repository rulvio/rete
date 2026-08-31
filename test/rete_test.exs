defmodule ReteTest do
  require Rete.Ruleset
  use ExUnit.Case

  defmodule ExampleFooRuleset do
    use Rete.Ruleset

    derive(:dog, :mammal)
    derive(:cat, :mammal)
    derive(:mammal, :animal)
    derive(:mammal, :plant)
    derive(:animal, :living_thing)
    derive(:plant, :living_thing)
    underive(:mammal, :plant)

    @id1 1

    defrule foo1_rule(
              %{salience: 100},
              {:foo, id = @id1},
              bar = {:bar, id} when id > 0,
              {:foo, id},
              [{:bar, id}],
              foo = {:foo, id},
              bars = [{:bar, id} when id > 0],
              {:living_thing, name}
            )
            when id > 0 do
      [id, foo, bar, bars, name]
    end

    defrule foo2_rule(
              %{salience: 100},
              {:foo, id = @id1},
              bar = {:bar, id} when id > 0,
              {:foo, id},
              [{:bar, id}],
              foo = {:foo, id},
              bars = [{:bar, id} when id > 0],
              {:living_thing, name}
            )
            when id > 0 do
      [id, foo, bar, bars, name]
    end
  end

  defmodule ExampleBarRuleset do
    use Rete.Ruleset

    underive(:cat, :mammal)
    underive(:dog, :mammal)
    derive(:cat, :feline)
    derive(:dog, :canine)
    derive(:feline, :mammal)
    derive(:canine, :mammal)

    @id1 1

    defquery bar1_query(
               {:foo, id = @id1},
               bar = {:bar, id} when id > 0,
               {:foo, id},
               [{:bar, id}],
               foo = {:foo, id},
               bars = [{:bar, id} when id > 0],
               {:mammal, name}
             )
             when id > 0 do
      [id, foo, bar, bars, name]
    end

    defquery bar2_query(
               {:foo, id = @id1},
               bar = {:bar, id} when id > 0,
               {:foo, id},
               [{:bar, id}],
               foo = {:foo, id},
               bars = [{:bar, id} when id > 0],
               {:mammal, name}
             )
             when id > 0 do
      [id, foo, bar, bars, name]
    end
  end

  defmodule ExampleLogicGateRuleset do
    use Rete.Ruleset

    derive(:bird, :animal)
    derive(:fish, :animal)
    derive(:animal, :living_thing)

    @id1 1

    defrule logic_rule(
              %{salience: 50},
              # simple logic gates
              {:and, [{:bird, id = @id1}, {:fish, id}]},
              {:or, [{:bird, id = @id1}, {:fish, id}]},
              {:not, [{:bird, id = @id1}, {:fish, id}]},
              {:nand, [{:bird, id = @id1}, {:fish, id}]},
              {:nor, [{:bird, id = @id1}, {:fish, id}]},
              {:xor, [{:bird, id = @id1}, {:fish, id}]},
              {:xnor, [{:bird, id = @id1}, {:fish, id}]},
              # nested logic gates
              {:or, [{:bird, id = @id1}, {:not, [{:fish, id}]}]}
            ) do
      [id, :bird_or_fish]
    end
  end

  doctest Rete

  test "verify version" do
    assert ReteTest.ExampleFooRuleset.get_version() ==
             :erlang.phash2([
               ReteTest.ExampleFooRuleset,
               ReteTest.ExampleFooRuleset.get_rule_data(),
               ReteTest.ExampleFooRuleset.get_taxo_data()
             ])

    assert ReteTest.ExampleBarRuleset.get_version() ==
             :erlang.phash2([
               ReteTest.ExampleBarRuleset,
               ReteTest.ExampleBarRuleset.get_rule_data(),
               ReteTest.ExampleBarRuleset.get_taxo_data()
             ])

    assert ReteTest.ExampleFooRuleset.get_version() != ReteTest.ExampleBarRuleset.get_version()
  end

  test "verify foo rule with lhs and rhs bindings and output" do
    rule_data = ReteTest.ExampleFooRuleset.get_rule_data()
    expr_data = ReteTest.ExampleFooRuleset.get_expr_data()
    assert length(rule_data) == 2
    assert length(expr_data) == 6

    for rule <- rule_data do
      rhs =
        rule
        |> Map.get(:rhs)

      assert [1, 2, 3, 4, "Foo"] ==
               rhs.(rule.hash, %{id: 1, foo: 2, bar: 3, bars: 4, name: "Foo"})

      lhs_expr =
        rule
        |> Map.get(:lhs)
        |> Enum.map(&(Rete.IR.exprs(&1) |> hd() |> Map.get(:fun)))

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs_expr

      # the two collections are written fourth and sixth, and they end up last.
      # `Rete.Compiler.Sort` takes a collection only once no plain condition is left to
      # take, and it takes the rule-level test after that.
      assert %{id: 1} == bind1.({:foo, 1})
      assert nil == bind1.({:foo, 0})
      assert %{id: 1} == bind2.({:bar, 1})
      assert nil == bind2.({:bar, 0})
      assert %{id: 1} == bind3.({:foo, 1})
      assert %{id: 1} == bind4.({:foo, 1})
      # bind5 tests that the fact matches any fact type. The expression does not validate
      # taxonomy, since that would not be efficient inside the Rete network. The taxonomy is
      # validated later instead — when the engine decides whether to propagate a fact to a
      # node, not when it evaluates the LHS conditions.
      assert %{name: "Foo"} == bind5.({:living_thing, "Foo"})
      assert %{name: "Fido"} == bind5.({:dog, "Fido"})
      assert %{name: "Whiskers"} == bind5.({:cat, "Whiskers"})
      assert %{name: "Oregano"} == bind5.({:plant, "Oregano"})
      assert %{name: "Thing"} == bind5.({:any, "Thing"})
      # the anonymous collection is unguarded, the bound one keeps its id > 0
      assert %{id: 1} == bind6.({:bar, 1})
      assert %{id: 0} == bind6.({:bar, 0})
      assert %{id: 1} == bind7.({:bar, 1})
      assert nil == bind7.({:bar, 0})
      assert true == test1.(%{id: 1})
      assert false == test1.(%{id: 0})
    end
  end

  test "verify foo rule with lhs and rhs parsed data" do
    rule_data = ReteTest.ExampleFooRuleset.get_rule_data()
    expr_data = ReteTest.ExampleFooRuleset.get_expr_data()
    assert length(rule_data) == 2
    assert length(expr_data) == 6

    for rule <- rule_data do
      rhs =
        rule
        |> Map.get(:rhs)

      expected_rhs =
        case rule.name do
          :foo1_rule -> &ReteTest.ExampleFooRuleset.__rhs_foo1_rule__/2
          :foo2_rule -> &ReteTest.ExampleFooRuleset.__rhs_foo2_rule__/2
        end

      assert expected_rhs == rhs

      assert [salience: 100] == Map.get(rule, :opts)
      assert [:bar, :bars, :foo, :id, :name] == Map.get(rule, :bind)
      assert is_integer(Map.get(rule, :hash))
      assert :rule == Map.get(rule, :type)

      lhs =
        rule
        |> Map.get(:lhs)

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs

      assert %{fact_binding: nil, type: :foo, bind: [:id]} ==
               Map.take(bind1, [:type, :fact_binding, :bind])

      assert %{fact_binding: :bar, type: :bar, bind: [:id]} ==
               Map.take(bind2, [:type, :fact_binding, :bind])

      assert %{fact_binding: nil, type: :foo, bind: [:id]} ==
               Map.take(bind3, [:type, :fact_binding, :bind])

      assert %{fact_binding: :foo, type: :foo, bind: [:id]} ==
               Map.take(bind4, [:type, :fact_binding, :bind])

      assert %{fact_binding: nil, type: :living_thing, bind: [:name]} ==
               Map.take(bind5, [:type, :fact_binding, :bind])

      # both collections are deferred behind every plain condition, keeping the
      # order they were written in
      assert %{coll_binding: nil, type: :bar, bind: [:id]} ==
               Map.take(bind6, [:type, :bind, :coll_binding])

      assert %{coll_binding: :bars, type: :bar, bind: [:id]} ==
               Map.take(bind7, [:type, :bind, :coll_binding])

      assert %{bind: [:id]} == Map.take(test1, [:bind])
    end
  end

  test "verify bar query with lhs and rhs bindings and output" do
    rule_data = ReteTest.ExampleBarRuleset.get_rule_data()
    expr_data = ReteTest.ExampleBarRuleset.get_expr_data()
    assert length(rule_data) == 2
    assert length(expr_data) == 6

    for rule <- rule_data do
      rhs =
        rule
        |> Map.get(:rhs)

      assert [1, 2, 3, 4, "Foo"] ==
               rhs.(rule.hash, %{id: 1, name: "Foo", foo: 2, bar: 3, bars: 4})

      lhs_expr =
        rule
        |> Map.get(:lhs)
        |> Enum.map(&(Rete.IR.exprs(&1) |> hd() |> Map.get(:fun)))

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs_expr

      assert %{id: 1} == bind1.({:foo, 1})
      assert nil == bind1.({:foo, 0})
      assert %{id: 1} == bind2.({:bar, 1})
      assert nil == bind2.({:bar, 0})
      assert %{id: 1} == bind3.({:foo, 1})
      assert %{id: 1} == bind4.({:foo, 1})
      assert %{name: "Bar"} == bind5.({:mammal, "Bar"})
      # the anonymous collection is unguarded, the bound one keeps its id > 0
      assert %{id: 1} == bind6.({:bar, 1})
      assert %{id: 0} == bind6.({:bar, 0})
      assert %{id: 1} == bind7.({:bar, 1})
      assert nil == bind7.({:bar, 0})
      assert true == test1.(%{id: 1})
      assert false == test1.(%{id: 0})
    end
  end

  test "verify bar query with lhs and rhs parsed data" do
    rule_data = ReteTest.ExampleBarRuleset.get_rule_data()
    expr_data = ReteTest.ExampleBarRuleset.get_expr_data()
    assert length(rule_data) == 2
    assert length(expr_data) == 6

    for rule <- rule_data do
      rhs =
        rule
        |> Map.get(:rhs)

      expected_rhs =
        case rule.name do
          :bar1_query -> &ReteTest.ExampleBarRuleset.__rhs_bar1_query__/2
          :bar2_query -> &ReteTest.ExampleBarRuleset.__rhs_bar2_query__/2
        end

      assert expected_rhs == rhs

      assert [] == Map.get(rule, :opts)
      assert [:bar, :bars, :foo, :id, :name] == Map.get(rule, :bind)
      assert is_integer(Map.get(rule, :hash))
      assert :query == Map.get(rule, :type)

      lhs =
        rule
        |> Map.get(:lhs)

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs

      assert %{fact_binding: nil, type: :foo, bind: [:id]} ==
               Map.take(bind1, [:type, :fact_binding, :bind])

      assert %{fact_binding: :bar, type: :bar, bind: [:id]} ==
               Map.take(bind2, [:type, :fact_binding, :bind])

      assert %{fact_binding: nil, type: :foo, bind: [:id]} ==
               Map.take(bind3, [:type, :fact_binding, :bind])

      assert %{type: :foo, fact_binding: :foo, bind: [:id]} ==
               Map.take(bind4, [:type, :fact_binding, :bind])

      assert %{fact_binding: nil, type: :mammal, bind: [:name]} ==
               Map.take(bind5, [:type, :fact_binding, :bind])

      # both collections are deferred behind every plain condition, keeping the
      # order they were written in
      assert %{coll_binding: nil, type: :bar, bind: [:id]} ==
               Map.take(bind6, [:type, :bind, :coll_binding])

      assert %{coll_binding: :bars, type: :bar, bind: [:id]} ==
               Map.take(bind7, [:type, :bind, :coll_binding])

      assert %{bind: [:id]} == Map.take(test1, [:bind])
    end
  end

  test "get taxonomy data from single module" do
    assert [
             {:derive, :dog, :mammal},
             {:derive, :cat, :mammal},
             {:derive, :mammal, :animal},
             {:derive, :mammal, :plant},
             {:derive, :animal, :living_thing},
             {:derive, :plant, :living_thing},
             {:underive, :mammal, :plant}
           ] == Rete.get_taxo_data([ExampleFooRuleset])
  end

  test "get rule data from single module" do
    assert [:foo1_rule, :foo2_rule] ==
             Rete.get_rule_data([ExampleFooRuleset])
             |> Enum.map(&Map.get(&1, :name))
  end

  test "get expr data from single module" do
    assert [
             :fact_foo_bind_id_expr_51194764,
             :test_fact_bar_bind_id_expr_32016514,
             :fact_foo_bind_id_expr_25092275,
             :fact_living_thing_bind_name_expr_122732082,
             :fact_bar_bind_id_expr_44631555,
             :test_bind_id_expr_72899215
           ] ==
             [ExampleFooRuleset]
             |> Rete.get_expr_data()
             |> Enum.map(fn {expr_id, _} -> expr_id end)
  end

  test "get taxonomy data from combined modules" do
    assert [
             {:derive, :dog, :mammal},
             {:derive, :cat, :mammal},
             {:derive, :mammal, :animal},
             {:derive, :mammal, :plant},
             {:derive, :animal, :living_thing},
             {:derive, :plant, :living_thing},
             {:underive, :mammal, :plant},
             {:underive, :cat, :mammal},
             {:underive, :dog, :mammal},
             {:derive, :cat, :feline},
             {:derive, :dog, :canine},
             {:derive, :feline, :mammal},
             {:derive, :canine, :mammal}
           ] == Rete.get_taxo_data([ExampleFooRuleset, ExampleBarRuleset])
  end

  test "get rule data from combined modules" do
    assert [:foo1_rule, :foo2_rule, :bar1_query, :bar2_query] ==
             Rete.get_rule_data([ExampleFooRuleset, ExampleBarRuleset])
             |> Enum.map(&Map.get(&1, :name))
  end

  # The modules are merged in the order they are given. An expression the second
  # module shares with the first is deduplicated onto the first.
  test "get expr data from combined modules" do
    assert [
             :fact_foo_bind_id_expr_51194764,
             :test_fact_bar_bind_id_expr_32016514,
             :fact_foo_bind_id_expr_25092275,
             :fact_living_thing_bind_name_expr_122732082,
             :fact_bar_bind_id_expr_44631555,
             :test_bind_id_expr_72899215,
             :fact_foo_bind_id_expr_59925075,
             :fact_mammal_bind_name_expr_41148079
           ] ==
             [ExampleFooRuleset, ExampleBarRuleset]
             |> Rete.get_expr_data()
             |> Enum.map(fn {expr_id, _} -> expr_id end)
  end
end
