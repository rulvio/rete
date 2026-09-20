defmodule Rete.Ruleset do
  @moduledoc """
  Macros for defining rulesets in a Rete network.

  A rule reads as a function. Its **arguments are the left hand side**, and its **body is
  the right hand side**. Pattern matching in the argument list gives you destructuring,
  variable binding, and join-variable identification for free. What the body returns is
  the facts to insert. `docs/dsl.md` is the guide.

      defmodule MyRuleset do
        use Rete.Ruleset

        derive(:dog, :mammal)

        defrule loyalty(%{salience: 100}, {:customer, cid, name}, orders = [{:order, cid, _amt}]) do
          {:loyalty, cid, name, length(orders)}
        end
      end

  Using this module makes the ruleset expose `get_rule_data/0`, `get_expr_data/0`,
  `get_taxo_data/0`, and `get_version/0`. `Rete` aggregates these across modules. It also
  defines `<query_name>/(N+1)` for each query, which is the public face of a query, plus the
  `__rhs_<name>__/2` and `__<expr_code>__/1,2` machinery the engine calls.

  Every `defrule` and `defquery` expands by running the front end pipeline:

      Rete.DSL.Parser      parse the quoted declaration into Rete.IR
      Rete.DSL.Normalize   rewrite gates into conditions, negations and :or
      Rete.Compiler.Sort   order the conditions so every join has its keys
      Rete.DSL.Bindings    classify join/new bindings, split guards
      build/4              recompute :bind from the result, then check the head against it
      Rete.DSL.Codegen     emit the expression functions and the RHS

  See `docs/design/ir.md` §1 for the contract between the phases.
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

      # name => {:rule | :query, line}. Used for the duplicate name check. This is
      # separate from @rule_data, which holds escaped IR with the compile-time AST
      # already dropped.
      @rete_productions %{}

      # The module attribute values behind each generated expression. This keeps two
      # identically written conditions, that read different values, from sharing one
      # compiled function. See `Rete.DSL.Codegen.check_attr_values!/3`.
      @rete_expr_attrs %{}

      @before_compile Rete.Ruleset
    end
  end

  @doc """
  Runs the front end pipeline over a quoted production declaration.

  Returns the fully classified `Rete.IR.Production`, ready for
  `Rete.DSL.Codegen.compile/1`. This is exposed so a test can inspect the IR of a
  declaration, without compiling a module for it.

  The last step recomputes `:bind` from the classified LHS. So `:bind` is exactly the set
  of variables a token reaching the right hand side can carry.
  """
  @spec build(Macro.Env.t(), Macro.t(), Macro.t(), :rule | :query) :: IR.Production.t()
  def build(env, decl, body, type) do
    production = Parser.parse_production(env, decl, body, type)
    production = %IR.Production{production | lhs: Normalize.normalize_lhs(production.lhs)}

    env
    |> Bindings.classify(Sort.sort(production))
    |> resolve_bindings()
  end

  # `:bind` is a product of the pipeline, not a pre-pass. To the parser, every variable of
  # every element looks like a binding. Only the classified LHS knows that a negation
  # binds nothing downstream, that a rule-level guard only reads, and that a disjunction
  # binds the union of its branches. See `docs/design/ir.md` §2.
  #
  # This checks the head for the same reason: a parameter must be a binding, and only now
  # is it known what the production binds.
  defp resolve_bindings(%IR.Production{lhs: lhs, __ast__: ast} = production) do
    {guaranteed, optional} = IR.lhs_bindings(lhs)
    bind = Enum.sort(guaranteed ++ optional)

    check_params!(production, guaranteed, optional)

    %IR.Production{production | bind: bind, __ast__: %{ast | bind: bind_ast(ast.bind, bind)}}
  end

  # A parameter keys every match that a query holds. It must thus be a binding that every
  # match carries. This excludes a variable that only some branches of a disjunction bind:
  # the matches of the other branches would key on its absence, and no call could name
  # them.
  defp check_params!(%IR.Production{params: []}, _guaranteed, _optional), do: :ok

  defp check_params!(%IR.Production{params: params} = production, guaranteed, optional) do
    cond do
      (unknown = params -- (guaranteed ++ optional)) != [] ->
        raise ArgumentError,
              "#{signature(production)} names #{inspect(unknown)}, which " <>
                "#{inspect(production.module)}.#{production.name} does not bind. " <>
                "It binds #{inspect(Enum.sort(guaranteed ++ optional))}."

      (partial = Enum.filter(params, &(&1 in optional))) != [] ->
        raise ArgumentError,
              "#{signature(production)} names #{inspect(partial)}, which only some " <>
                "branches of its disjunction bind. A parameter keys every match, so " <>
                "every match must carry it. This query guarantees " <>
                "#{inspect(guaranteed)}. Filter on #{inspect(partial)} in your own code, " <>
                "or write one query for each branch."

      true ->
        :ok
    end
  end

  # Names the head as it was written, not as a list of names. A head is a pattern now, so
  # `defquery rows([:cid])` would name nothing the author could find in their source.
  # `:head` is the parser's rendering of it, which is the same one every other message
  # about this query uses.
  #
  # Matches a head that is there, rather than rendering `()` for one that is not.
  # `check_params!/3` returns early on empty `:params`, and only a head sets `:params`, so
  # a production reaching here always carries one. A refactor that broke that should fail
  # here instead of naming a declaration nobody wrote.
  defp signature(%IR.Production{name: name, head: [_ | _] = head}) do
    "defquery #{name}(#{Enum.join(head, ", ")})"
  end

  # Keeps the variable AST the parser collected, so the RHS pattern carries the source
  # metadata. Drops the entries that turned out not to bind.
  defp bind_ast(parsed, bind) do
    Map.new(bind, fn var -> {var, Map.get(parsed, var) || {var, [], nil}} end)
  end

  # The name check is spliced in ahead of the codegen. So the first thing to fail on a
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
      # Fully qualified. This is spliced into the user's module, which has no alias for
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

  The compiler calls this from the module body, not at macro expansion. A module body is
  expanded in full **before** any of it is evaluated. So at expansion time, the attribute
  that records earlier declarations is still empty, and every declaration would look like
  the first.

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
  # function head. The module would then fail to compile, with "implementation not
  # provided for predefined def" — an error naming the generated function, not the rule.
  @spec no_body!(Macro.t(), :rule | :query) :: no_return()
  defp no_body!(decl, type) do
    raise ArgumentError,
          "`def#{type} #{decl_name(decl)}` has no body. The body of a rule is its right " <>
            "hand side, the facts to logically insert; the body of a query is the result " <>
            "computed for the caller. Write it as `def#{type} #{decl_name(decl)}(...) do " <>
            "... end`."
  end

  defp decl_name({:when, _, [decl, _guard]}), do: decl_name(decl)
  defp decl_name({{name, _, _head}, _, _args}) when is_atom(name), do: name
  defp decl_name({name, _, _args}) when is_atom(name), do: name
  defp decl_name(decl), do: Macro.to_string(decl)

  @doc """
  Defines a rule.

  The declaration is the left hand side, and the body is the right hand side. The engine
  logically inserts and truth-maintains what the body returns. `nil` or `[]` inserts
  nothing.

      {:user, id}                      fact pattern, any arity, including {:tick}
      %User{id: id}                    struct fact pattern, the type is the module
      %{__type__: :user, id: id}       tagged map fact pattern
      %User{__type__: :vip, id: id}    a declared type overrides the module
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

  A query has the same left hand side as a rule, but it never fires. It holds the matches
  that reached it. Its **body is what the caller gets**, one result per match.

  **The query is a function.** `defquery find_user(...)` also defines `find_user` in the
  same module, so you run it by calling it. Its arity is one more than the number of
  patterns in the head. That is what makes a query addressable, and why two rulesets may
  each define one of the same name. Use `Rete.Session.query/3`, with
  `{MyRuleset, :find_user}`, when the query is decided at runtime.

  A **head** before the conditions is the argument list of that function. It is a list of
  ordinary Elixir patterns, and a call matches them. The variables they bind are what the
  engine keys the matches on, and they are the only way to read the query.

      defquery find_user(id)({:user, id, name}) do
        {id, name}
      end
      #=> MyRuleset.find_user(session, 1)  [{1, "Ada"}]

  Any pattern works, so you choose the shape a caller writes:

      defquery by_pair(cid, tid)(...)           #=> by_pair(session, 1, 2)
      defquery by_tuple({cid, tid})(...)        #=> by_tuple(session, {1, 2})
      defquery by_map(%{cid: cid})(...)         #=> by_map(session, %{cid: 1})
      defquery by_list(cid: cid, tid: tid)(...) #=> by_list(session, cid: 1, tid: 2)

  The session is the first argument, so a query pipes. A head of N patterns gives
  `name/(N+1)`. A call that does not match raises `FunctionClauseError`, in the way that
  any other function does. Because the head is a pattern, a keyword head matches in the
  order that you declared, and a map head accepts a call with extra keys.

  A pattern may carry a **guard**:

      defquery big_sales(cid, amt when amt > 1000)({:sale, cid, amt}) do
        {cid, amt}
      end

  The guard becomes a test on the left hand side, and nothing else. So the query holds no
  match that it rejects, and `big_sales(session, 1, 5)` answers `[]`. It is not on the
  generated clause, so it may call anything a rule body may call, such as
  `name when String.length(name) > 3`.

  A head guard reads only what the head binds. Write a guard over the other bindings as a
  rule level guard instead, after the conditions.

  A query **without** a head takes no parameters. It answers with every match that it
  holds, in arrival order. This is the default, and it costs nothing more.

      defquery all_users({:user, id, name}) do
        {id, name}
      end
      #=> MyRuleset.all_users(session)  [{1, "Ada"}, {2, "Grace"}]

  Every variable a head binds must be one the left hand side binds on **every** match, so a
  variable that only some branches of a disjunction bind is refused. A head may bind
  nothing: `(:tick)` asserts at the call site, and a `_`-prefixed name labels a position, as
  in any `def`. A rule cannot take a head, because you never read a rule. See `docs/dsl.md`.
  """
  defmacro defquery(decl, body) do
    defproduction(__CALLER__, decl, body, :query)
  end

  @doc false
  defmacro defquery(decl), do: no_body!(decl, :query)

  @doc false
  # The engine now keys the matches of a query on its head, and that keying is the only
  # one. An `index` line thus has nothing to declare. This raises an error instead of being
  # undefined, because "undefined function index/2" does not tell you what to write.
  @spec index(atom(), [atom()]) :: no_return()
  defmacro index(name, keys) do
    raise ArgumentError,
          "index #{inspect(name)}, #{inspect(keys)} is no longer a declaration. The " <>
            "engine keys the matches of a query on its parameters, which are its head: " <>
            "`defquery #{name}(#{keys |> List.wrap() |> Enum.join(", ")})(<conditions>)`. " <>
            "That keying is the only one, so there is no second index to declare. A call " <>
            "must name every parameter, and no other name."
  end

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

      # A query's parameters are part of its declaration, so they are already in
      # `@rule_data` and a changed head changes the version.
      @version :erlang.phash2([__MODULE__, @rule_data, @taxo_data])
      def get_version do
        @version
      end
    end
  end
end
