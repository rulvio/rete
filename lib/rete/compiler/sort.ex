defmodule Rete.Compiler.Sort do
  @moduledoc """
  Topological ordering of the left hand side of a production.

  A rule reads best in the order the author thought of it; the network needs an
  order in which every join has its keys already in the token. This phase
  reconciles the two: it reorders the LHS so that a condition only ever comes
  after the conditions that bind the variables it needs.

      defrule r({:order, amt} when amt > t, {:threshold, t})

  is sorted into `{:threshold, t}, {:order, amt} when amt > t` and from there on
  is indistinguishable from the same rule written that way round.

  ## What a condition needs

  Only what it reads and cannot supply itself:

    * a `Rete.IR.Fact` or `Rete.IR.Coll` needs the variables of its guard that
      its own pattern does not bind - exactly the variables that would otherwise
      become a join filter read of the token side;
    * a `Rete.IR.Test` needs every variable its guard reads, since it has no
      fact of its own;
    * a `Rete.IR.Negation` needs what its inner condition needs. The variables
      the inner *pattern* binds are existential, not requirements: `{:not,
      [{:order, x}]}` with no `x` upstream reads "there is no order at all";
    * a `Rete.IR.CompoundNegation` and each branch of a `{:or, ...}` need the
      union of their elements' needs minus what those elements bind between
      them, because their conditions satisfy each other.

  `_`-prefixed names are dropped from every need: the pattern that would bind
  one discards it, so no ordering can ever satisfy it.
  `Rete.DSL.Bindings.check_guard_vars!/3` reports that with the hint to rename
  it, which is the answer the author needs.

  ## What a condition binds

  `Rete.IR.lhs_bindings/1`, so that this phase and the `:bind` of the production
  cannot drift apart. A negation and a test bind nothing downstream, and a
  disjunction binds only the *intersection* of its branches - a variable one
  branch leaves free is not a join key any condition after it can use.

  ## Stability

  Every pass takes **all** the conditions that are satisfiable right now, in
  author order, and only then moves on. Conditions that are equally satisfiable
  therefore keep the order they were written in, which matters twice over: a
  rule behaves the way it reads, and two rules that share a prefix still share
  their alpha and join nodes. A sort that reshuffled freely would silently
  degrade node sharing.

  ## Collections and tests are deferred

  A `Rete.IR.Coll` that introduces no new variable propagates `[]` and lets the
  rule fire with zero matches (see `Rete.IR.Coll`). Placed too early it does
  that *before* the conditions that would have filled it are joined, so a
  collection is only taken when no plain condition is satisfiable. Clara defers
  accumulators in `sort-conditions` for the same reason.

  A `Rete.IR.Test` is deferred with it, for a smaller reason: it binds nothing,
  so nothing is ever waiting on it, and the parser appends the rule level guard
  as the last element of the LHS. Deferring it is what keeps it there when a
  collection is pushed past it.

  ## When nothing can be satisfied

  Ordinarily an `ArgumentError` naming the production, the conditions still
  unplaced and exactly which variables are unbound - this is what a typo in a
  variable name looks like, so the message has to say which name.

  Two shapes are handed on instead of reported here, because the phase that runs
  next has a better answer for them:

    * a `Rete.IR.Test`, which `Rete.DSL.Bindings.check_test_vars!/2` checks once
      per path through the LHS, so it can say that only *some* branches of a
      disjunction bind the variable;
    * a condition whose missing variables are bound by some but not all branches
      of a disjunction, which `Rete.DSL.Bindings.check_guard_vars!/3` likewise
      reports per branch.

  Neither can be fixed by reordering, so nothing is lost by leaving them in
  author order.

  ## Position in the pipeline

  After `Rete.DSL.Normalize`, because a `Rete.IR.Gate` reaching this phase
  raises - the arguments of a gate do not all bind, and their needs cannot be
  read off it. Before `Rete.DSL.Bindings`, because `:join_bind` and `:new_bind`
  have to be computed against the final order.
  """

  alias Rete.DSL.Vars
  alias Rete.IR

  @typedoc "A set of variable names."
  @type vars :: MapSet.t(atom())

  @doc """
  Sorts the left hand side of a production topologically.

  Returns the production with its `:lhs` reordered; the conditions themselves
  are untouched, except that the branches of a disjunction and the conjunction
  inside a `Rete.IR.CompoundNegation` are sorted the same way, against the
  variables bound where they sit.

  Idempotent: sorting an already sorted LHS returns it unchanged.
  """
  @spec sort(IR.Production.t()) :: IR.Production.t()
  def sort(%IR.Production{lhs: lhs} = production) do
    {lhs, _bound, _optional} = order(lhs, MapSet.new(), MapSet.new(), production)
    %IR.Production{production | lhs: lhs}
  end

  @doc """
  The variables an element needs bound before it can be placed.

  See the moduledoc; this is the whole ordering constraint.
  """
  @spec needs(IR.element()) :: vars()
  def needs(%IR.Fact{} = fact), do: guard_needs(fact)
  def needs(%IR.Coll{} = coll), do: guard_needs(coll)
  def needs(%IR.Test{bind: bind}), do: MapSet.new(bind || [])
  def needs(%IR.Negation{condition: condition}), do: needs(condition)
  def needs(%IR.CompoundNegation{conditions: conditions}), do: residual(conditions)
  def needs({:or, branches}), do: union(branches, &residual/1)

  def needs(%IR.Gate{gate: gate}) do
    raise ArgumentError,
          "a #{gate} gate reached condition sorting; gates must be normalized into plain " <>
            "conditions, negations and disjunctions first"
  end

  def needs(element) do
    raise ArgumentError, "unsupported LHS element for condition sorting: " <> inspect(element)
  end

  # The needs of a conjunction of elements that the conjunction itself cannot
  # satisfy. Its elements bind each other, so only what none of them binds is
  # asked of the conditions upstream. Only *guaranteed* bindings count, for the
  # same reason they do at the top level.
  defp residual(elements) do
    {guaranteed, _optional} = IR.lhs_bindings(elements)
    elements |> union(&needs/1) |> MapSet.difference(MapSet.new(guaranteed))
  end

  # A guard variable the condition's own pattern binds is supplied by the fact
  # itself; everything else has to come out of the token, which is to say from
  # an earlier condition.
  defp guard_needs(condition) do
    own = MapSet.new(IR.bound_vars(condition))

    condition
    |> guards()
    |> union(&Vars.read_vars/1)
    |> MapSet.difference(own)
    |> Enum.reject(&Vars.discarded?/1)
    |> MapSet.new()
  end

  # The join filter is read too, so that sorting an already classified LHS - one
  # whose `:__ast__.guard` is only the alpha half - is still the identity.
  defp guards(%{__ast__: %{guard: guard}, join_filter: %IR.Expr{__ast__: %{body: body}}}) do
    [guard, body]
  end

  defp guards(%{__ast__: %{guard: guard}}), do: [guard]
  defp guards(_condition), do: []

  # --- the sort --------------------------------------------------------------

  defp order(elements, bound, optional, production) do
    elements
    |> Enum.map(&{&1, needs(&1)})
    |> take([], bound, optional, production)
  end

  defp take([], placed, bound, optional, _production) do
    {Enum.reverse(placed), bound, optional}
  end

  defp take(remaining, placed, bound, optional, production) do
    case ready(remaining, bound) do
      {[], _blocked} ->
        give_up(remaining, placed, bound, optional, production)

      {ready, blocked} ->
        {placed, bound, optional} = place_all(ready, placed, bound, optional, production)
        take(blocked, placed, bound, optional, production)
    end
  end

  # All the satisfiable conditions of this pass, in author order - `split_with/2`
  # preserves the order of both halves, which is the whole of the stability
  # guarantee. A collection is only reached when nothing else is satisfiable.
  defp ready(remaining, bound) do
    satisfied? = fn {_element, needs} -> MapSet.subset?(needs, bound) end

    case Enum.split_with(remaining, &(satisfied?.(&1) and not deferred?(elem(&1, 0)))) do
      {[], _blocked} -> Enum.split_with(remaining, satisfied?)
      {ready, blocked} -> {ready, blocked}
    end
  end

  defp deferred?(%IR.Coll{}), do: true
  defp deferred?(%IR.Test{}), do: true
  defp deferred?(_element), do: false

  defp place_all(ready, placed, bound, optional, production) do
    Enum.reduce(ready, {placed, bound, optional}, fn {element, _needs},
                                                     {placed, bound, optional} ->
      {element, bound, optional} = place(element, bound, optional, production)
      {[element | placed], bound, optional}
    end)
  end

  # A branch is a little LHS of its own, sorted against the variables bound
  # where the disjunction sits.
  defp place({:or, branches}, bound, optional, production) do
    branches = Enum.map(branches, &sorted(&1, bound, optional, production))
    contribute({:or, branches}, bound, optional)
  end

  # So is the conjunction inside a compound negation, whose conditions bind each
  # other even though none of them escapes.
  defp place(%IR.CompoundNegation{conditions: conditions}, bound, optional, production) do
    conditions = sorted(conditions, bound, optional, production)
    contribute(%IR.CompoundNegation{conditions: conditions}, bound, optional)
  end

  defp place(element, bound, optional, _production), do: contribute(element, bound, optional)

  defp sorted(elements, bound, optional, production) do
    {elements, _bound, _optional} = order(elements, bound, optional, production)
    elements
  end

  defp contribute(element, bound, optional) do
    {guaranteed, branch_only} = IR.lhs_bindings([element])

    {element, MapSet.union(bound, MapSet.new(guaranteed)),
     MapSet.union(optional, MapSet.new(branch_only))}
  end

  # --- the dead end ----------------------------------------------------------

  defp give_up(remaining, placed, bound, optional, production) do
    blocking =
      Enum.reject(remaining, fn {element, needs} ->
        checked_per_path?(element, MapSet.difference(needs, bound), optional)
      end)

    if blocking == [] do
      {placed, bound, optional} = place_all(remaining, placed, bound, optional, production)
      {Enum.reverse(placed), bound, optional}
    else
      raise ArgumentError, unsatisfiable(production, remaining, blocking, bound)
    end
  end

  # `Rete.DSL.Bindings` checks both of these once per path through the LHS, and
  # so can name the branch the variable is missing on. Reordering cannot help
  # either way, so they are left where the author put them.
  defp checked_per_path?(%IR.Test{}, _unmet, _optional), do: true
  defp checked_per_path?(_element, unmet, optional), do: MapSet.subset?(unmet, optional)

  defp unsatisfiable(production, remaining, blocking, bound) do
    unbound =
      blocking
      |> union(fn {_element, needs} -> needs end)
      |> MapSet.difference(bound)
      |> Enum.sort()

    """
    the left hand side of `def#{production.type} #{production.name}` in \
    #{inspect(production.module)} cannot be ordered: none of the \
    #{length(remaining)} remaining conditions can be satisfied.

    Unbound: #{vars(unbound)}

    Still unplaced, in the order they were written:

    #{Enum.map_join(remaining, "\n    ", &unplaced(&1, bound))}

    A variable is only bound by the pattern of the fact or collection condition \
    it appears in. A negation binds nothing downstream, and after a disjunction \
    only the variables *every* branch binds are available. Check the spelling, \
    and note that a `_`-prefixed variable is discarded by the pattern that \
    would have bound it.
    """
  end

  # Which condition is waiting for which variable is the whole of the answer, so
  # every unplaced condition carries its own unmet needs.
  defp unplaced({element, needs}, bound) do
    case needs |> MapSet.difference(bound) |> Enum.sort() do
      [] -> describe(element)
      unmet -> describe(element) <> " - needs " <> vars(unmet)
    end
  end

  defp vars(names), do: Enum.map_join(names, ", ", &"`#{&1}`")

  # The parser keeps a condition's guard beside its source rather than in it, so
  # a fact is spelled back out with the `when` the author wrote. A collection's
  # source already carries the guard, inside the brackets where it belongs.
  defp describe(%IR.Fact{__ast__: %{source: source, guard: nil}}), do: Macro.to_string(source)

  defp describe(%IR.Fact{__ast__: %{source: source, guard: guard}}) do
    Macro.to_string(source) <> " when " <> Macro.to_string(guard)
  end

  defp describe(%IR.Coll{__ast__: %{source: source}}), do: Macro.to_string(source)
  defp describe(%IR.Test{__ast__: %{guard: guard}}), do: "when " <> Macro.to_string(guard)
  defp describe(%IR.Negation{condition: condition}), do: "not " <> describe(condition)

  defp describe(%IR.CompoundNegation{conditions: conditions}) do
    "not (" <> Enum.map_join(conditions, " and ", &describe/1) <> ")"
  end

  defp describe({:or, branches}) do
    "(" <>
      Enum.map_join(branches, " or ", fn branch ->
        Enum.map_join(branch, " and ", &describe/1)
      end) <> ")"
  end

  # Only reachable for a condition whose `:__ast__` has been dropped, which is
  # to say for an already escaped production. Nothing calls the sort there, but
  # an error message must never be the thing that crashes.
  defp describe(element), do: inspect(element)

  defp union(enum, fun), do: Enum.reduce(enum, MapSet.new(), &MapSet.union(fun.(&1), &2))
end
