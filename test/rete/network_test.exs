defmodule Rete.NetworkTest do
  use ExUnit.Case, async: true

  alias Rete.Compiler
  alias Rete.Compiler.BetaGraph
  alias Rete.IR
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Taxonomy

  doctest Rete.Network

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

  # --- cross module node sharing ------------------------------------------------
  #
  # Each pair below writes the *same* condition in two modules. They differ only in
  # whether that condition's behavior can be read off its AST alone. A plain pattern
  # and a qualified call can. An imported or local call cannot, because the bare name
  # is all the hash sees.

  defmodule QualifiedHelper do
    @moduledoc false
    def ok?(amt), do: amt > 10
  end

  # Nothing that ties either to its module: a plain pattern and a literal guard.
  defmodule PlainA do
    use Rete.Ruleset

    defrule plain_a({:customer, cid}, {:order, cid, amt} when amt > 100) do
      {:flagged_a, cid, amt}
    end
  end

  defmodule PlainB do
    use Rete.Ruleset

    defrule plain_b({:customer, cid}, {:order, cid, amt} when amt > 100) do
      {:flagged_b, cid, amt}
    end
  end

  # The same two rules in one module. This is the baseline the split is measured
  # against: within a module, sharing has always worked.
  defmodule PlainBoth do
    use Rete.Ruleset

    defrule plain_a({:customer, cid}, {:order, cid, amt} when amt > 100) do
      {:flagged_a, cid, amt}
    end

    defrule plain_b({:customer, cid}, {:order, cid, amt} when amt > 100) do
      {:flagged_b, cid, amt}
    end
  end

  # A qualified call. The alias resolves before hashing, so both modules name the
  # same function and the code is safe to share.
  defmodule QualA do
    use Rete.Ruleset
    alias Rete.NetworkTest.QualifiedHelper

    defrule qual_a({:bar, amt} when QualifiedHelper.ok?(amt)) do
      {:qual_a, amt}
    end
  end

  defmodule QualB do
    use Rete.Ruleset
    alias Rete.NetworkTest.QualifiedHelper

    defrule qual_b({:bar, amt} when QualifiedHelper.ok?(amt)) do
      {:qual_b, amt}
    end
  end

  # A *local* call. Same spelling, different function, and the hash cannot tell.
  # This is the `Lenient`/`Strict` hazard reached by definition instead of import.
  defmodule LocalA do
    use Rete.Ruleset

    def ok?(amt), do: amt > 10

    defrule local_a({:baz, amt} when ok?(amt)) do
      {:local_a, amt}
    end
  end

  defmodule LocalB do
    use Rete.Ruleset

    def ok?(amt), do: amt > 1000

    defrule local_b({:baz, amt} when ok?(amt)) do
      {:local_b, amt}
    end
  end

  # The same attribute name holding different values. Already safe before this
  # pass runs: `@x` hashes as `{:@, _, [{:x, _, DefiningModule}]}`.
  defmodule AttrA do
    use Rete.Ruleset

    @limit 10

    defrule attr_a({:qux, amt} when amt > @limit) do
      {:attr_a, amt}
    end
  end

  defmodule AttrB do
    use Rete.Ruleset

    @limit 1000

    defrule attr_b({:qux, amt} when amt > @limit) do
      {:attr_b, amt}
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
      # negation are byte identical once discarded names are canonicalized, so
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

      # the fact still reaches both alphas. Only the sharing was wrong
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

    test "disambiguate_codes/1 qualifies an unshared code two modules contribute" do
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

    test "disambiguate_codes/1 leaves a shared code two modules contribute" do
      productions = [
        production(Lenient, :one, share: true),
        production(Strict, :two, share: true)
      ]

      assert [[:shared_alpha, :shared_test], [:shared_alpha, :shared_test]] ==
               productions |> Compiler.disambiguate_codes() |> Enum.map(&codes/1)
    end

    # One refusal splits the code for both. Qualifying only the refusing side would leave
    # the other on a node holding the wrong module's function.
    test "disambiguate_codes/1 splits both sides when only one refuses" do
      productions = [
        production(Lenient, :one, share: true),
        production(Strict, :two, share: false)
      ]

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

    defp production(module, name, opts \\ []) do
      share = Keyword.get(opts, :share, false)

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
            alpha: expr(:shared_alpha, :alpha, share)
          },
          %IR.Test{bind: [:amt], expr: expr(:shared_test, :test, share)}
        ]
      }
    end

    defp expr(code, kind, share) do
      %IR.Expr{
        code: code,
        name: :"__#{code}__",
        arity: 1,
        kind: kind,
        fun: fn _ -> nil end,
        share: share
      }
    end
  end

  describe "cross module node sharing" do
    # `Rete.Engine.alpha_ops/2` calls `alpha.fun.(fact)` exactly once per alpha the
    # taxonomy routes a fact to. So this count *is* the number of times a condition is
    # evaluated per fact. Nothing needs instrumenting to measure it.
    defp evaluations(net, fact), do: length(Network.alphas_for(net, fact))

    # Terminals never share across modules — a production's sharing key is
    # `{:production, module, name, hash}` — so counting them would hide the join
    # chain, which is the part that duplicates.
    defp joins(net), do: net |> Network.beta_nodes() |> Enum.reject(&Node.terminal?/1) |> length()

    test "two rules in one module evaluate a shared condition once" do
      net = Compiler.build([PlainBoth])

      assert 1 == evaluations(net, {:customer, 1})
      assert 1 == evaluations(net, {:order, 1, 250})
      assert 2 == joins(net)
    end

    test "the same two rules in separate modules evaluate it once too" do
      net = Compiler.build([PlainA, PlainB])

      assert 1 == evaluations(net, {:customer, 1})
      assert 1 == evaluations(net, {:order, 1, 250})
      assert 2 == joins(net)
    end

    test "splitting a ruleset across modules does not change the network" do
      together = Compiler.build([PlainBoth])
      apart = Compiler.build([PlainA, PlainB])

      assert map_size(together.alphas) == map_size(apart.alphas)
      assert joins(together) == joins(apart)
    end

    test "a qualified call is shared across modules" do
      net = Compiler.build([QualA, QualB])

      assert 1 == evaluations(net, {:bar, 50})
      assert 1 == joins(net)
    end

    test "an imported call is not shared across modules" do
      net = Compiler.build([Lenient, Strict])

      assert 2 == evaluations(net, {:bar, 50})
      assert 2 == joins(net)
    end

    test "a local call is not shared across modules" do
      net = Compiler.build([LocalA, LocalB])

      assert 2 == evaluations(net, {:baz, 50})
      assert 2 == joins(net)
    end

    test "an attribute of the same name holding different values is not shared" do
      net = Compiler.build([AttrA, AttrB])

      assert 2 == evaluations(net, {:qux, 50})
    end

    # Sharing changes how much work a fact causes, never what a session concludes.
    test "sharing does not change what fires" do
      fire = fn modules ->
        modules
        |> Compiler.build()
        |> Rete.Session.from_network()
        |> Rete.Session.insert([{:customer, 1}, {:order, 1, 250}])
        |> Rete.Session.fire_rules()
        |> Rete.Session.facts()
        |> Enum.sort()
      end

      assert fire.([PlainBoth]) == fire.([PlainA, PlainB])

      assert [{:customer, 1}, {:flagged_a, 1, 250}, {:flagged_b, 1, 250}, {:order, 1, 250}] ==
               fire.([PlainA, PlainB])
    end

    # The guards that make the split worth keeping. Each module must still run its own
    # compiled function, not whichever one the reduce happened to reach first.
    test "each module keeps its own predicate when a code is not shared" do
      net = Compiler.build([LocalA, LocalB])

      predicates =
        for root <- Network.beta_nodes(net),
            match?(%Node.RootJoin{}, root),
            [child] = Network.children(net, root.id),
            into: %{},
            do: {Network.node(net, child).name, net.alphas[root.alpha_code].fun}

      assert %{amt: 50} == predicates[:local_a].({:baz, 50})
      assert nil == predicates[:local_b].({:baz, 50})
      assert %{amt: 5000} == predicates[:local_b].({:baz, 5000})
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
    # to change behavior.
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
      assert error.message =~ "bad(session, cid: value)"
    end
  end

  # A repeated name is caught where it is written, not when a session is built
  # from the module. Two queries of one name would otherwise collide as two
  # definitions of one function, and a rule and a query of one name would reach
  # the compiler, which knows the module but not the line.
  describe "a repeated production name" do
    defp compile_dup(body) do
      source = """
      defmodule Rete.NetworkTest.Dup#{System.unique_integer([:positive])} do
        use Rete.Ruleset
      #{body}
      end
      """

      assert_raise ArgumentError, fn -> Code.compile_string(source, "lib/rules.ex") end
    end

    test "two rules of one name are rejected at the second declaration" do
      error =
        compile_dup("""
          defrule flag({:order, cid}), do: {:flagged, cid}
          defrule flag({:ticket, cid}), do: {:flagged, cid}
        """)

      assert error.message =~ "lib/rules.ex:4: defrule flag repeats a name"
      assert error.message =~ "defrule flag, lib/rules.ex:3"
    end

    test "two queries of one name are rejected before the function collides" do
      error =
        compile_dup("""
          defquery thing({:a, x}), do: x
          defquery thing({:b, x}), do: x
        """)

      assert error.message =~ "defquery thing repeats a name"
      refute error.message =~ "defined", "Elixir's duplicate-def error should not get there first"
    end

    # Rules and queries share one namespace: a name identifies a rule to
    # attribute an activation to and a query to run, and neither tells two apart.
    test "a rule and a query may not share a name" do
      error =
        compile_dup("""
          defrule thing({:a, x}), do: {:b, x}
          defquery thing({:b, x}), do: x
        """)

      assert error.message =~ "defquery thing repeats a name"
      assert error.message =~ "defrule thing"
    end

    # The mistake behind it is usually reaching for function-clause semantics.
    test "the error says why rules are not clauses, and what to write instead" do
      error =
        compile_dup("""
          defrule flag({:order, cid}), do: {:flagged, cid}
          defrule flag({:ticket, cid}), do: {:flagged, cid}
        """)

      assert error.message =~ "not a function clause"
      assert error.message =~ "{:or, [...]}"
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
