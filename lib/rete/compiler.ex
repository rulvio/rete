defmodule Rete.Compiler do
  @moduledoc """
  Turns ruleset modules into a `Rete.Network`.

  The DSL front end already ran at *compile* time, inside each `defrule`: the
  productions a ruleset module hands over are parsed, normalized, sorted and
  classified, and their expression functions are compiled into that module. What
  is left to do at *build* time is the part that depends on the whole set of
  rules rather than on one rule:

      Rete.Compiler.Negation   rewrite compound negations into helper productions
      disambiguate_codes/1     qualify an expression code two modules disagree on
      Rete.Compiler.BetaGraph  build the beta nodes, sharing them where possible
      Rete.Network             group conditions into alpha nodes, index the taxonomy

  Node sharing is the reason this cannot happen per rule: whether two conditions
  collapse onto one node depends on what every other rule already put in the
  graph.

  ## Cross module expression codes

  An expression code is the sharing key of every node built from it, and the front end
  promises that two codes are equal exactly when the two expressions behave the
  same. That promise has one hole, recorded as a known gap in `w1-ir.md`: the
  hash is taken over the meta stripped AST with aliases, `__MODULE__` and module
  attributes resolved, but an **unqualified** call - a local or imported
  function of the ruleset module - hashes as the bare name. Two modules that
  each define `ok?/1` differently produce the same code for
  `{:bar, amt} when ok?(amt)` and compile it to two different functions.

  So a code contributed by more than one module is qualified with the module
  that contributed it, `<code>@<module>`, before anything is built from it.
  Sharing inside a module is untouched; sharing across modules is only ever an
  optimisation, while getting it wrong is silent corruption - the alpha map
  would keep whichever module was reduced first, and since a node's sharing key
  is built from the alpha code the two rules would collapse onto one beta chain
  as well, so the second rule would run the first module's predicate.

  Nothing at build time can tell a real collision from two modules that did
  write the same condition: the AST is long gone and the captured functions are
  `&A.f/1` and `&B.f/1` either way. Qualifying is the conservative half of that
  choice, and the only one that cannot be wrong.

  ## Validation

  Building fails, rather than producing a network that misbehaves later:

    * two productions with the same name, even across modules — a query would
      otherwise be ambiguous and an activation unattributable.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.Compiler.Negation
  alias Rete.IR
  alias Rete.Network

  @doc """
  Builds a network from ruleset modules.

  Options are passed through to `Rete.Taxonomy.new/2`; `:fact_type_fn` is the
  one that matters, and it defaults to struct, tagged tuple and tagged map.

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

  # A helper must be added before the production that negates its marker, so
  # that its terminal exists when the negation node is built.
  defp extract(production) do
    {rewritten, helpers} = Negation.extract(production)
    helpers ++ [rewritten]
  end

  defp validate_names!(productions) do
    duplicates =
      productions
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, group} -> length(group) > 1 end)

    case duplicates do
      [] ->
        :ok

      duplicates ->
        detail =
          Enum.map_join(duplicates, "\n", fn {name, group} ->
            "  #{name} in #{Enum.map_join(group, ", ", &inspect(&1.module))}"
          end)

        raise ArgumentError, """
        two or more productions share a name:

        #{detail}

        A name identifies a query to look up and a rule to attribute an \
        activation to, so it has to be unique across every module in a network.
        """
    end
  end

  # --- cross module expression codes -------------------------------------------

  @doc """
  Qualifies every expression code that more than one module contributed.

  The code of an expression only the module it is written in produces is left
  alone, so nothing changes for a single module network. See the module doc for
  why a shared code cannot be trusted across modules.

  Exposed so that a test can check the disambiguation without a network.
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

  # Codes contributed by two or more distinct modules. `Enum.uniq/1` first, so
  # that a code written twice in one module does not look shared.
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

  # The same shapes `Rete.IR.exprs/1` walks, and deliberately with no catch all
  # clause: a condition kind this does not know about would otherwise keep a
  # code that the rest of the build has already split.
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

  # Normalization rewrites every gate away long before this runs, so :code -
  # which identifies the gate by the codes of its arguments - has no reader
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
