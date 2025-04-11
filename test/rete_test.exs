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
    # remove plant from mammal
    underive(:mammal, :plant)

    id1 = 1

    defrule foo_rule(
              {:foo, id = ^id1},
              bar = {:bar, id},
              {:foo, id},
              [{:bar, id}],
              foo = {:foo, id},
              bars = [{:bar, id}]
            )
            when id > 0 do
      [id, foo, bar, bars]
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

    id1 = 1

    defrule bar_rule(
              %{salience: 100},
              {:foo, id = ^id1},
              bar = {:bar, id},
              {:foo, id},
              [{:bar, id}],
              foo = {:foo, id},
              bars = [{:bar, id}]
            )
            when id > 0 do
      [id, foo, bar, bars]
    end
  end

  doctest Rete

  test "create foo rule with lhs and rhs bindings and output" do
    [rule | _] = ReteTest.ExampleFooRuleset.get_rule_data()

    rhs =
      rule
      |> Map.get(:rhs)

    assert [1, 2, 3, 4] == rhs.(rule.hash, %{id: 1, foo: 2, bar: 3, bars: 4})

    lhs_expr =
      rule
      |> Map.get(:lhs)
      |> Enum.map(fn cond ->
        {expr, expr_data} = Map.get(cond, :expr)
        :erlang.binary_to_term(expr_data)
      end)

    [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [test1 | _]]]]]]] = lhs_expr

    assert %{id: 1} == bind1.({:foo, 1})
    assert nil == bind1.({:foo, 0})
    assert %{id: 1, bar: {:bar, 1}} == bind2.({:bar, 1})
    assert %{id: 1} == bind3.({:foo, 1})
    assert %{id: 1} == bind4.({:bar, 1})
    assert %{id: 1, foo: {:foo, 1}} == bind5.({:foo, 1})
    assert %{id: 1} == bind6.({:bar, 1})
    assert true == test1.(%{id: 1})
    assert false == test1.(%{id: 0})
  end

  test "creates taxonomy from single module" do
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

  test "creates ruleset from single module" do
    assert [:foo_rule] ==
             Rete.get_rule_data([ExampleFooRuleset])
             |> Enum.map(&Map.get(&1, :name))
  end

  test "creates taxonomy from combined modules" do
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

  test "creates ruleset from combined modules" do
    assert [:foo_rule, :bar_rule] ==
             Rete.get_rule_data([ExampleFooRuleset, ExampleBarRuleset])
             |> Enum.map(&Map.get(&1, :name))
  end
end
