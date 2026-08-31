defmodule Rete.Compiler.Sort do
  @moduledoc """
  Topological ordering of the left hand side of a production.

  **Internal.** A rule reads best in the order the author thought of it. The network needs
  an order in which every join already has its keys in the token. This phase reorders the
  LHS so a condition comes after the conditions that bind what it needs, so

      defrule r({:order, amt} when amt > t, {:threshold, t})

  is sorted into `{:threshold, t}, {:order, amt} when amt > t`.

  A condition **needs** only what it reads and cannot supply itself. `_`-prefixed names
  are dropped, since no ordering can satisfy one. What it **binds** comes from
  `Rete.IR.lhs_bindings/1`, so this phase and the production's `:bind` cannot drift apart.

  Each pass takes every condition satisfiable right now, in author order, so equally
  satisfiable conditions keep the order they were written in and two rules sharing a
  prefix still share their nodes. Collections and tests are deferred: a collection placed
  too early propagates `[]` before the conditions that would have filled it are joined.

  Runs after `Rete.DSL.Normalize`, because a `Rete.IR.Gate` reaching it raises, and before
  `Rete.DSL.Bindings`, which reads `:join_bind` off the final order. See
  `docs/design/ir.md` §1.
  """

  alias Rete.DSL.Vars
  alias Rete.IR

  @typedoc "A set of variable names."
  @type vars :: MapSet.t(atom())

  @doc """
  Sorts the left hand side of a production topologically.

  Returns the production with its `:lhs` reordered. The conditions themselves are
  untouched, except that a disjunction's branches and a `Rete.IR.CompoundNegation`'s
  conjunction are sorted the same way, against the variables bound where they sit.

  Idempotent. Sorting an already sorted LHS returns it unchanged.

      iex> alias Rete.{Compiler.Sort, IR}
      iex> order = %IR.Fact{bind: [:amt], __ast__: %{guard: quote(do: amt > t), bind: %{}}}
      iex> threshold = %IR.Fact{bind: [:t]}
      iex> production = %IR.Production{name: :r, lhs: [order, threshold]}
      iex> Sort.sort(production).lhs |> Enum.map(& &1.bind)
      [[:t], [:amt]]
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

  # What a conjunction cannot satisfy for itself. Its elements bind each other, so only
  # what none of them binds is asked of the conditions upstream.
  defp residual(elements) do
    {guaranteed, _optional} = IR.lhs_bindings(elements)
    elements |> union(&needs/1) |> MapSet.difference(MapSet.new(guaranteed))
  end

  # The fact supplies a guard variable the condition's own pattern binds. Everything else
  # has to come out of the token, which means from an earlier condition.
  defp guard_needs(condition) do
    own = MapSet.new(IR.bound_vars(condition))

    condition
    |> guards()
    |> union(&Vars.read_vars/1)
    |> MapSet.difference(own)
    |> Enum.reject(&Vars.discarded?/1)
    |> MapSet.new()
  end

  # The join filter is read too, so sorting an already classified LHS is the identity.
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

  # Every satisfiable condition of this pass, in author order. `split_with/2` preserves
  # the order of both halves, which is the whole stability guarantee.
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

  # A branch is a small LHS of its own, sorted against the variables bound where the
  # disjunction sits.
  defp place({:or, branches}, bound, optional, production) do
    branches = Enum.map(branches, &sorted(&1, bound, optional, production))
    contribute({:or, branches}, bound, optional)
  end

  # So is the conjunction inside a compound negation, whose conditions bind each other
  # even though none of them escapes.
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

  # `Rete.DSL.Bindings` checks both once per path through the LHS, so it can name the
  # branch the variable is missing on. Reordering cannot help either way.
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

  # Which condition waits for which variable is the whole answer, so every unplaced
  # condition carries its own unmet needs.
  defp unplaced({element, needs}, bound) do
    case needs |> MapSet.difference(bound) |> Enum.sort() do
      [] -> describe(element)
      unmet -> describe(element) <> " - needs " <> vars(unmet)
    end
  end

  defp vars(names), do: Enum.map_join(names, ", ", &"`#{&1}`")

  # The parser keeps a condition's guard beside its source, so a fact is spelled back out
  # with the `when` the author wrote. A collection's source already carries its guard.
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

  # Only reachable for an already escaped production, whose `:__ast__` is gone. Nothing
  # sorts there, but an error message must never be the thing that crashes.
  defp describe(element), do: inspect(element)

  defp union(enum, fun), do: Enum.reduce(enum, MapSet.new(), &MapSet.union(fun.(&1), &2))
end
