defmodule Rete do
  @moduledoc """
  Main entry point for the Rete library.

  Provides helper functions to aggregate rule, expression, and taxonomy data
  from multiple ruleset modules. Use this module to collect and combine data
  from modules that `use Rete.Ruleset`.

  ## Example

      defmodule MyRuleset do
        use Rete.Ruleset
        # ... define rules, queries, taxonomy ...
      end

      Rete.get_rule_data([MyRuleset])
  """

  @doc """
  Retrieves expression data from the given modules, in module order.

  Returns a list of `{expr_id, expr_function}` tuples where `expr_id` is an atom
  and `expr_function` is a captured function reference.

  Deduplicated by `expr_id`, keeping the first module that defines it. That is
  sound because an expression id is the hash of the meta-stripped argument and
  body AST, with module attributes qualified by the defining module and aliases
  resolved to the module they name (see `Rete.DSL.Parser.expand_aliases/2`): two
  expressions with the same id are the same expression, so the network can share
  one node for them. The one thing the id cannot see through is an *unqualified*
  call - a local or imported function of the ruleset module - so a guard calling
  `helper(x)` in two modules that define `helper/1` differently deduplicates to
  whichever module comes first. Qualify the call.
  """
  def get_expr_data(modules) do
    modules
    |> Enum.flat_map(& &1.get_expr_data())
    |> Enum.uniq_by(fn {expr_id, _} -> expr_id end)
  end

  @doc """
  Retrieves rule data from the given modules.
  Combines all the rule data into a single list.

  Returns a list of `Rete.IR.Production` structs, one for each
  rule or query defined across all provided modules.
  """
  def get_rule_data(modules) do
    Enum.flat_map(modules, & &1.get_rule_data())
  end

  @doc """
  Retrieves taxonomy data from the given modules.
  Combines all the taxonomy data into a single list.

  Returns a list of `{operation, child_type, parent_type}` tuples where
  `operation` is either `:derive` or `:underive`, and types are atoms.
  """
  def get_taxo_data(modules) do
    Enum.flat_map(modules, & &1.get_taxo_data())
  end
end
