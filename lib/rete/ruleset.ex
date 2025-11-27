defmodule Rete.Ruleset do
  @moduledoc """
  Provides macros and structures for defining rulesets in a Rete network.
  This module allows users to define rules and queries using `defrule/2` and
  `defquery/2` macros, which parse the provided expressions and generate the
  necessary internal representations. The module also supports taxonomy definitions through
  `derive/2` and `underive/2` macros.
  """

  defmodule BindTestExprNode do
    @moduledoc """
    Represents a binding test expression node in a Rete network.
    """
    defstruct [:bind, :expr]
  end

  defmodule FactTypeExprNode do
    @moduledoc """
    Represents a fact type expression node in a Rete network.
    """
    defstruct [:fact, :type, :bind, :expr]
  end

  defmodule CollTypeExprNode do
    @moduledoc """
    Represents a collection type expression node in a Rete network.
    """
    defstruct [:coll, :type, :bind, :expr]
  end

  defmodule ProductionNode do
    @moduledoc """
    Represents a production node (rule or query) in a Rete network.
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

  # Creates a standardized expression form for given arguments and body.
  # This form is used for hashing and identification of unique expressions.
  defp expr_form(args, body) do
    expr_fn =
      quote do
        fn
          unquote(args) -> unquote(body)
          _ -> nil
        end
      end

    Macro.postwalk(expr_fn, &Macro.update_meta(&1, fn _ -> [] end))
    |> Macro.escape()
  end

  # Parses the binding variables from an expression.
  # Returns a map of variable names to their AST representations.
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
  # Returns a map containing the expression name, form, arguments, and body.
  defp parse_bind_expr(fact_expr, bind) do
    {fact_type, args_expr} = parse_args_expr(fact_expr)
    bind_expr = {:%{}, [], Map.to_list(bind)}

    expr_form = expr_form(fact_expr, bind_expr)
    expr_hash = :erlang.phash2(expr_form)
    expr_name_str = "__bind_" <> to_string(fact_type) <> "_" <> to_string(expr_hash) <> "__"
    expr_name = String.to_atom(expr_name_str)

    %{
      name: expr_name,
      form: expr_form,
      args: args_expr,
      body: bind_expr
    }
  end

  # Parses a binding expression with an associated test expression.
  # Returns a map containing the expression name, form, arguments, and body.
  defp parse_bind_expr(fact_expr, test_expr, bind) do
    {fact_type, args_expr} = parse_args_expr(fact_expr)

    bind_expr =
      quote do
        if unquote(test_expr) do
          unquote({:%{}, [], Map.to_list(bind)})
        end
      end

    expr_form = expr_form(fact_expr, bind_expr)
    expr_hash = :erlang.phash2(expr_form)
    expr_name_str = "__test_bind_" <> to_string(fact_type) <> "_" <> to_string(expr_hash) <> "__"
    expr_name = String.to_atom(expr_name_str)

    %{
      name: expr_name,
      form: expr_form,
      args: args_expr,
      body: bind_expr
    }
  end

  # Parses a test expression with associated bindings.
  # Returns a map containing the expression name, form, arguments, and body.
  defp parse_test_expr(test_expr, bind) do
    bind_expr = {:%{}, [], Map.to_list(bind)}

    expr_form = expr_form(bind_expr, test_expr)
    expr_hash = :erlang.phash2(expr_form)
    expr_name_str = "__test_" <> to_string(expr_hash) <> "__"
    expr_name = String.to_atom(expr_name_str)

    %{
      name: expr_name,
      form: expr_form,
      args: bind_expr,
      body: test_expr
    }
  end

  # Parses the left-hand side (LHS) of a rule or query.
  # Returns a map containing the fact or collection, type, arguments, bindings, and expression
  defp parse_lhs(lhs_expr) do
    case lhs_expr do
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
       lhs:
         for cond <- rule_lhs do
           case cond do
             %{coll: coll, type: type, bind: bind, expr: expr} ->
               struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :CollTypeExprNode]}
               node_expr = {expr.form, expr.name}
               bind_keys = Map.keys(bind)
               node_ast = {:%{}, [], [coll: coll, type: type, bind: bind_keys, expr: node_expr]}
               {:%, [], [struct_alias, node_ast]}

             %{fact: fact, type: type, bind: bind, expr: expr} ->
               struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :FactTypeExprNode]}
               node_expr = {expr.form, expr.name}
               bind_keys = Map.keys(bind)
               node_ast = {:%{}, [], [fact: fact, type: type, bind: bind_keys, expr: node_expr]}
               {:%, [], [struct_alias, node_ast]}

             %{bind: bind, expr: expr} ->
               struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :BindTestExprNode]}
               node_expr = {expr.form, expr.name}
               bind_keys = Map.keys(bind)
               node_ast = {:%{}, [], [bind: bind_keys, expr: node_expr]}
               {:%, [], [struct_alias, node_ast]}
           end
         end
     ]}
  end

  # Qualifies special forms in the AST with the given module.
  # This ensures that attributes are correctly referenced within the module context.
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

  @doc false
  def rule_data(module, rule = %{name: rule_name, lhs: rule_lhs}) do
    rule_lhs =
      Enum.map(
        rule_lhs,
        &Map.update(&1, :expr, nil, fn
          {expr_form, expr_name} ->
            {expr_form, Function.capture(module, expr_name, 1)}
        end)
      )

    rule_rhs = Function.capture(module, rule_name, 2)

    struct(
      Rete.Ruleset.ProductionNode,
      Map.merge(rule, %{lhs: rule_lhs, rhs: rule_rhs})
    )
  end

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
      Enum.uniq_by(
        rule_lhs,
        fn cond -> cond.expr.name end
      )

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
  """
  defmacro defrule(rule_decl, rule_body \\ nil) do
    defproduction(__CALLER__.module, rule_decl, rule_body, type: :rule)
  end

  @doc """
  Allows defining a query within a ruleset.
  The `defquery/2` macro takes a query declaration and an optional query body,
  parses them, and generates the necessary internal representation for the query.
  """
  defmacro defquery(rule_decl, rule_body \\ nil) do
    defproduction(__CALLER__.module, rule_decl, rule_body, type: :query)
  end

  @doc """
  Allows defining a derivation relationship between two types in the taxonomy.
  The `derive/2` macro takes a child type and a parent type, and records the derivation
  in the ruleset's taxonomy data.
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
  """
  defmacro underive(child, parent) do
    quote do
      @taxo_data Enum.concat(@taxo_data, [{:underive, unquote(child), unquote(parent)}])
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      def get_expr_data do
        @rule_data
        |> Enum.flat_map(&Enum.map(&1.lhs, fn cond -> cond.expr end))
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
