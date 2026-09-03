defmodule Rete.DSL.Parser do
  @moduledoc """
  Turns the quoted arguments of `Rete.Ruleset.defrule/2` and
  `Rete.Ruleset.defquery/2` into `Rete.IR` structs.

  **Internal.** This is the first phase of the DSL front end. It records each LHS
  element's type, bindings, and guard. It builds the alpha and test `Rete.IR.Expr`
  descriptors. It keeps the raw pattern and guard AST in `:__ast__`, for the later phases.

  It deliberately does **not** normalize gates, classify bindings, or split guards. Gates
  become `Rete.IR.Gate` placeholders. `:join_filter`, `:join_bind`, and `:new_bind` are
  left `nil`.

      {:type, a, b, ...}              fact pattern of any arity, including {:type}
      %Mod{f: v}                      struct fact pattern, type is the module
      %{__type__: :type, f: v}        tagged map fact pattern
      f = <pattern>                   bind the whole fact to f
      <pattern> when <guard>          per condition guard
      [<pattern>]                     collection binding (collect all), anonymous
      c = [<pattern> when <guard>]    collection binding, bound, with a guard
      {gate, [element, ...]}          gate, gate in #{inspect([:and, :or, :not, :nand, :nor, :xor, :xnor])}

  A leading `%{...}` literal is the options map, not a fact pattern. A rule level guard
  becomes a trailing `Rete.IR.Test`.

  Expression codes stay stable across compilations of the same source. This is what lets
  the network share nodes. The compiler qualifies module attributes with the defining
  module before hashing, so the same pattern in two modules with different attribute
  values gets different codes. See `docs/design/ir.md` §5.
  """

  alias Rete.DSL.Codegen
  alias Rete.DSL.Vars
  alias Rete.IR

  @gates [:and, :or, :not, :nand, :nor, :xor, :xnor]

  @typedoc "The `Macro.Env` of the caller of `defrule`/`defquery`."
  @type env :: Macro.Env.t()

  @doc """
  Parses a production declaration and body into a `Rete.IR.Production`.

  `decl` is the quoted call, e.g. `r(%{salience: 1}, {:foo, id}) when id > 0`. `body` is
  the quoted `do` block, or `nil`. `type` is `:rule` or `:query`.

  `:rhs` is `nil` on the result. It is captured when the production is escaped.
  """
  @spec parse_production(env(), Macro.t(), Macro.t(), :rule | :query) :: IR.Production.t()
  def parse_production(env, decl, body, type) do
    decl = decl |> expand_aliases(env) |> resolve_constants(env)
    body = body |> expand_aliases(env) |> resolve_constants(env)
    hash = Codegen.ast_hash([decl, body])

    parse_rule(env, hash, type, decl, body)
  end

  defp parse_rule(env, hash, type, {:when, _, [decl, guard]}, body) do
    %IR.Production{} = production = parse_rule(env, hash, type, decl, body)
    bind = parse_bind(guard)

    test = %IR.Test{
      bind: bind_vars(bind),
      expr: build_test_expr(env, guard, bind),
      __ast__: %{guard: guard, bind: bind}
    }

    %IR.Production{production | lhs: production.lhs ++ [test]}
  end

  defp parse_rule(env, hash, type, {name, _, args}, body) when is_atom(name) do
    {opts, elements} = parse_args(args)
    check_opts!(name, opts)
    bind = parse_bind(elements)

    %IR.Production{
      name: name,
      type: type,
      hash: hash,
      opts: opts,
      bind: bind_vars(bind),
      lhs: Enum.map(elements, &parse_element(env, &1)),
      rhs: nil,
      module: env.module,
      __ast__: %{bind: bind, decl: {name, [], args}, body: body}
    }
  end

  defp parse_rule(_env, _hash, _type, decl, _body) do
    raise ArgumentError,
          "invalid rule declaration, expected a call such as `my_rule(<conditions>)`, got: " <>
            Macro.to_string(decl)
  end

  # `:params` used to declare which bindings a query's caller could supply. There is no
  # such declaration any more. `Rete.Session.query/3` accepts any variable the left hand
  # side binds. So a leftover `:params` would be silently ignored — the worst outcome for
  # something that used to change behaviour.
  # `:internal_salience` and `:generated` are set by `Rete.Compiler.Negation` on the
  # helper it extracts, not written by hand. They are listed because they are legal on a
  # production, not because anyone should type them.
  @known_opts [:salience, :internal_salience, :generated]

  defp check_opts!(name, opts) do
    check_params!(name, opts)

    case Keyword.keys(opts) -- @known_opts do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{name} sets #{inspect(unknown)}, which is not an option. " <>
                "The options map takes #{inspect(@known_opts)}. An index is declared " <>
                "separately, with `index :#{name}, [...]`. A silently ignored option is " <>
                "worse than a rejected one, so this is an error rather than a no-op."
    end
  end

  defp check_params!(name, opts) do
    case Keyword.get(opts, :params) do
      nil ->
        :ok

      params ->
        first = params |> List.wrap() |> List.first()

        raise ArgumentError,
              "#{name} declares `params: #{inspect(params)}`, which is no longer a thing. " <>
                "A query is its conditions and its body, and the caller may constrain any " <>
                "variable the left hand side binds, with no declaration. A query is also a " <>
                "function in its own module, so it is run by calling it: " <>
                "#{name}(session, #{first}: value)"
    end
  end

  # Splits the optional leading options map off the declaration arguments. A leading map
  # literal is the options map, unless it carries a `__type__` key. That key makes it a
  # tagged map fact pattern instead.
  defp parse_args(nil), do: {[], []}

  defp parse_args([{:%{}, _, opts} = head | elements]) when is_list(opts) do
    if Keyword.has_key?(opts, :__type__) do
      {[], [head | elements]}
    else
      {opts, elements}
    end
  end

  defp parse_args(elements) when is_list(elements), do: {[], elements}

  @doc """
  Parses a single LHS element into a condition struct.

  Exposed so that later phases can re-parse fragments (for example the branches
  a gate is normalized into).
  """
  @spec parse_element(env(), Macro.t()) :: IR.condition()
  def parse_element(env, element), do: parse_element(env, element, %{binding: nil, guard: nil})

  defp parse_element(env, {:when, _, [inner, guard]}, acc) do
    parse_element(env, inner, %{acc | guard: join_guards(acc.guard, guard)})
  end

  defp parse_element(env, {:=, _, [{name, _, ctx}, inner]}, acc)
       when is_atom(name) and is_atom(ctx) do
    if acc.binding do
      raise ArgumentError, "condition is bound twice, to #{acc.binding} and to #{name}"
    end

    parse_element(env, inner, %{acc | binding: name})
  end

  defp parse_element(env, {gate, args} = source, acc) when gate in @gates and is_list(args) do
    if acc.binding || acc.guard do
      raise ArgumentError,
            "a #{gate} gate cannot be bound to a variable or carry a `when` guard, " <>
              "put the guard on the conditions inside it: " <> Macro.to_string(source)
    end

    args = Enum.map(args, &parse_element(env, &1))
    %IR.Gate{gate: gate, args: args, code: [gate | Enum.map(args, &condition_code/1)]}
  end

  defp parse_element(env, [inner] = source, acc) do
    {pattern, guard} =
      case inner do
        {:when, _, [pattern, guard]} -> {pattern, guard}
        pattern -> {pattern, nil}
      end

    case pattern do
      {:=, _, _} ->
        raise ArgumentError,
              "a collection element cannot be bound to a variable, bind the whole " <>
                "collection instead (`facts = [{:type, x}]`): " <> Macro.to_string(source)

      # Without this, `compile_pattern/2` would treat the gate as a fact pattern. It
      # would silently build a collection of facts whose type tag is the atom `:or`.
      {gate, args} when gate in @gates and is_list(args) ->
        raise ArgumentError,
              "a #{gate} gate cannot appear inside a collection. A collection " <>
                "gathers the facts matching one pattern, so it takes a single " <>
                "condition: " <> Macro.to_string(source)

      _ ->
        :ok
    end

    guard = join_guards(guard, acc.guard)
    {type, args_ast} = compile_pattern(env, pattern)
    bind = parse_bind(pattern)

    %IR.Coll{
      type: type,
      coll_binding: acc.binding,
      bind: bind_vars(bind),
      alpha: build_alpha_expr(env, type, pattern, args_ast, guard, bind),
      __ast__: %{pattern: pattern, guard: guard, bind: bind, source: source}
    }
  end

  defp parse_element(env, pattern, acc) do
    {type, args_ast} = compile_pattern(env, pattern)
    bind = parse_bind(pattern)

    %IR.Fact{
      type: type,
      fact_binding: acc.binding,
      bind: bind_vars(bind),
      alpha: build_alpha_expr(env, type, pattern, args_ast, acc.guard, bind),
      __ast__: %{pattern: pattern, guard: acc.guard, bind: bind, source: pattern}
    }
  end

  # Combines an inner and an outer guard, either of which may be absent.
  defp join_guards(nil, guard), do: guard
  defp join_guards(guard, nil), do: guard
  defp join_guards(inner, outer), do: {:and, [], [inner, outer]}

  @doc """
  Compiles a fact pattern into `{type, argument_pattern}`.

  The argument pattern is what the generated alpha function matches the fact against. It
  never checks the fact type. The tag slot of a tuple becomes `_`. A struct pattern loses
  its `__struct__` check. A tagged map pattern loses its `__type__` key. Type filtering,
  including taxonomy, happens later, when the alpha index decides whether to propagate a
  fact to a node.
  """
  @spec compile_pattern(env(), Macro.t()) :: {atom() | module(), Macro.t()}
  def compile_pattern(env, pattern)

  # {:type, a} - literal two element tuple
  def compile_pattern(_env, {type, arg}) when is_atom(type) do
    {type, {{:_, [], nil}, arg}}
  end

  # {:type}, {:type, a, b, ...} - any other arity
  def compile_pattern(_env, {:{}, meta, [type | args]}) when is_atom(type) do
    {type, {:{}, meta, [{:_, [], nil} | args]}}
  end

  # %Mod{f: v}
  def compile_pattern(env, {:%, _, [alias_ast, {:%{}, meta, fields}]}) do
    {expand_type(env, alias_ast), {:%{}, meta, fields}}
  end

  # %{__type__: :type, f: v}
  def compile_pattern(_env, {:%{}, meta, fields} = pattern) when is_list(fields) do
    case Keyword.fetch(fields, :__type__) do
      {:ok, type} when is_atom(type) and not is_nil(type) ->
        {type, {:%{}, meta, Keyword.delete(fields, :__type__)}}

      {:ok, other} ->
        raise ArgumentError,
              "the __type__ of a map fact pattern must be a literal atom, got: " <>
                Macro.to_string(other)

      :error ->
        raise ArgumentError,
              "a map fact pattern must declare its type with __type__, e.g. " <>
                "%{__type__: :order, id: id}, got: " <> Macro.to_string(pattern)
    end
  end

  def compile_pattern(_env, pattern) do
    raise ArgumentError,
          "unsupported condition, expected a tagged tuple such as {:order, id}, a struct " <>
            "such as %Order{id: id}, or a tagged map such as %{__type__: :order, id: id}, got: " <>
            Macro.to_string(pattern)
  end

  defp expand_type(env, alias_ast) do
    case Macro.expand(alias_ast, env) do
      type when is_atom(type) ->
        type

      other ->
        raise ArgumentError,
              "the type of a struct fact pattern must resolve to a module at compile time, " <>
                "got: " <> Macro.to_string(other)
    end
  end

  @doc """
  Builds the alpha `Rete.IR.Expr` of a condition.

  `pattern` is the raw pattern as written — only used to compute the stable hash.
  `args_ast` is the compiled argument pattern from `compile_pattern/2`. `guard` is the
  per-condition guard AST, or `nil`. `bind` maps every bound variable to its AST.

  The generated function returns the bindings map when the fact matches and the guard
  holds, and `nil` otherwise. This delegates to `Rete.DSL.Codegen.alpha_expr/6`, which
  owns the naming and hashing scheme. `env` resolves the guard's unqualified calls.
  """
  @spec build_alpha_expr(
          Macro.Env.t(),
          atom() | module(),
          Macro.t(),
          Macro.t(),
          Macro.t() | nil,
          %{atom() => Macro.t()}
        ) :: IR.Expr.t()
  defdelegate build_alpha_expr(env, type, pattern, args_ast, guard, bind),
    to: Codegen,
    as: :alpha_expr

  @doc """
  Builds the `Rete.IR.Expr` of a test over bindings only.

  The generated function takes the bindings map and returns the value of the
  guard. Delegates to `Rete.DSL.Codegen.test_expr/3`.
  """
  @spec build_test_expr(Macro.Env.t(), Macro.t(), %{atom() => Macro.t()}) :: IR.Expr.t()
  defdelegate build_test_expr(env, guard, bind), to: Codegen, as: :test_expr

  @doc """
  Collects the variables bound by a pattern.

  Returns `%{name => variable_ast}`. Pinned values (`^x`), module attributes (`@x`), and
  variables whose name starts with `_` are not bindings, and this excludes them. It also
  excludes anything a nested construct binds for itself. This delegates to
  `Rete.DSL.Vars.pattern_vars/1`, which owns scope analysis.
  """
  @spec parse_bind(Macro.t()) :: %{atom() => Macro.t()}
  defdelegate parse_bind(ast), to: Vars, as: :pattern_vars

  # The :bind list of every IR struct is sorted, so that two conditions binding
  # the same variables always compare equal.
  defp bind_vars(bind), do: bind |> Map.keys() |> Enum.sort()

  # A structural id for a condition, used to identify gates.
  defp condition_code(%IR.Fact{alpha: %IR.Expr{code: code}}), do: code
  defp condition_code(%IR.Coll{alpha: %IR.Expr{code: code}}), do: code
  defp condition_code(%IR.Test{expr: %IR.Expr{code: code}}), do: code
  defp condition_code(%IR.Gate{code: code}), do: code

  @doc """
  Replaces compile-time constants in the AST with their values.

  This resolves both forms, because an LHS condition compiles into a standalone function
  in the ruleset module, and neither form survives being moved there.

  The compiler qualifies `@attr` with the defining module, so the same pattern in two
  modules with different attribute values does not share an expression. It cannot resolve
  the value itself here: `@attr` expands to a call that only runs once the module body is
  evaluated — after every macro in it has already expanded. So what distinguishes two uses
  of one attribute is their *line* instead, which `Rete.DSL.Codegen.ast_hash/1` keeps for
  attribute nodes alone. Without that, `@limit 5` and a later `@limit 100` over the same
  pattern would hash identically, and share one generated function.

  `^value` has no enclosing scope to refer to, once the condition becomes its own
  function. So the compiler unwraps each spelling. `^@limit` and `^5` become the literal
  value, since matching on `^5` and on `5` is the same match. `^amt` becomes plain `amt`,
  because sharing a variable between two conditions is already how this DSL spells a
  join. Dropping the pin lets ordinary binding classification turn it into a join key.
  """
  @spec resolve_constants(Macro.t(), env()) :: Macro.t()
  def resolve_constants(ast, env) do
    Macro.prewalk(ast, fn
      {:@, m1, [{name, m2, context}]} when is_atom(name) and is_atom(context) ->
        {:@, m1, [{name, m2, env.module}]}

      {:^, _, [inner]} ->
        inner

      node ->
        node
    end)
  end

  @doc """
  Resolves every alias and `__MODULE__` in the AST to the module it names.

  Expression codes are shared across modules, so two conditions with the same code must
  have the same behaviour. An alias is lexical. `H.ok?(amt)` is the same AST in two
  modules that alias `H` to different things. Hashing it unresolved would give both the
  same code, and let `Rete.get_expr_data/1` collapse them onto whichever function it saw
  first. Resolving the alias before hashing makes the code depend on the module actually
  called instead.

  Only alias nodes are expanded, never macros — the body has to reach the generated
  function exactly as the user wrote it.
  """
  @spec expand_aliases(Macro.t(), env()) :: Macro.t()
  def expand_aliases(ast, env) do
    Macro.prewalk(ast, fn
      {:__aliases__, _, _} = node -> Macro.expand(node, env)
      {:__MODULE__, _, ctx} when is_atom(ctx) -> env.module
      node -> node
    end)
  end

  @doc """
  Quoted definitions of every expression function of a production.

  Emit these into the module body before escaping the production. Delegates to
  `Rete.DSL.Codegen.expr_defs/1`, which owns code generation.
  """
  @spec expr_defs(IR.Production.t()) :: [Macro.t()]
  defdelegate expr_defs(production), to: Codegen
end
