defmodule Rete.Compiler.Negation do
  @moduledoc """
  Turns a `Rete.IR.CompoundNegation` into something a Rete network can express.

  A negation node watches one condition and propagates its token while nothing
  matches. It cannot watch a *conjunction*: "no `x` has both an order and a
  refund" is not a statement about orders, nor about refunds, but about pairs.

  De Morgan does not rescue it either. `not(and(a, b)) = or(not a, not b)` is
  sound propositionally, but the conjuncts of a rule condition share
  existentially quantified variables, so with orders `{1}` and refunds `{2}`
  the original is true and the rewrite is false. `Rete.DSL.Normalize` therefore
  refuses to apply it and leaves a `CompoundNegation` behind for this module.

  ## The rewrite

  The conjunction is lifted into a generated helper production that inserts a
  **marker fact** whenever it matches, and the compound negation becomes an
  ordinary negation of that marker:

      defrule clean({:customer, cid}, {:nand, [{:order, cid}, {:refund, cid}]})

      # becomes, in effect
      defrule clean__neg_1({:customer, cid}, {:order, cid}, {:refund, cid}) do
        {:"clean__neg_1", %{cid: cid}}          # the marker
      end
      defrule clean({:customer, cid}, {:not, [{:"clean__neg_1", cid}]})

  Three things make this correct rather than merely plausible.

  ### The marker is scoped to its bindings

  The marker carries the ancestor bindings the negated conjunction actually
  joins on, and the negation matches on them. Without that, one customer having
  both an order and a refund would suppress the rule for *every* customer: the
  negation would be asking "does any match exist at all" instead of "does one
  exist for this `cid`". Clara hit exactly this as issue 304.

  Only bindings the conjunction *uses* are carried. Including every ancestor
  binding would split the marker into needlessly many groups and stop it being
  shared between tokens that the negation cannot tell apart.

  ### The helper repeats the preceding conditions

  Its left hand side is the conditions before the negation, then the
  conjunction. The prefix is what binds the ancestor variables, so without it
  the marker would have nothing to carry — and it means the marker is only
  produced for binding groups that actually reached the negation.

  ### The helper fires first

  A generated production gets a higher `:internal_salience` than anything a user
  can write. If the rule that negates the marker ran first it would observe an
  absence that simply had not been computed yet, fire, and then be retracted by
  truth maintenance once the marker arrived — a visible spurious activation.

  `:internal_salience` is the **nesting depth**, not a flag, because extraction
  chains. In `{:nand, [b, {:nand, [c, d]}]}` the inner conjunction is extracted
  first and the outer helper negates *its* marker, so the outer helper stands to
  the inner one exactly as the user's rule stands to it. Ranking both at 1 would
  reproduce the bug one level in. Depth orders inner above outer above the rule:
  2, then 1, then 0.

  ## Why closures

  Extraction runs when the network is built, long after macro expansion, so a
  helper's expressions cannot be generated as named functions in the ruleset
  module the way `Rete.DSL.Codegen` does it. They are plain closures instead,
  wrapped in `Rete.IR.Expr` with deterministic `:code`s so that node sharing and
  the alpha index treat them like any other expression.
  """

  alias Rete.DSL.Codegen
  alias Rete.IR

  @typedoc "A production and the helper productions extracted out of it."
  @type extraction :: {IR.Production.t(), [IR.Production.t()]}

  @doc """
  Rewrites every compound negation in a production.

  Returns the rewritten production and the helper productions it generated, in
  the order they must be added to the network. Helpers are extracted depth
  first, so a compound negation nested inside another is itself extracted and
  appears before the helper that negates it.

  A production with no compound negation is returned unchanged with `[]`.
  """
  @spec extract(IR.Production.t()) :: extraction()
  def extract(%IR.Production{lhs: lhs} = production) do
    {lhs, helpers, _counter} = walk(lhs, production, [], [], 1, 1)
    {%IR.Production{production | lhs: lhs}, Enum.reverse(helpers)}
  end

  # Walks the LHS in order, carrying the conditions seen so far (the prefix a
  # helper needs) and a counter that makes generated names unique and stable.
  defp walk(lhs, production, prefix, helpers, counter, depth) do
    Enum.reduce(lhs, {[], helpers, counter}, fn element, {done, helpers, counter} ->
      prefix = prefix ++ Enum.reverse(done)

      case element do
        %IR.CompoundNegation{} = compound ->
          {negation, helpers, counter} =
            rewrite(compound, production, prefix, helpers, counter, depth)

          {[negation | done], helpers, counter}

        {:or, branches} ->
          # Each branch is its own path, so each carries the same prefix and
          # extracts independently.
          {branches, helpers, counter} =
            Enum.reduce(branches, {[], helpers, counter}, fn branch, {acc, helpers, counter} ->
              {branch, helpers, counter} =
                walk(branch, production, prefix, helpers, counter, depth)

              {[branch | acc], helpers, counter}
            end)

          {[{:or, Enum.reverse(branches)} | done], helpers, counter}

        element ->
          {[element | done], helpers, counter}
      end
    end)
    |> then(fn {done, helpers, counter} -> {Enum.reverse(done), helpers, counter} end)
  end

  defp rewrite(
         %IR.CompoundNegation{conditions: conditions},
         production,
         prefix,
         helpers,
         counter,
         depth
       ) do
    # A nested compound negation inside the conjunction is extracted first, so
    # that the helper's own LHS contains only things the network can express.
    {conditions, helpers, counter} =
      walk(conditions, production, prefix, helpers, counter, depth + 1)

    name = helper_name(production, counter)
    carried = carried_bindings(conditions, prefix)

    helper = %IR.Production{
      name: name,
      type: :rule,
      hash: :erlang.phash2({production.module, production.name, production.hash, counter}),
      opts: helper_opts(production, depth),
      bind: prefix_bindings(prefix),
      lhs: prefix ++ conditions,
      rhs: marker_rhs(name, carried),
      module: production.module,
      __ast__: nil
    }

    {%IR.Negation{condition: marker_condition(name, carried)}, [helper | helpers], counter + 1}
  end

  # Deterministic across compilations and unique across modules: two rules with
  # the same name in different modules, and two compound negations in one rule,
  # all get distinct markers. Nothing here may use make_ref or a time seed —
  # node sharing depends on these being reproducible.
  defp helper_name(%IR.Production{module: module, name: name}, counter) do
    :"#{inspect(module)}.#{name}__neg_#{counter}"
  end

  # The ancestor bindings the negated conjunction actually reads. Anything the
  # conjunction binds for itself is not carried: it is existentially quantified
  # inside the negation and means nothing outside it.
  defp carried_bindings(conditions, prefix) do
    available = prefix_bindings(prefix)
    set = MapSet.new(available)

    conditions
    |> Enum.flat_map(&joined_vars(&1, available))
    |> Enum.filter(&MapSet.member?(set, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # An equality key is in `:join_bind`; a variable a cross-condition guard reads
  # from the token side is **not** (see docs/design/w1-ir.md section 2), and it
  # is an ancestor binding the conjunction depends on just the same. Missing one
  # makes the marker global, so a single binding group that has a match
  # suppresses the rule for every group — Clara's issue 304 again, reached
  # through a guard instead of through a shared pattern variable.
  defp joined_vars(%IR.Fact{} = fact, available),
    do: (fact.join_bind || []) ++ filter_vars(fact.join_filter, fact.type, available)

  defp joined_vars(%IR.Coll{} = coll, available),
    do: (coll.join_bind || []) ++ filter_vars(coll.join_filter, coll.type, available)

  defp joined_vars(%IR.Test{bind: bind}, _available), do: bind || []

  defp joined_vars(%IR.Negation{condition: condition}, available),
    do: joined_vars(condition, available)

  defp joined_vars(%IR.CompoundNegation{conditions: cs}, available),
    do: Enum.flat_map(cs, &joined_vars(&1, available))

  defp joined_vars({:or, branches}, available),
    do: Enum.flat_map(branches, &Enum.flat_map(&1, fn c -> joined_vars(c, available) end))

  defp joined_vars(_element, _available), do: []

  # Extraction runs at build time, long after `Rete.IR.escape/1` dropped the
  # filter's AST, so the only record of what it reads is its `:code` — whose
  # shape W1 fixes as `join_<type>_bind_<v1>_<v2>_..._expr_<hash>`, with the
  # variables of *both* sides sorted (docs/design/w1-ir.md section 5). We ask
  # which of the ancestor bindings that code mentions.
  #
  # Both approximations here are deliberately one sided. A code we cannot read
  # falls back to every ancestor binding, and the membership test matches on `_`
  # delimited boundaries, so a variable whose name is a segment of another one
  # is over-reported. Carrying a binding the conjunction does not read only
  # splits the marker into more groups than necessary; failing to carry one it
  # does read is a wrong answer.
  defp filter_vars(nil, _type, _available), do: []

  defp filter_vars(%IR.Expr{code: code}, type, available) do
    case filter_var_segment(code, type) do
      nil -> available
      segment -> Enum.filter(available, &mentions?(segment, &1))
    end
  end

  defp filter_var_segment(code, type) do
    prefix = "join_" <> Codegen.type_code(type) <> "_bind_"
    string = Atom.to_string(code)

    with true <- String.starts_with?(string, prefix),
         rest = binary_part(string, byte_size(prefix), byte_size(string) - byte_size(prefix)),
         [_whole, segment] <- Regex.run(~r/\A(.+)_expr_\d+\z/s, rest) do
      segment
    else
      _ -> nil
    end
  end

  defp mentions?(segment, var),
    do: String.contains?("_" <> segment <> "_", "_" <> Atom.to_string(var) <> "_")

  defp prefix_bindings(prefix) do
    {guaranteed, optional} = IR.lhs_bindings(prefix)
    Enum.sort(guaranteed ++ optional)
  end

  # The helper inherits the user's salience so it stays in the same ordering
  # band as the rule it serves, and outranks it only on the internal tier.
  defp helper_opts(%IR.Production{opts: opts}, depth) do
    opts
    |> Kernel.||([])
    |> Keyword.take([:salience])
    |> Keyword.put(:internal_salience, depth)
    |> Keyword.put(:generated, true)
  end

  # `(hash, bindings) -> marker`. The marker's type is the generated name, so
  # the alpha index routes it to exactly one place and the alpha below needs no
  # name check of its own.
  defp marker_rhs(name, carried) do
    fn _hash, bindings -> {name, Map.take(bindings, carried)} end
  end

  defp marker_condition(name, carried) do
    %IR.Fact{
      type: name,
      fact_binding: nil,
      bind: carried,
      alpha: marker_alpha(name, carried),
      join_filter: nil,
      join_bind: carried,
      new_bind: [],
      __ast__: nil
    }
  end

  defp marker_alpha(name, _carried) do
    %IR.Expr{
      code: :"neg_marker_#{name}",
      name: :"__neg_marker_#{name}__",
      arity: 1,
      kind: :alpha,
      fun: fn
        {^name, bindings} when is_map(bindings) -> bindings
        _ -> nil
      end,
      __ast__: nil
    }
  end

  @doc """
  Whether a production was generated by extraction rather than written.
  """
  @spec generated?(IR.Production.t()) :: boolean()
  def generated?(%IR.Production{opts: opts}), do: Keyword.get(opts || [], :generated, false)
end
