defmodule Rete.Compiler.Negation do
  @moduledoc """
  Turns a `Rete.IR.CompoundNegation` into something a Rete network can express.

  **Internal.** A negation node watches one condition, and propagates its token while
  nothing matches. It cannot watch a *conjunction*. De Morgan's law does not rescue it
  here: the conjuncts share existentially quantified variables. With orders `{1}` and
  refunds `{2}`, "no `x` has both" is true, and the rewrite is false.

  So the conjunction is lifted into a generated helper that inserts a **marker fact**, and
  the compound negation becomes an ordinary negation of that marker:

      defrule clean({:customer, cid}, {:nand, [{:order, cid}, {:refund, cid}]})

      # becomes, in effect
      defrule clean__neg_1({:customer, cid}, {:order, cid}, {:refund, cid}) do
        {:"clean__neg_1", %{cid: cid}}
      end
      defrule clean({:customer, cid}, {:not, [{:"clean__neg_1", cid}]})

  Three things make that correct.

  The marker **carries the bindings** the conjunction joins on. Otherwise, one customer
  with both an order and a refund would suppress the rule for every customer. The helper
  **repeats the preceding conditions**, which is what binds those variables. The helper
  also **fires first**, through an `:internal_salience` set to the nesting depth. So
  extraction chains correctly, and the negating rule never observes an absence that had
  merely not been computed yet.

  A helper's expressions are plain closures, because extraction runs at build time, long
  after macro expansion. See `docs/design/network.md` §6.
  """

  alias Rete.DSL.Codegen
  alias Rete.IR

  @typedoc "A production and the helper productions extracted out of it."
  @type extraction :: {IR.Production.t(), [IR.Production.t()]}

  @doc """
  Rewrites every compound negation in a production.

  Returns the rewritten production, and the helpers it generated, in the order they must
  be added to the network. Extraction runs depth-first, so a compound negation nested
  inside another appears before the helper that negates it.

  A production with no compound negation comes back unchanged, with `[]`.
  """
  @spec extract(IR.Production.t()) :: extraction()
  def extract(%IR.Production{lhs: lhs} = production) do
    {lhs, helpers, _counter} = walk(lhs, production, [], [], 1, 1)
    {%IR.Production{production | lhs: lhs}, Enum.reverse(helpers)}
  end

  # Carries the conditions seen so far — the prefix a helper needs — and a counter that
  # makes generated names unique and stable.
  defp walk(lhs, production, prefix, helpers, counter, depth) do
    Enum.reduce(lhs, {[], helpers, counter}, fn element, {done, helpers, counter} ->
      prefix = prefix ++ Enum.reverse(done)

      case element do
        %IR.CompoundNegation{} = compound ->
          {negation, helpers, counter} =
            rewrite(compound, production, prefix, helpers, counter, depth)

          {[negation | done], helpers, counter}

        {:or, branches} ->
          # Each branch is its own path, so each carries the same prefix.
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
    # A nested compound negation is extracted first, so the helper's own LHS holds only
    # what the network can express.
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

  # Must be deterministic across compilations, since node sharing depends on it. Never
  # use make_ref or a time seed here.
  defp helper_name(%IR.Production{module: module, name: name}, counter) do
    :"#{inspect(module)}.#{name}__neg_#{counter}"
  end

  # The ancestor bindings the conjunction reads. What it binds for itself is
  # existentially quantified inside the negation, and it means nothing outside it.
  defp carried_bindings(conditions, prefix) do
    available = prefix_bindings(prefix)
    set = MapSet.new(available)

    conditions
    |> Enum.flat_map(&joined_vars(&1, available))
    |> Enum.filter(&MapSet.member?(set, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A variable a cross-condition guard reads from the token side is not in `:join_bind`,
  # but it is an ancestor binding just the same. Missing one makes the marker global. So
  # one binding group with a match would suppress the rule for every group.
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

  # `Rete.IR.escape/1` dropped the filter's AST, so the only record of what it reads is
  # its `:code`. Both approximations here over-report on purpose. Carrying a binding the
  # conjunction does not read only splits the marker into more groups. Missing one it
  # does read gives a wrong answer instead.
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

  # The helper inherits the user's salience. So it stays in the same ordering band, and
  # it outranks the rule only on the internal tier.
  defp helper_opts(%IR.Production{opts: opts}, depth) do
    opts
    |> Kernel.||([])
    |> Keyword.take([:salience])
    |> Keyword.put(:internal_salience, depth)
    |> Keyword.put(:generated, true)
  end

  # `(hash, bindings) -> marker`. The marker's type is the generated name, so the alpha
  # index routes it to exactly one place.
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

  # `share` is stated rather than left to the default, because this is the one
  # expression built at *build* time. There is no AST to read and no environment to read
  # it against, and the code is derived from a name that carries no module. Two modules
  # that each extract a compound negation from a rule of the same name reach the same
  # code, so this keeps them on separate nodes.
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
      share: false,
      __ast__: nil
    }
  end

  @doc """
  Whether a production was generated by extraction rather than written.
  """
  @spec generated?(IR.Production.t()) :: boolean()
  def generated?(%IR.Production{opts: opts}), do: Keyword.get(opts || [], :generated, false)
end
