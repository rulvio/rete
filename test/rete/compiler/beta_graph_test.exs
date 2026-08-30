defmodule Rete.Compiler.BetaGraphTest do
  use ExUnit.Case, async: true

  alias Rete.Compiler.BetaGraph
  alias Rete.Network.Node

  defp graph(mod), do: BetaGraph.build(mod.get_rule_data())

  defp of_kind(graph, kind), do: BetaGraph.filter(graph, &match?(%^kind{}, &1))

  defp typed(graph, type), do: BetaGraph.filter(graph, &(Map.get(&1, :type) == type))

  defp parents(graph, node), do: graph |> BetaGraph.parents(node.id) |> Enum.sort()

  defp rule_lhs(mod, name), do: Enum.find(mod.get_rule_data(), &(&1.name == name)).lhs

  describe "node sharing" do
    defmodule SharedPrefix do
      use Rete.Ruleset

      defrule a({:customer, cid}, {:order, cid, amt}) do
        {:a, cid, amt}
      end

      defrule b({:customer, cid}, {:refund, cid, amt}) do
        {:b, cid, amt}
      end
    end

    test "two rules over a common prefix evaluate it once" do
      graph = graph(SharedPrefix)

      assert [customer] = typed(graph, :customer)
      assert [BetaGraph.root_id()] == parents(graph, customer)

      # The shared node fans out to both continuations.
      assert 2 == length(BetaGraph.children(graph, customer.id))
    end

    defmodule DifferentPrefix do
      use Rete.Ruleset

      defrule a({:customer, cid}, {:order, cid, amt}) do
        {:a, cid, amt}
      end

      defrule c({:vendor, cid}, {:order, cid, amt}) do
        {:c, cid, amt}
      end
    end

    # The two {:order, cid, amt} conditions are equal, but they sit under
    # different parents. Sharing them would let a token from {:vendor, ...} join
    # elements that only ever belonged to {:customer, ...}, so `a` would fire on
    # `c`'s facts. Clara records this as issue 433.
    test "equal conditions under different parents do NOT share" do
      graph = graph(DifferentPrefix)

      assert [order_a, order_c] = typed(graph, :order)
      refute parents(graph, order_a) == parents(graph, order_c)

      assert [customer] = typed(graph, :customer)
      assert [vendor] = typed(graph, :vendor)
      assert [customer.id] == parents(graph, order_a)
      assert [vendor.id] == parents(graph, order_c)
    end

    defmodule DeepPrefix do
      use Rete.Ruleset

      defrule a({:a, x}, {:b, x}, {:c, x}) do
        {:a, x}
      end

      defrule b({:a, x}, {:b, x}, {:d, x}) do
        {:b, x}
      end

      defrule c({:a, x}, {:b, x}, {:c, x}, {:e, x}) do
        {:c, x}
      end
    end

    test "three rules sharing a two condition prefix produce one chain" do
      graph = graph(DeepPrefix)

      assert [_] = typed(graph, :a)
      assert [_] = typed(graph, :b)
      # `c` is shared by rules a and c, which agree on the whole prefix.
      assert [_] = typed(graph, :c)
      assert [_] = typed(graph, :d)
      assert [_] = typed(graph, :e)
    end

    test "a terminal is never shared, even between identical left hand sides" do
      defmodule Twins do
        use Rete.Ruleset

        defrule one({:tick, x}) do
          {:one, x}
        end

        defrule two({:tick, x}) do
          {:two, x}
        end
      end

      graph = graph(Twins)

      assert [_shared_condition] = typed(graph, :tick)
      assert [_, _] = of_kind(graph, Node.Production)
    end

    # Rebuilding the same already-compiled productions proves nothing: their
    # expression codes were fixed when the module compiled. What has to be
    # stable is what the *hash* produces, so compile the same source twice and
    # compare the sharing keys the graph is actually built from.
    test "the same source produces the same sharing keys when compiled again" do
      source = """
      defmodule Rete.Compiler.BetaGraphTest.Recompiled do
        use Rete.Ruleset

        defrule a({:customer, cid}, {:order, cid, amt}) do
          {:a, cid, amt}
        end

        defrule b({:customer, cid}, {:refund, cid, amt}) do
          {:b, cid, amt}
        end
      end
      """

      keys = fn ->
        [{mod, _} | _] = Code.compile_string(source)

        mod.get_rule_data()
        |> BetaGraph.build()
        |> BetaGraph.filter(fn _ -> true end)
        |> Enum.map(&Node.sharing_key/1)
      end

      # Compiling the same module twice is the point of the test, so the
      # redefinition warning is expected rather than a signal.
      previous = Code.compiler_options(ignore_module_conflict: true)
      on_exit(fn -> Code.compiler_options(previous) end)

      first = keys.()
      second = keys.()

      assert first == second
      # No two nodes in one graph may carry the same key under the same parents.
      assert Enum.uniq(first) == first
    end
  end

  describe "node kinds" do
    defmodule Kinds do
      use Rete.Ruleset

      defrule root({:a, x}) do
        {:root, x}
      end

      defrule hash({:a, x}, {:b, x}) do
        {:hash, x}
      end

      defrule expr({:lim, t}, {:c, amt} when amt > t) do
        {:expr, amt}
      end

      defrule coll({:a, x}, items = [{:d, x}]) do
        {:coll, length(items)}
      end

      defrule neg({:a, x}, {:not, [{:e, x}]}) do
        {:neg, x}
      end

      defrule test_node({:a, x}) when x > 0 do
        {:test, x}
      end
    end

    test "each condition shape becomes the right node" do
      graph = graph(Kinds)

      assert [%Node.HashJoin{}] = typed(graph, :b)
      assert [%Node.ExprJoin{filter: filter}] = typed(graph, :c)
      assert [%Node.Accumulate{}] = typed(graph, :d)
      assert [%Node.Negation{}] = typed(graph, :e)
      assert [%Node.Test{}] = of_kind(graph, Node.Test)

      # The filter really is the 2-arity cross condition guard.
      assert true == filter.(%{t: 1}, %{amt: 5})
      assert false == filter.(%{t: 9}, %{amt: 5})
    end

    test "a first condition is a root join, not a hash join" do
      graph = graph(Kinds)
      assert [%Node.RootJoin{}] = typed(graph, :a)
    end

    # The locked empty-collection rule.
    test "a collection binding records whether it can propagate an empty list" do
      graph = graph(Kinds)

      assert [%Node.Accumulate{propagates_empty?: true, join_bind: [:x], new_bind: []}] =
               typed(graph, :d)
    end

    defmodule Grouped do
      use Rete.Ruleset

      # `k` is matched by a second collection, so it is a real join and not
      # local to either. Two collections is the shape that still groups: the
      # sort defers both, so neither can bind `k` before the other and the
      # first one groups by it. A plain condition matching `k` would sort
      # *before* the collection and make it an ordinary join key instead.
      defrule per_group({:a, x}, items = [{:d, x, k}], others = [{:e, x, k}]) do
        {:grouped, x, length(items), length(others)}
      end
    end

    test "a collection introducing a new variable groups by it and cannot propagate empty" do
      graph = graph(Grouped)
      assert [%Node.Accumulate{propagates_empty?: false, new_bind: [:k]}] = typed(graph, :d)
    end

    test "the second collection joins on the variable the first grouped by" do
      graph = graph(Grouped)
      assert [%Node.Accumulate{join_bind: [:k, :x], new_bind: []}] = typed(graph, :e)
    end
  end

  describe "keyless joins away from the root" do
    defmodule Cartesian do
      use Rete.Ruleset

      defrule product({:customer, cid}, {:tick}) do
        {:product, cid}
      end
    end

    # A RootJoin has no token to join against and turns each element straight
    # into a token, so a *later* condition built as one drops everything the
    # prefix bound: `product` would fire on a bare {:tick} with no cid at all.
    test "a keyless condition that is not first is a cross product, not a root join" do
      graph = graph(Cartesian)

      assert [%Node.RootJoin{} = customer] = typed(graph, :customer)
      assert [tick] = typed(graph, :tick)

      assert %Node.HashJoin{join_bind: []} = tick
      assert [customer.id] == parents(graph, tick)
    end

    defmodule FreeBranch do
      use Rete.Ruleset

      defrule audit({:or, [{:user, id}, {:override, :all}]}, {:login, id, ts}) do
        {:audit, id, ts}
      end
    end

    # The override branch binds no id, so the login joins nothing on that path.
    # As a RootJoin it would manufacture a token from any login whatsoever and
    # the branch would degenerate into "audit every login, override or not".
    test "a condition only some branches give a join key to is still a join" do
      graph = graph(FreeBranch)

      assert [under_user, under_override] = typed(graph, :login)
      assert %Node.HashJoin{join_bind: [:id], new_bind: [:ts]} = under_user
      assert %Node.HashJoin{join_bind: [], new_bind: [:id, :ts]} = under_override

      assert [override] = typed(graph, :override)
      assert [override.id] == parents(graph, under_override)
    end

    defmodule FreshAfterNegation do
      use Rete.Ruleset

      defrule fresh({:a, x}, {:not, [{:b, x}]}, {:c, y}) when y > x do
        {:fresh, x, y}
      end
    end

    test "a fresh variable after a negation is a join, not a second entry point" do
      graph = graph(FreshAfterNegation)

      assert [negation] = typed(graph, :b)
      assert [c] = typed(graph, :c)

      assert %Node.HashJoin{join_bind: [], new_bind: [:y]} = c
      assert [negation.id] == parents(graph, c)
      assert [BetaGraph.root_id()] == parents(graph, hd(typed(graph, :a)))
    end
  end

  describe "unsatisfiable left hand sides" do
    defmodule Contradiction do
      use Rete.Ruleset

      # Normalization reduces the contradiction to {:or, []}, which is false.
      defrule impossible({:and, [{:flag, x}, {:not, [{:flag, x}]}]}, {:customer, cid}) do
        {:fired, cid}
      end

      defrule literal({:or, []}, {:q, y}) do
        {:fired, y}
      end
    end

    # Anything built after a false element is unreachable from the root, but a
    # keyless condition there is a RootJoin the alpha index still feeds, so the
    # rule that can never be satisfied would fire on every fact.
    test "a false element builds no node at all, not even the conditions after it" do
      graph = graph(Contradiction)

      assert [] == BetaGraph.filter(graph, fn _node -> true end)
      assert [] == BetaGraph.roots(graph)
    end

    test "an unsatisfiable production gets no terminal" do
      graph = graph(Contradiction)

      assert [] == of_kind(graph, Node.Production)
    end

    defmodule Branchy do
      use Rete.Ruleset

      defrule src({:gold, x}, {:order, x}) do
        {:src, x}
      end
    end

    test "a false branch is dropped and the live branches still re-converge" do
      [gold, order] = rule_lhs(Branchy, :src)

      production = %Rete.IR.Production{
        name: :partly,
        type: :rule,
        hash: 2,
        opts: [],
        bind: [:x],
        lhs: [{:or, [[{:or, []}], [gold]]}, order],
        module: __MODULE__
      }

      graph = BetaGraph.build([production])

      assert [gold_node] = typed(graph, :gold)
      assert [order_node] = typed(graph, :order)
      assert [gold_node.id] == BetaGraph.roots(graph)
      assert [gold_node.id] == parents(graph, order_node)
      assert [_] = of_kind(graph, Node.Production)
    end
  end

  describe "negated collections" do
    defmodule NegatedCollections do
      use Rete.Ruleset

      defrule empty({:customer, cid}, {:not, [[{:order, cid, _amt}]]}) do
        {:empty, cid}
      end

      defrule none_over({:threshold, t}, {:not, [[{:big, amt} when amt > t]]}) do
        {:none_over, t}
      end
    end

    # Rete.IR.Negation's own type is Fact | Coll, and w1-ir says the same, so
    # this shape is legal all the way down. Collections are collect-all, so an
    # element is in the collection exactly when it matches the token: "the
    # collection is empty" is literally "no element matches", with nothing to
    # accumulate.
    test "a negated collection is a negation over the element pattern" do
      graph = graph(NegatedCollections)

      assert [%Node.Negation{join_bind: [:cid]}] = typed(graph, :order)
      assert [] == of_kind(graph, Node.Accumulate)
    end

    test "a guarded negated collection keeps the cross condition filter" do
      graph = graph(NegatedCollections)

      assert [%Node.NegationJoin{join_bind: [], filter: filter}] = typed(graph, :big)
      assert [] == of_kind(graph, Node.AccumulateJoin)

      assert true == filter.(%{t: 1}, %{amt: 5})
      assert false == filter.(%{t: 9}, %{amt: 5})
    end
  end

  describe "reserved options" do
    test "a user written :internal_salience is rejected rather than honoured" do
      defmodule Sneaky do
        use Rete.Ruleset

        defrule sneaky(%{internal_salience: 99}, {:customer, cid}) do
          {:sneaky, cid}
        end
      end

      assert_raise ArgumentError, ~r/sneaky.*:internal_salience, which is reserved/s, fn ->
        BetaGraph.build(Sneaky.get_rule_data())
      end
    end

    test "an extracted helper may still set it, and outranks the rule it serves" do
      defmodule Extracted do
        use Rete.Ruleset

        defrule clean({:customer, cid}, {:nand, [{:order, cid}, {:refund, cid}]}) do
          {:clean, cid}
        end
      end

      rule = Enum.find(Extracted.get_rule_data(), &(&1.name == :clean))
      {rewritten, [helper]} = Rete.Compiler.Negation.extract(rule)
      graph = BetaGraph.build([helper, rewritten])

      assert [%{name: helper_name, internal_salience: 1, generated?: true}, rule_node] =
               of_kind(graph, Node.Production)

      assert helper_name == helper.name
      assert %{internal_salience: 0, generated?: false} = rule_node
    end
  end

  describe "disjunctions" do
    defmodule Branching do
      use Rete.Ruleset

      defrule branchy({:or, [{:gold, cid}, {:silver, cid}]}, {:order, cid, amt}) do
        {:branchy, cid, amt}
      end
    end

    test "branches fan out and re-converge on the next condition" do
      graph = graph(Branching)

      assert [gold] = typed(graph, :gold)
      assert [silver] = typed(graph, :silver)
      assert [order] = typed(graph, :order)

      # One node after the disjunction, with one parent per branch.
      assert [gold.id, silver.id] == parents(graph, order)
    end

    defmodule BranchLast do
      use Rete.Ruleset

      defrule tail({:customer, cid}, {:or, [{:gold, cid}, {:silver, cid}]}) do
        {:tail, cid}
      end
    end

    test "a disjunction in last position gives the terminal one parent per branch" do
      graph = graph(BranchLast)

      assert [gold] = typed(graph, :gold)
      assert [silver] = typed(graph, :silver)
      assert [production] = of_kind(graph, Node.Production)

      assert [gold.id, silver.id] == parents(graph, production)
    end
  end

  describe "rejected input" do
    test "a compound negation must be extracted first" do
      compound = %Rete.IR.CompoundNegation{conditions: []}

      production = %Rete.IR.Production{
        name: :r,
        type: :rule,
        hash: 1,
        opts: [],
        bind: [],
        lhs: [compound],
        module: __MODULE__
      }

      assert_raise ArgumentError, ~r/compound negation cannot be built/, fn ->
        BetaGraph.build([production])
      end
    end

    test "a gate means normalization was skipped" do
      production = %Rete.IR.Production{
        name: :r,
        type: :rule,
        hash: 1,
        opts: [],
        bind: [],
        lhs: [%Rete.IR.Gate{gate: :or, args: [], code: []}],
        module: __MODULE__
      }

      assert_raise ArgumentError, ~r/gate reached the network builder/, fn ->
        BetaGraph.build([production])
      end
    end
  end
end
