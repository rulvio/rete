defmodule Rete.DSL.Vars do
  @moduledoc """
  Scope aware variable analysis for DSL fragments.

  **Internal.** Two questions with different answers:

    * `pattern_vars/1` — what does this *pattern* bind? The variables a condition
      contributes to the token.
    * `read_vars/1` — what does this *expression* read from its enclosing scope? Decides
      whether a guard is local to its condition or needs a join filter.

  Both are scope aware, which a plain `Macro.prewalk/3` is not. A traversal collecting
  every `{name, meta, nil}` node would report the parameter of `fn v -> v > 0 end`, a
  comprehension generator, a `case` clause head and the `binary` in `<<rest::binary>>` as
  bound by the rule. A spurious name is not in the condition's own bindings, so the guard
  would be judged non-local, lifted into a join filter and destructured from a token that
  can never carry it. The rule would then never fire.
  """

  @typedoc "A variable name."
  @type name :: atom()

  @typedoc "A set of variable names that are bound in the current scope."
  @type scope :: MapSet.t(name())

  # ---------------------------------------------------------------------------
  # patterns
  # ---------------------------------------------------------------------------

  @doc """
  The variables a pattern binds, as `%{name => variable_ast}`.

  Not bindings, and therefore excluded:

    * `^pinned` — a match against an existing value
    * `@attr` — a compile time constant
    * `_` and `_`-prefixed names — explicitly discarded by the author
    * the modifier side of `::` in a bitstring — `binary` in `<<rest::binary>>`
      is a type, not a variable
    * map and struct keys — a pattern key is a literal or a pin, never a binder

  ## Examples

      iex> Rete.DSL.Vars.pattern_vars(quote(do: {:order, id, _ignored})) |> Map.keys()
      [:id]

      iex> Rete.DSL.Vars.pattern_vars(quote(do: <<a::8, rest::binary>>)) |> Map.keys() |> Enum.sort()
      [:a, :rest]
  """
  @spec pattern_vars(Macro.t()) :: %{name() => Macro.t()}
  def pattern_vars(ast), do: pattern_vars(ast, %{})

  # One clause per quoted form. The branch count is the number of shapes an Elixir
  # pattern can take, which restructuring does not reduce.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp pattern_vars(ast, acc) do
    case ast do
      # A pinned value matches against something that already exists.
      {:^, _, _} ->
        acc

      {:@, _, _} ->
        acc

      # `rest :: binary` — only the left side binds. The right side is a type specifier
      # whose atoms are modifier names, not variables.
      {:"::", _, [left, _spec]} ->
        pattern_vars(left, acc)

      # Struct pattern: only the map part can bind.
      {:%, _, [_alias, map]} ->
        pattern_vars(map, acc)

      # Map pattern: keys are literals or pins, only values bind.
      {:%{}, _, pairs} when is_list(pairs) ->
        Enum.reduce(pairs, acc, fn
          {_key, value}, acc -> pattern_vars(value, acc)
          other, acc -> pattern_vars(other, acc)
        end)

      {name, meta, context} when is_atom(name) and is_atom(context) ->
        if discarded?(name), do: acc, else: Map.put_new(acc, name, {name, meta, context})

      {left, _meta, args} when is_list(args) ->
        Enum.reduce(args, pattern_vars(left, acc), &pattern_vars/2)

      {left, right} ->
        pattern_vars(right, pattern_vars(left, acc))

      list when is_list(list) ->
        Enum.reduce(list, acc, &pattern_vars/2)

      _literal ->
        acc
    end
  end

  @doc """
  `pattern_vars/1` as a sorted list of names.
  """
  @spec pattern_var_names(Macro.t()) :: [name()]
  def pattern_var_names(ast), do: ast |> pattern_vars() |> Map.keys() |> Enum.sort()

  # ---------------------------------------------------------------------------
  # expressions
  # ---------------------------------------------------------------------------

  @doc """
  The variables an expression reads from its enclosing scope, as a `MapSet`.

  Excluded: `^pinned` and `@attr` (compile time constants), the anonymous `_`,
  and anything bound by a construct *inside* the expression — `fn` parameters,
  `for`/`with` generators, `case`/`receive`/`try` clause heads, and `=` earlier
  in the same block.

  `_`-prefixed names are deliberately kept. `_t` in `amt > _t` genuinely is a
  read of `_t`; treating it as local would inline it into the alpha function,
  where it is not in scope.

  ## Examples

      iex> Rete.DSL.Vars.read_vars(quote(do: amt > t)) |> Enum.sort()
      [:amt, :t]

      iex> Rete.DSL.Vars.read_vars(quote(do: Enum.all?(xs, fn v -> v > 0 end))) |> Enum.sort()
      [:xs]
  """
  @spec read_vars(Macro.t() | nil) :: scope()
  def read_vars(nil), do: MapSet.new()
  def read_vars(ast), do: free(ast, MapSet.new())

  @doc """
  `read_vars/1` as a sorted list of names.
  """
  @spec read_var_names(Macro.t() | nil) :: [name()]
  def read_var_names(ast), do: ast |> read_vars() |> Enum.sort()

  # `bound` is the set of names a construct inside the expression already introduced. A
  # read of one of those is not a read of the rule's scope. As with `pattern_vars/2`, the
  # branch count is the number of quoted forms that scope a variable.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp free(ast, bound) do
    case ast do
      {:^, _, _} ->
        MapSet.new()

      {:@, _, _} ->
        MapSet.new()

      # Anonymous functions: each clause binds its own parameters.
      {:fn, _, clauses} when is_list(clauses) ->
        union(clauses, &clause_free(&1, bound))

      # Comprehensions and `with`: generators bind left to right, and their bindings are
      # visible to later clauses and to the body.
      {op, _, args} when op in [:for, :with] and is_list(args) ->
        comprehension_free(args, bound)

      {:case, _, [subject, blocks]} ->
        MapSet.union(free(subject, bound), blocks_free(blocks, bound))

      # `cond` clause heads are conditions, not patterns, so they read rather than bind.
      # The pattern path would treat every name in them as introduced here.
      {:cond, _, [blocks]} ->
        union(clauses_of(blocks), fn
          {:->, _, [head, body]} -> MapSet.union(free(head, bound), free(body, bound))
          other -> free(other, bound)
        end)

      {:receive, _, [blocks]} ->
        blocks_free(blocks, bound)

      {:try, _, [blocks]} ->
        blocks_free(blocks, bound)

      # A block threads bindings: `a = f(x)` makes `a` local to what follows.
      {:__block__, _, exprs} when is_list(exprs) ->
        {free, _bound} =
          Enum.reduce(exprs, {MapSet.new(), bound}, fn expr, {acc, bound} ->
            {MapSet.union(acc, free(expr, bound)), MapSet.union(bound, binds(expr))}
          end)

        free

      # A match in expression position reads its right side and binds its left.
      {:=, _, [left, right]} ->
        MapSet.union(free_pattern_reads(left, bound), free(right, bound))

      # `rest :: binary` — the modifier side names types, but a modifier may still call
      # out to a variable, as in `x :: size(n)`.
      {:"::", _, [left, spec]} ->
        MapSet.union(free(left, bound), spec_free(spec, bound))

      {:_, _, context} when is_atom(context) ->
        MapSet.new()

      {name, _, context} when is_atom(name) and is_atom(context) ->
        if MapSet.member?(bound, name), do: MapSet.new(), else: MapSet.new([name])

      # A call: the callee of `foo(1)` is a name, not a variable read.
      {name, _, args} when is_atom(name) and is_list(args) ->
        union(args, &free(&1, bound))

      {left, _, args} when is_list(args) ->
        MapSet.union(free(left, bound), union(args, &free(&1, bound)))

      {left, right} ->
        MapSet.union(free(left, bound), free(right, bound))

      list when is_list(list) ->
        union(list, &free(&1, bound))

      _literal ->
        MapSet.new()
    end
  end

  # A `->` clause. The head binds for the body, and a `when` guard in the head reads both
  # the newly bound names and the enclosing scope.
  defp clause_free({:->, _, [head, body]}, bound) do
    {patterns, guard} = split_when(head)
    introduced = union(patterns, &MapSet.new(Map.keys(pattern_vars(&1))))
    inner = MapSet.union(bound, introduced)

    [
      union(patterns, &free_pattern_reads(&1, bound)),
      free(guard, inner),
      free(body, inner)
    ]
    |> Enum.reduce(&MapSet.union/2)
  end

  defp clause_free(other, bound), do: free(other, bound)

  defp split_when([{:when, _, args}]) when is_list(args) do
    {patterns, [guard]} = Enum.split(args, length(args) - 1)
    {patterns, guard}
  end

  defp split_when(head) when is_list(head), do: {head, nil}
  defp split_when(head), do: {[head], nil}

  # `for`/`with`: `pat <- enum` binds `pat` for every later clause and the body.
  defp comprehension_free(args, bound) do
    {free, _bound} =
      Enum.reduce(args, {MapSet.new(), bound}, fn clause, {acc, bound} ->
        case clause do
          {op, _, [pattern, source]} when op in [:<-, :<<>>] ->
            acc = MapSet.union(acc, free(source, bound))
            acc = MapSet.union(acc, free_pattern_reads(pattern, bound))
            {acc, MapSet.union(bound, MapSet.new(Map.keys(pattern_vars(pattern))))}

          blocks when is_list(blocks) ->
            {MapSet.union(acc, blocks_free(blocks, bound)), bound}

          other ->
            {MapSet.union(acc, free(other, bound)), bound}
        end
      end)

    free
  end

  # `[do: ..., else: [clauses], rescue: [clauses], after: ...]`
  defp blocks_free(blocks, bound) when is_list(blocks) do
    union(blocks, fn
      {_key, value} -> body_free(value, bound)
      other -> body_free(other, bound)
    end)
  end

  defp blocks_free(other, bound), do: free(other, bound)

  defp body_free(clauses, bound) when is_list(clauses) do
    union(clauses, fn
      {:->, _, _} = clause -> clause_free(clause, bound)
      other -> free(other, bound)
    end)
  end

  defp body_free(other, bound), do: free(other, bound)

  defp clauses_of(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      {_key, clauses} when is_list(clauses) -> clauses
      {_key, other} -> [other]
      other -> [other]
    end)
  end

  defp clauses_of(other), do: [other]

  # A pattern binds rather than reads, but it can still read `^x` and the argument of a
  # modifier such as `size(n)`.
  defp free_pattern_reads(ast, bound) do
    case ast do
      {:^, _, [inner]} ->
        free(inner, bound)

      {:"::", _, [left, spec]} ->
        MapSet.union(free_pattern_reads(left, bound), spec_free(spec, bound))

      {_name, _, context} when is_atom(context) ->
        MapSet.new()

      {left, _, args} when is_list(args) ->
        MapSet.union(free_pattern_reads(left, bound), union(args, &free_pattern_reads(&1, bound)))

      {left, right} ->
        MapSet.union(free_pattern_reads(left, bound), free_pattern_reads(right, bound))

      list when is_list(list) ->
        union(list, &free_pattern_reads(&1, bound))

      _ ->
        MapSet.new()
    end
  end

  # A bitstring type specifier: `binary`, `integer-signed`, `size(n)`. Bare atoms are
  # modifier names. Only a call such as `size(n)` reads a variable.
  defp spec_free(spec, bound) do
    case spec do
      {:-, _, [left, right]} ->
        MapSet.union(spec_free(left, bound), spec_free(right, bound))

      {name, _, context} when is_atom(name) and is_atom(context) ->
        MapSet.new()

      {name, _, args} when is_atom(name) and is_list(args) ->
        union(args, &free(&1, bound))

      other ->
        free(other, bound)
    end
  end

  # The names an expression introduces into the scope that follows it.
  defp binds({:=, _, [left, _right]}), do: MapSet.new(Map.keys(pattern_vars(left)))
  defp binds(_), do: MapSet.new()

  defp union(enum, fun) do
    Enum.reduce(enum, MapSet.new(), fn item, acc -> MapSet.union(acc, fun.(item)) end)
  end

  @doc """
  Whether a name is explicitly discarded, `_` or `_`-prefixed.
  """
  @spec discarded?(name()) :: boolean()
  def discarded?(name) when is_atom(name) do
    case Atom.to_string(name) do
      "_" <> _ -> true
      _ -> false
    end
  end
end
