defmodule Rete.DSL.Normalize do
  # The largest number of disjunctive branches one gate may normalize into.
  # Declared before the moduledoc so that the documentation can quote it.
  @max_branches 256

  @moduledoc """
  Gate normalization, compile phase **W2a**.

  Turns the `Rete.IR.Gate` placeholders left behind by `Rete.DSL.Parser` into
  the normalized per-condition form of `t:Rete.IR.lhs/0`: either a single
  condition struct, or a disjunction of conjunctions,
  `{:or, [[condition, ...], ...]}`.

  Normalization is **per LHS element**. The LHS as a whole is never flattened to
  DNF (that explodes combinatorially); an element that normalizes to a
  disjunction fans out from the current parents and re-converges before the next
  element, exactly as in Clara's `add-production`.

  ## What it does, in order

  1. **Lift** the element into a boolean tree, `to_tree/1`.
  2. **Distribute** that tree into disjunctive normal form, `to_dnf/1`. Gates are
     rewritten into `and`/`or`/`not` on the way down and the DNF is built bottom
     up, so nested `and`s and `or`s flatten and single-child gates disappear as a
     consequence of the distribution itself.
  3. **Simplify**: drop repeated literals inside a conjunction, drop a
     conjunction holding both a literal and its negation, collapse the whole
     disjunction to *true* if any branch is empty, then drop duplicate branches.

  Author order is preserved throughout and nothing depends on map iteration
  order, so the same input always produces byte-identical output.

  ## Gate semantics

  | gate | meaning |
  |---|---|
  | `and(a, b, ...)` | all hold |
  | `or(a, b, ...)` | at least one holds |
  | `not(a, b, ...)` | `not(and(a, b, ...))` |
  | `nand(a, b, ...)` | `not(and(a, b, ...))`, identical to `not` |
  | `nor(a, b, ...)` | `not(or(a, b, ...))` |
  | `xor(a, b, ...)` | **exactly one** holds |
  | `xnor(a, b, ...)` | `not(xor(a, b, ...))` |

  n-ary `xor` expands to the "exactly one" disjunction

      or(and(a1, not a2, not a3), and(not a1, a2, not a3), and(not a1, not a2, a3))

  ### Degenerate arities

  The expansions above are applied literally, which settles the empty and
  single-argument cases without any special casing:

  | gate | 0 arguments | 1 argument |
  |---|---|---|
  | `and` | true, the empty conjunction | the argument |
  | `or` | false, the empty disjunction | the argument |
  | `not` / `nand` | `not(true)` = false | the negated argument |
  | `nor` | `not(false)` = true | the negated argument |
  | `xor` | false, no argument can be the one that holds | the argument |
  | `xnor` | true | the negated argument |

  A **true** element normalizes to `{:or, [[]]}`: one branch that adds no
  condition, i.e. the element constrains nothing. A **false** element
  normalizes to `{:or, []}`: no branch at all, i.e. the production can never
  fire. Both are legal `t:Rete.IR.lhs/0` elements, and `normalize_lhs/1` splices
  the former away.

  A disjunction that has *some* empty branch is *true* as a whole - the other
  branches are absorbed. That matters for more than tidiness: only the variables
  bound by **every** branch survive a disjunction, and an empty branch binds
  nothing, so the other branches could not have contributed a binding anyway.
  `simplify/1` therefore collapses `{:or, [[], [a]]}` to `{:or, [[]]}`, and W4
  never sees a disjunction with an empty branch next to a non-empty one.

  ## Negation

  ### A negation of a single condition

  ...is the normal, supported case and becomes a `Rete.IR.Negation` node.

  ### A negation of a disjunction

  ...distributes. `not(or(a, b))` is `and(not a, not b)` whatever `a` and `b`
  quantify over, so de Morgan is applied here and only here.

  ### A negation of a conjunction

  ...becomes a `Rete.IR.CompoundNegation` holding the conjunction, and is
  **never** de Morganed. The propositional rewrite `not(and(a, b))` =
  `or(not a, not b)` is invalid in a rules engine as soon as the conjuncts share
  an existentially quantified variable, which is the normal case:

      {:nand, [{:order, x}, {:refund, x}]}

  reads "no `x` has both an order and a refund". Rewritten by de Morgan it would
  read "there is no order at all, or there is no refund at all", which is a
  different - and much stronger - statement. With one order for `x = 1` and one
  refund for `x = 2` the intended reading is true and the de Morganed one is
  false.

  Clara draws the same line: `get-complex-negation` extracts a negated
  conjunction into a generated subrule that inserts a marker fact, and negates
  the marker instead. It runs at `add-production` time, *before* `to-dnf`, which
  is why Clara's own de-Morgan-over-`and` branch is unreachable. Here the
  extraction is left to W4, and W2a hands it a `Rete.IR.CompoundNegation` to
  extract.

  Double negation still collapses, including through a compound:
  `not(not(and(a, b)))` is `and(a, b)`.

  ## The branch limit

  Distribution is the one step that can explode: a conjunction of `k`
  disjunctions of `m` branches each yields `m^k` branches, and every branch is a
  separate join path in the beta network. `to_dnf/1` therefore refuses to build
  more than #{@max_branches} branches for a single gate and raises an
  `ArgumentError` naming the gate, its arity and the branch count.

  The limit is set by compile *time*, not by normalization. Normalizing 1024
  branches takes single digit milliseconds; classifying, generating and escaping
  them costs super-linearly — measured end to end at 0.4 s for 64 branches,
  2.1 s for 256 and 32 s for 1024. #{@max_branches} keeps the worst case a
  single rule can impose on a build to a couple of seconds.

  Negation is not a source of growth: `not` of a DNF of `n` branches is a single
  branch of `n` literals, each of them a `Rete.IR.CompoundNegation` (or a plain
  negation, when the branch is one literal wide). That is why `xnor` over eight
  arguments, which used to distribute into 5282 branches, is now one branch of
  eight compound negations.
  """

  alias Rete.IR

  @typedoc """
  The internal boolean tree normalization works on.

  `{:gate, gate, args}` nodes are the `Rete.IR.Gate` placeholders; `to_dnf/1`
  rewrites them on the way down. `:not` is always unary here - an n-ary `not`
  gate is the negation of the conjunction of its arguments.
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

  # and(a, b, ...): the cartesian join of the branches, the one step that can
  # explode, so it is the one step that is size checked.
  defp conjoin(gate, args), do: product(gate, length(args), Enum.map(args, &to_dnf/1))

  # or(a, b, ...): concatenation. It cannot multiply, but it can still
  # accumulate past the limit, so it is checked too.
  defp disjoin(gate, args) do
    clauses = args |> Enum.map(&to_dnf/1) |> Enum.concat()
    check_size!(gate, length(args), length(clauses))
    clauses
  end

  # or( and(a1, !a2, !a3), and(!a1, a2, !a3), and(!a1, !a2, a3) )
  #
  # Every negated argument contributes exactly one branch, so the result is at
  # most the sum of the argument branch counts: `xor` does not explode.
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

  # Stops multiplying as soon as the limit is passed, so a pathological input is
  # rejected instead of being counted exactly.
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
  # Every negated clause is at most one branch wide - a single literal, or a
  # single compound negation - so the conjunction of them is at most one branch
  # too. Negation can therefore never grow the DNF and needs no size check.
  defp negate(clauses) do
    Enum.reduce(clauses, [[]], fn clause, acc ->
      negated = negate_clause(clause)
      for kept <- acc, addition <- negated, do: kept ++ addition
    end)
  end

  # The negation of one conjunction of literals, as a DNF of at most one branch.
  # This is where de Morgan stops: a conjunction of two or more literals is
  # negated as a whole, not distributed.
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

  # Drops literals that repeat an earlier literal of the same conjunction, and
  # rejects the conjunction outright when it holds both a literal and its
  # negation.
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

  # Identity of a literal, used to spot repetitions and contradictions. It is
  # derived from what a condition compiles to - its type, its bindings and its
  # expression codes - and never from `:__ast__`, whose metadata differs between
  # two occurrences of the same condition written on different lines.
  #
  # A compound negation keys on its whole inner conjunction. Nothing is the
  # opposite of it: its complement is a conjunction, not a literal, so it can
  # only ever match another compound negation over the same conjunction.
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
