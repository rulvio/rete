defmodule Rete.Ruleset do
  defmodule BindTestExprNode do
    defstruct [:bind, :expr]
  end

  defmodule FactTypeExprNode do
    defstruct [:fact, :type, :bind, :expr]
  end

  defmodule CollTypeExprNode do
    defstruct [:coll, :type, :bind, :expr]
  end

  defmodule ProductionNode do
    defstruct [:name, :type, :hash, :opts, :bind, :lhs, :rhs]
  end

  @moduledoc """
  Documentation for `Rete.Ruleset`.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Rete.Ruleset

      @rule_data []
      @taxo_data []

      @before_compile Rete.Ruleset
    end
  end

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

  defp parse_bind_expr(fact_type, fact_expr, bind) do
    bind_expr = {:%{}, [], Map.to_list(bind)}

    expr_form = expr_form(fact_expr, bind_expr)
    expr_hash = :erlang.phash2(expr_form)
    expr_name_str = "__bind_" <> to_string(fact_type) <> "_" <> to_string(expr_hash) <> "__"
    expr_name = String.to_atom(expr_name_str)

    %{
      name: expr_name,
      form: expr_form,
      args: fact_expr,
      body: bind_expr
    }
  end

  defp parse_bind_expr(fact_type, fact_expr, test_expr, bind) do
    bind_expr = {:%{}, [], Map.to_list(bind)}

    body_expr =
      quote do
        if unquote(test_expr) do
          unquote(bind_expr)
        else
          nil
        end
      end

    expr_form = expr_form(fact_expr, body_expr)
    expr_hash = :erlang.phash2(expr_form)
    expr_name_str = "__test_bind_" <> to_string(fact_type) <> "_" <> to_string(expr_hash) <> "__"
    expr_name = String.to_atom(expr_name_str)

    %{
      name: expr_name,
      form: expr_form,
      args: fact_expr,
      body: body_expr
    }
  end

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

  defp parse_lhs(lhs_expr) do
    case lhs_expr do
      bind_expr = {type, args} ->
        bind = parse_bind(bind_expr)
        expr = parse_bind_expr(type, bind_expr, bind)
        %{ast: bind_expr, fact: :_, type: type, args: args, bind: bind, expr: expr}

      {:when, _, [lhs_expr = {_, _}, lhs_test]} ->
        lhs = parse_lhs(lhs_expr)
        expr = parse_bind_expr(lhs.type, lhs.ast, lhs_test, lhs.bind)
        Map.put(lhs, :expr, expr)

      {:when, _, [lhs_expr = {:=, _, [_, {_, _}]}, lhs_test]} ->
        lhs = parse_lhs(lhs_expr)
        expr = parse_bind_expr(lhs.type, lhs.ast, lhs_test, lhs.bind)
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

  defp parse_args(rule_args) do
    case rule_args do
      [{:%{}, _, rule_opts} | rule_lhs] -> {rule_opts, rule_lhs}
      rule_lhs -> {[], rule_lhs}
    end
  end

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
  """
  defmacro defrule(rule_decl, rule_body \\ nil) do
    defproduction(__CALLER__.module, rule_decl, rule_body, type: :rule)
  end

  @doc """
  """
  defmacro defquery(rule_decl, rule_body \\ nil) do
    defproduction(__CALLER__.module, rule_decl, rule_body, type: :query)
  end

  @doc """
  """
  defmacro derive(child, parent) do
    quote do
      @taxo_data Enum.concat(@taxo_data, [{:derive, unquote(child), unquote(parent)}])
    end
  end

  @doc """
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
