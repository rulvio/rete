defmodule Rete.Ruleset do
  @moduledoc """
  Macros for defining rulesets in a Rete network.

  A rule reads as a function: its **arguments are the left hand side** and its
  **body is the right hand side**. Pattern matching in the argument list gives
  destructuring, variable binding and join variable identification for free, and
  the value the body returns is the facts to insert.

      defmodule MyRuleset do
        use Rete.Ruleset

        derive(:dog, :mammal)
        derive(:mammal, :animal)

        defrule loyalty(
                  %{salience: 100},
                  {:customer, cid, name},
                  orders = [{:order, cid, _amt}]
                ) do
          {:loyalty, cid, name, length(orders)}
        end
      end

  This module is the public face of the DSL; every `defrule` and `defquery`
  expands by running the front end pipeline

      Rete.DSL.Parser      parse the quoted declaration into Rete.IR
      Rete.DSL.Normalize   rewrite gates into conditions, negations and :or
      Rete.Compiler.Sort   order the conditions so every join has its keys
      Rete.DSL.Bindings    classify join/new bindings, split guards
      build/4              recompute the production's :bind from the result
      Rete.DSL.Codegen     emit the expression functions and the RHS

  See `docs/design/w1-ir.md` for the contract between the phases.

  ## Generated functions

  Using this module makes the ruleset expose:

    * `get_rule_data/0` - the `Rete.IR.Production` structs of the module.
    * `get_expr_data/0` - `{code, function}` pairs of every LHS expression:
      alpha expressions, join filters and tests alike, deduplicated by code.
    * `get_taxo_data/0` - the `derive`/`underive` declarations, in order.
    * `get_version/0` - a hash of the module, its rules and its taxonomy.
    * `<rule_name>/2` - the right hand side of each production,
      `(hash, bindings_map) -> facts`.
    * `__<expr_code>__/1` and `__<expr_code>__/2` - one function per distinct
      expression.

  `Rete` aggregates the first four across modules.
  """

  alias Rete.Compiler.Sort
  alias Rete.DSL.Bindings
  alias Rete.DSL.Codegen
  alias Rete.DSL.Normalize
  alias Rete.DSL.Parser
  alias Rete.IR

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Rete.Ruleset

      @rule_data []
      @taxo_data []

      # The module attribute values behind each generated expression, so that
      # two identically written conditions reading different values are
      # rejected instead of silently sharing one compiled function. See
      # `Rete.DSL.Codegen.check_attr_values!/3`.
      @rete_expr_attrs %{}

      @before_compile Rete.Ruleset
    end
  end

  @doc """
  Runs the front end pipeline over a quoted production declaration.

  Returns the fully classified `Rete.IR.Production`, ready for
  `Rete.DSL.Codegen.compile/1`. Exposed so that a test can inspect the IR of a
  declaration without compiling a module for it.

  The last step is recomputing `:bind` from the classified LHS with
  `Rete.IR.lhs_bindings/1`, so that it is exactly the set of variables a token
  reaching the right hand side can carry.
  """
  @spec build(Macro.Env.t(), Macro.t(), Macro.t(), :rule | :query) :: IR.Production.t()
  def build(env, decl, body, type) do
    production = Parser.parse_production(env, decl, body, type)
    production = %IR.Production{production | lhs: Normalize.normalize_lhs(production.lhs)}

    env
    |> Bindings.classify(Sort.sort(production))
    |> resolve_bindings()
  end

  # `:bind` is a product of the pipeline, not a pre-pass. The parser can only
  # see the raw declaration, where every variable of every element looks like a
  # binding; only the normalized and classified LHS knows that a negation binds
  # nothing downstream, that a rule level guard only *reads* variables, and that
  # a disjunction binds the union of its branches with only the intersection
  # guaranteed. Recomputing it here is what keeps the RHS callable with exactly
  # the bindings the LHS produces.
  defp resolve_bindings(%IR.Production{lhs: lhs, __ast__: ast} = production) do
    {guaranteed, optional} = IR.lhs_bindings(lhs)
    bind = Enum.sort(guaranteed ++ optional)

    %IR.Production{production | bind: bind, __ast__: %{ast | bind: bind_ast(ast.bind, bind)}}
  end

  # Keeps the variable AST the parser collected, so the RHS pattern carries the
  # metadata of the source, and drops the entries that turned out not to bind.
  defp bind_ast(parsed, bind) do
    Map.new(bind, fn var -> {var, Map.get(parsed, var) || {var, [], nil}} end)
  end

  # Runs the pipeline, then emits the expression functions, records the IR in
  # @rule_data and defines the right hand side function.
  defp defproduction(env, decl, body, type) do
    env
    |> build(decl, body, type)
    |> Codegen.compile()
  end

  # A production written without a `do` block. Emitting its RHS would define a
  # bodiless function head, and the module would fail to compile with
  # "implementation not provided for predefined def", naming the generated
  # function rather than the rule.
  @spec no_body!(Macro.t(), :rule | :query) :: no_return()
  defp no_body!(decl, type) do
    raise ArgumentError,
          "`def#{type} #{decl_name(decl)}` has no body. The body of a rule is its right " <>
            "hand side, the facts to logically insert; the body of a query is the result " <>
            "computed for the caller. Write it as `def#{type} #{decl_name(decl)}(...) do " <>
            "... end`."
  end

  defp decl_name({:when, _, [decl, _guard]}), do: decl_name(decl)
  defp decl_name({name, _, _args}) when is_atom(name), do: name
  defp decl_name(decl), do: Macro.to_string(decl)

  @doc """
  Defines a rule.

  The declaration is the left hand side and the body is the right hand side.
  The value the body returns is logically inserted and truth maintained;
  returning `nil` or `[]` inserts nothing.

  ## Left hand side elements

      {:user, id}                      fact pattern, any arity, including {:tick}
      %User{id: id}                    struct fact pattern, the type is the module
      %{__type__: :user, id: id}       tagged map fact pattern
      user = {:user, id}               bind the whole fact
      {:order, total} when total > 10  per condition guard
      [{:order, id}]                   collect all matching facts (anonymous)
      orders = [{:order, id}]          collect all matching facts, bound
      {:not, [{:order, id}]}           gate: :and :or :not :nand :nor :xor :xnor

  A `%{...}` literal in first position is the rule options, not a condition. A
  `when` after the argument list is a guard over all bindings.

  ## Examples

      # Simple rule
      defrule process_user({:user, id, name}) do
        {:greeted, id, name}
      end

      # Rule with salience and multiple conditions
      defrule high_priority_rule(
                %{salience: 100},
                {:user, id},
                {:order, id, total} when total > 1000
              ) do
        {:high_value, id, total}
      end

      # Rule with bound facts and collections
      defrule process_orders(
                user = {:user, id},
                orders = [{:order, id, amount}]
              ) do
        {:total, user, Enum.sum(Enum.map(orders, fn {_, _, amt} -> amt end))}
      end
  """
  defmacro defrule(decl, body) do
    defproduction(__CALLER__, decl, body, :rule)
  end

  @doc false
  defmacro defrule(decl), do: no_body!(decl, :rule)

  @doc """
  Defines a query.

  A query has the same left hand side as a rule, but it never fires: it holds
  the matches that reached it, for `Rete.Session.query/3` to read back by name.
  Its **body is what the caller gets**, one result per match — so a query is a
  question with an answer shaped however you like, not a window onto raw
  bindings.

  There is nothing to declare about parameters. The caller may constrain any
  variable the left hand side binds:

      Rete.Session.query(session, :find_orders_of, id: 1)

  Filtering happens on the bindings, before the body runs, which is what makes a
  filter name a variable rather than a shape of the result. A filter naming
  something the query does not bind is an error rather than an empty list.

  ## Examples

      defquery find_user({:user, id, name}) do
        {id, name}
      end
      #=> Rete.Session.query(session, :find_user)         [{1, "Ada"}]
      #=> Rete.Session.query(session, :find_user, id: 1)  [{1, "Ada"}]

      # The body can compute anything, including things no binding holds.
      defquery order_summary({:user, id, name}, orders = [{:order, id, total}]) do
        %{customer: name, orders: length(orders), total: Enum.sum(Enum.map(orders, &elem(&1, 2)))}
      end
  """
  defmacro defquery(decl, body) do
    defproduction(__CALLER__, decl, body, :query)
  end

  @doc false
  defmacro defquery(decl), do: no_body!(decl, :query)

  @doc """
  Declares a derivation relationship between two types in the taxonomy.

  ## Examples

      derive(:dog, :mammal)
      derive(:cat, :mammal)
      derive(:mammal, :animal)

      # Now rules matching :animal will also match :dog and :cat facts
      defrule process_animal({:animal, name}) do
        {:seen, name}
      end
  """
  defmacro derive(child, parent) do
    quote do
      @taxo_data Enum.concat(@taxo_data, [{:derive, unquote(child), unquote(parent)}])
    end
  end

  @doc """
  Removes a derivation relationship between two types in the taxonomy.

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
      def get_expr_data do
        @rule_data
        |> Enum.flat_map(&Rete.IR.expr_data/1)
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
