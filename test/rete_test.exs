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

      assert [1, 2, 3, 4, "Foo"] == rhs.(rule.hash, %{id: 1, foo: 2, bar: 3, bars: 4, name: "Foo"})

      lhs_expr =
        rule
        |> Map.get(:lhs)
        |> Enum.map(fn cond ->
          {_, expr_func} = Map.get(cond, :expr)
          expr_func
        end)

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs_expr

      assert %{id: 1} == bind1.({:foo, 1})
      assert nil == bind1.({:foo, 0})
      assert %{id: 1} == bind2.({:bar, 1})
      assert nil == bind2.({:bar, 0})
      assert %{id: 1} == bind3.({:foo, 1})
      assert %{id: 1} == bind4.({:bar, 1})
      assert %{id: 1} == bind5.({:foo, 1})
      assert %{id: 1} == bind6.({:bar, 1})
      assert %{name: "Foo"} == bind7.({:living_thing, "Foo"})
      assert nil == bind6.({:bar, 0})
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
          :foo1_rule -> &ReteTest.ExampleFooRuleset.foo1_rule/2
          :foo2_rule -> &ReteTest.ExampleFooRuleset.foo2_rule/2
        end

      assert expected_rhs == rhs

      assert [salience: 100] == Map.get(rule, :opts)
      assert [:id, :name, :foo, :bar, :bars] == Map.get(rule, :bind)
      assert is_integer(Map.get(rule, :hash))
      assert :rule == Map.get(rule, :type)

      lhs =
        rule
        |> Map.get(:lhs)

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs

      assert %{fact: :_, type: :foo, bind: [:id]} == Map.take(bind1, [:type, :fact, :bind])
      assert %{fact: :bar, type: :bar, bind: [:id]} == Map.take(bind2, [:type, :fact, :bind])
      assert %{fact: :_, type: :foo, bind: [:id]} == Map.take(bind3, [:type, :fact, :bind])
      assert %{coll: :_, type: :bar, bind: [:id]} == Map.take(bind4, [:type, :bind, :coll])
      assert %{fact: :foo, type: :foo, bind: [:id]} == Map.take(bind5, [:type, :fact, :bind])
      assert %{coll: :bars, type: :bar, bind: [:id]} == Map.take(bind6, [:type, :bind, :coll])
      assert %{fact: :_, type: :living_thing, bind: [:name]} == Map.take(bind7, [:type, :fact, :bind])
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

      assert [1, 2, 3, 4, "Foo"] == rhs.(rule.hash, %{id: 1, name: "Foo", foo: 2, bar: 3, bars: 4})

      lhs_expr =
        rule
        |> Map.get(:lhs)
        |> Enum.map(fn cond ->
          {_, expr_func} = Map.get(cond, :expr)
          expr_func
        end)

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs_expr

      assert %{id: 1} == bind1.({:foo, 1})
      assert nil == bind1.({:foo, 0})
      assert %{id: 1} == bind2.({:bar, 1})
      assert nil == bind2.({:bar, 0})
      assert %{id: 1} == bind3.({:foo, 1})
      assert %{id: 1} == bind4.({:bar, 1})
      assert %{id: 1} == bind5.({:foo, 1})
      assert %{id: 1} == bind6.({:bar, 1})
      assert %{name: "Bar"} == bind7.({:mammal, "Bar"})
      assert nil == bind6.({:bar, 0})
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
          :bar1_query -> &ReteTest.ExampleBarRuleset.bar1_query/2
          :bar2_query -> &ReteTest.ExampleBarRuleset.bar2_query/2
        end

      assert expected_rhs == rhs

      assert [] == Map.get(rule, :opts)
      assert [:id, :name, :foo, :bar, :bars] == Map.get(rule, :bind)
      assert is_integer(Map.get(rule, :hash))
      assert :query == Map.get(rule, :type)

      lhs =
        rule
        |> Map.get(:lhs)

      [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [bind7 | [test1]]]]]]]] = lhs

      assert %{fact: :_, type: :foo, bind: [:id]} == Map.take(bind1, [:type, :fact, :bind])
      assert %{fact: :bar, type: :bar, bind: [:id]} == Map.take(bind2, [:type, :fact, :bind])
      assert %{fact: :_, type: :foo, bind: [:id]} == Map.take(bind3, [:type, :fact, :bind])
      assert %{coll: :_, type: :bar, bind: [:id]} == Map.take(bind4, [:type, :bind, :coll])
      assert %{type: :foo, fact: :foo, bind: [:id]} == Map.take(bind5, [:type, :fact, :bind])
      assert %{coll: :bars, type: :bar, bind: [:id]} == Map.take(bind6, [:type, :bind, :coll])
      assert %{fact: :_, type: :mammal, bind: [:name]} == Map.take(bind7, [:type, :fact, :bind])
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
end
