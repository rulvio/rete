defmodule Rete.NetworkTest do
  use ExUnit.Case, async: true

  alias Rete.Compiler
  alias Rete.Compiler.BetaGraph
  alias Rete.IR
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Taxonomy

  defmodule LenientHelper do
    @moduledoc false
    def ok?(amt), do: amt > 10
  end

  defmodule StrictHelper do
    @moduledoc false
    def ok?(amt), do: amt > 1000
  end

  defmodule Lenient do
    use Rete.Ruleset
    import Rete.NetworkTest.LenientHelper

    defrule lenient({:bar, amt} when ok?(amt)) do
      {:lenient, amt}
    end
  end

  defmodule Strict do
    use Rete.Ruleset
    import Rete.NetworkTest.StrictHelper

    defrule strict({:bar, amt} when ok?(amt)) do
      {:strict, amt}
    end
  end

  defmodule Demo do
    use Rete.Ruleset

    derive :premium, :customer
    derive :standard, :customer

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

  setup_all do
    {:ok, net: Compiler.build([Demo])}
  end

  defp typed(net, type), do: Enum.filter(Network.beta_nodes(net), &(Map.get(&1, :type) == type))

  defp alpha_types(net, fact) do
    net.taxonomy
    |> Taxonomy.alpha_ids(fact)
    |> Enum.map(&net.alphas[&1].type)
    |> Enum.sort()
  end

  describe "structure" do
    test "every condition becomes a node of the right kind", %{net: net} do
      assert [%Node.Accumulate{coll_binding: :orders}] = typed(net, :order) |> accumulates()
      assert [%Node.ExprJoin{}] = typed(net, :order) |> expr_joins()
      assert [%Node.Negation{}] = typed(net, :order) |> negations()
      assert [%Node.RootJoin{}] = typed(net, :threshold)
      assert [%Node.RootJoin{}] = typed(net, :flagged)
    end

    defp accumulates(nodes), do: Enum.filter(nodes, &match?(%Node.Accumulate{}, &1))
    defp expr_joins(nodes), do: Enum.filter(nodes, &match?(%Node.ExprJoin{}, &1))
    defp negations(nodes), do: Enum.filter(nodes, &match?(%Node.Negation{}, &1))

    test "every child id exists and every node is reachable from the root", %{net: net} do
      ids = net |> Network.beta_nodes() |> MapSet.new(& &1.id)

      for node <- Network.beta_nodes(net), child <- Network.children(net, node.id) do
        assert MapSet.member?(ids, child), "dangling child #{child} of node #{node.id}"
      end

      reachable = reachable(net, BetaGraph.root_id(), MapSet.new())
      assert MapSet.subset?(ids, reachable)
    end

    defp reachable(net, id, seen) do
      net
      |> Network.children(id)
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.reduce(seen, fn child, seen -> reachable(net, child, MapSet.put(seen, child)) end)
    end
  end

  describe "alpha sharing" do
    test "conditions with the same expression share one alpha", %{net: net} do
      # {:order, cid, _amt} in the collection and {:order, cid, _} in the
      # negation are byte identical once discarded names are canonicalised, so
      # they share an alpha that feeds two different beta nodes.
      shared =
        net.alphas
        |> Map.keys()
        |> Enum.filter(&(length(Network.beta_children(net, &1)) > 1))

      assert [code] = shared
      assert :order == net.alphas[code].type
      assert 2 == length(Network.beta_children(net, code))
    end

    test "conditions that bind differently do not share", %{net: net} do
      customers = Enum.filter(net.alphas, fn {_code, a} -> a.type == :customer end)

      # {:customer, cid, name} binds two variables, {:customer, cid, _} binds one.
      assert 2 == length(customers)
    end

    test "an alpha matches a fact of any type", %{net: net} do
      # Type routing is the index's job, so the function itself must not check.
      {_code, alpha} = Enum.find(net.alphas, fn {_c, a} -> a.type == :threshold end)

      assert %{t: 5} == alpha.fun.({:threshold, 5})
      assert %{t: 5} == alpha.fun.({:anything_at_all, 5})
    end
  end

  describe "cross module expression codes" do
    # `ok?(amt)` is resolved by an import, and an unqualified call is invisible
    # to the expression hash, so both modules write the *same* code for a
    # condition that compiles to a different function. Keying the alpha map on
    # the code alone kept whichever module was reduced first, and because a
    # node's sharing key is built from the alpha code the two rules collapsed
    # onto one RootJoin as well: `strict` fired on {:bar, 50}, which
    # StrictHelper.ok?/1 rejects, and Strict's own compiled function was never
    # called.
    test "two modules that disagree about an unqualified guard call do not share a node" do
      net = Compiler.build([Lenient, Strict])

      roots = Enum.filter(Network.beta_nodes(net), &match?(%Node.RootJoin{}, &1))
      assert 2 == length(roots)

      predicates =
        Map.new(roots, fn root ->
          [child] = Network.children(net, root.id)
          {Network.node(net, child).name, net.alphas[root.alpha_code].fun}
        end)

      assert %{amt: 50} == predicates[:lenient].({:bar, 50})
      assert nil == predicates[:strict].({:bar, 50})
      assert %{amt: 5000} == predicates[:strict].({:bar, 5000})

      # the fact still reaches both alphas; only the sharing was wrong
      assert 2 == length(Network.alphas_for(net, {:bar, 50}))
    end

    test "a code only one module contributes is left alone", %{net: net} do
      refute Enum.any?(Map.keys(net.alphas), &(Atom.to_string(&1) =~ "@"))
    end

    # Hand built, so that the pass is pinned even if W1 later learns to resolve
    # unqualified calls and the codes above stop colliding.
    test "disambiguate_codes/1 keeps a code two productions of one module share" do
      productions = [production(Lenient, :one), production(Lenient, :two)]

      assert [[:shared_alpha, :shared_test], [:shared_alpha, :shared_test]] ==
               productions |> Compiler.disambiguate_codes() |> Enum.map(&codes/1)
    end

    test "disambiguate_codes/1 qualifies every code two modules contribute" do
      productions = [production(Lenient, :one), production(Strict, :two)]

      assert [
               [
                 :"shared_alpha@Rete.NetworkTest.Lenient",
                 :"shared_test@Rete.NetworkTest.Lenient"
               ],
               [
                 :"shared_alpha@Rete.NetworkTest.Strict",
                 :"shared_test@Rete.NetworkTest.Strict"
               ]
             ] == productions |> Compiler.disambiguate_codes() |> Enum.map(&codes/1)
    end

    defp codes(production), do: production |> IR.exprs() |> Enum.map(& &1.code)

    defp production(module, name) do
      %IR.Production{
        name: name,
        type: :rule,
        hash: 0,
        module: module,
        bind: [:amt],
        rhs: fn _hash, _bindings -> [] end,
        lhs: [
          %IR.Fact{
            type: :bar,
            bind: [:amt],
            join_bind: [],
            new_bind: [:amt],
            alpha: expr(:shared_alpha, :alpha)
          },
          %IR.Test{bind: [:amt], expr: expr(:shared_test, :test)}
        ]
      }
    end

    defp expr(code, kind) do
      %IR.Expr{code: code, name: :"__#{code}__", arity: 1, kind: kind, fun: fn _ -> nil end}
    end
  end

  describe "taxonomy routing" do
    test "a derived type reaches conditions written against its ancestor", %{net: net} do
      assert [:customer, :customer] == alpha_types(net, {:premium, 1, "Ada"})
      assert [:customer, :customer] == alpha_types(net, {:standard, 2, "Grace"})
      assert [:customer, :customer] == alpha_types(net, {:customer, 3, "Bo"})
    end

    # The direction that is easy to get backwards, and silent when you do.
    test "an ancestor does NOT reach conditions written against a descendant" do
      defmodule Descendant do
        use Rete.Ruleset

        derive :premium, :customer

        defrule only_premium({:premium, cid}) do
          {:vip, cid}
        end
      end

      net = Compiler.build([Descendant])

      assert [:premium] == alpha_types(net, {:premium, 1})
      assert [] == alpha_types(net, {:customer, 1})
    end

    test "a type no condition mentions routes nowhere", %{net: net} do
      assert [] == alpha_types(net, {:widget, 9})
    end
  end

  describe "queries" do
    test "a query is reachable by module and name", %{net: net} do
      assert %Node.Query{name: :flagged_for, bind: [:amt, :cid]} =
               Network.query(net, {Demo, :flagged_for})

      assert nil == Network.query(net, {Demo, :no_such_query})
    end

    # A query node carries what its left hand side binds, and nothing else. There
    # is no parameter list: the caller constrains whichever of those it likes.
    test "a query node carries its bindings and no parameter list", %{net: net} do
      node = Network.query(net, {Demo, :flagged_for})

      assert [:amt, :cid] == node.bind
      refute Map.has_key?(node, :param_keys)
    end

    # `params:` used to declare which bindings a caller could supply. Silently
    # ignoring a leftover one would be the worst outcome for something that used
    # to change behaviour.
    test "the obsolete params option is rejected where it is written" do
      source = """
      defmodule Rete.NetworkTest.OldParams do
        use Rete.Ruleset

        defquery bad(%{params: [:cid]}, {:flagged, cid, amt}) do
          {cid, amt}
        end
      end
      """

      error = assert_raise ArgumentError, fn -> Code.compile_string(source) end

      assert error.message =~ "no longer a thing"
      assert error.message =~ "query(session, :bad, cid: value)"
    end
  end

  describe "ordering" do
    test "productions come back most salient first", %{net: net} do
      assert [:loyalty | _] = Enum.map(Network.production_nodes(net), & &1.name)
    end

    test "a generated negation helper outranks the rule that negates it" do
      defmodule Compound do
        use Rete.Ruleset

        defrule clean({:customer, cid}, {:nand, [{:order, cid}, {:refund, cid}]}) do
          {:clean, cid}
        end
      end

      net = Compiler.build([Compound])
      [first, second] = Network.production_nodes(net)

      assert first.generated?
      assert first.internal_salience > second.internal_salience
      assert :clean == second.name
    end
  end

  describe "validation" do
    defmodule DupA do
      use Rete.Ruleset

      defrule same({:a, x}) do
        {:a, x}
      end

      defquery both({:a, x}) do
        {:a, x}
      end
    end

    defmodule DupB do
      use Rete.Ruleset

      defrule same({:b, x}) do
        {:b, x}
      end

      defquery both({:b, x}) do
        {:b, x}
      end
    end

    # Two rulesets written independently must compose. A name belongs to its
    # module, so the pair is what identifies a production, and each query
    # answers for its own rules.
    test "two modules may use the same production name" do
      session =
        [DupA, DupB]
        |> Rete.Session.new()
        |> Rete.Session.insert([{:a, 1}, {:b, 2}])
        |> Rete.Session.fire_rules()

      assert [{:a, 1}] == DupA.both(session)
      assert [{:b, 2}] == DupB.both(session)

      assert [{:a, 1}] == Rete.Session.query(session, {DupA, :both})
      assert [{:b, 2}] == Rete.Session.query(session, {DupB, :both})
    end

    # Within one module it is still a mistake: the second declaration would take
    # over the query function and the RHS of the first.
    test "one module may not use the same production name twice" do
      productions = Rete.get_rule_data([DupA])

      error =
        assert_raise ArgumentError, fn ->
          Compiler.build_productions(productions ++ productions)
        end

      assert error.message =~ "declared 2 times"
      assert error.message =~ "same"
    end

    test "an empty rule set builds an empty network" do
      defmodule NoRules do
        use Rete.Ruleset
      end

      net = Compiler.build([NoRules])

      assert %{} == net.alphas
      assert [] == Network.beta_nodes(net)
    end
  end
end
