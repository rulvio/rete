defmodule Rete.Compiler do
  @moduledoc """
  Turns ruleset modules into a `Rete.Network`.

  **Internal.** The DSL front end already ran at *compile* time inside each `defrule`.
  What is left at *build* time is the part that depends on the whole set of rules:

      Rete.Compiler.Negation   rewrite compound negations into helper productions
      disambiguate_codes/1     qualify an expression code two modules disagree on
      Rete.Compiler.BetaGraph  build the beta nodes, sharing them where possible
      Rete.Network             group conditions into alpha nodes, index the taxonomy

  Node sharing is why this cannot happen per rule. Whether two conditions collapse onto
  one node depends on what every other rule already put in the graph.

  **Cross-module expression codes.** A code is equal exactly when two expressions behave
  the same — with one hole. An *unqualified* call hashes as the bare name. So two modules
  that each define `ok?/1` differently produce the same code for
  `{:bar, amt} when ok?(amt)`. The compiler qualifies a code more than one module
  contributed as `<code>@<module>`, before building anything from it. Sharing within a
  module is untouched. Sharing across modules is only an optimisation, and getting it
  wrong is silent corruption. See `docs/design/ir.md` §5.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.Compiler.Negation
  alias Rete.IR
  alias Rete.Network

  @doc """
  Builds a network from ruleset modules.

  Options go to `Rete.Taxonomy.new/2`. `:fact_type_fn` is the one that matters, and it
  defaults to struct, tagged tuple and tagged map.

      Rete.Compiler.build([MyRuleset])
      Rete.Compiler.build([MyRuleset, OtherRuleset], fact_type_fn: &MyApp.type/1)
  """
  @spec build([module()], keyword()) :: Network.t()
  def build(modules, opts \\ []) when is_list(modules) do
    productions = Rete.get_rule_data(modules)
    taxo_data = Rete.get_taxo_data(modules)

    build_productions(productions, taxo_data, opts)
  end

  @doc """
  Builds a network from productions directly, bypassing module aggregation.

  Useful for testing a set of productions without a ruleset module per case.
  """
  @spec build_productions([IR.Production.t()], [tuple()], keyword()) :: Network.t()
  def build_productions(productions, taxo_data \\ [], opts \\ []) do
    validate_names!(productions)

    productions
    |> Enum.flat_map(&extract/1)
    |> disambiguate_codes()
    |> Network.new(taxo_data, opts)
  end

  # A helper must be added before the production that negates its marker. So its
  # terminal exists when the negation node is built.
  defp extract(production) do
    {rewritten, helpers} = Negation.extract(production)
    helpers ++ [rewritten]
  end

  # A production is identified by module *and* name, so two rulesets may use the same
  # name. Within one module, a repeat is a mistake. The second declaration would take
  # over the query function and the RHS.
  defp validate_names!(productions) do
    duplicates =
      productions
      |> Enum.group_by(&{&1.module, &1.name})
      |> Enum.filter(fn {_ref, group} -> length(group) > 1 end)

    case duplicates do
      [] ->
        :ok

      duplicates ->
        detail =
          Enum.map_join(duplicates, "\n", fn {{module, name}, group} ->
            "  #{name} declared #{length(group)} times in #{inspect(module)}"
          end)

        raise ArgumentError, """
        a module declares the same production name more than once:

        #{detail}

        A name identifies a query to run and a rule to attribute an activation \
        to, so it has to be unique within its module. Across modules it need \
        not be — a production is identified by `{module, name}`.
        """
    end
  end

  # --- cross module expression codes -------------------------------------------

  @doc """
  Qualifies every expression code that more than one module contributed.

  If only one module produces an expression's code, this leaves it alone. So
  nothing changes for a single-module network. See the module doc for why a
  shared code cannot be trusted across modules.

  This is exposed so a test can check the disambiguation, without building a network.
  """
  @spec disambiguate_codes([IR.Production.t()]) :: [IR.Production.t()]
  def disambiguate_codes(productions) do
    shared = shared_codes(productions)

    if MapSet.size(shared) == 0 do
      productions
    else
      Enum.map(productions, &qualify_production(&1, shared))
    end
  end

  # Codes contributed by two or more distinct modules. `Enum.uniq/1` runs first, so a
  # code written twice in one module does not look shared.
  defp shared_codes(productions) do
    productions
    |> Enum.flat_map(fn production ->
      Enum.map(IR.exprs(production), &{&1.code, production.module})
    end)
    |> Enum.uniq()
    |> Enum.frequencies_by(fn {code, _module} -> code end)
    |> Enum.filter(fn {_code, modules} -> modules > 1 end)
    |> MapSet.new(fn {code, _modules} -> code end)
  end

  defp qualify_production(%IR.Production{lhs: lhs, module: module} = production, shared) do
    %IR.Production{production | lhs: Enum.map(lhs, &qualify(&1, module, shared))}
  end

  # The same shapes `Rete.IR.exprs/1` walks. Do not add a catch-all clause here. A
  # condition kind this does not know about would keep a code the rest of the build has
  # split.
  defp qualify(%IR.Fact{} = fact, module, shared) do
    %IR.Fact{
      fact
      | alpha: qualify_expr(fact.alpha, module, shared),
        join_filter: qualify_expr(fact.join_filter, module, shared)
    }
  end

  defp qualify(%IR.Coll{} = coll, module, shared) do
    %IR.Coll{
      coll
      | alpha: qualify_expr(coll.alpha, module, shared),
        join_filter: qualify_expr(coll.join_filter, module, shared)
    }
  end

  defp qualify(%IR.Test{} = test, module, shared) do
    %IR.Test{test | expr: qualify_expr(test.expr, module, shared)}
  end

  defp qualify(%IR.Negation{condition: condition}, module, shared) do
    %IR.Negation{condition: qualify(condition, module, shared)}
  end

  defp qualify(%IR.CompoundNegation{conditions: conditions}, module, shared) do
    %IR.CompoundNegation{conditions: Enum.map(conditions, &qualify(&1, module, shared))}
  end

  # Normalization rewrites every gate away before this runs. So `:code` has no reader
  # left to keep in step.
  defp qualify(%IR.Gate{args: args} = gate, module, shared) do
    %IR.Gate{gate | args: Enum.map(args, &qualify(&1, module, shared))}
  end

  defp qualify({:or, branches}, module, shared) do
    {:or, Enum.map(branches, fn branch -> Enum.map(branch, &qualify(&1, module, shared)) end)}
  end

  defp qualify_expr(nil, _module, _shared), do: nil

  defp qualify_expr(%IR.Expr{code: code} = expr, module, shared) do
    if MapSet.member?(shared, code) do
      %IR.Expr{expr | code: :"#{code}@#{inspect(module)}"}
    else
      expr
    end
  end

  @doc """
  The beta graph of a network, for inspection.
  """
  @spec graph(Network.t()) :: BetaGraph.t()
  def graph(%Network{graph: graph}), do: graph
end
