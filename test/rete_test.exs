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
              %{salience: 100},
              {:foo, id = ^id1},
              bar = {:bar, id} when id > 0,
              {:foo, id},
              [{:bar, id}],
              foo = {:foo, id},
              bars = [{:bar, id} when id > 0]
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
              {:foo, id = ^id1},
              bar = {:bar, id} when id > 0,
              {:foo, id},
              [{:bar, id} when id > 0],
              foo = {:foo, %{id: id}},
              bars = [{:bar, id: id}]
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
        {_, expr_data} = Map.get(cond, :expr)
        :erlang.binary_to_term(expr_data)
      end)

    [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [test1 | _]]]]]]] = lhs_expr

    assert %{id: 1} == bind1.({:foo, 1})
    assert nil == bind1.({:foo, 0})
    assert %{id: 1} == bind2.({:bar, 1})
    assert nil == bind2.({:bar, 0})
    assert %{id: 1} == bind3.({:foo, 1})
    assert %{id: 1} == bind4.({:bar, 1})
    assert %{id: 1} == bind5.({:foo, 1})
    assert %{id: 1} == bind6.({:bar, 1})
    assert nil == bind6.({:bar, 0})
    assert true == test1.(%{id: 1})
    assert false == test1.(%{id: 0})
  end

  test "create foo rule with lhs and rhs parsed data" do
    [rule | _] = ReteTest.ExampleFooRuleset.get_rule_data()

    rhs =
      rule
      |> Map.get(:rhs)

    expected_rhs = &ReteTest.ExampleFooRuleset.foo_rule/2
    assert expected_rhs == rhs

    assert :foo_rule == Map.get(rule, :name)
    assert [salience: 100] == Map.get(rule, :opts)
    assert [:id, :foo, :bar, :bars] == Map.get(rule, :bind)
    assert is_integer(Map.get(rule, :hash))

    lhs =
      rule
      |> Map.get(:lhs)

    [bind1 | [bind2 | [bind3 | [bind4 | [bind5 | [bind6 | [test1 | _]]]]]]] = lhs
    assert %{type: :foo, fact: :_, bind: [:id]} == Map.take(bind1, [:type, :fact, :bind])
    assert %{type: :bar, fact: :bar, bind: [:id]} == Map.take(bind2, [:type, :fact, :bind])
    assert %{type: :foo, fact: :_, bind: [:id]} == Map.take(bind3, [:type, :fact, :bind])
    assert %{type: :bar, bind: [:id], into: :_} == Map.take(bind4, [:type, :bind, :into])
    assert %{type: :foo, fact: :foo, bind: [:id]} == Map.take(bind5, [:type, :fact, :bind])
    assert %{type: :bar, into: :bars, bind: [:id]} == Map.take(bind6, [:type, :bind, :into])
    assert %{bind: [:id]} == Map.take(test1, [:bind])
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
