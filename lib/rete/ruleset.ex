defmodule Rete.Ruleset do
  @moduledoc """
  Provides macros and structures for defining rulesets in a Rete network.

  This module allows users to define rules and queries using `defrule/2` and
  `defquery/2` macros, which parse the provided expressions and generate the
  necessary internal representations. The module also supports taxonomy definitions through
  `derive/2` and `underive/2` macros.

  ## Usage

      defmodule MyRuleset do
        use Rete.Ruleset

        derive(:dog, :mammal)
        derive(:mammal, :animal)

        defrule process_animal({:animal, name}) do
          IO.puts("Found animal: \#{name}")
        end
      end
  """

  defmodule BindTestExprNode do
    @moduledoc """
    Represents a binding test expression node in a Rete network.

    Used for `when` clauses that test conditions on already-bound variables
    (e.g., `when id > 0`).

    ## Fields

    - `:code` - Unique code identifier for the test expression
    - `:bind` - List of variable names used in the test expression
    - `:expr` - The test expression function reference
    """
    defstruct [:code, :bind, :expr]
  end

  defmodule FactTypeExprNode do
    @moduledoc """
    Represents a fact type expression node in a Rete network.

    Matches individual facts against a pattern and extracts bound variables.

    ## Fields

    - `:code` - Unique code identifier for the fact type expression
    - `:fact` - Variable name the matched fact is bound to (or `:_` if not bound)
    - `:type` - The fact type atom to match against
    - `:bind` - List of variable names bound by this pattern
    - `:expr` - The fact matching expression function reference
    """
    defstruct [:code, :fact, :type, :bind, :expr]
  end

  defmodule CollTypeExprNode do
    @moduledoc """
    Represents a collection type expression node in a Rete network.

    Matches collections of facts (specified with `[{:type, var}]` syntax).

    ## Fields

    - `:code` - Unique code identifier for the collection pattern
    - `:coll` - Variable name the collection is bound to (or `:_` if not bound)
    - `:type` - The fact type atom to match against
    - `:bind` - List of variable names bound by this pattern
    - `:expr` - The collection matching expression function reference
    """
    defstruct [:code, :coll, :type, :bind, :expr]
  end

  defmodule BindTestGateNode do
    @moduledoc """
    Represents a logical gate node (AND, OR, NOT, etc.) in a Rete network.

    Combines multiple binding test expressions using logical operations.

    ## Fields

    - `:code` - Unique code identifier for the gate node
    - `:gate` - The logical gate type (`:and`, `:or`, `:not`, `:nand`, `:nor`, `:xor`, `:xnor`)
    - `:args` - List of condition nodes (FactTypeExprNode, CollTypeExprNode, BindTestExprNode, or nested BindTestGateNode)
    """
    defstruct [:code, :gate, :args]
  end

  defmodule ProductionNode do
    @moduledoc """
    Represents a production node (rule or query) in a Rete network.

    Contains the complete definition of a rule or query including its conditions
    and action.

    ## Fields

    - `:name` - The rule/query name (atom)
    - `:type` - Either `:rule` or `:query`
    - `:hash` - Unique hash identifying this production based on its declaration and body
    - `:opts` - Options keyword list (e.g., `[salience: 100]`)
    - `:bind` - List of all variable names bound across all LHS conditions
    - `:lhs` - List of condition nodes (FactTypeExprNode, CollTypeExprNode, or BindTestExprNode)
    - `:rhs` - Captured function reference with signature `(hash, bindings_map) -> result`
    """
    defstruct [:name, :type, :hash, :opts, :bind, :lhs, :rhs]
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Rete.Ruleset

      @rule_data []
      @taxo_data []

      @before_compile Rete.Ruleset
    end
  end

  # Generates a hash for an expression based on its arguments and body.
  # Strips metadata, escapes the AST, serializes to binary, then hashes with :erlang.phash2/1.
  # Returns an integer hash value.
  defp expr_hash(args, body) do
    {args, body}
    |> Macro.postwalk(&Macro.update_meta(&1, fn _ -> [] end))
    |> Macro.escape()
    |> :erlang.term_to_binary()
    |> :erlang.phash2()
  end

  # Parses the binding variables from an expression.
  # Returns a map of variable names to their AST representations.
  # Excludes pinned variables (prefixed with ^) from the binding map.
  defp parse_bind(expr) do
    {_, bind} =
      Macro.prewalk(expr, %{}, fn
        {:^, _, _}, acc ->
          {nil, acc}

        {var, meta, nil}, acc when is_atom(var) ->
          {{var, meta, nil}, Map.put(acc, var, {var, meta, nil})}

        bind, acc ->
          {bind, acc}
      end)

    bind
  end

  # Parses the arguments of a fact expression.
  # Returns a tuple of the fact type and the arguments expression.
  defp parse_args_expr(fact_expr) do
    case fact_expr do
      {fact_type, fact_args} ->
        fact_expr = quote do: {_, unquote(fact_args)}
        {fact_type, fact_expr}

      {:=, _, [fact, {fact_type, fact_args}]} ->
        {fact_type, quote(do: unquote(fact) = {_, unquote(fact_args)})}
    end
  end

  # Parses a binding expression without an associated test expression.
  # Returns a map containing the expression name, id, arguments, and body.
  defp parse_bind_expr(fact_expr, fact_bind) do
    {fact_type, args_expr} = parse_args_expr(fact_expr)
    bind_keys = Map.keys(fact_bind) |> Enum.sort()
    bind_expr = {:%{}, [], Map.to_list(fact_bind)}

    expr_hash = expr_hash(fact_expr, bind_expr)

    expr_code =
      [:fact, fact_type, :bind]
      |> Enum.concat(bind_keys)
      |> Enum.concat([:expr, expr_hash])
      |> Enum.join("_")
      |> String.to_atom()

    expr_name = String.to_atom("__#{expr_code}__")

    %{code: expr_code, name: expr_name, args: args_expr, body: bind_expr}
  end

  # Parses a binding expression with an associated test expression.
  # Returns a map containing the expression name, id, arguments, and body.
  defp parse_bind_expr(fact_expr, test_expr, fact_bind) do
    {fact_type, args_expr} = parse_args_expr(fact_expr)
    bind_keys = Map.keys(fact_bind) |> Enum.sort()

    bind_expr =
      quote do
        if unquote(test_expr) do
          unquote({:%{}, [], Map.to_list(fact_bind)})
        end
      end

    expr_hash = expr_hash(fact_expr, bind_expr)

    expr_code =
      [:test, :fact, fact_type, :bind]
      |> Enum.concat(bind_keys)
      |> Enum.concat([:expr, expr_hash])
      |> Enum.join("_")
      |> String.to_atom()

    expr_name = String.to_atom("__#{expr_code}__")

    %{code: expr_code, name: expr_name, args: args_expr, body: bind_expr}
  end

  # Parses a test expression with associated bindings.
  # Returns a map containing the expression name, id, arguments, and body.
  defp parse_test_expr(test_expr, test_bind) do
    bind_expr = {:%{}, [], Map.to_list(test_bind)}
    bind_keys = Map.keys(test_bind) |> Enum.sort()

    expr_hash = expr_hash(bind_expr, test_expr)

    expr_code =
      [:test, :bind]
      |> Enum.concat(bind_keys)
      |> Enum.concat([:expr, expr_hash])
      |> Enum.join("_")
      |> String.to_atom()

    expr_name = String.to_atom("__#{expr_code}__")

    %{code: expr_code, name: expr_name, args: bind_expr, body: test_expr}
  end

  # Parses the left-hand side (LHS) of a rule or query.
  # Returns a map containing the fact or collection, type, arguments, bindings, and expression
  defp parse_lhs(lhs_expr) do
    case lhs_expr do
      {gate, args} when is_list(args) and gate in [:and, :or, :not, :nand, :nor, :xor, :xnor] ->
        %{gate: gate, args: Enum.map(args, &parse_lhs/1)}

      {type, args} ->
        bind = parse_bind(lhs_expr)
        expr = parse_bind_expr(lhs_expr, bind)
        %{ast: lhs_expr, fact: :_, type: type, args: args, bind: bind, expr: expr}

      {:when, _, [lhs_expr = {_, _}, lhs_test]} ->
        lhs = parse_lhs(lhs_expr)
        expr = parse_bind_expr(lhs.ast, lhs_test, lhs.bind)
        Map.put(lhs, :expr, expr)

      {:when, _, [lhs_expr = {:=, _, [_, {_, _}]}, lhs_test]} ->
        lhs = parse_lhs(lhs_expr)
        expr = parse_bind_expr(lhs.ast, lhs_test, lhs.bind)
        Map.put(lhs, :expr, expr)

      [lhs_expr = {:when, _, [{_, _}, _]}] ->
        parse_lhs(lhs_expr)
        |> Map.put(:coll, :_)

      [lhs_expr = {_, _}] ->
        parse_lhs(lhs_expr)
        |> Map.put(:coll, :_)

      {:=, _, [{bind, _, nil}, bind_expr]} when is_atom(bind) ->
        lhs = parse_lhs(bind_expr)
        if Map.get(lhs, :coll), do: Map.put(lhs, :coll, bind), else: Map.put(lhs, :fact, bind)
    end
  end

  # Parses the arguments of a rule declaration.
  # Returns a tuple of rule options and the left-hand side expressions.
  defp parse_args(rule_args) do
    case rule_args do
      [{:%{}, _, rule_opts} | rule_lhs] -> {rule_opts, rule_lhs}
      rule_lhs -> {[], rule_lhs}
    end
  end

  # Parses a rule declaration and body.
  # Returns a map containing the rule name, hash, options, bindings, LHS, and RHS.
  defp parse_rule(rule_hash, rule_decl, rule_body) do
    case rule_decl do
      {:when, _, [rule_decl, rule_test]} ->
        bind = parse_bind(rule_test)
        expr = parse_test_expr(rule_test, bind)

        parse_rule(rule_hash, rule_decl, rule_body)
        |> Map.update(
          :lhs,
          [],
          &Enum.concat(&1, [
            %{bind: bind, expr: expr}
          ])
        )

      {rule_name, _, rule_args} ->
        {rule_opts, rule_lhs} = parse_args(rule_args)

        %{
          name: rule_name,
          hash: rule_hash,
          opts: rule_opts,
          bind: parse_bind(rule_lhs),
          lhs: Enum.map(rule_lhs, &parse_lhs/1),
          rhs: rule_body
        }
    end
  end

  defp cond_code(%{expr: expr}), do: expr.code
  defp cond_code(%{gate: gate, args: args}), do: Enum.concat([gate], Enum.map(args, &cond_code/1))

  defp escape_cond(cond) do
    case cond do
      %{coll: coll, type: type, bind: bind, expr: expr} ->
        struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :CollTypeExprNode]}
        bind_keys = Map.keys(bind)

        node_ast =
          {:%{}, [],
           [
             code: expr.code,
             coll: coll,
             type: type,
             bind: bind_keys,
             expr: expr.name
           ]}

        {:%, [], [struct_alias, node_ast]}

      %{fact: fact, type: type, bind: bind, expr: expr} ->
        struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :FactTypeExprNode]}
        bind_keys = Map.keys(bind)

        node_ast =
          {:%{}, [],
           [
             code: expr.code,
             fact: fact,
             type: type,
             bind: bind_keys,
             expr: expr.name
           ]}

        {:%, [], [struct_alias, node_ast]}

      %{bind: bind, expr: expr} ->
        struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :BindTestExprNode]}
        bind_keys = Map.keys(bind)

        node_ast =
          {:%{}, [],
           [
             code: expr.code,
             bind: bind_keys,
             expr: expr.name
           ]}

        {:%, [], [struct_alias, node_ast]}

      %{gate: gate, args: args} ->
        struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :BindTestGateNode]}
        code = cond_code(cond)
        node_ast = {:%{}, [], [code: code, gate: gate, args: Enum.map(args, &escape_cond/1)]}
        {:%, [], [struct_alias, node_ast]}
    end
  end

  # Escapes a rule structure into an AST representation.
  defp escape_rule(
         %{
           name: rule_name,
           hash: rule_hash,
           opts: rule_opts,
           bind: rule_bind,
           lhs: rule_lhs
         },
         type: rule_type
       ) do
    {:%{}, [],
     [
       name: rule_name,
       hash: rule_hash,
       opts: rule_opts,
       type: rule_type,
       bind: Map.keys(rule_bind),
       lhs: Enum.map(rule_lhs, &escape_cond/1)
     ]}
  end

  # Qualifies module attributes in the AST with the given module context.
  # This ensures that module attributes (@) are correctly referenced within the module scope
  # when used in rule definitions.
  defp qualify_special(ast, module) do
    Macro.prewalk(
      ast,
      fn
        {:@, m1, [{x, m2, nil}]} when is_atom(x) ->
          {:@, m1, [{x, m2, module}]}

        expr ->
          expr
      end
    )
  end

  defp cond_data(module, cond = %{expr: expr_name}) do
    expr_func = Function.capture(module, expr_name, 1)
    Map.put(cond, :expr, expr_func)
  end

  defp cond_data(module, cond = %{args: args}) do
    args = Enum.map(args, &cond_data(module, &1))
    Map.put(cond, :args, args)
  end

  @doc false
  def rule_data(module, rule = %{name: rule_name, lhs: rule_lhs}) do
    rule_lhs = Enum.map(rule_lhs, &cond_data(module, &1))

    rule_rhs = Function.capture(module, rule_name, 2)

    struct(
      Rete.Ruleset.ProductionNode,
      Map.merge(rule, %{lhs: rule_lhs, rhs: rule_rhs})
    )
  end

  defp rule_cond(cond = %{expr: _}), do: [cond]
  defp rule_cond(%{gate: _, args: args}), do: Enum.flat_map(args, &rule_cond/1)

  @doc false
  defp defproduction(rule_module, rule_decl, rule_body, rule_attr) do
    rule_decl = qualify_special(rule_decl, rule_module)
    rule_body = qualify_special(rule_body, rule_module)
    rule_hash = :erlang.phash2([rule_decl, rule_body])
    rule = parse_rule(rule_hash, rule_decl, rule_body)
    %{name: rule_name, bind: rule_bind, lhs: rule_lhs} = rule
    rule_args = [rule_hash, {:%{}, [], Map.to_list(rule_bind)}]
    rule_head = {rule_name, [], rule_args}
    rule_ast = escape_rule(rule, rule_attr)

    rule_lhs =
      rule_lhs
      |> Enum.flat_map(&rule_cond/1)
      |> Enum.uniq_by(fn cond -> cond.expr.name end)

    lhs_func =
      for %{expr: expr} <- rule_lhs do
        quote do
          if not Module.defines?(__MODULE__, {unquote(expr.name), 1}) do
            def unquote(expr.name)(args) do
              case args do
                unquote(expr.args) -> unquote(expr.body)
                _ -> nil
              end
            end
          end
        end
      end

    quote do
      unquote_splicing(lhs_func)

      @rule_data @rule_data ++ [rule_data(__MODULE__, unquote(rule_ast))]
      Kernel.def(unquote(rule_head), unquote(rule_body))
    end
  end

  @doc """
  Allows defining a rule within a ruleset.

  The `defrule/2` macro takes a rule declaration and an optional rule body,
  parses them, and generates the necessary internal representation for the rule.

  ## Examples

      # Simple rule
      defrule process_user({:user, id, name}) do
        IO.puts("User \#{id}: \#{name}")
      end

      # Rule with salience and multiple conditions
      defrule high_priority_rule(
        %{salience: 100},
        {:user, id},
        {:order, id, total} when total > 1000
      ) do
        IO.puts("High value order for user \#{id}")
      end

      # Rule with bound facts and collections
      defrule process_orders(
        user = {:user, id},
        orders = [{:order, id, amount}]
      ) do
        total = Enum.sum(Enum.map(orders, fn {_, _, amt} -> amt end))
        {user, total}
      end
  """
  defmacro defrule(rule_decl, rule_body \\ nil) do
    defproduction(__CALLER__.module, rule_decl, rule_body, type: :rule)
  end

  @doc """
  Allows defining a query within a ruleset.

  The `defquery/2` macro takes a query declaration and an optional query body,
  parses them, and generates the necessary internal representation for the query.

  ## Examples

      # Simple query
      defquery find_user({:user, id, name}) do
        {id, name}
      end

      # Query with multiple conditions
      defquery find_high_value_customers(
        {:user, id, name},
        orders = [{:order, id, total} when total > 1000]
      ) do
        {id, name, length(orders)}
      end
  """
  defmacro defquery(rule_decl, rule_body \\ nil) do
    defproduction(__CALLER__.module, rule_decl, rule_body, type: :query)
  end

  @doc """
  Allows defining a derivation relationship between two types in the taxonomy.

  The `derive/2` macro takes a child type and a parent type, and records the derivation
  in the ruleset's taxonomy data.

  ## Examples

      derive(:dog, :mammal)
      derive(:cat, :mammal)
      derive(:mammal, :animal)

      # Now rules matching :animal will also match :dog and :cat facts
      defrule process_animal({:animal, name}) do
        IO.puts("Found animal: \#{name}")
      end
  """
  defmacro derive(child, parent) do
    quote do
      @taxo_data Enum.concat(@taxo_data, [{:derive, unquote(child), unquote(parent)}])
    end
  end

  @doc """
  Allows removing a derivation relationship between two types in the taxonomy.

  The `underive/2` macro takes a child type and a parent type, and records the removal
  of the derivation in the ruleset's taxonomy data.

  ## Examples

      derive(:dog, :mammal)
      derive(:cat, :mammal)

      # Later, remove one of the derivations
      underive(:cat, :mammal)

      # Now :cat facts will no longer match rules looking for :mammal
  """
  defmacro underive(child, parent) do
    quote do
      @taxo_data Enum.concat(@taxo_data, [{:underive, unquote(child), unquote(parent)}])
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      defp get_expr_data(%{code: code, expr: expr}) do
        [{code, expr}]
      end

      defp get_expr_data(%{args: args}) do
        Enum.flat_map(args, &get_expr_data/1)
      end

      def get_expr_data do
        @rule_data
        |> Enum.flat_map(&Enum.flat_map(&1.lhs, fn cond -> get_expr_data(cond) end))
        |> Enum.uniq()
      end

      def get_rule_data do
        @rule_data
      end

      def get_taxo_data do
        @taxo_data
      end

      @version :erlang.phash2([__MODULE__, @rule_data, @taxo_data])
      def get_version do
        @version
      end
    end
  end
end
