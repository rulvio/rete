defmodule Rete.DSL.NormalizeTest do
  use ExUnit.Case, async: true

  alias Rete.DSL.Normalize
  alias Rete.DSL.Parser
  alias Rete.IR

  @gates [:and, :or, :not, :nand, :nor, :xor, :xnor]

  # true is one branch that constrains nothing, false is no branch at all.
  @truth {:or, [[]]}
  @falsity {:or, []}

  # A leaf condition. Distinct names produce distinct expression codes, which is
  # what the literal identity used by the simplifier is derived from.
  defp leaf(name) do
    %IR.Fact{
      type: name,
      fact_binding: nil,
      bind: [],
      alpha: %IR.Expr{code: :"fact_#{name}", name: :"__fact_#{name}__", arity: 1},
      __ast__: %{pattern: {name, []}, guard: nil, bind: %{}, source: {name, []}}
    }
  end

  defp gate(gate, args), do: %IR.Gate{gate: gate, args: args, code: [gate]}

  defp neg(condition), do: %IR.Negation{condition: condition}

  defp cneg(conditions), do: %IR.CompoundNegation{conditions: conditions}

  describe "plain conditions" do
    test "a fact is returned unchanged" do
      fact = leaf(:a)
      assert Normalize.normalize(fact) == fact
    end

    test "a collection is returned unchanged" do
      coll = %IR.Coll{type: :order, coll_binding: :orders, bind: [:id]}
      assert Normalize.normalize(coll) == coll
    end

    test "a test is returned unchanged" do
      test = %IR.Test{bind: [:x], expr: %IR.Expr{code: :test_bind_x, arity: 1}}
      assert Normalize.normalize(test) == test
    end

    test "a negation of a single condition is returned unchanged" do
      assert Normalize.normalize(neg(leaf(:a))) == neg(leaf(:a))
    end

    test "an already normalized disjunction is returned unchanged" do
      element = {:or, [[leaf(:a), leaf(:b)], [leaf(:c)]]}
      assert Normalize.normalize(element) == element
    end
  end

  describe "and / or" do
    test "and of two conditions is a single branch" do
      assert Normalize.normalize(gate(:and, [leaf(:a), leaf(:b)])) ==
               {:or, [[leaf(:a), leaf(:b)]]}
    end

    test "or of two conditions is two branches, in author order" do
      assert Normalize.normalize(gate(:or, [leaf(:a), leaf(:b)])) ==
               {:or, [[leaf(:a)], [leaf(:b)]]}
    end

    test "a single child and / or wrapper is dropped" do
      assert Normalize.normalize(gate(:and, [leaf(:a)])) == leaf(:a)
      assert Normalize.normalize(gate(:or, [leaf(:a)])) == leaf(:a)
    end

    test "nested ands are flattened" do
      tree = gate(:and, [leaf(:a), gate(:and, [leaf(:b), gate(:and, [leaf(:c)])])])
      assert Normalize.normalize(tree) == {:or, [[leaf(:a), leaf(:b), leaf(:c)]]}
    end

    test "nested ors are flattened" do
      tree = gate(:or, [leaf(:a), gate(:or, [leaf(:b), leaf(:c)])])
      assert Normalize.normalize(tree) == {:or, [[leaf(:a)], [leaf(:b)], [leaf(:c)]]}
    end
  end

  describe "distribution to DNF" do
    test "an or inside an and is distributed" do
      tree = gate(:and, [leaf(:a), gate(:or, [leaf(:b), leaf(:c)])])

      assert Normalize.normalize(tree) ==
               {:or, [[leaf(:a), leaf(:b)], [leaf(:a), leaf(:c)]]}
    end

    test "two ors inside an and give the cartesian product, left major" do
      tree = gate(:and, [gate(:or, [leaf(:a), leaf(:b)]), gate(:or, [leaf(:c), leaf(:d)])])

      assert Normalize.normalize(tree) ==
               {:or,
                [
                  [leaf(:a), leaf(:c)],
                  [leaf(:a), leaf(:d)],
                  [leaf(:b), leaf(:c)],
                  [leaf(:b), leaf(:d)]
                ]}
    end

    test "an and inside an or keeps its conjunction" do
      tree = gate(:or, [leaf(:a), gate(:and, [leaf(:b), leaf(:c)])])
      assert Normalize.normalize(tree) == {:or, [[leaf(:a)], [leaf(:b), leaf(:c)]]}
    end
  end

  describe "not" do
    test "not of a single condition becomes a negation node" do
      assert Normalize.normalize(gate(:not, [leaf(:a)])) == neg(leaf(:a))
    end

    test "double negation collapses" do
      assert Normalize.normalize(gate(:not, [gate(:not, [leaf(:a)])])) == leaf(:a)
    end

    test "triple negation collapses to a single negation" do
      tree = gate(:not, [gate(:not, [gate(:not, [leaf(:a)])])])
      assert Normalize.normalize(tree) == neg(leaf(:a))
    end

    test "not of an and is one compound negation, NOT a disjunction of negations" do
      tree = gate(:not, [gate(:and, [leaf(:a), leaf(:b)])])
      assert Normalize.normalize(tree) == cneg([leaf(:a), leaf(:b)])
    end

    test "not of an or is de Morganed into a conjunction of negations" do
      tree = gate(:not, [gate(:or, [leaf(:a), leaf(:b)])])
      assert Normalize.normalize(tree) == {:or, [[neg(leaf(:a)), neg(leaf(:b))]]}
    end

    test "n-ary not is the negation of the conjunction of its arguments" do
      assert Normalize.normalize(gate(:not, [leaf(:a), leaf(:b)])) ==
               Normalize.normalize(gate(:not, [gate(:and, [leaf(:a), leaf(:b)])]))
    end

    test "negation distributes over a disjunction and stops at each conjunction" do
      # not(a and (b or c)) = not(a and b) and not(a and c)
      tree = gate(:not, [gate(:and, [leaf(:a), gate(:or, [leaf(:b), leaf(:c)])])])

      assert Normalize.normalize(tree) ==
               {:or, [[cneg([leaf(:a), leaf(:b)]), cneg([leaf(:a), leaf(:c)])]]}
    end

    test "the output never holds a gate or a nested disjunction" do
      tree = gate(:not, [gate(:or, [gate(:and, [leaf(:a), leaf(:b)]), leaf(:c)])])
      normalized = Normalize.normalize(tree)
      assert_dnf(normalized)
      assert normalized == {:or, [[cneg([leaf(:a), leaf(:b)]), neg(leaf(:c))]]}
    end
  end

  # --------------------------------------------------------------------
  # Compound negation - de Morgan over a conjunction is existentially wrong
  # --------------------------------------------------------------------

  describe "compound negation" do
    test "nand over conditions sharing a variable stays one compound negation" do
      # "no x has both an order and a refund". De Morganed this would read
      # "there are no orders at all, or no refunds at all", which is false as
      # soon as some other x has an order.
      element =
        Parser.parse_element(
          __ENV__,
          quote do
            {:nand, [{:order, x}, {:refund, x}]}
          end
        )

      normalized = Normalize.normalize(element)

      refute match?({:or, [[%IR.Negation{}], [%IR.Negation{}]]}, normalized),
             "de Morgan was applied to a negated conjunction"

      assert %IR.CompoundNegation{conditions: [order, refund]} = normalized
      assert %IR.Fact{type: :order} = order
      assert %IR.Fact{type: :refund} = refund
    end

    test "a compound negation keeps its conjuncts in author order" do
      assert cneg([leaf(:a), leaf(:b), leaf(:c)]) ==
               Normalize.normalize(gate(:nand, [leaf(:a), leaf(:b), leaf(:c)]))
    end

    test "a compound negation of one condition collapses to a plain negation" do
      assert Normalize.normalize(gate(:nand, [leaf(:a), leaf(:a)])) == neg(leaf(:a))
    end

    test "negating a contradictory conjunction is true" do
      tree = gate(:not, [gate(:and, [leaf(:a), gate(:not, [leaf(:a)])])])
      assert Normalize.normalize(tree) == @truth
    end

    test "a double negation collapses through a compound" do
      tree = gate(:not, [gate(:nand, [leaf(:a), leaf(:b)])])
      assert Normalize.normalize(tree) == {:or, [[leaf(:a), leaf(:b)]]}
    end

    test "a compound negation nests inside another one" do
      # not(a and not(b and c))
      tree = gate(:nand, [leaf(:a), gate(:nand, [leaf(:b), leaf(:c)])])

      assert Normalize.normalize(tree) ==
               cneg([leaf(:a), cneg([leaf(:b), leaf(:c)])])
    end

    test "normalizing an already normalized compound negation is idempotent" do
      element = cneg([leaf(:a), neg(leaf(:b))])
      assert Normalize.normalize(element) == element
      assert Normalize.normalize(Normalize.normalize(element)) == element
    end

    test "identical compound negations dedup inside a conjunction" do
      inner = gate(:nand, [leaf(:a), leaf(:b)])
      assert Normalize.normalize(gate(:and, [inner, inner])) == cneg([leaf(:a), leaf(:b)])
    end
  end

  describe "derived gates" do
    test "nand is not of and" do
      assert Normalize.normalize(gate(:nand, [leaf(:a), leaf(:b)])) ==
               Normalize.normalize(gate(:not, [gate(:and, [leaf(:a), leaf(:b)])]))
    end

    test "nor is not of or" do
      assert Normalize.normalize(gate(:nor, [leaf(:a), leaf(:b)])) ==
               Normalize.normalize(gate(:not, [gate(:or, [leaf(:a), leaf(:b)])]))
    end

    test "binary xor is exactly one" do
      assert Normalize.normalize(gate(:xor, [leaf(:a), leaf(:b)])) ==
               {:or, [[leaf(:a), neg(leaf(:b))], [neg(leaf(:a)), leaf(:b)]]}
    end

    test "ternary xor is exactly one of three" do
      assert Normalize.normalize(gate(:xor, [leaf(:a), leaf(:b), leaf(:c)])) ==
               {:or,
                [
                  [leaf(:a), neg(leaf(:b)), neg(leaf(:c))],
                  [neg(leaf(:a)), leaf(:b), neg(leaf(:c))],
                  [neg(leaf(:a)), neg(leaf(:b)), leaf(:c)]
                ]}
    end

    test "xnor is a conjunction of compound negations, one per xor branch" do
      # not(a xor b) = not(a and !b) and not(!a and b), which is two compound
      # negations in a single branch - no distribution at all.
      assert Normalize.normalize(gate(:xnor, [leaf(:a), leaf(:b)])) ==
               {:or, [[cneg([leaf(:a), neg(leaf(:b))]), cneg([neg(leaf(:a)), leaf(:b)])]]}
    end

    test "xnor over three arguments agrees with not of xor" do
      args = [leaf(:a), leaf(:b), leaf(:c)]

      assert Normalize.normalize(gate(:xnor, args)) ==
               Normalize.normalize(gate(:not, [gate(:xor, args)]))
    end
  end

  describe "degenerate arities" do
    test "no arguments" do
      assert Normalize.normalize(gate(:and, [])) == @truth
      assert Normalize.normalize(gate(:or, [])) == @falsity
      assert Normalize.normalize(gate(:not, [])) == @falsity
      assert Normalize.normalize(gate(:nand, [])) == @falsity
      assert Normalize.normalize(gate(:nor, [])) == @truth
      assert Normalize.normalize(gate(:xor, [])) == @falsity
      assert Normalize.normalize(gate(:xnor, [])) == @truth
    end

    test "one argument" do
      a = leaf(:a)

      assert Normalize.normalize(gate(:and, [a])) == a
      assert Normalize.normalize(gate(:or, [a])) == a
      assert Normalize.normalize(gate(:not, [a])) == neg(a)
      assert Normalize.normalize(gate(:nand, [a])) == neg(a)
      assert Normalize.normalize(gate(:nor, [a])) == neg(a)
      assert Normalize.normalize(gate(:xor, [a])) == a
      assert Normalize.normalize(gate(:xnor, [a])) == neg(a)
    end

    test "an empty gate nested in an and" do
      # and(a, or()) is false, and(a, and()) is a
      assert Normalize.normalize(gate(:and, [leaf(:a), gate(:or, [])])) == @falsity
      assert Normalize.normalize(gate(:and, [leaf(:a), gate(:and, [])])) == leaf(:a)
    end

    test "an empty gate nested in an or" do
      assert Normalize.normalize(gate(:or, [leaf(:a), gate(:or, [])])) == leaf(:a)

      # `a or true` is true: the empty branch absorbs the others rather than
      # reaching W4 as `{:or, [[a], []]}`.
      assert Normalize.normalize(gate(:or, [leaf(:a), gate(:and, [])])) == @truth
    end
  end

  describe "an empty branch absorbs the disjunction" do
    test "a disjunction never keeps an empty branch next to a real one" do
      element = {:or, [[], [leaf(:a)]]}
      assert Normalize.normalize(element) == @truth

      element = {:or, [[leaf(:a)], [], [leaf(:b), leaf(:c)]]}
      assert Normalize.normalize(element) == @truth
    end

    test "an absorbed disjunction disappears from the LHS entirely" do
      lhs = [leaf(:a), gate(:or, [gate(:and, []), leaf(:b)]), leaf(:c)]
      assert Normalize.normalize_lhs(lhs) == [leaf(:a), leaf(:c)]
    end

    test "no normalized LHS element is a disjunction holding an empty branch" do
      for tree <- all_trees(2, 2, 2), element <- Normalize.normalize_lhs([tree]) do
        case element do
          {:or, branches} ->
            refute Enum.any?(branches, &(&1 == [])),
                   "an empty branch survived next to #{length(branches) - 1} others"

          _ ->
            :ok
        end
      end
    end
  end

  describe "simplification" do
    test "a literal repeated in a conjunction is kept once" do
      assert Normalize.normalize(gate(:and, [leaf(:a), leaf(:a)])) == leaf(:a)
    end

    test "a conjunction holding a literal and its negation is dropped" do
      assert Normalize.normalize(gate(:and, [leaf(:a), gate(:not, [leaf(:a)])])) == {:or, []}
    end

    test "only the contradictory branch of a disjunction is dropped" do
      tree =
        gate(:or, [
          gate(:and, [leaf(:a), gate(:not, [leaf(:a)])]),
          leaf(:b)
        ])

      assert Normalize.normalize(tree) == leaf(:b)
    end

    test "duplicate branches are kept once, the first occurrence" do
      assert Normalize.normalize(gate(:or, [leaf(:a), leaf(:a)])) == leaf(:a)

      tree = gate(:or, [gate(:and, [leaf(:a), leaf(:b)]), gate(:and, [leaf(:b), leaf(:a)])])
      assert Normalize.normalize(tree) == {:or, [[leaf(:a), leaf(:b)]]}
    end

    test "a positive and a negative literal of the same condition are distinct" do
      assert Normalize.normalize(gate(:or, [leaf(:a), gate(:not, [leaf(:a)])])) ==
               {:or, [[leaf(:a)], [neg(leaf(:a))]]}
    end

    test "literals differing only in their fact binding are distinct" do
      a = leaf(:a)
      bound = %IR.Fact{a | fact_binding: :f}

      assert Normalize.normalize(gate(:and, [a, bound])) == {:or, [[a, bound]]}
    end

    test "literals differing only in AST metadata are the same literal" do
      a = leaf(:a)
      relocated = %IR.Fact{a | __ast__: %{a.__ast__ | source: {:a, [line: 99], nil}}}

      assert Normalize.normalize(gate(:and, [a, relocated])) == a
    end
  end

  describe "errors" do
    test "an unknown gate is rejected" do
      assert_raise ArgumentError, ~r/unknown gate :maybe/, fn ->
        Normalize.normalize(%IR.Gate{gate: :maybe, args: [leaf(:a)], code: [:maybe]})
      end
    end

    test "an unsupported condition is rejected" do
      assert_raise ArgumentError, ~r/cannot normalize an unsupported condition/, fn ->
        Normalize.normalize(%URI{})
      end
    end
  end

  describe "determinism" do
    test "the same input always gives byte identical output" do
      tree =
        gate(:xor, [
          gate(:or, [leaf(:a), leaf(:b)]),
          gate(:nand, [leaf(:c), leaf(:d)]),
          leaf(:e)
        ])

      first = Normalize.normalize(tree)

      for _ <- 1..20 do
        assert :erlang.term_to_binary(Normalize.normalize(tree)) ==
                 :erlang.term_to_binary(first)
      end
    end
  end

  describe "normalize_lhs/1" do
    test "leaves plain conditions alone" do
      lhs = [leaf(:a), leaf(:b)]
      assert Normalize.normalize_lhs(lhs) == lhs
    end

    test "splices a conjunction into the element list" do
      lhs = [leaf(:a), gate(:and, [leaf(:b), leaf(:c)]), leaf(:d)]
      assert Normalize.normalize_lhs(lhs) == [leaf(:a), leaf(:b), leaf(:c), leaf(:d)]
    end

    test "keeps a real disjunction as one element" do
      lhs = [leaf(:a), gate(:or, [leaf(:b), leaf(:c)])]
      assert Normalize.normalize_lhs(lhs) == [leaf(:a), {:or, [[leaf(:b)], [leaf(:c)]]}]
    end

    test "drops an element that is always true" do
      assert Normalize.normalize_lhs([leaf(:a), gate(:and, [])]) == [leaf(:a)]
    end

    test "keeps an element that is always false" do
      assert Normalize.normalize_lhs([leaf(:a), gate(:or, [])]) == [leaf(:a), {:or, []}]
    end
  end

  describe "parser output" do
    test "normalizes a gate parsed from the DSL" do
      element =
        Parser.parse_element(
          __ENV__,
          quote do
            {:or, [{:user, id}, {:not, [{:admin, id}]}]}
          end
        )

      assert %IR.Gate{gate: :or, args: [user, not_admin]} = element
      assert %IR.Fact{type: :user} = user
      assert %IR.Gate{gate: :not, args: [admin]} = not_admin

      assert Normalize.normalize(element) == {:or, [[user], [%IR.Negation{condition: admin}]]}
    end

    test "normalizes a collection inside a gate" do
      element =
        Parser.parse_element(
          __ENV__,
          quote do
            {:and, [{:user, id}, orders = [{:order, id, _amt}]]}
          end
        )

      assert %IR.Gate{args: [user, orders]} = element
      assert %IR.Coll{type: :order, coll_binding: :orders} = orders
      assert Normalize.normalize(element) == {:or, [[user, orders]]}
    end

    test "keeps a compound negation parsed from the DSL compound" do
      element =
        Parser.parse_element(
          __ENV__,
          quote do
            {:not, [{:and, [{:user, id}, {:order, id}]}]}
          end
        )

      assert %IR.CompoundNegation{conditions: [user, order]} = Normalize.normalize(element)
      assert %IR.Fact{type: :user} = user
      assert %IR.Fact{type: :order} = order
    end

    test "a compound negation survives the whole front end pipeline" do
      production =
        Rete.Ruleset.build(
          __ENV__,
          Code.string_to_quoted!("clean({:nand, [{:order, x}, {:refund, x}]})"),
          nil,
          :rule
        )

      assert [%IR.CompoundNegation{conditions: [order, refund]}] = production.lhs

      # The inner conjunction is classified as a little LHS of its own: `x` is
      # new in the order and a join key in the refund.
      assert %IR.Fact{type: :order, join_bind: [], new_bind: [:x]} = order
      assert %IR.Fact{type: :refund, join_bind: [:x], new_bind: []} = refund

      # Nothing inside a negation escapes downstream.
      assert IR.bound_vars(hd(production.lhs)) == []
    end
  end

  # --------------------------------------------------------------------
  # The branch limit
  # --------------------------------------------------------------------

  describe "branch limit" do
    test "a conjunction of too many disjunctions is rejected, naming the gate" do
      # 11 binary ors under one and would distribute into 2048 branches.
      ors = Enum.map(1..11, fn i -> gate(:or, [leaf(:"a#{i}"), leaf(:"b#{i}")]) end)

      assert_raise ArgumentError, ~r/the :and gate of 11 arguments/, fn ->
        Normalize.normalize(gate(:and, ors))
      end
    end

    test "the error reports the branch count and the limit" do
      ors = Enum.map(1..11, fn i -> gate(:or, [leaf(:"a#{i}"), leaf(:"b#{i}")]) end)

      message =
        assert_raise(ArgumentError, fn -> Normalize.normalize(gate(:and, ors)) end).message

      assert message =~ "disjunctive branches"
      assert message =~ "over the limit of #{Normalize.max_branches()}"
      assert [count] = Regex.run(~r/at least (\d+) disjunctive/, message, capture: :all_but_first)
      assert String.to_integer(count) > Normalize.max_branches()
    end

    test "the limit is enforced on the innermost offending gate" do
      ors = Enum.map(1..11, fn i -> gate(:or, [leaf(:"a#{i}"), leaf(:"b#{i}")]) end)

      assert_raise ArgumentError, ~r/the :and gate of 11 arguments/, fn ->
        Normalize.normalize(gate(:or, [leaf(:z), gate(:and, ors)]))
      end
    end

    test "a wide disjunction that stays exactly on the limit compiles" do
      ors = Enum.map(1..8, fn i -> gate(:or, [leaf(:"a#{i}"), leaf(:"b#{i}")]) end)
      assert {:or, branches} = Normalize.normalize(gate(:and, ors))
      assert length(branches) == 256
      assert length(branches) == Normalize.max_branches()
    end

    test "a negation never grows the branch count, so wide xnor is cheap" do
      # This is the rule that used to distribute into 5282 branches and take
      # minutes to compile; it is now a single branch of eight negations.
      args = Enum.map(1..8, fn i -> leaf(:"v#{i}") end)

      {us, normalized} = :timer.tc(fn -> Normalize.normalize(gate(:xnor, args)) end)

      assert {:or, [branch]} = normalized
      assert length(branch) == 8
      assert Enum.all?(branch, &match?(%IR.CompoundNegation{}, &1))
      assert us < 100_000, "xnor/8 took #{div(us, 1000)} ms"
    end
  end

  # --------------------------------------------------------------------
  # Truth table equivalence
  # --------------------------------------------------------------------

  describe "truth table equivalence" do
    test "every gate over every assignment of two variables" do
      for gate <- @gates, arity <- 0..3 do
        args = Enum.map(1..arity//1, &leaf(:"v#{rem(&1 - 1, 2) + 1}"))
        assert_equivalent(gate(gate, args), 2)
      end
    end

    test "every single gate of up to three arguments over two variables" do
      for tree <- all_trees(2, 1, 3), do: assert_equivalent(tree, 2)
    end

    test "every tree of up to two gate levels and two arguments over two variables" do
      for tree <- all_trees(2, 2, 2), do: assert_equivalent(tree, 2)
    end

    test "every pair of nested gates over three variables" do
      for outer <- @gates, inner <- @gates do
        tree = gate(outer, [gate(inner, [leaf(:v1), leaf(:v2)]), leaf(:v3)])
        assert_equivalent(tree, 3)

        tree = gate(outer, [leaf(:v3), gate(inner, [leaf(:v1), leaf(:v2)])])
        assert_equivalent(tree, 3)
      end
    end

    test "random trees of depth up to three over one to four variables" do
      :rand.seed(:exsss, {20_260_829, 2, 1})

      for _ <- 1..600 do
        vars = Enum.random(1..4)
        tree = random_tree(vars, Enum.random(1..3))
        assert_equivalent(tree, vars)
      end
    end
  end

  # Asserts that the normalized form of `tree` is in DNF and agrees with `tree`
  # on all 2^vars assignments of :v1..:vN.
  defp assert_equivalent(tree, vars) do
    normalized = Normalize.normalize(tree)
    assert_dnf(normalized)

    for assignment <- assignments(vars) do
      assert eval(tree, assignment) == eval(normalized, assignment),
             """
             normalization changed the truth table

             tree:       #{inspect(tree, pretty: true)}
             normalized: #{inspect(normalized, pretty: true)}
             assignment: #{inspect(assignment)}
             expected:   #{inspect(eval(tree, assignment))}
             """
    end
  end

  defp assignments(vars) do
    Enum.reduce(1..vars//1, [%{}], fn n, acc ->
      Enum.flat_map(acc, fn a ->
        [Map.put(a, :"v#{n}", false), Map.put(a, :"v#{n}", true)]
      end)
    end)
  end

  # The reference semantics, evaluated directly on the gate tree.
  defp eval(%IR.Fact{type: type}, assignment), do: Map.fetch!(assignment, type)
  defp eval(%IR.Negation{condition: condition}, assignment), do: not eval(condition, assignment)

  defp eval(%IR.CompoundNegation{conditions: conditions}, assignment) do
    not Enum.all?(conditions, &eval(&1, assignment))
  end

  defp eval({:or, branches}, assignment) do
    Enum.any?(branches, fn branch -> Enum.all?(branch, &eval(&1, assignment)) end)
  end

  defp eval(%IR.Gate{gate: gate, args: args}, assignment) do
    values = Enum.map(args, &eval(&1, assignment))

    case gate do
      :and -> Enum.all?(values)
      :or -> Enum.any?(values)
      :not -> not Enum.all?(values)
      :nand -> not Enum.all?(values)
      :nor -> not Enum.any?(values)
      :xor -> Enum.count(values, & &1) == 1
      :xnor -> Enum.count(values, & &1) != 1
    end
  end

  # The output is in DNF: a single literal, or a disjunction of conjunctions of
  # literals, where a literal is a condition, the negation of a condition, or
  # the compound negation of a conjunction of literals.
  defp assert_dnf({:or, branches}) do
    assert is_list(branches)

    Enum.each(branches, fn branch ->
      assert is_list(branch)
      Enum.each(branch, &assert_literal/1)
    end)

    # An empty branch is `true`, which absorbs everything else.
    if Enum.any?(branches, &(&1 == [])),
      do: assert(branches == [[]], "an empty branch survived next to a non-empty one")
  end

  defp assert_dnf(other), do: assert_literal(other)

  defp assert_literal(%IR.Negation{condition: condition}) do
    refute match?(%IR.Gate{}, condition), "negation of a gate survived normalization"
    refute match?(%IR.Negation{}, condition), "double negation survived normalization"

    refute match?(%IR.CompoundNegation{}, condition),
           "a compound negation wrapped in a plain negation survived normalization"

    refute match?({:or, _}, condition), "negation of a disjunction survived normalization"
  end

  # A compound negation is a literal too, and its inner conjunction is itself a
  # conjunction of literals.
  defp assert_literal(%IR.CompoundNegation{conditions: conditions}) do
    assert length(conditions) >= 2, "a one-condition compound negation survived normalization"
    Enum.each(conditions, &assert_literal/1)
  end

  defp assert_literal(literal) do
    refute match?(%IR.Gate{}, literal), "a gate survived normalization"
    refute match?({:or, _}, literal), "an or nested inside an and survived normalization"
  end

  # Every tree of at most `depth` gate levels over `vars` variables, with gate
  # arities 1..max_arity.
  defp all_trees(vars, depth, max_arity) do
    leaves = Enum.map(1..vars//1, &leaf(:"v#{&1}"))
    Enum.reduce(1..depth//1, leaves, fn _, children -> children ++ grow(children, max_arity) end)
  end

  defp grow(children, max_arity) do
    for gate <- @gates, arity <- 1..max_arity//1, args <- tuples(children, arity) do
      gate(gate, args)
    end
  end

  defp tuples(_children, 0), do: [[]]

  defp tuples(children, arity) do
    for head <- children, tail <- tuples(children, arity - 1), do: [head | tail]
  end

  # A random tree, rejected and regrown while it has more than @max_leaves leaf
  # occurrences. The cap keeps the DNF of nested xors from exploding: negating a
  # disjunction of k conjunctions of n literals yields up to n^k conjunctions.
  @max_leaves 6

  defp random_tree(vars, depth) do
    tree = grow_random(vars, depth)
    if count_leaves(tree) > @max_leaves, do: random_tree(vars, depth), else: tree
  end

  defp grow_random(vars, 0), do: leaf(:"v#{Enum.random(1..vars)}")

  defp grow_random(vars, depth) do
    if :rand.uniform() < 0.25 do
      grow_random(vars, 0)
    else
      arity = Enum.random(0..3)
      gate(Enum.random(@gates), Enum.map(1..arity//1, fn _ -> grow_random(vars, depth - 1) end))
    end
  end

  defp count_leaves(%IR.Fact{}), do: 1
  defp count_leaves(%IR.Gate{args: args}), do: Enum.sum([0 | Enum.map(args, &count_leaves/1)])
end
