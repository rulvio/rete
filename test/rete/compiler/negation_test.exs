defmodule Rete.Compiler.NegationTest do
  use ExUnit.Case, async: true

  alias Rete.Compiler.Negation
  alias Rete.IR

  defp rule(mod, name), do: Enum.find(mod.get_rule_data(), &(&1.name == name))

  defp negation_of(production) do
    Enum.find_value(production.lhs, fn
      %IR.Negation{condition: condition} -> condition
      _ -> nil
    end)
  end

  defmodule Rules do
    use Rete.Ruleset

    # "no cid has BOTH an order and a refund"
    defrule clean({:customer, cid}, {:nand, [{:order, cid}, {:refund, cid}]}) do
      {:clean, cid}
    end

    # A compound negation with no ancestor binding at all.
    defrule global({:nand, [{:alarm, a}, {:silenced, a}]}) do
      {:global}
    end

    defrule plain({:customer, cid}, {:not, [{:order, cid}]}) do
      {:plain, cid}
    end
  end

  describe "extraction" do
    test "a plain negation is left alone and generates no helper" do
      {rewritten, helpers} = Negation.extract(rule(Rules, :plain))

      assert [] == helpers
      assert rewritten.lhs == rule(Rules, :plain).lhs
    end

    test "a compound negation becomes a helper plus a plain negation of its marker" do
      {rewritten, [helper]} = Negation.extract(rule(Rules, :clean))

      marker = negation_of(rewritten)
      assert %IR.Fact{} = marker
      assert marker.type == helper.name

      # The helper repeats the prefix, so the marker is only produced for
      # binding groups that actually reached the negation.
      assert [:customer, :order, :refund] == Enum.map(helper.lhs, & &1.type)
    end

    # Without this the negation asks "does any match exist at all" instead of
    # "does one exist for this cid", so one customer with both an order and a
    # refund would suppress the rule for every customer. Clara's issue 304.
    test "the marker is scoped to the bindings the conjunction joins on" do
      {rewritten, [helper]} = Negation.extract(rule(Rules, :clean))
      marker = negation_of(rewritten)

      assert [:cid] == marker.join_bind
      assert [:cid] == marker.bind

      assert {helper.name, %{cid: 7}} == helper.rhs.(helper.hash, %{cid: 7})
      assert %{cid: 7} == marker.alpha.fun.({helper.name, %{cid: 7}})
      assert %{cid: 9} == marker.alpha.fun.({helper.name, %{cid: 9}})
    end

    test "the marker alpha ignores anything that is not its own marker" do
      {rewritten, _} = Negation.extract(rule(Rules, :clean))
      marker = negation_of(rewritten)

      assert nil == marker.alpha.fun.({:order, 1})
      assert nil == marker.alpha.fun.({:some_other_marker, %{cid: 1}})
    end

    defmodule Guarded do
      use Rete.Ruleset

      # The conjunction reaches `limit` through a cross-condition guard rather
      # than a shared pattern variable, so `ir.md` puts it in the join filter and
      # explicitly *not* in :join_bind.
      defrule under(
                {:limit, limit},
                {:nand, [{:order, x, amt} when amt > limit, {:refund, x}]}
              ) do
        {:under, limit}
      end

      # `region` is an ancestor binding the conjunction never reads.
      defrule wide(
                {:limit, limit},
                {:region, region},
                {:nand, [{:order, x, amt} when amt > limit, {:refund, x}]}
              ) do
        {:wide, limit, region}
      end
    end

    # Issue 304 reached through a guard. A marker carrying nothing is global:
    # the one produced for limit = 10 would suppress limit = 1000 as well, and
    # `under` would never fire for the higher limit.
    test "the marker carries an ancestor binding a join filter reads from the token" do
      {rewritten, [helper]} = Negation.extract(rule(Guarded, :under))
      marker = negation_of(rewritten)

      assert [:limit] == marker.join_bind
      assert [:limit] == marker.bind

      assert {helper.name, %{limit: 10}} ==
               helper.rhs.(helper.hash, %{limit: 10, x: 1, amt: 50})
    end

    test "an ancestor binding the conjunction never reads is still not carried" do
      {rewritten, [helper]} = Negation.extract(rule(Guarded, :wide))
      marker = negation_of(rewritten)

      assert [:limit] == marker.join_bind

      assert {helper.name, %{limit: 10}} ==
               helper.rhs.(helper.hash, %{limit: 10, region: :eu, x: 1, amt: 50})
    end

    test "a conjunction with no ancestor binding carries nothing" do
      {rewritten, [helper]} = Negation.extract(rule(Rules, :global))
      marker = negation_of(rewritten)

      assert [] == marker.join_bind
      assert {helper.name, %{}} == helper.rhs.(helper.hash, %{a: 1})
    end

    # A rule that negated the marker before the helper produced it would fire
    # against an absence that had merely not been computed yet.
    test "the helper outranks the rule that negates it" do
      {_rewritten, [helper]} = Negation.extract(rule(Rules, :clean))

      assert 1 == Keyword.fetch!(helper.opts, :internal_salience)
      assert Negation.generated?(helper)
      refute Negation.generated?(rule(Rules, :clean))
    end

    # A nested extraction chains: the outer helper negates a marker the inner
    # one produces. Giving them the same rank reintroduces the bug extraction
    # exists to avoid, one level in - the outer helper would observe an absence
    # of the inner marker that had merely not been computed yet.
    test "an inner helper outranks the helper that negates its marker" do
      defmodule Nested do
        use Rete.Ruleset

        defrule outer({:a, x}, {:nand, [{:b, x}, {:nand, [{:c, x}, {:d, x}]}]}) do
          {:outer, x}
        end
      end

      {_rewritten, [inner, outer]} = Negation.extract(rule(Nested, :outer))

      assert Keyword.fetch!(inner.opts, :internal_salience) >
               Keyword.fetch!(outer.opts, :internal_salience)

      # And both still outrank anything a user can write, which is 0.
      assert Keyword.fetch!(outer.opts, :internal_salience) > 0

      # The outer helper negates the inner one's marker.
      assert Enum.any?(outer.lhs, fn
               %IR.Negation{condition: %IR.Fact{type: type}} -> type == inner.name
               _ -> false
             end)
    end

    test "generated names are deterministic and carry their module" do
      {_, [first]} = Negation.extract(rule(Rules, :clean))
      {_, [again]} = Negation.extract(rule(Rules, :clean))

      assert first.name == again.name
      assert to_string(first.name) =~ "NegationTest.Rules"
      assert to_string(first.name) =~ "clean"
    end

    test "two compound negations in one rule get distinct markers" do
      defmodule Two do
        use Rete.Ruleset

        defrule both(
                  {:customer, cid},
                  {:nand, [{:order, cid}, {:refund, cid}]},
                  {:nand, [{:claim, cid}, {:denial, cid}]}
                ) do
          {:both, cid}
        end
      end

      {rewritten, helpers} = Negation.extract(rule(Two, :both))

      assert [one, two] = helpers
      refute one.name == two.name

      markers =
        for %IR.Negation{condition: condition} <- rewritten.lhs, do: condition.type

      assert [one.name, two.name] == markers
    end

    test "rules with the same name in different modules do not collide" do
      defmodule ModA do
        use Rete.Ruleset

        defrule same({:a, x}, {:nand, [{:b, x}, {:c, x}]}) do
          {:a, x}
        end
      end

      defmodule ModB do
        use Rete.Ruleset

        defrule same({:a, x}, {:nand, [{:b, x}, {:c, x}]}) do
          {:b, x}
        end
      end

      {_, [a]} = Negation.extract(rule(ModA, :same))
      {_, [b]} = Negation.extract(rule(ModB, :same))

      refute a.name == b.name
    end
  end
end
