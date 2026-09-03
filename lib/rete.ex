defmodule Rete do
  @moduledoc """
  Collects rule, expression and taxonomy data from ruleset modules.

  `Rete.Compiler.build/2` reads these three functions to compile a network. Call them
  directly only to look at what a set of modules compiled to.

      defmodule MyRuleset do
        use Rete.Ruleset
        # ... rules, queries, taxonomy ...
      end

      Rete.get_rule_data([MyRuleset])
  """

  @doc """
  The productions of `modules`, in module order.

      iex> Rete.get_rule_data([Rete.Doc.Orders]) |> Enum.map(&{&1.name, &1.type})
      [large_order: :rule, flagged_for: :query]
  """
  @spec get_rule_data([module()]) :: [Rete.IR.Production.t()]
  def get_rule_data(modules) do
    Enum.flat_map(modules, & &1.get_rule_data())
  end

  @doc """
  The `{expr_id, function}` pairs of `modules`, deduplicated by id, first module winning.

  An expr id is the hash of the meta-stripped AST, so two conditions share an id exactly
  when they behave the same. It cannot see through an *unqualified* call, though. Two
  modules that define `helper/1` differently, and both write `helper(x)`, get one id
  here — and the code drops one of the two functions. Qualify the call to avoid this.

  This is not how a network decides what to share. `Rete.Compiler.build/2` reads
  `get_rule_data/1` instead, where every expression still carries the function of the
  module that wrote it, and its `:share` flag. It qualifies a code that more than one
  module contributed and that the front end did not mark shared. An unqualified call is
  what clears that flag, so the network keeps the two functions apart where this
  aggregation would not. See `docs/design/ir.md` §5.

      iex> Rete.get_expr_data([Rete.Doc.Orders]) |> length()
      3
  """
  @spec get_expr_data([module()]) :: [{atom(), fun()}]
  def get_expr_data(modules) do
    modules
    |> Enum.flat_map(& &1.get_expr_data())
    |> Enum.uniq_by(fn {expr_id, _fun} -> expr_id end)
  end

  @doc """
  The taxonomy declarations of `modules`, in module order.

      iex> Rete.get_taxo_data([Rete.Doc.Orders])
      [{:derive, :premium, :customer}]
  """
  @spec get_taxo_data([module()]) :: [{:derive | :underive, atom(), atom()}]
  def get_taxo_data(modules) do
    Enum.flat_map(modules, & &1.get_taxo_data())
  end
end
