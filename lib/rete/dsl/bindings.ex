defmodule Rete.DSL.Bindings do
  @max_elements 1024

  @moduledoc """
  Binding classification and guard splitting.

  This is the compile phase that runs between gate normalization and code
  generation. It walks the LHS of a `Rete.IR.Production` **in order**, carrying
  the set of variables bound so far, and for every fact or collection condition
  it computes:

    * `:join_bind` - the variables of the condition that are already bound
      upstream. These are the hash join keys: the engine groups elements and
      tokens by them and joins on equality.
    * `:new_bind` - the variables the condition introduces. They flow
      downstream and, for a collection, decide the grouping and therefore the
      empty collection semantics (see `Rete.IR.Coll`).
    * `:join_filter` - the part of the per-condition guard that cannot be
      evaluated against a single fact.

  `join_bind ++ new_bind == bind` always holds, and both lists are sorted,
  because `:bind` is.

  ## Guard splitting

  A per-condition guard is split in two:

    * the **alpha part**, the sub-expressions that only reference variables the
      condition's own pattern binds - including its fact binding, which *is* the
      alpha's argument - plus pinned values and module attributes, which are
      compile time constants and never bindings. It is compiled into the arity 1
      alpha function so that unmatched facts are rejected as early as possible,
      before any join work happens.
    * the **join filter part**, the sub-expressions that reference a variable
      bound by an earlier condition. It is compiled into an arity 2 function
      `(token_bindings, fact_bindings) -> boolean` evaluated at the beta node.

  The split is conjunct by conjunct over the top level `and`/`&&` chain, so

      {:order, id, amt} when amt > 0 and amt > limit

  puts `amt > 0` in the alpha and `amt > limit` in the join filter. A guard that
  is not decomposable - an `or` mixing local and upstream variables, or a single
  expression touching both - goes to the join filter **whole**: correctness
  beats early filtering.

  Each half is rejoined with the operators the guard was written with, so an
  all-`&&` chain is rebuilt as an all-`&&` chain. Rejoining with a strict `and`
  would turn a guard over a truthy value into a `BadBooleanError`, which is to
  say splitting a guard would change its meaning. `and` is kept only while the
  rebuilt chain is still the original one from the start; once a conjunct has
  been lifted out of it, the left operand of every following `and` is an
  expression the guard never contained, so the weaker `&&` is used instead.

  When the whole guard is local the alpha expression is left untouched, so its
  `:code` is unchanged. When the whole guard is lifted out, the alpha is rebuilt
  without a guard and therefore gets exactly the same `:code` as the same
  condition written without one - which is the point, it shares the alpha node.

  ## The fact binding is local

  `f` in `f = {:order, amt} when elem(f, 1) > 100` is not an upstream variable:
  the alpha is handed the whole fact, so `f` is exactly its argument. A guard
  over the fact binding therefore stays in the alpha, whose argument pattern is
  rebuilt as `f = <pattern>`.

  When a **join filter** reads the fact binding, the rebuilt alpha additionally
  returns it in its bindings map, because that map is the only thing the fact
  side of a join filter ever sees. The extra key holds the same fact the engine
  puts in the token, so nothing downstream has to change.

  A **collection** binding is different: the alpha of a `Rete.IR.Coll` runs once
  per candidate element, so the collected list does not exist yet. A collection
  guard that reads its own collection binding raises.

  ## Unbound guard variables

  A guard variable that is neither local nor bound by an earlier condition
  raises at compile time, naming the variable and the condition. Conditions
  written in the wrong order,

      defrule r({:order, amt} when amt > t, {:threshold, t})

  are **not** that case any more: `Rete.Compiler.Sort` runs first and reorders
  them, so by the time this phase sees them `{:threshold, t}` comes first and
  the guard is an ordinary join filter. What is left for `check_guard_vars!/3`
  to reject is a variable *no* condition binds on this path - a typo, a
  `_`-prefixed name the pattern discarded, a variable that only exists inside a
  negation, or one only some branches of a disjunction bind. Any of those would
  compile into a join filter reading the token side for a key that is never
  there, so the production could never fire.

  The rule level guard, `defrule r(...) when <guard>`, has the same defect and
  the same rule: `check_test_vars!/2` rejects a `Rete.IR.Test` reading a variable
  no condition binds on its path. It is checked *per path*, so a guard over a
  variable only some branches of a disjunction bind is an error too - it can only
  be evaluated inside the branch that binds it, where it belongs.

  ## What does not bind

    * A `Rete.IR.Test` reads bindings but has no fact input, so it introduces no
      variable.
    * A `Rete.IR.Negation` never matches a fact, so the variables inside it are
      **not** bound for the conditions that follow. (Clara documents the same
      rule in `compiler.clj`, `analyze-condition`.) The same goes for a
      `Rete.IR.CompoundNegation`, whose conditions do bind each other.
    * Pinned values (`^x`) and module attributes (`@x`) are compile time values,
      never bindings.

  ## Disjunctions

  Every branch of a `{:or, [[condition, ...], ...]}` is a distinct path through
  the beta graph, so each branch is classified in **its own** binding context -
  and so is everything downstream of it:

      defrule audit({:or, [{:user, id}, {:override, :all}]}, {:login, id, ts})

  On the `{:user, id}` path `{:login, id, ts}` joins on `id`; on the
  `{:override, :all}` path `id` is free and `{:login, id, ts}` introduces it.
  Classifying it once against the intersection of the branches would give it no
  join key at all on either path, i.e. a cartesian product - silently wrong
  results. (Clara keeps a list of parent ids per disjunct for the same reason,
  see `add-production` in `compiler.clj`.)

  `classify_elements/3` therefore classifies the elements that follow a
  disjunction once per branch and then:

    * if every branch produced the **same** classified tail, keeps one shared
      copy of it and leaves the LHS flat. This is the common case and always
      holds when the branches bind the same variables;
    * otherwise **absorbs** the tail into the branches. The disjunction becomes
      the last element of the sequence, its branches carry the rest of the LHS,
      and a branch may itself contain further `{:or, ...}` elements.

  Downstream of the disjunction as a whole, only the variables bound by *every*
  branch count as bound, since the branches re-converge.

  Absorption duplicates conditions and nested disjunctions multiply, so
  `classify_elements/3` refuses to build more than #{@max_elements} LHS elements
  and raises instead.

  ## Position in the pipeline

  Gates must already be normalized: a `Rete.IR.Gate` reaching this phase raises.
  Conditions must already be sorted, because `:join_bind` and `:new_bind` are
  read off the order they are in. Conditions must still carry their `:__ast__`,
  so this runs before `Rete.IR.escape/1`.
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

  Returns the production with `:join_bind`, `:new_bind`, `:join_filter` filled
  in on every `Rete.IR.Fact` and `Rete.IR.Coll`, and with alpha expressions
  rebuilt wherever a guard was partly or wholly lifted into a join filter.

  `env` is the `Macro.Env` of the `defrule`/`defquery` call; it is needed to
  re-expand struct aliases when an alpha is rebuilt.
  """
  @spec classify(Parser.env(), IR.Production.t()) :: IR.Production.t()
  def classify(env, %IR.Production{} = production) do
    {lhs, _bound} = classify_elements(env, production.lhs, MapSet.new())
    %IR.Production{production | lhs: lhs}
  end

  @doc """
  Classifies a list of LHS elements against the variables bound before them.

  Returns `{classified_elements, bound_after}`. The returned list is not
  necessarily as long as the one given: the elements that follow a disjunction
  whose branches classify them differently are absorbed into those branches, see
  the moduledoc.

  Exposed so that a caller can classify a fragment, for instance a branch of a
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

  # A negation never matches a fact, so nothing inside it escapes. Its own
  # condition is still classified: the engine needs the join keys to know which
  # tokens the negation applies to.
  defp classify_element(env, %IR.Negation{condition: condition}, bound) do
    {%IR.Negation{condition: classify_condition(env, condition, bound)}, bound}
  end

  # Same for a compound negation, except that its inner conjunction is a little
  # LHS of its own: the conditions bind each other, and none of them escapes.
  defp classify_element(env, %IR.CompoundNegation{conditions: conditions}, bound) do
    {conditions, _inner} = classify_elements(env, conditions, bound)
    {%IR.CompoundNegation{conditions: conditions}, bound}
  end

  # A test has no fact input, so it binds nothing - it only reads, and every
  # variable it reads has to be in the token that reaches it.
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

  # `{:or, []}` is *false*: no branch, so nothing downstream is reachable. The
  # rest is still classified, because the IR has to be complete.
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

  # One shared tail when every path classified it the same way, a tail per
  # branch when they disagree.
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
    own = MapSet.new(IR.bound_vars(condition))
    check_shadowing!(condition, bound)
    check_guard_vars!(condition, own, bound)

    {join_bind, new_bind} = Enum.split_with(condition.bind, &MapSet.member?(bound, &1))
    {alpha_guard, join_guard} = split_guard(ast.guard, own)

    condition = %{condition | join_bind: join_bind, new_bind: new_bind}

    condition =
      case join_guard do
        nil ->
          condition

        join_guard ->
          %{
            condition
            | join_filter: build_join_filter(condition.type, own, join_guard),
              __ast__: %{ast | guard: alpha_guard}
          }
      end

    maybe_rebuild_alpha(env, condition, alpha_guard, join_guard)
  end

  # A fact or collection binding names the whole fact, so it cannot also be a
  # join key: there is nothing upstream for a whole fact to equal. If an earlier
  # condition already bound that name, the guard silently reads the fact instead
  # of the upstream value - `{:lim, t}, t = {:order, amt} when amt > t` compares
  # an integer against a tuple, which Erlang term order makes false for every
  # fact, so the rule can never fire and nothing reports it.
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

  defp binding_name(%IR.Fact{fact_binding: name}), do: name
  defp binding_name(%IR.Coll{coll_binding: name}), do: name

  @doc """
  Raises unless every variable a condition's guard reads is available to it.

  A guard may read the variables its own pattern binds (`own`, which includes
  the fact binding, because the alpha's argument is the fact) and the variables
  bound by an earlier condition (`bound`). Anything else would compile into a
  join filter that reads the token side for a variable that is never there, and
  the production could never fire.

  A **forward reference** is no longer one of those cases. `Rete.Compiler.Sort`
  reorders the LHS before this phase runs, so a condition whose guard reads a
  variable another condition binds has already been moved after it. Reaching
  here means no condition on this path binds the variable at all, which no
  ordering can fix. Calling `classify/2` on an unsorted LHS - as a test may -
  still raises, and that is the same defect seen one phase early.
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

  # A `_`-prefixed variable is never a binding, in any position: the pattern
  # discards it, so it is in no bindings map and in no token, and inlining the
  # guard into the alpha would only trade this error for Elixir's "the
  # underscored variable is used after being set" warning.
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
  Raises unless every variable a rule level guard reads is bound on its path.

  A `Rete.IR.Test` has no fact of its own, so the only thing its function is
  handed is the token: a variable no condition on this path binds is a key that
  is never in that map, the generated function falls through to `false`, and the
  production silently never fires.

  The check is **path exact**. After a disjunction whose branches bind different
  variables, `classify_elements/3` has absorbed everything downstream into the
  branches, so the test is checked once per branch against exactly what that
  branch binds. A guard over a variable only some branches bind is therefore an
  error on the branches that do not - write it as a per condition guard inside
  the branch that does, where it can actually be evaluated.
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
  including its fact binding. A conjunct of the top level `and`/`&&` chain whose
  variables are all local goes to the alpha, any other conjunct goes to the join
  filter. Either half may be `nil`.

  Each half is rejoined with the operators the guard was written with, so an
  all-`&&` chain stays an all-`&&` chain and a guard over a truthy value keeps
  working after the split. A conjunct that has lost a predecessor is rejoined
  with `&&` even where the source said `and`: the strict operator would demand a
  boolean of an expression that is not the one it was written against.

  When nothing has to move, the original guard AST is returned untouched so that
  the alpha expression keeps its code and stays shared.

      iex> Rete.DSL.Bindings.split_guard(nil, [:amt])
      {nil, nil}
  """
  @spec split_guard(Macro.t() | nil, bound() | [atom()]) :: {Macro.t() | nil, Macro.t() | nil}
  def split_guard(nil, _local), do: {nil, nil}

  def split_guard(guard, local) do
    local = to_set(local)

    # split_while, not split_with: the two halves have to stay contiguous.
    # Sorting local conjuncts out of the middle of the chain reorders them
    # relative to the ones left behind, and the alpha always runs before the
    # beta node, so a conjunct that the source had short-circuit protected
    # would start running first. `amt > t and div(100, amt) > 1` used to put
    # `div(100, amt) > 1` in the alpha and raise ArithmeticError on amt = 0,
    # even though as written it can never divide by zero.
    #
    # The price is that a local conjunct sitting after a cross condition one
    # stays on the beta side and filters later than it could. That is the right
    # way round: correctness first, early filtering second.
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

  Pinned values (`^x`) and module attributes (`@x`) are compile time constants
  and excluded. `_`-prefixed variables are **not**: `_t` in `amt > _t` really is
  a read of `_t`, and treating it as local would inline it into the alpha, where
  it is not in scope. Only the anonymous `_` is skipped.
  """
  @spec guard_vars(Macro.t() | nil) :: [atom()]
  def guard_vars(ast), do: ast |> read_vars() |> Enum.sort()

  @doc """
  The variables a condition's guard needs that its own fact cannot supply.

  These are exactly the variables that force a join filter. Call it on a parsed,
  not yet classified condition; after `classify_condition/3` the guard left on
  the condition is the alpha part, which by construction reads nothing but the
  condition's own variables, so the result is `[]`.
  """
  @spec filter_vars(binder()) :: [atom()]
  def filter_vars(%{__ast__: %{guard: guard}} = condition) do
    own = MapSet.new(IR.bound_vars(condition))
    guard |> guard_vars() |> Enum.reject(&MapSet.member?(own, &1))
  end

  # --- guard decomposition ---------------------------------------------------

  # Only a top level conjunction is decomposable. `or`, `not` and anything else
  # is one indivisible conjunct: splitting it would change its meaning. Every
  # conjunct is tagged with its position in the chain and with the operator that
  # joined it to its predecessor, which is what lets `conjoin/1` rebuild a
  # subset of them without changing what the guard means.
  defp conjuncts(guard) do
    guard
    |> conjuncts(nil)
    |> Enum.with_index(fn {op, conjunct}, index -> {index, op, conjunct} end)
  end

  defp conjuncts({op, _, [left, right]}, join) when op in [:and, :&&] do
    conjuncts(left, join) ++ conjuncts(right, op)
  end

  defp conjuncts(guard, join), do: [{join, guard}]

  # Left associative, the way `a and b and c` parses, so that a rejoined chain
  # of untouched conjuncts is the AST it came from. The head's operator is
  # dropped: it joined the head to something that is not in this chain.
  defp conjoin([]), do: nil

  defp conjoin([{index, _op, guard} | rest]) do
    {guard, _next} =
      Enum.reduce(rest, {guard, next_index(0, index)}, fn {index, op, conjunct}, {acc, next} ->
        {{join_op(op, index, next), [], [acc, conjunct]}, next_index(next, index)}
      end)

    guard
  end

  # `and` is strict in its *left* operand, and after a split that operand is no
  # longer the expression it was written against. Keeping `and` is only safe
  # while the chain rebuilt so far is still the original one, conjunct for
  # conjunct from the start; as soon as one has been lifted out, the weaker `&&`
  # is used, which imposes no demand the original did not already make.
  defp join_op(:and, index, index), do: :and
  defp join_op(_op, _index, _next), do: :&&

  # The index the next conjunct must have for the chain to still be intact,
  # or `:broken` once one is missing.
  defp next_index(index, index), do: index + 1
  defp next_index(_next, _index), do: :broken

  defp local?(conjunct, local), do: conjunct |> read_vars() |> MapSet.subset?(local)

  defp to_set(%MapSet{} = set), do: set
  defp to_set(list) when is_list(list), do: MapSet.new(list)

  # Every variable an expression reads from the rule's scope. Unlike
  # `Rete.DSL.Parser.parse_bind/1`, which answers what a *pattern* binds, this
  # keeps `_`-prefixed names: a guard that mentions `_t` really does read `_t`.
  # Scope analysis lives in `Rete.DSL.Vars`, so that what a guard is judged to
  # read here and what `Rete.DSL.Codegen` destructures for it cannot drift.
  defp read_vars(ast), do: Vars.read_vars(ast)

  # --- expression building ---------------------------------------------------

  # The alpha is left alone unless something forces it to change, so that a
  # condition whose guard did not move keeps its code and shares its node.
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

  # A collection binding is not the alpha's argument - the alpha runs per
  # element - and `check_coll_binding!/3` has already rejected a guard reading
  # it, so a collection never has a "self" variable here.
  defp fact_binding(%IR.Fact{fact_binding: fact_binding}), do: fact_binding
  defp fact_binding(%IR.Coll{}), do: nil

  # The join guard of this pass, or the one a previous pass already compiled, so
  # that classifying twice rebuilds exactly the same alpha.
  defp join_body(_condition, join_guard) when not is_nil(join_guard), do: join_guard
  defp join_body(%{join_filter: %IR.Expr{__ast__: %{body: body}}}, nil), do: body
  defp join_body(_condition, nil), do: nil

  # Rebuilt through the parser's own helpers so that a condition whose guard was
  # fully lifted out hashes identically to the same condition written without a
  # guard, and shares its alpha node.
  #
  # A non-nil `self` makes the fact binding available inside the alpha by
  # matching it against the whole argument; `expose_self?` additionally returns
  # it in the bindings map, which is what a join filter reading it destructures
  # from the fact side.
  defp rebuild_alpha(env, condition, alpha_guard, self, expose_self?) do
    %{__ast__: %{pattern: pattern, bind: bind}} = condition
    {type, args_ast} = Parser.compile_pattern(env, pattern)

    {args_ast, bind} =
      case self do
        nil -> {args_ast, bind}
        self -> {{:=, [], [{self, [], nil}, args_ast]}, expose(bind, self, expose_self?)}
      end

    %{condition | alpha: Parser.build_alpha_expr(type, pattern, args_ast, alpha_guard, bind)}
  end

  defp expose(bind, _self, false), do: bind
  defp expose(bind, self, true), do: Map.put(bind, self, {self, [], nil})

  # `(token_bindings, fact_bindings) -> boolean`, built by Rete.DSL.Codegen so
  # that the naming and hashing scheme has one implementation.
  defp build_join_filter(type, own, join_guard) do
    Codegen.join_filter_expr(type, own, join_guard)
  end
end
