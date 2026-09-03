defmodule Rete.DSL.Bindings do
  @max_elements 1024

  @moduledoc """
  Binding classification and guard splitting.

  **Internal.** This runs between gate normalization and code generation. It walks the
  LHS **in order**, carrying the variables bound so far. For every fact or collection
  condition, it computes three things: `:join_bind` (bound upstream already — the hash
  join keys), `:new_bind` (introduced here, which for a collection decides the
  empty-collection semantics), and `:join_filter` (the part of the guard a single fact
  cannot decide). `join_bind ++ new_bind == bind` always holds.

  The compiler splits a per-condition guard conjunct by conjunct, over the top-level
  `and`/`&&` chain. So `{:order, id, amt} when amt > 0 and amt > limit` puts `amt > 0` in
  the alpha, and `amt > limit` in the join filter. A guard that cannot be decomposed goes
  to the join filter **whole**. Each half is rejoined with the operators it was written
  with. `and` weakens to `&&` once a conjunct has been lifted out, because `and` is
  strict in its left operand.

  Every branch of a disjunction is a distinct path through the beta graph. So each
  branch is classified in **its own** binding context, and so is everything downstream.
  When the branches classify the tail differently, the tail is **absorbed** into them,
  bounded at #{@max_elements} LHS elements.

  Raises at compile time for a guard variable no condition binds on a path, a collection
  guard reading its own collection binding, and a right hand side reading a
  collection-local variable. See `docs/design/ir.md` §7.
  """

  alias Rete.DSL.Codegen
  alias Rete.DSL.Parser
  alias Rete.DSL.Vars
  alias Rete.IR

  @typedoc "The set of variable names bound at a point in the LHS."
  @type bound :: MapSet.t(atom())

  @typedoc "A condition that binds variables from a fact."
  @type binder :: IR.Fact.t() | IR.Coll.t()

  @doc """
  Classifies every condition of a production and splits its guards.

  Returns the production with `:join_bind`, `:new_bind`, and `:join_filter` filled in on
  every `Rete.IR.Fact` and `Rete.IR.Coll`. It rebuilds alpha expressions wherever a guard
  was partly or wholly lifted into a join filter.

  `env` is the `Macro.Env` of the `defrule`/`defquery` call. It is needed to re-expand
  struct aliases when an alpha is rebuilt.
  """
  @spec classify(Parser.env(), IR.Production.t()) :: IR.Production.t()
  def classify(env, %IR.Production{} = production) do
    production = mark_inert(production)
    {lhs, _bound} = classify_elements(env, production.lhs, MapSet.new())
    production = %IR.Production{production | lhs: lhs}

    check_inert_reads!(production)
    production
  end

  # Reading a collection-local variable outside its collection cannot work. Every
  # gathered fact has its own value. Without this check, the module still fails to
  # compile — but with Elixir's "undefined variable" error pointing at a generated
  # function name instead.
  defp check_inert_reads!(%IR.Production{__ast__: %{body: body}} = production) do
    {guaranteed, optional} = IR.lhs_bindings(production.lhs)
    available = MapSet.new(guaranteed ++ optional)
    reads = Vars.read_vars(body)

    for {var, coll} <- inert_bindings(production.lhs),
        MapSet.member?(reads, var),
        not MapSet.member?(available, var) do
      raise ArgumentError, inert_read_message(production, var, coll)
    end

    :ok
  end

  defp check_inert_reads!(_production), do: :ok

  defp inert_read_message(production, var, coll) do
    shown = describe_coll(coll)

    "the right hand side of `#{production.name}` reads `#{var}`, which is local to " <>
      "the collection `#{shown}`.\n\n" <>
      "Every fact the collection gathers has its own `#{var}`, so there is no one " <>
      "value to bind outside it. `#{var}` is local because no other condition " <>
      "matches on it - only a pattern counts, not a guard and not the right hand " <>
      "side.\n\n" <>
      "Either add a condition that matches on it, so the collection groups by it:\n\n" <>
      "    #{shown}, {:some_fact, #{var}}\n\n" <>
      "or collect everything and group in the right hand side with " <>
      "Enum.group_by/2."
  end

  defp inert_bindings(lhs) do
    Enum.flat_map(lhs, fn
      {:or, branches} -> Enum.flat_map(branches, &inert_bindings/1)
      %IR.Coll{inert: inert} = coll -> Enum.map(inert || [], &{&1, coll})
      _element -> []
    end)
  end

  defp describe_coll(%IR.Coll{coll_binding: nil, __ast__: %{source: source}}),
    do: Macro.to_string(source)

  defp describe_coll(%IR.Coll{coll_binding: name, __ast__: %{source: source}}),
    do: "#{name} = #{Macro.to_string(source)}"

  defp describe_coll(%IR.Coll{coll_binding: name}), do: to_string(name)

  @doc """
  Marks the variables that are local to a collection.

  Elixir fuses binding with constraining. So `os = [{:order, cid, amt} when amt > lim]`
  reads as introducing `amt`. A collection that introduces a variable groups by it —
  which would collect one singleton group per distinct amount, instead of every order
  over the limit.

  The rule: **a collection's pattern variable participates only if another condition also
  matches on it.** Otherwise it is inert, meaning local to the collection. An inert
  variable constrains which facts are gathered. It groups nothing, and it binds nothing
  downstream.

  Only another condition's **pattern** counts — never a guard, and never the right hand
  side. So `os = [{:order, cid, day, _amt}]`, with `day` read only in the body, makes
  `day` inert. Reading it outside the collection is a compile error. Group by adding
  `{:holiday, day}` instead, or collect everything and use `Enum.group_by/2` in the body.

  A variable an *earlier* condition bound is a join key, and it is never inert. See
  `docs/design/ir.md` §2.
  """
  @spec mark_inert(IR.Production.t()) :: IR.Production.t()
  def mark_inert(%IR.Production{lhs: lhs} = production) do
    %IR.Production{production | lhs: apply_inert(lhs, [], element_sites(lhs, []))}
  end

  # Every *pattern* in the LHS, tagged by path. This lets a collection ask whether
  # another condition matches on a variable. Guards are not sites — reading is not
  # joining.
  defp element_sites(elements, path) do
    elements
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, index} -> element_site(element, path ++ [index]) end)
  end

  defp element_sites_in({:or, branches}, path) do
    branches
    |> Enum.with_index()
    |> Enum.flat_map(fn {branch, index} -> element_sites(branch, path ++ [index]) end)
  end

  defp element_site({:or, _} = disjunction, path), do: element_sites_in(disjunction, path)

  # A negation binds nothing downstream, so matching on a variable inside one is not a
  # join.
  defp element_site(%IR.Negation{}, _path), do: []
  defp element_site(%IR.CompoundNegation{}, _path), do: []

  # The rule-level `when` reads bindings. It does not match on them.
  defp element_site(%IR.Test{}, _path), do: []

  defp element_site(%{__ast__: %{pattern: pattern}}, path) do
    [{path, MapSet.new(Map.keys(Vars.pattern_vars(pattern)))}]
  end

  defp element_site(_element, _path), do: []

  defp apply_inert(elements, path, sites) do
    elements
    |> Enum.with_index()
    |> Enum.map(fn {element, index} -> put_inert(element, path ++ [index], sites) end)
  end

  defp put_inert({:or, branches}, path, sites) do
    {:or,
     branches
     |> Enum.with_index()
     |> Enum.map(fn {branch, index} -> apply_inert(branch, path ++ [index], sites) end)}
  end

  defp put_inert(%IR.Coll{bind: bind} = coll, path, sites) do
    outside =
      sites
      |> Enum.reject(fn {site, _vars} -> site == path end)
      |> Enum.reduce(MapSet.new(), fn {_site, vars}, acc -> MapSet.union(acc, vars) end)

    %IR.Coll{coll | inert: Enum.reject(bind || [], &MapSet.member?(outside, &1))}
  end

  defp put_inert(element, _path, _sites), do: element

  @doc """
  Classifies a list of LHS elements against the variables bound before them.

  Returns `{classified_elements, bound_after}`. The returned list is not necessarily as
  long as the one given. The elements that follow a disjunction, whose branches classify
  them differently, get absorbed into those branches — see the moduledoc.

  This is exposed so a caller can classify a fragment, for instance a branch of a
  disjunction.
  """
  @spec classify_elements(Parser.env(), IR.lhs(), bound()) :: {IR.lhs(), bound()}
  def classify_elements(_env, [], bound), do: {[], bound}

  def classify_elements(env, [{:or, branches} | rest], bound) do
    classify_disjunction(env, branches, rest, bound)
  end

  def classify_elements(env, [element | rest], bound) do
    {element, bound} = classify_element(env, element, bound)
    {rest, bound} = classify_elements(env, rest, bound)
    {[element | rest], bound}
  end

  defp classify_element(env, %IR.Fact{} = fact, bound) do
    fact = classify_condition(env, fact, bound)
    {fact, MapSet.union(bound, MapSet.new(IR.bound_vars(fact)))}
  end

  defp classify_element(env, %IR.Coll{} = coll, bound) do
    coll = classify_condition(env, coll, bound)
    {coll, MapSet.union(bound, MapSet.new(IR.bound_vars(coll)))}
  end

  # A negation never matches a fact, so nothing inside it escapes. Its own condition is
  # still classified, because the engine needs the join keys.
  defp classify_element(env, %IR.Negation{condition: condition}, bound) do
    {%IR.Negation{condition: classify_condition(env, condition, bound)}, bound}
  end

  # Same for a compound negation, whose inner conjunction is a small LHS of its own.
  # Its conditions bind each other, and none of them escapes.
  defp classify_element(env, %IR.CompoundNegation{conditions: conditions}, bound) do
    {conditions, _inner} = classify_elements(env, conditions, bound)
    {%IR.CompoundNegation{conditions: conditions}, bound}
  end

  # A test has no fact input, so it binds nothing. Every variable it reads has to be in
  # the token that reaches it.
  defp classify_element(_env, %IR.Test{} = test, bound) do
    check_test_vars!(test, bound)
    {test, bound}
  end

  defp classify_element(_env, %IR.Gate{gate: gate}, _bound) do
    raise ArgumentError,
          "a #{gate} gate reached binding classification; gates must be normalized into " <>
            "plain conditions, negations and disjunctions first"
  end

  defp classify_element(_env, element, _bound) do
    raise ArgumentError,
          "unsupported LHS element for binding classification: " <> inspect(element)
  end

  # --- disjunctions ----------------------------------------------------------

  # `{:or, []}` is *false*, so nothing downstream is reachable. The rest is still
  # classified, because the IR has to be complete.
  defp classify_disjunction(env, [], rest, bound) do
    {rest, bound} = classify_elements(env, rest, bound)
    {[{:or, []} | rest], bound}
  end

  defp classify_disjunction(env, branches, rest, bound) do
    {branches, branch_bounds} =
      branches |> Enum.map(&classify_elements(env, &1, bound)) |> Enum.unzip()

    if rest == [] do
      {[{:or, branches}], intersect(branch_bounds, bound)}
    else
      tails = Enum.map(branch_bounds, &classify_elements(env, rest, &1))
      converge(branches, tails)
    end
  end

  # One shared tail when every path classified it the same way, one per branch otherwise.
  defp converge(branches, [tail | _] = tails) do
    if Enum.all?(tails, &(&1 == tail)) do
      {elements, bound} = tail
      {[{:or, branches} | elements], bound}
    else
      specialized = Enum.zip_with(branches, tails, fn branch, {tail, _} -> branch ++ tail end)
      check_size!(specialized)
      {[{:or, specialized}], intersect(Enum.map(tails, &elem(&1, 1)), MapSet.new())}
    end
  end

  defp intersect([], bound), do: bound
  defp intersect(bounds, _bound), do: Enum.reduce(bounds, &MapSet.intersection/2)

  defp check_size!(branches) do
    count = Enum.sum(Enum.map(branches, &count_elements/1))

    if count > @max_elements do
      raise ArgumentError,
            "binding classification gave up: the branches of a disjunction bind different " <>
              "variables, so every condition after it has to be classified once per branch, " <>
              "and doing that needs #{count} left hand side elements - more than the " <>
              "#{@max_elements} allowed. Split the production into smaller rules, or make " <>
              "the branches of the disjunction bind the same variables."
    end
  end

  defp count_elements(elements), do: Enum.sum(Enum.map(elements, &count_element/1))
  defp count_element({:or, branches}), do: 1 + Enum.sum(Enum.map(branches, &count_elements/1))
  defp count_element(_element), do: 1

  # --- conditions ------------------------------------------------------------

  @doc """
  Classifies a single fact or collection condition against the bound variables.

  Splits the condition's guard, rebuilding the alpha and building the join
  filter when part or all of the guard has to move to the beta node.
  """
  @spec classify_condition(Parser.env(), binder(), bound()) :: binder()
  def classify_condition(_env, %{__ast__: nil} = condition, _bound) do
    raise ArgumentError,
          "condition has no :__ast__, binding classification must run before " <>
            "Rete.IR.escape/1: " <> inspect(condition)
  end

  def classify_condition(env, %module{__ast__: ast} = condition, bound)
      when module in [IR.Fact, IR.Coll] do
    own = own_scope(condition)
    check_shadowing!(condition, bound)
    check_guard_vars!(condition, own, bound)

    {join_bind, new_bind} = Enum.split_with(condition.bind, &MapSet.member?(bound, &1))

    # An inert collection variable stays in `:bind`, for the alpha to return. But it is
    # not a new binding — it groups nothing, and it flows nowhere.
    new_bind = new_bind -- inert(condition)

    {alpha_guard, join_guard} = split_guard(ast.guard, own)

    condition = %{condition | join_bind: join_bind, new_bind: new_bind}

    condition =
      case join_guard do
        nil ->
          condition

        join_guard ->
          %{
            condition
            | join_filter: build_join_filter(env, condition.type, own, join_guard),
              __ast__: %{ast | guard: alpha_guard}
          }
      end

    maybe_rebuild_alpha(env, condition, alpha_guard, join_guard)
  end

  # A fact binding names the whole fact, so it cannot also be a join key. If an earlier
  # condition bound that name, the guard would read the fact instead of the upstream
  # value — comparing an integer against a tuple.
  defp check_shadowing!(condition, bound) do
    name = binding_name(condition)

    if name && MapSet.member?(bound, name) do
      raise ArgumentError, """
      the condition #{Macro.to_string(condition.__ast__.source)} is bound to \
      `#{name}`, but `#{name}` is already bound by an earlier condition.

      A fact binding names the whole fact, so it cannot join against an \
      upstream value of the same name - a guard reading `#{name}` would get the \
      fact, not the value. Rename the binding.
      """
    end

    :ok
  end

  # `:inert` defaults to `[]` and `mark_inert/1` only sets a list, so there is no nil
  # case to defend against.
  defp inert(%IR.Coll{inert: inert}), do: inert
  defp inert(_condition), do: []

  # What a condition's *own guard* may read. This is not the same as what it makes
  # visible downstream. A collection's inert variables are excluded from
  # `Rete.IR.bound_vars/1`, but its own guard is where they are read.
  defp own_scope(%IR.Fact{bind: bind, fact_binding: nil}), do: MapSet.new(bind || [])
  defp own_scope(%IR.Fact{bind: bind, fact_binding: f}), do: MapSet.new([f | bind || []])
  defp own_scope(%IR.Coll{bind: bind, coll_binding: nil}), do: MapSet.new(bind || [])
  defp own_scope(%IR.Coll{bind: bind, coll_binding: c}), do: MapSet.new([c | bind || []])

  defp binding_name(%IR.Fact{fact_binding: name}), do: name
  defp binding_name(%IR.Coll{coll_binding: name}), do: name

  @doc """
  Raises unless every variable a condition's guard reads is available to it.

  A guard may read the variables its own pattern binds (`own` — which includes the fact
  binding, since the alpha's argument is the fact), and the variables bound by an
  earlier condition (`bound`). Anything else would compile into a join filter that reads
  the token side for a variable that is never there. The production could then never
  fire.

  A **forward reference** is no longer one of those cases. `Rete.Compiler.Sort` reorders
  the LHS before this phase runs. So a condition whose guard reads a variable another
  condition binds has already been moved after it. Reaching here means no condition on
  this path binds the variable at all — no ordering can fix that. Calling `classify/2` on
  an unsorted LHS, as a test may, still raises. That is the same defect, seen one phase
  early.
  """
  @spec check_guard_vars!(binder(), bound(), bound()) :: :ok
  def check_guard_vars!(%{__ast__: %{guard: guard, source: source}} = condition, own, bound) do
    reads = read_vars(guard)
    check_coll_binding!(condition, reads, source)

    unknown = reads |> MapSet.difference(own) |> MapSet.difference(bound) |> Enum.sort()

    case unknown do
      [] ->
        :ok

      [var | _] ->
        raise ArgumentError,
              "the guard of `#{Macro.to_string(source)}` reads `#{var}`, which is neither " <>
                "bound by the condition's own pattern nor by an earlier condition. " <>
                unknown_hint(var)
    end
  end

  # A `_`-prefixed variable is never a binding, in any position. The pattern discards it,
  # so it is in no bindings map and in no token.
  defp unknown_hint(var) do
    case Atom.to_string(var) do
      "_" <> rest ->
        "A variable whose name starts with `_` is discarded by the pattern that binds it, " <>
          "so a guard cannot read it. Rename it to `#{rest}`."

      _ ->
        "Conditions are sorted so that binders come first, so no condition binds `#{var}` " <>
          "on this path at all: a negation binds nothing downstream, and a variable only " <>
          "some branches of a disjunction bind is not available after it. Otherwise, " <>
          "correct the name."
    end
  end

  defp check_coll_binding!(%IR.Coll{coll_binding: coll}, reads, source) when not is_nil(coll) do
    if MapSet.member?(reads, coll) do
      raise ArgumentError,
            "the guard of `#{Macro.to_string(source)}` reads `#{coll}`, the collection " <>
              "binding. A collection guard runs against every candidate element, one at a " <>
              "time, so the collected list does not exist yet; filter elements here and " <>
              "aggregate on the right hand side."
    end

    :ok
  end

  defp check_coll_binding!(_condition, _reads, _source), do: :ok

  @doc """
  Raises unless every variable a rule-level guard reads is bound on its path.

  A `Rete.IR.Test` has no fact of its own, so its function is handed only the token. A
  variable no condition on this path binds is a key that is never in that map. The
  generated function would fall through to `false`, and the production would silently
  never fire.

  The check is **path exact**. After a disjunction whose branches bind different
  variables, `classify_elements/3` has absorbed everything downstream into the branches.
  So the test is checked once per branch, against exactly what that branch binds. A
  guard over a variable only some branches bind is therefore an error, on the branches
  that do not bind it. Write it as a per-condition guard instead, inside the branch that
  does bind it, where it can actually be evaluated.
  """
  @spec check_test_vars!(IR.Test.t(), bound()) :: :ok
  def check_test_vars!(%IR.Test{__ast__: nil}, _bound), do: :ok

  def check_test_vars!(%IR.Test{__ast__: %{guard: guard}}, bound) do
    case guard |> read_vars() |> MapSet.difference(bound) |> Enum.sort() do
      [] ->
        :ok

      [var | _] ->
        raise ArgumentError,
              "the rule level guard `#{Macro.to_string(guard)}` reads `#{var}`, which no " <>
                "condition binds on this path through the left hand side. " <> test_hint(var)
    end
  end

  defp test_hint(var) do
    case Atom.to_string(var) do
      "_" <> rest ->
        "A variable whose name starts with `_` is discarded by the pattern that binds it, " <>
          "so a guard cannot read it. Rename it to `#{rest}`."

      _ ->
        "A negation binds nothing downstream, and a variable only some branches of a " <>
          "disjunction bind is not available after it - put such a guard on the condition " <>
          "inside the branch instead. Otherwise, correct the name."
    end
  end

  @doc """
  Splits a guard into `{alpha_guard, join_guard}`.

  `local` is the set (or list) of variables the condition's own pattern binds,
  including its fact binding. A conjunct of the top-level `and`/`&&` chain goes to the
  alpha, when all its variables are local. Any other conjunct goes to the join filter
  instead. Either half may be `nil`.

  Each half is rejoined with the operators the guard was written with. So an all-`&&`
  chain stays an all-`&&` chain, and a guard over a truthy value keeps working after the
  split. A conjunct that has lost a predecessor is rejoined with `&&`, even where the
  source said `and`. The strict operator would otherwise demand a boolean of an
  expression that is not the one it was written against.

  When nothing has to move, this returns the original guard AST untouched. That way the
  alpha expression keeps its code, and it stays shared.

      iex> Rete.DSL.Bindings.split_guard(nil, [:amt])
      {nil, nil}
  """
  @spec split_guard(Macro.t() | nil, bound() | [atom()]) :: {Macro.t() | nil, Macro.t() | nil}
  def split_guard(nil, _local), do: {nil, nil}

  def split_guard(guard, local) do
    local = to_set(local)

    # split_while, not split_with. The two halves have to stay contiguous. Sorting local
    # conjuncts out of the middle would reorder them relative to the ones left behind. The
    # alpha always runs before the beta node, so a short-circuit-protected conjunct would
    # start running first. `amt > t and div(100, amt) > 1` used to put `div(100, amt) > 1`
    # in the alpha, and raise `ArithmeticError` on `amt = 0`.
    #
    # The price: a local conjunct after a cross-condition one stays on the beta side, and
    # it filters later than it could.
    {alpha, join} =
      guard
      |> conjuncts()
      |> Enum.split_while(fn {_index, _op, conjunct} -> local?(conjunct, local) end)

    case join do
      [] -> {guard, nil}
      _ -> {conjoin(alpha), conjoin(join)}
    end
  end

  @doc """
  The variables an AST fragment reads, sorted.

  Pinned values (`^x`) and module attributes (`@x`) are compile-time constants, and this
  excludes them. `_`-prefixed variables are **not** excluded: `_t` in `amt > _t` really
  is a read of `_t`. Treating it as local would inline it into the alpha, where it is
  not in scope. Only the anonymous `_` is skipped.
  """
  @spec guard_vars(Macro.t() | nil) :: [atom()]
  def guard_vars(ast), do: ast |> read_vars() |> Enum.sort()

  @doc """
  The variables a condition's guard needs that its own fact cannot supply.

  These are exactly the variables that force a join filter. Call this on a parsed, not
  yet classified condition. After `classify_condition/3` runs, the guard left on the
  condition is the alpha part. That part reads nothing but the condition's own
  variables, by construction, so the result is `[]`.
  """
  @spec filter_vars(binder()) :: [atom()]
  def filter_vars(%{__ast__: %{guard: guard}} = condition) do
    own = MapSet.new(IR.bound_vars(condition))
    guard |> guard_vars() |> Enum.reject(&MapSet.member?(own, &1))
  end

  # --- guard decomposition ---------------------------------------------------

  # Only a top-level conjunction is decomposable. Each conjunct is tagged with its
  # position and its joining operator. This is what lets `conjoin/1` rebuild a subset.
  defp conjuncts(guard) do
    guard
    |> conjuncts(nil)
    |> Enum.with_index(fn {op, conjunct}, index -> {index, op, conjunct} end)
  end

  defp conjuncts({op, _, [left, right]}, join) when op in [:and, :&&] do
    conjuncts(left, join) ++ conjuncts(right, op)
  end

  defp conjuncts(guard, join), do: [{join, guard}]

  # Left associative, the way `a and b and c` parses. The head's operator is dropped,
  # because it joined the head to something outside this chain.
  defp conjoin([]), do: nil

  defp conjoin([{index, _op, guard} | rest]) do
    {guard, _next} =
      Enum.reduce(rest, {guard, next_index(0, index)}, fn {index, op, conjunct}, {acc, next} ->
        {{join_op(op, index, next), [], [acc, conjunct]}, next_index(next, index)}
      end)

    guard
  end

  # `and` is strict in its *left* operand. After a split, that operand is no longer the
  # expression it was written against. This is safe only while the rebuilt chain is
  # still the original.
  defp join_op(:and, index, index), do: :and
  defp join_op(_op, _index, _next), do: :&&

  # The index the next conjunct must have for the chain to be intact, or `:broken`.
  defp next_index(index, index), do: index + 1
  defp next_index(_next, _index), do: :broken

  defp local?(conjunct, local), do: conjunct |> read_vars() |> MapSet.subset?(local)

  defp to_set(%MapSet{} = set), do: set
  defp to_set(list) when is_list(list), do: MapSet.new(list)

  # Keeps `_`-prefixed names, unlike `Rete.DSL.Parser.parse_bind/1` — a guard mentioning
  # `_t` does read `_t`.
  defp read_vars(ast), do: Vars.read_vars(ast)

  # --- expression building ---------------------------------------------------

  # The alpha is left alone unless something forces a change. So a condition whose
  # guard did not move keeps its code, and it shares its node.
  defp maybe_rebuild_alpha(env, condition, alpha_guard, join_guard) do
    self = fact_binding(condition)
    alpha_self? = reads_self?(alpha_guard, self)
    join_self? = reads_self?(join_body(condition, join_guard), self)

    cond do
      join_self? -> rebuild_alpha(env, condition, alpha_guard, self, true)
      alpha_self? -> rebuild_alpha(env, condition, alpha_guard, self, false)
      is_nil(join_guard) -> condition
      true -> rebuild_alpha(env, condition, alpha_guard, nil, false)
    end
  end

  defp reads_self?(_ast, nil), do: false
  defp reads_self?(ast, self), do: MapSet.member?(read_vars(ast), self)

  # A collection binding is not the alpha's argument, because the alpha runs per
  # element. `check_coll_binding!/3` already rejected a guard that reads it.
  defp fact_binding(%IR.Fact{fact_binding: fact_binding}), do: fact_binding
  defp fact_binding(%IR.Coll{}), do: nil

  # The join guard of this pass, or one a previous pass compiled, so classifying twice
  # rebuilds the same alpha.
  defp join_body(_condition, join_guard) when not is_nil(join_guard), do: join_guard
  defp join_body(%{join_filter: %IR.Expr{__ast__: %{body: body}}}, nil), do: body
  defp join_body(_condition, nil), do: nil

  # Rebuilt through the parser's own helpers. So a condition whose guard was fully
  # lifted out hashes identically to the same condition written without one. A non-nil
  # `self` matches the fact binding against the whole argument. `expose_self?` also
  # returns it in the bindings map, for a join filter to destructure.
  defp rebuild_alpha(env, condition, alpha_guard, self, expose_self?) do
    %{__ast__: %{pattern: pattern, bind: bind}} = condition
    {type, args_ast} = Parser.compile_pattern(env, pattern)

    {args_ast, bind} =
      case self do
        nil -> {args_ast, bind}
        self -> {{:=, [], [{self, [], nil}, args_ast]}, expose(bind, self, expose_self?)}
      end

    %{condition | alpha: Parser.build_alpha_expr(env, type, pattern, args_ast, alpha_guard, bind)}
  end

  defp expose(bind, _self, false), do: bind
  defp expose(bind, self, true), do: Map.put(bind, self, {self, [], nil})

  # `(token_bindings, fact_bindings) -> boolean`, built by Rete.DSL.Codegen so the naming
  # and hashing scheme has one implementation.
  defp build_join_filter(env, type, own, join_guard) do
    Codegen.join_filter_expr(env, type, own, join_guard)
  end
end
