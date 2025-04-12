defmodule Rete.Ruleset do
  defmodule TestExprNode do
    defstruct [:bind, :expr]
  end

  defmodule TypeExprNode do
    defstruct [:fact, :type, :bind, :expr]
  end

  defmodule IntoExprNode do
    defstruct [:into, :type, :bind, :expr]
  end

  defmodule RuleNode do
    defstruct [:name, :hash, :opts, :bind, :lhs, :rhs]
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

  defp strip_meta(expr) do
    Macro.postwalk(expr, &Macro.update_meta(&1, fn _ -> [] end))
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

  defp parse_bind_expr(fact_expr, bind) do
    bind_expr = {:%{}, [], Map.to_list(bind)}

    expr_fn =
      quote do: fn
              unquote(fact_expr) -> unquote(bind_expr)
              _ -> nil
            end

    expr_key = Macro.escape(strip_meta(expr_fn))
    expr_data = quote do: :erlang.term_to_binary(unquote(expr_fn))
    {expr_key, expr_data}
  end

  defp parse_bind_expr(fact_expr, test_expr, bind) do
    bind_expr = {:%{}, [], Map.to_list(bind)}

    expr_fn =
      quote do: fn
              unquote(fact_expr) ->
                if unquote(test_expr) do
                  unquote(bind_expr)
                else
                  nil
                end

              _ ->
                nil
            end

    expr_key = Macro.escape(strip_meta(expr_fn))
    expr_data = quote do: :erlang.term_to_binary(unquote(expr_fn))
    {expr_key, expr_data}
  end

  defp parse_test_expr(test_expr, bind) do
    bind_expr = {:%{}, [], Map.to_list(bind)}

    expr_fn =
      quote do: fn
              unquote(bind_expr) -> unquote(test_expr)
              _ -> nil
            end

    expr_key = Macro.escape(strip_meta(expr_fn))
    expr_data = quote do: :erlang.term_to_binary(unquote(expr_fn))
    {expr_key, expr_data}
  end

  defp parse_lhs(lhs_expr) do
    case lhs_expr do
      {:when, _, [lhs_expr = {_, _}, lhs_test]} ->
        lhs = parse_lhs(lhs_expr)
        expr = parse_bind_expr(lhs.ast, lhs_test, lhs.bind)
        Map.put(lhs, :expr, expr)

      {:when, _, [lhs_expr = {:=, _, [_, {_, _}]}, lhs_test]} ->
        lhs = parse_lhs(lhs_expr)
        expr = parse_bind_expr(lhs.ast, lhs_test, lhs.bind)
        Map.put(lhs, :expr, expr)

      bind_expr = {type, args} ->
        bind = parse_bind(bind_expr)
        expr = parse_bind_expr(bind_expr, bind)
        %{ast: bind_expr, fact: :_, type: type, args: args, bind: bind, expr: expr}

      [lhs_expr = {:when, _, [{_, _}, _]}] ->
        parse_lhs(lhs_expr)
        |> Map.put(:into, :_)

      [lhs_expr = {_, _}] ->
        parse_lhs(lhs_expr)
        |> Map.put(:into, :_)

      {:=, _, [{bind, _, nil}, bind_expr]} when is_atom(bind) ->
        lhs = parse_lhs(bind_expr)
        if Map.get(lhs, :into), do: Map.put(lhs, :into, bind), else: Map.put(lhs, :fact, bind)
    end
  end

  defp parse_args(rule_args) do
    case rule_args do
      [{:%{}, _, rule_opts} | rule_lhs] -> {rule_opts, rule_lhs}
      rule_lhs -> {[], rule_lhs}
    end
  end

  defp parse_rule(rule_hash, rule_decl, rule_body, rule_attr) do
    case rule_decl do
      {:when, _, [rule_decl, rule_test]} ->
        bind = parse_bind(rule_test)
        expr = parse_test_expr(rule_test, bind)

        parse_rule(rule_hash, rule_decl, rule_body, rule_attr)
        |> Map.update(
          :lhs,
          [],
          &Enum.concat(&1, [
            %{bind: bind, expr: expr}
          ])
        )

      {rule_name, _, rule_args} ->
        {rule_opts, rule_lhs} = parse_args(rule_args)

        Map.merge(
          rule_attr,
          %{
            name: rule_name,
            hash: rule_hash,
            opts: rule_opts,
            bind: parse_bind(rule_lhs),
            lhs: Enum.map(rule_lhs, &parse_lhs/1),
            rhs: rule_body
          }
        )
    end
  end

  def parse_rule_data(%{
        name: rule_name,
        hash: rule_hash,
        opts: rule_opts,
        bind: rule_bind,
        lhs: rule_lhs
      }) do
    {:%{}, [],
     [
       name: rule_name,
       hash: rule_hash,
       opts: rule_opts,
       bind: Map.keys(rule_bind),
       lhs:
         for cond <- rule_lhs do
           case cond do
             %{type: type, bind: bind, expr: expr, into: into} ->
               struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :IntoExprNode]}
               node_ast = {:%{}, [], [type: type, bind: Map.keys(bind), expr: expr, into: into]}
               {:%, [], [struct_alias, node_ast]}

             %{fact: fact, type: type, bind: bind, expr: expr} ->
               struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :TypeExprNode]}
               node_ast = {:%{}, [], [fact: fact, type: type, bind: Map.keys(bind), expr: expr]}
               {:%, [], [struct_alias, node_ast]}

             %{bind: bind, expr: expr} ->
               struct_alias = {:__aliases__, [alias: false], [:Rete, :Ruleset, :TestExprNode]}
               node_ast = {:%{}, [], [bind: Map.keys(bind), expr: expr]}
               {:%, [], [struct_alias, node_ast]}
           end
         end
     ]}
  end

  defmacro defrule(rule_decl, rule_body \\ nil) do
    rule_hash = :erlang.phash2([rule_decl, rule_body])
    rule = parse_rule(rule_hash, rule_decl, rule_body, %{type: :rule})
    %{name: rule_name, bind: rule_bind} = rule
    rule_args = [rule_hash, {:%{}, [], Map.to_list(rule_bind)}]
    rule_head = {rule_name, [], rule_args}
    rule_data = parse_rule_data(rule)

    quote do
      @rule_data Enum.concat(
                   @rule_data,
                   [
                     struct(
                       Rete.Ruleset.RuleNode,
                       unquote(rule_data)
                       |> Map.put(:rhs, &(__MODULE__.unquote(rule_name) / 2))
                     )
                   ]
                 )
      Kernel.def(unquote(rule_head), unquote(rule_body))
    end
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
      def get_rule_data do
        @rule_data
      end

      def get_taxo_data do
        @taxo_data
      end
    end
  end
end
