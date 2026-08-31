defmodule Rete.DSL.Normalize do
  # Declared before the moduledoc so the documentation can quote it.
  @max_branches 256

  @moduledoc """
  Gate normalization: the phase between parsing and binding classification.

  **Internal.** Turns the `Rete.IR.Gate` placeholders `Rete.DSL.Parser` left behind into
  the per-condition form of `t:Rete.IR.lhs/0`: a single condition struct, or a disjunction
  of conjunctions `{:or, [[condition, ...], ...]}`.

  Normalization is **per LHS element**. The LHS as a whole is never flattened to DNF,
  which explodes combinatorially. Three steps: lift into a boolean tree, distribute into
  DNF, simplify. Author order is preserved and nothing depends on map iteration order, so
  the same input always produces byte-identical output.

  `not(a, b, ...)` and `nand` mean `not(and(...))`, `nor` means `not(or(...))`, n-ary
  `xor` means **exactly one** holds, and `xnor` is its negation. These expansions are
  applied literally, which settles the degenerate arities without special casing. A true
  element becomes `{:or, [[]]}` and a false one `{:or, []}`.

  Negation of a **disjunction** distributes: de Morgan applies there and only there.
  Negation of a **conjunction** becomes a `Rete.IR.CompoundNegation`, because the
  conjuncts share existentially quantified variables and the rewrite would be a stronger
  statement. `Rete.Compiler.Negation` extracts it later.

  Distribution is the one step that can explode, so `to_dnf/1` refuses to build more than
  #{@max_branches} branches for one gate. Compile time sets that limit: escaping 1024
  branches costs 32 s. See `docs/design/ir.md` §2.
  """

  alias Rete.IR

  @typedoc """
  The internal boolean tree normalization works on.

  `{:gate, gate, args}` nodes are the `Rete.IR.Gate` placeholders, which `to_dnf/1`
  rewrites on the way down. `:not` is always unary here. An n-ary `not` gate is the
  negation of the conjunction of its arguments.
  """
  @type tree ::
          {:gate, atom(), [tree()]}
          | {:and, [tree()]}
          | {:or, [tree()]}
          | {:not, tree()}
          | {:lit, IR.condition()}

  @typedoc """
  A literal of a normalized conjunction.

  Either a condition, the negation of a condition, or the negation of a whole
  conjunction of literals - the case de Morgan is not allowed to touch.
  """
  @type literal ::
          {:pos, IR.condition()}
          | {:neg, IR.condition()}
          | {:cneg, [literal()]}

  @typedoc "Disjunctive normal form: a disjunction of conjunctions of literals."
  @type dnf :: [[literal()]]

  @typedoc "A normalized LHS element."
  @type element :: IR.condition() | {:or, [[IR.condition()]]}

  @doc """
  The largest number of disjunctive branches a single gate may normalize into.

  Past this, `to_dnf/1` raises rather than let a rule take minutes to compile
  and build a beta network with thousands of join paths.
  """
  @spec max_branches() :: pos_integer()
  def max_branches, do: @max_branches

  @doc """
  Normalizes one parsed LHS element.

  Returns the element unchanged when it holds no gate, and otherwise a single
  condition (possibly a `Rete.IR.Negation` or a `Rete.IR.CompoundNegation`) or
  `{:or, [[condition, ...], ...]}`.

  ## Examples

  Writing `a` for a condition, `!a` for `%Rete.IR.Negation{condition: a}` and
  `!(a, b)` for `%Rete.IR.CompoundNegation{conditions: [a, b]}`:

      %Gate{gate: :and, args: [a, b]}    ->  {:or, [[a, b]]}
      %Gate{gate: :or, args: [a, b]}     ->  {:or, [[a], [b]]}
      %Gate{gate: :not, args: [a]}       ->  !a
      %Gate{gate: :nand, args: [a, b]}   ->  !(a, b)
      %Gate{gate: :nor, args: [a, b]}    ->  {:or, [[!a, !b]]}
      %Gate{gate: :or, args: []}         ->  {:or, []}
      %Fact{}                            ->  the fact itself
  """
  @spec normalize(IR.condition() | element()) :: element()
  def normalize(element) do
    element
    |> to_tree()
    |> to_dnf()
    |> simplify()
    |> to_element()
  end

  @doc """
  Normalizes every element of an LHS, in order.

  Returns a `t:Rete.IR.lhs/0`. A conjunction is spliced into the surrounding
  element list rather than kept as a one-branch disjunction, and an element that
  normalizes to *true* disappears. An element that normalizes to *false* is kept
  as `{:or, []}`, because dropping it would change the meaning of the
  production.
  """
  @spec normalize_lhs(IR.lhs()) :: IR.lhs()
  def normalize_lhs(lhs) when is_list(lhs) do
    Enum.flat_map(lhs, fn element ->
      case normalize(element) do
        {:or, [branch]} -> branch
        other -> [other]
      end
    end)
  end

  # ----------------------------------------------------------------------
  # 1. lift into a boolean tree
  # ----------------------------------------------------------------------

  @doc """
  Lifts an LHS element into the internal boolean `t:tree/0`.

  Gates, `Rete.IR.Negation` and `Rete.IR.CompoundNegation` nodes and
  `{:or, [[condition, ...], ...]}` elements become tree nodes; every other
  condition becomes an opaque `{:lit, condition}` leaf. Lifting an already
  normalized element back into a tree is what makes `normalize/1` idempotent.
  """
  # A conjunction at LHS level is a list of elements, not an element, so a top-level
  # `{:and, _}` is one shape of `tree()` this cannot return. `:and` only appears nested
  # inside a `:not` or an `:or`.
  @dialyzer {:no_extra_return, to_tree: 1}
  @spec to_tree(IR.condition() | element()) :: tree()
  def to_tree(%IR.Gate{gate: gate, args: args}), do: {:gate, gate, Enum.map(args, &to_tree/1)}
  def to_tree(%IR.Negation{condition: condition}), do: {:not, to_tree(condition)}

  def to_tree(%IR.CompoundNegation{conditions: conditions}) do
    {:not, {:and, Enum.map(conditions, &to_tree/1)}}
  end

  def to_tree({:or, branches}) when is_list(branches) do
    {:or, Enum.map(branches, fn branch -> {:and, Enum.map(branch, &to_tree/1)} end)}
  end

  def to_tree(condition), do: {:lit, condition}

  # ----------------------------------------------------------------------
  # 2. distribute into DNF
  # ----------------------------------------------------------------------

  @doc """
  Distributes a `t:tree/0` into disjunctive normal form.

  The empty disjunction is `[]` (false) and the empty conjunction is `[[]]`
  (true). Gates are rewritten as they are met, so the gate that overflows the
  branch limit can be named in the error.

  Raises `ArgumentError` when a single gate would produce more than
  `max_branches/0` branches.
  """
  @spec to_dnf(tree()) :: dnf()
  def to_dnf({:lit, condition}), do: [[{:pos, condition}]]
  def to_dnf({:not, arg}), do: negate(to_dnf(arg))
  def to_dnf({:and, args}), do: conjoin(:and, args)
  def to_dnf({:or, args}), do: disjoin(:or, args)
  def to_dnf({:gate, :and, args}), do: conjoin(:and, args)
  def to_dnf({:gate, :or, args}), do: disjoin(:or, args)
  def to_dnf({:gate, :not, args}), do: negate(conjoin(:not, args))
  def to_dnf({:gate, :nand, args}), do: negate(conjoin(:nand, args))
  def to_dnf({:gate, :nor, args}), do: negate(disjoin(:nor, args))
  def to_dnf({:gate, :xor, args}), do: exactly_one(:xor, args)
  def to_dnf({:gate, :xnor, args}), do: negate(exactly_one(:xnor, args))

  def to_dnf({:gate, gate, _args}) do
    raise ArgumentError,
          "unknown gate #{inspect(gate)}, expected one of " <>
            inspect([:and, :or, :not, :nand, :nor, :xor, :xnor])
  end

  # and(a, b, ...): the cartesian join of the branches. The one step that can explode, so
  # the one step that is size checked.
  defp conjoin(gate, args), do: product(gate, length(args), Enum.map(args, &to_dnf/1))

  # or(a, b, ...): concatenation. It cannot multiply, but it can accumulate past the
  # limit, so it is checked too.
  defp disjoin(gate, args) do
    clauses = args |> Enum.map(&to_dnf/1) |> Enum.concat()
    check_size!(gate, length(args), length(clauses))
    clauses
  end

  # or( and(a1, !a2, !a3), and(!a1, a2, !a3), and(!a1, !a2, a3) )
  #
  # Every negated argument contributes one branch, so the result is at most the sum of
  # the argument branch counts. `xor` does not explode.
  defp exactly_one(gate, args) do
    dnfs = args |> Enum.map(&to_dnf/1) |> Enum.with_index()
    arity = length(dnfs)

    clauses =
      Enum.flat_map(dnfs, fn {_dnf, chosen} ->
        dnfs
        |> Enum.map(fn {dnf, i} -> if i == chosen, do: dnf, else: negate(dnf) end)
        |> then(&product(gate, arity, &1))
      end)

    check_size!(gate, arity, length(clauses))
    clauses
  end

  defp product(gate, arity, dnfs) do
    check_size!(gate, arity, product_size(dnfs))

    Enum.reduce(dnfs, [[]], fn dnf, clauses ->
      for clause <- clauses, addition <- dnf, do: clause ++ addition
    end)
  end

  # Stops multiplying once the limit is passed, so a pathological input is rejected
  # instead of counted exactly.
  defp product_size(dnfs) do
    Enum.reduce_while(dnfs, 1, fn dnf, acc ->
      acc = acc * length(dnf)
      if acc > @max_branches, do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp check_size!(_gate, _arity, size) when size <= @max_branches, do: :ok

  defp check_size!(gate, arity, size) do
    raise ArgumentError, """
    the #{inspect(gate)} gate of #{arity} arguments normalizes into at least \
    #{size} disjunctive branches, over the limit of #{@max_branches}.

    Every branch becomes its own join path in the beta network, so a condition \
    this wide takes minutes to compile and builds a network nothing can run. \
    Narrow it down: split the rule, factor the shared part of the alternatives \
    into an intermediate fact, or replace the inner disjunctions with a guard.
    """
  end

  # --- negation --------------------------------------------------------------

  # not(c1 or c2 or ...) = not(c1) and not(c2) and ...
  #
  # Every negated clause is at most one branch wide, so their conjunction is too.
  # Negation cannot grow the DNF and needs no size check.
  defp negate(clauses) do
    Enum.reduce(clauses, [[]], fn clause, acc ->
      negated = negate_clause(clause)
      for kept <- acc, addition <- negated, do: kept ++ addition
    end)
  end

  # The negation of one conjunction of literals, as a DNF of at most one branch. De
  # Morgan stops here: a conjunction of two or more literals is negated as a whole.
  defp negate_clause(literals) do
    case simplify_clause(literals) do
      # not(false) = true
      :unsatisfiable -> [[]]
      # not(true) = false
      [] -> []
      [{:pos, condition}] -> [[{:neg, condition}]]
      [{:neg, condition}] -> [[{:pos, condition}]]
      # not(not(a and b)) = a and b
      [{:cneg, inner}] -> [inner]
      kept -> [[{:cneg, kept}]]
    end
  end

  # ----------------------------------------------------------------------
  # 3. simplify
  # ----------------------------------------------------------------------

  @doc """
  Prunes a DNF: repeated literals, contradictory branches, absorbed branches and
  duplicate branches.

  A branch that is empty is *true*, and `true or anything` is `true`, so the
  whole disjunction collapses to `[[]]`. No branch is ever dropped because
  another subsumes it (`a or (a and b)` keeps both): branches carry bindings and
  the longer one binds more.
  """
  @spec simplify(dnf()) :: dnf()
  def simplify(clauses) do
    clauses
    |> Enum.map(&simplify_clause/1)
    |> Enum.reject(&(&1 == :unsatisfiable))
    |> absorb_true()
    |> dedup_clauses()
  end

  # Drops literals repeating an earlier literal of the same conjunction, and rejects the
  # conjunction outright when it holds both a literal and its negation.
  defp simplify_clause(literals) do
    literals
    |> Enum.reduce_while({[], %{}}, fn literal, {kept, seen} ->
      {sign, key} = literal_key(literal)

      case Map.fetch(seen, key) do
        {:ok, ^sign} -> {:cont, {kept, seen}}
        {:ok, _opposite} -> {:halt, :unsatisfiable}
        :error -> {:cont, {[literal | kept], Map.put(seen, key, sign)}}
      end
    end)
    |> case do
      :unsatisfiable -> :unsatisfiable
      {kept, _seen} -> Enum.reverse(kept)
    end
  end

  defp absorb_true(clauses) do
    if Enum.any?(clauses, &(&1 == [])), do: [[]], else: clauses
  end

  defp dedup_clauses(clauses) do
    {kept, _seen} =
      Enum.reduce(clauses, {[], MapSet.new()}, fn clause, {kept, seen} ->
        key = clause |> Enum.map(&literal_key/1) |> Enum.sort()

        if MapSet.member?(seen, key) do
          {kept, seen}
        else
          {[clause | kept], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(kept)
  end

  # Identity of a literal, used to spot repetitions and contradictions. Derived from what
  # a condition compiles to, never from `:__ast__`, whose metadata differs between two
  # occurrences of the same condition written on different lines.
  #
  # A compound negation keys on its whole inner conjunction. Its complement is a
  # conjunction, not a literal, so nothing is the opposite of it.
  defp literal_key({:cneg, literals}), do: {:cneg, Enum.map(literals, &literal_key/1)}
  defp literal_key({sign, condition}), do: {sign, condition_key(condition)}

  defp condition_key(%IR.Fact{} = fact) do
    {IR.Fact, fact.type, fact.fact_binding, fact.bind, expr_key(fact.alpha),
     expr_key(fact.join_filter), fact.join_bind, fact.new_bind}
  end

  defp condition_key(%IR.Coll{} = coll) do
    {IR.Coll, coll.type, coll.coll_binding, coll.bind, expr_key(coll.alpha),
     expr_key(coll.join_filter), coll.join_bind, coll.new_bind}
  end

  defp condition_key(%IR.Test{} = test), do: {IR.Test, test.bind, expr_key(test.expr)}

  defp condition_key(other) do
    raise ArgumentError,
          "cannot normalize an unsupported condition, expected a Rete.IR.Fact, " <>
            "Rete.IR.Coll, Rete.IR.Test, Rete.IR.Negation, Rete.IR.CompoundNegation " <>
            "or Rete.IR.Gate, got: " <> inspect(other)
  end

  defp expr_key(nil), do: nil
  defp expr_key(%IR.Expr{code: code, arity: arity}), do: {code, arity}

  # ----------------------------------------------------------------------
  # back to an LHS element
  # ----------------------------------------------------------------------

  defp to_element([[literal]]), do: to_condition(literal)

  defp to_element(clauses) do
    {:or, Enum.map(clauses, fn clause -> Enum.map(clause, &to_condition/1) end)}
  end

  defp to_condition({:pos, condition}), do: condition
  defp to_condition({:neg, condition}), do: %IR.Negation{condition: condition}

  defp to_condition({:cneg, literals}) do
    %IR.CompoundNegation{conditions: Enum.map(literals, &to_condition/1)}
  end
end
