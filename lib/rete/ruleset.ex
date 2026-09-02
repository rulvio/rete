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
  defines `<query_name>/1,2` for each query, which is the public face of a query, plus the
  `__rhs_<name>__/2` and `__<expr_code>__/1,2` machinery the engine calls.

  Every `defrule` and `defquery` expands by running the front end pipeline:

      Rete.DSL.Parser      parse the quoted declaration into Rete.IR
      Rete.DSL.Normalize   rewrite gates into conditions, negations and :or
      Rete.Compiler.Sort   order the conditions so every join has its keys
      Rete.DSL.Bindings    classify join/new bindings, split guards
      build/4              recompute the production's :bind from the result
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

      # `index/2` declarations, and the bindings of each query to check them against.
      # Both plain data, so `@before_compile` can resolve them without touching the
      # escaped IR in `@rule_data`.
      @rete_index_data []
      @rete_query_binds %{}

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
  defp resolve_bindings(%IR.Production{lhs: lhs, __ast__: ast} = production) do
    {guaranteed, optional} = IR.lhs_bindings(lhs)
    bind = Enum.sort(guaranteed ++ optional)

    %IR.Production{production | bind: bind, __ast__: %{ast | bind: bind_ast(ast.bind, bind)}}
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
      unquote(bind_record(production, type))
      unquote(Codegen.compile(production))
    end
  end

  # Only a query can be indexed, so only a query's bindings are worth recording.
  defp bind_record(_production, :rule), do: nil

  defp bind_record(production, :query) do
    quote do
      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      Rete.Ruleset.record_query_bind!(
        __MODULE__,
        unquote(production.name),
        unquote(production.bind)
      )
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

  **The query is a function.** `defquery find_user(...)` also defines `find_user/1,2` in
  the same module, so you run it by calling it. That is what makes a query addressable,
  and why two rulesets may each define one of the same name. Use `Rete.Session.query/3`,
  with `{MyRuleset, :find_user}`, when the query is decided at runtime.

  There is nothing to declare about parameters. The caller may constrain any variable the
  left hand side binds. Filtering happens on the bindings, before the body runs. A filter
  that names something the query does not bind raises an error, instead of answering
  `[]`.

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
  Declares an index over a query's bindings.

  A query answers from a scan of every match it holds. An index buckets those matches by
  the bindings named here, so a call that filters on exactly those bindings, or on a
  superset of them, reads one bucket instead of all of them.

      defquery flagged_for({:flagged, cid, tid, amt}) do
        {cid, tid, amt}
      end

      index :flagged_for, [:cid]
      index :flagged_for, [:cid, :tid]

  `[:cid, :tid]` is **one** index over both bindings, not two. Write two lines for two
  indexes. Order within the list does not matter.

  **An index changes speed, not results.** Every filter still works, indexed or not, and
  returns the same rows in the same order. Declaring none is the default, and costs
  nothing. This declares no parameters and permits nothing: the caller may still filter on
  any variable the left hand side binds.

  A declaration may come before or after the query it names. Both are resolved when the
  module finishes compiling.
  """
  @spec index(atom(), [atom()]) :: Macro.t()
  defmacro index(name, keys) do
    file = Path.relative_to_cwd(__CALLER__.file)
    line = __CALLER__.line

    quote do
      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      Rete.Ruleset.record_index!(
        __MODULE__,
        unquote(name),
        unquote(keys),
        unquote(file),
        unquote(line)
      )
    end
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

  @doc """
  Records one `index/2` declaration, checking its shape.

  Called from the module body rather than at macro expansion, for the reason
  `check_name!/5` gives: a module body is expanded in full before any of it runs, so at
  expansion time the attribute holding earlier declarations is still empty.

  Only the shape is checked here. Whether the name is a query, and whether the keys are
  bindings of it, cannot be known until every declaration has been seen — an `index` may
  come before its `defquery`. `resolve_indexes!/1` does that at `@before_compile`.
  """
  @spec record_index!(module(), atom(), [atom()], String.t(), pos_integer()) :: :ok
  def record_index!(module, name, keys, file, line) do
    unless is_atom(name) and not is_nil(name) do
      raise ArgumentError,
            "#{file}:#{line}: index expects a query name as an atom, got: #{inspect(name)}. " <>
              "Write `index :#{inspect(name)}, [...]`."
    end

    check_index_keys!(name, keys, file, line)

    recorded = Module.get_attribute(module, :rete_index_data) || []
    entry = {name, keys |> Enum.uniq() |> Enum.sort(), file, line}

    Module.put_attribute(module, :rete_index_data, [entry | recorded])
    :ok
  end

  defp check_index_keys!(name, keys, file, line) do
    cond do
      not is_list(keys) or not Enum.all?(keys, &is_atom/1) ->
        raise ArgumentError,
              "#{file}:#{line}: index :#{name} expects a list of binding names, got: " <>
                "#{inspect(keys)}. One index over two bindings is `[:a, :b]`. Two indexes " <>
                "are two `index` lines."

      keys == [] ->
        raise ArgumentError,
              "#{file}:#{line}: index :#{name} names no bindings. An index over nothing " <>
                "would bucket every match under one key, which is what a query without " <>
                "one already does."

      keys != Enum.uniq(keys) ->
        raise ArgumentError,
              "#{file}:#{line}: index :#{name}, #{inspect(keys)} repeats a binding. " <>
                "An index is a set of bindings."

      true ->
        :ok
    end
  end

  @doc """
  Resolves every recorded `index/2` against the queries of a module.

  Returns `query name => [key set]`, in declaration order. Raises when a declaration names
  something that is not a query of this module, or a binding that query does not have.
  """
  @spec resolve_indexes!(module()) :: %{atom() => [[atom()]]}
  def resolve_indexes!(module) do
    productions = Module.get_attribute(module, :rete_productions) || %{}
    binds = Module.get_attribute(module, :rete_query_binds) || %{}

    module
    |> Module.get_attribute(:rete_index_data)
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn {name, keys, file, line}, acc ->
      check_index_target!(module, productions, binds, name, keys, file, line)
      check_index_repeat!(module, Map.get(acc, name, []), name, keys, file, line)

      Map.update(acc, name, [keys], &(&1 ++ [keys]))
    end)
  end

  defp check_index_target!(module, productions, binds, name, keys, file, line) do
    case Map.fetch(productions, name) do
      {:ok, {:query, _line}} ->
        check_index_bindings!(module, Map.get(binds, name, []), name, keys, file, line)

      {:ok, {:rule, rule_line}} ->
        raise ArgumentError,
              "#{file}:#{line}: index :#{name} names a rule, defined at #{file}:#{rule_line}. " <>
                "Only a query can be indexed, because only a query is filtered. A rule " <>
                "fires on every match its left hand side has."

      :error ->
        raise ArgumentError,
              "#{file}:#{line}: index :#{name} names nothing #{inspect(module)} defines. " <>
                queries_defined(productions)
    end
  end

  defp check_index_bindings!(module, bind, name, keys, file, line) do
    case keys -- bind do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{file}:#{line}: index :#{name}, #{inspect(keys)} names " <>
                "#{inspect(unknown)}, which #{inspect(module)}.#{name} does not bind. " <>
                "It binds #{inspect(bind)}."
    end
  end

  defp check_index_repeat!(module, sets, name, keys, file, line) do
    if keys in sets do
      raise ArgumentError,
            "#{file}:#{line}: index :#{name}, #{inspect(keys)} is already declared for " <>
              "#{inspect(module)}.#{name}. Order within the list does not matter, so " <>
              "`[:a, :b]` and `[:b, :a]` are the same index."
    end
  end

  defp queries_defined(productions) do
    case for {name, {:query, _line}} <- productions, do: name do
      [] -> "It defines no queries at all."
      names -> "Defined: #{names |> Enum.sort() |> Enum.map_join(", ", &":#{&1}")}."
    end
  end

  @doc """
  Records the bindings of a query, so `resolve_indexes!/1` can check an index against them.

  Plain atoms, kept apart from `@rule_data`, which holds escaped IR.
  """
  @spec record_query_bind!(module(), atom(), [atom()]) :: :ok
  def record_query_bind!(module, name, bind) do
    recorded = Module.get_attribute(module, :rete_query_binds) || %{}

    Module.put_attribute(module, :rete_query_binds, Map.put(recorded, name, bind))
    :ok
  end

  @doc """
  Puts each query's declared indexes into its `:opts`.

  Runs when `get_rule_data/0` is called, rather than at `@before_compile`, because
  `@rule_data` holds escaped IR and only becomes structs when the generated function runs.
  """
  @spec with_indexes([IR.Production.t()], %{atom() => [[atom()]]}) :: [IR.Production.t()]
  def with_indexes(productions, indexes) when map_size(indexes) == 0, do: productions
  def with_indexes(productions, indexes), do: Enum.map(productions, &apply_index(&1, indexes))

  defp apply_index(%IR.Production{type: :query, name: name} = production, indexes) do
    case Map.fetch(indexes, name) do
      {:ok, sets} ->
        %IR.Production{production | opts: Keyword.put(production.opts || [], :index, sets)}

      :error ->
        production
    end
  end

  defp apply_index(%IR.Production{} = production, _indexes), do: production

  @doc false
  defmacro __before_compile__(env) do
    indexes = Macro.escape(resolve_indexes!(env.module))

    quote do
      def get_expr_data do
        @rule_data
        |> Enum.flat_map(&Rete.IR.expr_data/1)
        |> Enum.uniq()
      end

      def get_rule_data do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        Rete.Ruleset.with_indexes(@rule_data, unquote(indexes))
      end

      def get_taxo_data do
        @taxo_data
      end

      # Hashes what the module exposes, not the attribute behind it, so a changed index
      # changes the version and `get_version/0` stays a hash of `get_rule_data/0` and
      # `get_taxo_data/0`.
      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      @version :erlang.phash2([
                 __MODULE__,
                 Rete.Ruleset.with_indexes(@rule_data, unquote(indexes)),
                 @taxo_data
               ])
      def get_version do
        @version
      end
    end
  end
end
