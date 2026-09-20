defmodule Rete.ReadmeTest do
  @moduledoc """
  The worked example in `README.md`, run against the engine.

  The README is the first thing a reader tries, and its outputs are written as `#=>`
  comments, which nothing executes. Three of them were wrong: `Enum.sort/1` orders tuples by
  size before content, so the two element `{:threshold, 100}` sorts ahead of every three
  element fact, and the README listed it last. This runs the example so that a wrong output
  fails the build.

  A doctest cannot do this job. The ruleset has to be compiled before the session that uses
  it, and `README.md` is prose rather than a module.
  """

  use ExUnit.Case, async: true

  alias Rete.Inspect
  alias Rete.Session

  defmodule Retail do
    use Rete.Ruleset

    derive :online_order, :order

    defrule large_order({:threshold, limit}, {:order, cid, amt} when amt > limit) do
      {:large_order, cid, amt}
    end

    defrule spend({:customer, cid, name}, orders = [{:order, cid, _amt}]) do
      {:spend, name, Enum.sum(for {_, _, amt} <- orders, do: amt)}
    end

    defrule dormant({:customer, cid, name}, {:not, [{:order, cid, _}]}) do
      {:dormant, name}
    end

    defquery large_orders(cid)({:large_order, cid, amt}) do
      {cid, amt}
    end
  end

  @inserted [
    {:threshold, 100},
    {:customer, 1, "Ada"},
    {:customer, 2, "Bo"},
    {:order, 1, 250},
    {:order, 1, 40},
    {:online_order, 2, 30}
  ]

  defp inserted, do: Session.new([Retail]) |> Session.insert(@inserted)
  defp fired, do: Session.fire_rules(inserted())

  describe "the README worked example" do
    test "a query answers nothing before the first fire" do
      assert [] == Retail.large_orders(inserted(), 1)
    end

    test "firing concludes the large order, both spends, and no dormancy" do
      assert [
               {:threshold, 100},
               {:customer, 1, "Ada"},
               {:customer, 2, "Bo"},
               {:large_order, 1, 250},
               {:online_order, 2, 30},
               {:order, 1, 40},
               {:order, 1, 250},
               {:spend, "Ada", 290},
               {:spend, "Bo", 30}
             ] == fired() |> Session.facts() |> Enum.sort()
    end

    test "the query reads back by its head, and by the pair at runtime" do
      session = fired()

      assert [{1, 250}] == Retail.large_orders(session, 1)
      assert [{1, 250}] == Session.query(session, {Retail, :large_orders}, cid: 1)
    end

    test "retracting the large order withdraws it and re-sums the collection" do
      session = fired() |> Session.retract({:order, 1, 250}) |> Session.fire_rules()

      assert [
               {:threshold, 100},
               {:customer, 1, "Ada"},
               {:customer, 2, "Bo"},
               {:online_order, 2, 30},
               {:order, 1, 40},
               {:spend, "Ada", 40},
               {:spend, "Bo", 30}
             ] == session |> Session.facts() |> Enum.sort()
    end

    test "retracting the rest makes both customers dormant, and spend fires empty" do
      assert [
               {:dormant, "Ada"},
               {:dormant, "Bo"},
               {:threshold, 100},
               {:customer, 1, "Ada"},
               {:customer, 2, "Bo"},
               {:spend, "Ada", 0},
               {:spend, "Bo", 0}
             ] == emptied() |> Session.facts() |> Enum.sort()
    end

    test "explain names both matches of the dormant rule" do
      assert %{rule: :dormant, module: Retail, type: :rule, activations: [ada, bo]} =
               Inspect.explain(emptied(), {Retail, :dormant})

      assert %{
               bindings: %{cid: 1, name: "Ada"},
               matches: [
                 %{fact: {:customer, 1, "Ada"}, origin: :asserted, from: [], members: nil}
               ],
               inserted: [{:dormant, "Ada"}]
             } = ada

      assert %{bindings: %{cid: 2, name: "Bo"}, inserted: [{:dormant, "Bo"}]} = bo
    end
  end

  defp emptied do
    fired()
    |> Session.retract({:order, 1, 250})
    |> Session.fire_rules()
    |> Session.retract([{:order, 1, 40}, {:online_order, 2, 30}])
    |> Session.fire_rules()
  end
end
