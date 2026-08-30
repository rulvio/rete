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

  Deduplicated by `expr_id`, keeping the first module that defines it.

  An expression id is the hash of the meta-stripped argument and body AST, with
  module attributes qualified by the defining module and aliases resolved to the
  module they name (see `Rete.DSL.Parser.expand_aliases/2`). The one thing it
  cannot see through is an *unqualified* call - a local or imported function of
  the ruleset module - so a guard calling `helper(x)` in two modules that define
  `helper/1` differently gets one id here and loses one of the two functions.
  Qualify the call.

  **This function is not how a network decides what to share.**
  `Rete.Compiler.build/2` reads `get_rule_data/1`, where every expression still
  carries the function of the module that wrote it, and qualifies any code more
  than one module contributed before building a node from it. Use this only to
  look at what a set of modules compiled to.
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
