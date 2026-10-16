defmodule Rete.Compiler do
  @moduledoc """
  Turns ruleset modules into a `Rete.Network`.

  **Internal.** The DSL front end already ran at *compile* time inside each `defrule`.
  What is left at *build* time is the part that depends on the whole set of rules:

      Rete.Compiler.Negation   rewrite compound negations into helper productions
      disambiguate_codes/1     qualify an expression code two modules disagree on
      Rete.Image.target/2      point the productions at the image of each module
      Rete.Compiler.BetaGraph  build the beta nodes, sharing them where possible
      Rete.Network             group conditions into alpha nodes, index the taxonomy

  Node sharing is why this cannot happen per rule. Whether two conditions collapse onto
  one node depends on what every other rule already put in the graph.

  **Cross-module expression codes.** A code is equal exactly when two expressions behave
  the same — with one hole. An *unqualified* call hashes as the bare name. So two modules
  that each define `ok?/1` differently produce the same code for
  `{:bar, amt} when ok?(amt)`.

  `Rete.DSL.Codegen` clears `Rete.IR.Expr`'s `:share` for such an expression, while
  the AST and the caller's environment are still in hand. This qualifies a code the front end
  did not mark shared, and that more than one module contributed, as `<code>@<module>`, before building
  anything from it.

  Everything else is shared across modules, because nothing left in it can differ. Aliases
  resolve to the module they name, `@x` carries its defining module, and a pin is
  unwrapped — all before hashing. See `docs/design/ir.md` §5. So two modules that write
  `{:customer, cid}` match it once per fact, not once each.

  Sharing within a module is untouched. Getting a cross-module share wrong is silent
  corruption, so `:share` defaults to `false` and only a positive answer shares.
  """

  alias Rete.Compiler.BetaGraph
  alias Rete.Compiler.Negation
  alias Rete.DSL.Parser
  alias Rete.Image
  alias Rete.IR
  alias Rete.Network

  @doc """
  Builds a network from ruleset modules.

  Options:

    * `:fact_type_fn` goes to `Rete.Taxonomy.new/2`. It defaults to struct, tagged tuple
      and tagged map.
    * `:target_images` is `false` by default. The network then calls the ruleset modules.
      With `true`, it runs the image of each ruleset module, so it keeps its rules after a
      hot upgrade of the module. `config :rete, target_images: true` changes the default.
    * `:default_rule_opts` gives every rule these options, as a map or a keyword list. It
      takes `:salience`, `:cache` and `:meta`. The defaults of a module, and the options
      map of a rule, both win over it. A query does not get it.

  `config :rete, compile_timeout: ms` limits each image compile. It acts when a ruleset
  module compiles, so no build option can change it.

  **With hot code upgrades, build with `target_images: true`.** Call
  `Rete.Session.latest?/1` after each upgrade, and build a new network when it returns
  `false`. Without target images, a network built before an upgrade calls the new code.

  With `target_images: true`, raises `ArgumentError` if the image of a ruleset module did
  not compile or does not load.

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

  Useful for testing a set of productions without a ruleset module per case. It takes the
  options of `build/2`, and raises as `build/2` does.
  """
  @spec build_productions([IR.Production.t()], [tuple()], keyword()) :: Network.t()
  def build_productions(productions, taxo_data \\ [], opts \\ []) do
    validate_names!(productions)

    productions =
      productions
      |> with_defaults(Keyword.get(opts, :default_rule_opts, []))
      |> Enum.flat_map(&extract/1)
      |> disambiguate_codes()

    {productions, built} =
      if target_images?(opts), do: run_images(productions), else: {productions, %{}}

    Network.new(productions, taxo_data, Keyword.put(opts, :built_images, built))
  end

  # Before extraction, so every production here is one the user wrote, and a negation
  # helper inherits a default salience as it inherits a written one. It never inherits
  # `:cache`. See `Rete.Compiler.Negation`. A query takes the defaults too, and ignores
  # `:salience` as it ignores a written one.
  defp with_defaults(productions, defaults) do
    case Parser.check_default_rule_opts!(":default_rule_opts", defaults, inspect(defaults)) do
      [] ->
        productions

      defaults ->
        Enum.map(productions, fn %IR.Production{} = production ->
          %IR.Production{production | opts: Keyword.merge(defaults, production.opts)}
        end)
    end
  end

  defp target_images?(opts),
    do: Keyword.get(opts, :target_images, Application.get_env(:rete, :target_images, false))

  # Every function of a network comes from its productions, so pointing them at the images
  # before the build points the whole network. That walks the input, which is much smaller
  # than the network. An image that did not compile, or does not load, raises. Calls to the
  # module instead would hide it, and the session would no longer keep its rules across an
  # upgrade. A module that offers no image, such as one that is not a ruleset, keeps its
  # calls.
  defp run_images(productions) do
    modules = productions |> Enum.map(& &1.module) |> Enum.uniq()

    with {:ok, images} <- Image.collect(modules),
         :ok <- Image.load(Map.new(Map.values(images))) do
      built = Map.new(images, fn {module, {name, _beam}} -> {module, name} end)
      {Image.target(productions, images), built}
    else
      {:error, reason} ->
        raise ArgumentError, "cannot build the network. " <> Image.message(reason)
    end
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
  Qualifies every unshared expression code that more than one module contributed.

  If only one module produces an expression's code, this leaves it alone. So nothing
  changes for a single-module network. See the module doc for when a shared code can be
  trusted across modules and when it cannot.

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

  # Codes that two or more distinct modules contributed, and that at least one of them
  # refused to share.
  #
  # One refusal splits the code for **every** contributor. Qualifying only the refusing
  # side would leave the rest on a node whose function came from whichever module the
  # reduce reached first — the original bug, narrowed rather than fixed.
  #
  # The module list is deduplicated before it is counted, so a code written twice in one
  # module does not look like two contributors.
  defp shared_codes(productions) do
    productions
    |> Enum.flat_map(fn production ->
      Enum.map(IR.exprs(production), &{&1.code, production.module, &1.share})
    end)
    |> Enum.group_by(fn {code, _module, _share} -> code end)
    |> Enum.filter(fn {_code, entries} -> split?(entries) end)
    |> MapSet.new(fn {code, _entries} -> code end)
  end

  defp split?(entries) do
    contributors = entries |> Enum.map(fn {_code, module, _s} -> module end) |> Enum.uniq()

    length(contributors) > 1 and
      Enum.any?(entries, fn {_code, _module, share} -> not share end)
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
