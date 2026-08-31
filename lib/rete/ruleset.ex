defmodule Rete.Ruleset do
  @moduledoc """
  Macros for defining rulesets in a Rete network.

  A rule reads as a function. Its **arguments are the left hand side** and its **body is
  the right hand side**. Pattern matching in the argument list gives destructuring,
  variable binding and join-variable identification for free, and what the body returns
  is the facts to insert. `docs/dsl.md` is the guide.

      defmodule MyRuleset do
        use Rete.Ruleset

        derive(:dog, :mammal)

        defrule loyalty(%{salience: 100}, {:customer, cid, name}, orders = [{:order, cid, _amt}]) do
          {:loyalty, cid, name, length(orders)}
        end
      end

  Using this module makes the ruleset expose `get_rule_data/0`, `get_expr_data/0`,
  `get_taxo_data/0` and `get_version/0`, which `Rete` aggregates across modules. It also
  defines `<query_name>/1,2` per query, which is the public face of a query, plus the
  `__rhs_<name>__/2` and `__<expr_code>__/1,2` machinery the engine calls.

  Every `defrule` and `defquery` expands by running the front end pipeline:

      Rete.DSL.Parser      parse the quoted declaration into Rete.IR
      Rete.DSL.Normalize   rewrite gates into conditions, negations and :or
      Rete.Compiler.Sort   order the conditions so every join has its keys
      Rete.DSL.Bindings    classify join/new bindings, split guards
      build/4              recompute the production's :bind from the result
      Rete.DSL.Codegen     emit the expression functions and the RHS

  See `docs/design/w1-ir.md` §1 for the contract between the phases.
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

      # name => {:rule | :query, line}, for the duplicate name check. Separate from
      # @rule_data, which holds escaped IR with the compile-time AST already dropped.
      @rete_productions %{}

      # The module attribute values behind each generated expression, so two identically
      # written conditions reading different values do not share one compiled function.
      # See `Rete.DSL.Codegen.check_attr_values!/3`.
      @rete_expr_attrs %{}

      @before_compile Rete.Ruleset
    end
  end

  @doc """
  Runs the front end pipeline over a quoted production declaration.

  Returns the fully classified `Rete.IR.Production`, ready for
  `Rete.DSL.Codegen.compile/1`. Exposed so a test can inspect the IR of a declaration
  without compiling a module for it.

  The last step recomputes `:bind` from the classified LHS, so it is exactly the set of
  variables a token reaching the right hand side can carry.
  """
  @spec build(Macro.Env.t(), Macro.t(), Macro.t(), :rule | :query) :: IR.Production.t()
  def build(env, decl, body, type) do
    production = Parser.parse_production(env, decl, body, type)
    production = %IR.Production{production | lhs: Normalize.normalize_lhs(production.lhs)}

    env
    |> Bindings.classify(Sort.sort(production))
    |> resolve_bindings()
  end

  # `:bind` is a product of the pipeline, not a pre-pass. To the parser every variable of
  # every element looks like a binding. Only the classified LHS knows that a negation
  # binds nothing downstream, that a rule level guard only reads, and that a disjunction
  # binds the union of its branches. See `docs/design/w1-ir.md` §2.
  defp resolve_bindings(%IR.Production{lhs: lhs, __ast__: ast} = production) do
    {guaranteed, optional} = IR.lhs_bindings(lhs)
    bind = Enum.sort(guaranteed ++ optional)

    %IR.Production{production | bind: bind, __ast__: %{ast | bind: bind_ast(ast.bind, bind)}}
  end

  # Keeps the variable AST the parser collected, so the RHS pattern carries the source
  # metadata, and drops the entries that turned out not to bind.
  defp bind_ast(parsed, bind) do
    Map.new(bind, fn var -> {var, Map.get(parsed, var) || {var, [], nil}} end)
  end

  # The name check is spliced in ahead of the codegen, so the first thing to fail on a
  # repeated name is the check that can explain it. Two queries of one name would
  # otherwise collide as two definitions of the same function.
  defp defproduction(env, decl, body, type) do
    production = build(env, decl, body, type)

    quote do
      unquote(name_check(env, production.name, type))
      unquote(Codegen.compile(production))
    end
  end

  defp name_check(env, name, type) do
    quote do
      # Fully qualified: this is spliced into the user's module, which has no alias for
      # this one.
      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      Rete.Ruleset.check_name!(
        __MODULE__,
        unquote(name),
        unquote(type),
        unquote(Path.relative_to_cwd(env.file)),
        unquote(env.line)
      )
    end
  end

  @doc """
  Rejects a production name the module has already used, and records it.

  Called from the module body, not at macro expansion. A module body is expanded in full
  **before** any of it is evaluated, so at expansion time the attribute recording earlier
  declarations is still empty and every declaration would look like the first.

  Rules and queries share one namespace.
  """
  @spec check_name!(module(), atom(), :rule | :query, String.t(), pos_integer()) :: :ok
  def check_name!(module, name, type, file, line) do
    declared = Module.get_attribute(module, :rete_productions) || %{}

    case Map.fetch(declared, name) do
      {:ok, {first_type, first_line}} ->
        raise ArgumentError, """
        #{file}:#{line}: def#{type} #{name} repeats a name already declared in \
        #{inspect(module)} — def#{first_type} #{name}, #{file}:#{first_line}.

        A production name identifies a rule to attribute an activation to and a \
        query to run, so it has to be unique within its module, and rules and \
        queries share one namespace. Across modules it need not be unique: a \
        production is identified by `{module, name}`.

        A production is not a function clause. Every rule whose left hand side \
        holds fires, and a query answers from every match, so two of one name \
        would both apply rather than the first winning. Write one production \
        over a disjunction, `{:or, [...]}`, if that is what you meant.
        """

      :error ->
        Module.put_attribute(module, :rete_productions, Map.put(declared, name, {type, line}))
        :ok
    end
  end

  # A production written without a `do` block. Emitting its RHS would define a bodiless
  # function head, and the module would fail to compile with "implementation not provided
  # for predefined def", naming the generated function rather than the rule.
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

  The declaration is the left hand side and the body is the right hand side. What the
  body returns is logically inserted and truth maintained. `nil` or `[]` inserts nothing.

      {:user, id}                      fact pattern, any arity, including {:tick}
      %User{id: id}                    struct fact pattern, the type is the module
      %{__type__: :user, id: id}       tagged map fact pattern
      user = {:user, id}               bind the whole fact
      {:order, total} when total > 10  per condition guard
      orders = [{:order, id}]          collect all matching facts, bound or anonymous
      {:not, [{:order, id}]}           gate: :and :or :not :nand :nor :xor :xnor

  A `%{...}` literal in **first** position is the rule's options, not a condition. A
  `when` after the argument list is a guard over all bindings. See `docs/dsl.md`.

      defrule high_value(%{salience: 100}, {:user, id}, {:order, id, t} when t > 1000) do
        {:high_value, id, t}
      end
  """
  defmacro defrule(decl, body) do
    defproduction(__CALLER__, decl, body, :rule)
  end

  @doc false
  defmacro defrule(decl), do: no_body!(decl, :rule)

  @doc """
  Defines a query.

  A query has the same left hand side as a rule but never fires. It holds the matches
  that reached it, and its **body is what the caller gets**, one result per match.

  **The query is a function.** `defquery find_user(...)` also defines `find_user/1,2` in
  the same module, so it is run by calling it. That is what makes a query addressable, and
  why two rulesets may each define one of the same name. Use `Rete.Session.query/3` with
  `{MyRuleset, :find_user}` when the query is decided at runtime.

  There is nothing to declare about parameters. The caller may constrain any variable the
  left hand side binds. Filtering happens on the bindings, before the body runs. A filter
  naming something the query does not bind raises rather than answering `[]`.

      defquery find_user({:user, id, name}) do
        {id, name}
      end
      #=> MyRuleset.find_user(session)         [{1, "Ada"}]
      #=> MyRuleset.find_user(session, id: 1)  [{1, "Ada"}]
  """
  defmacro defquery(decl, body) do
    defproduction(__CALLER__, decl, body, :query)
  end

  @doc false
  defmacro defquery(decl), do: no_body!(decl, :query)

  @doc """
  Declares that `child` *is a* kind of `parent`.

  A `child` fact then reaches every condition written against `parent`. The reverse does
  not hold. Derivation is transitive.

      derive(:dog, :mammal)
      derive(:mammal, :animal)

      # a {:dog, "Rex"} fact now matches this rule
      defrule process_animal({:animal, name}), do: {:seen, name}
  """
  defmacro derive(child, parent) do
    quote do
      @taxo_data Enum.concat(@taxo_data, [{:derive, unquote(child), unquote(parent)}])
    end
  end

  @doc """
  Removes a derivation declared earlier.

  Declarations are folded in module order, so a module can only undo what a module before
  it declared.

      derive(:cat, :mammal)
      underive(:cat, :mammal)
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
