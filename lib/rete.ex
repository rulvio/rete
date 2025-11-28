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
  Retrieves expression data from the given modules.
  Combines and deduplicates the data based on the expression id.

  Returns a list of `{expr_id, expr_function}` tuples where `expr_id` is an atom
  and `expr_function` is a captured function reference.
  """
  def get_expr_data(modules) do
    Enum.map(modules, & &1.get_expr_data())
    |> Enum.reduce([], &Enum.concat/2)
    |> Enum.uniq_by(fn {expr_id, _} -> expr_id end)
  end

  @doc """
  Retrieves rule data from the given modules.
  Combines all the rule data into a single list.

  Returns a list of `Rete.Ruleset.ProductionNode` structs, one for each
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
