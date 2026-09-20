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
      %Mod{__type__: :type, f: v}     struct pattern, the declared type overrides the module
      f = <pattern>                   bind the whole fact to f
      <pattern> when <guard>          per condition guard
      [<pattern>]                     collection binding (collect all), anonymous
      c = [<pattern> when <guard>]    collection binding, bound, with a guard
      {gate, [element, ...]}          gate, gate in #{inspect([:and, :or, :not, :nand, :nor, :xor, :xnor])}

  A leading `%{...}` literal is the options map, not a fact pattern. A rule level guard
  becomes a trailing `Rete.IR.Test`.

  A query can carry a **head**, `rows(cid, tid)(<conditions>)`. Elixir parses this as a call
  applied to a second argument list, so the head arrives here around the declaration.

  A head is a list of **patterns**, and a call matches them. The variables they bind key the
  matches of the query, and they become `:params`. A pattern may carry a guard,
  `rows(amt when amt > 10)(...)`. The guard becomes a `Rete.IR.Test` on the left hand side,
  and it reads only what the head binds. Each pattern takes one `when`. A `when` after the
  second argument list is the rule level guard instead, and it reads every binding.

  A type is any term except `nil`. A pattern must write it as a literal. `__type__` always
  declares a type. It is never a field to match on, so the parser drops it from every
  pattern that names it.

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

  # The field list of a map or struct AST node, as `{key, value}` pairs. A key is not
  # always an atom, so this is not a `t:keyword/0`: `%{"id" => id}` is a valid pattern,
  # and it gives `[{"id", ...}]`.
  @typep fields :: [{Macro.t(), Macro.t()}]

  @doc """
  Parses a production declaration and body into a `Rete.IR.Production`.

  `decl` is the quoted call, e.g. `r(%{salience: 1}, {:foo, id}) when id > 0`, or a query
  with a head, `q(cid)({:foo, cid})`. `body` is the quoted `do` block, or `nil`. `type` is
  `:rule` or `:query`.

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

    reject_extra_guards!(production.name, :rule, guard)
    bind = parse_bind(guard)

    test = %IR.Test{
      bind: bind_vars(bind),
      expr: build_test_expr(env, guard, bind),
      source: :rule,
      __ast__: %{guard: guard, bind: bind}
    }

    %IR.Production{production | lhs: production.lhs ++ [test]}
  end

  # The head of a query: `rows(cid, tid)(<conditions>)`. Elixir parses a call applied to a
  # second argument list as a nested call, so the head arrives around the declaration. The
  # head is a list of patterns. Its bindings key the matches of the query, and a call
  # matches those patterns. `Rete.Ruleset.build/4` checks the bindings against the
  # classified LHS, which is not known until the full pipeline has run.
  defp parse_rule(env, hash, type, {{name, _, head}, _, args}, body)
       when is_atom(name) and is_list(head) do
    %IR.Production{} = production = parse_rule(env, hash, type, {name, [], args}, body)

    reject_head_on_rule!(name, type, head)
    reject_defaults!(name, :head, head)

    {patterns, guard} = split_head(name, head)
    head_bind = parse_bind(patterns)

    check_head_guard!(name, patterns, guard, head_bind)

    %IR.Production{
      production
      | params: bind_vars(head_bind),
        # Rendered here, where the patterns are. Every message about this query names the
        # head the way its author wrote it, and a message reaches for a string.
        head: Enum.map(patterns, &Macro.to_string/1),
        lhs: production.lhs ++ head_test(env, guard),
        # The guard is not kept here. It goes into the `Rete.IR.Test` that `head_test/2`
        # appends, which records it in the same shape every other guard uses.
        __ast__: Map.merge(production.__ast__, %{head: patterns, head_bind: head_bind})
    }
  end

  defp parse_rule(env, hash, type, {name, _, args}, body) when is_atom(name) do
    {opts, elements} = parse_args(args)
    check_opts!(name, opts)
    Enum.each(elements, &reject_defaults!(name, :condition, &1))
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

  # This rejects an empty head on a rule too. `defrule r()(<conditions>)` declares nothing,
  # but it has the shape of a query. To accept it without a message would let a person who
  # intended a query believe that they had written one.
  defp reject_head_on_rule!(name, :rule, head) do
    raise ArgumentError,
          "#{name}(#{Enum.map_join(head, ", ", &Macro.to_string/1)}) gives a rule a head, " <>
            "and a rule cannot take parameters. Only a query is read by parameters, because " <>
            "only a query is read. A rule fires on every match that its left hand side has. " <>
            "Write the conditions as the one argument list: `defrule #{name}(...)`."
  end

  defp reject_head_on_rule!(_name, _type, _head), do: :ok

  # A default applies where a call is made, and neither of these places is one. Elixir
  # reports `\\` in a match as "undefined function \\/2", which names nothing the author
  # wrote, so this arrives first.
  #
  # `when` binds tighter than `\\`, so `cid \\ 1 when cid > 0` parses with the guard inside
  # the default. Walking the head before `split_head/1` is what catches that spelling.
  defp reject_defaults!(name, source, ast) do
    case Macro.prewalk(ast, nil, &find_default/2) do
      {_ast, nil} -> :ok
      {_ast, _default} -> raise ArgumentError, default_message(name, source, ast)
    end
  end

  defp find_default({:\\, _meta, [_pattern, _default]} = node, nil), do: {node, node}
  defp find_default(node, found), do: {node, found}

  defp default_message(name, :head, head) do
    "#{name}(#{Enum.map_join(head, ", ", &Macro.to_string/1)}) gives a head pattern a " <>
      "default, and a head pattern cannot take one. A default applies at the call site, " <>
      "so `Rete.Session.query/3` could not honour it and the two ways of reading this " <>
      "query would disagree. Write a second query, or a wrapper function that supplies " <>
      "the value."
  end

  defp default_message(_name, :condition, element) do
    "#{Macro.to_string(element)} gives a condition a default, and a condition cannot take " <>
      "one. A condition matches a fact that is already there, so there is no call to " <>
      "supply a value for. Remove the default."
  end

  # Separates the patterns of a head from its guards. Elixir attaches a `when` to the one
  # argument it follows, so `rows(cid, tid when cid < tid)` guards the last pattern alone.
  # The guards all become one test over the head bindings, though, and every head binding
  # is in scope for it. So they combine into one, and where an author wrote a guard does
  # not change what it reads.
  defp split_head(name, head) do
    {patterns, guards} =
      Enum.map_reduce(head, [], fn
        {:when, _meta, [pattern, guard]}, guards ->
          reject_extra_guards!(name, :head, guard)
          {pattern, guards ++ [guard]}

        pattern, guards ->
          {pattern, guards}
      end)

    {patterns, combine_guards(guards)}
  end

  defp combine_guards([]), do: nil
  defp combine_guards(guards), do: Enum.reduce(guards, &quote(do: unquote(&2) and unquote(&1)))

  # One `when` per pattern, and one after the conditions. Elixir nests each `when` after
  # the first to the right, so `amt when a when b` leaves a `when` at the root of the
  # guard. A guard here becomes a compiled function, and `when` is not an expression, so
  # without this the compiler reports "undefined function when/2" against a generated name
  # nobody wrote. A `def` head accepts the spelling, which is why an author reaches for it.
  #
  # The root only. A guard may be any expression a rule body may call, so it may hold an
  # `fn` with a clause guard of its own. A walk of the whole guard would refuse that.
  #
  # Any number of them, and not two. `flatten_when/1` unnests the whole chain, so the count
  # and the rewrite both describe what was written rather than the first mistake in it.
  defp reject_extra_guards!(name, source, {:when, _meta, _args} = guard) do
    guards = flatten_when(guard)

    raise ArgumentError,
          "#{name} writes #{length(guards)} guards where one `when` is all that a " <>
            "#{when_noun(source)} takes. Elixir nests each `when` after the first inside " <>
            "the one before it. A guard here becomes a compiled function, and `when` is " <>
            "not an expression, so the nested ones would reach it as a call. Join them " <>
            "with `and`: `when #{Macro.to_string(combine_guards(guards))}`."
  end

  defp reject_extra_guards!(_name, _source, _guard), do: :ok

  defp when_noun(:head), do: "head pattern"
  defp when_noun(:rule), do: "rule"

  defp flatten_when({:when, _meta, [left, right]}), do: flatten_when(left) ++ flatten_when(right)
  defp flatten_when(guard), do: [guard]

  # A head guard is a constraint on the call, so it reads what the call supplies. Letting it
  # read the rest of the left hand side would make it the trailing `when` under a second
  # spelling, and the two are one character apart in the source. So this keeps them apart,
  # and it names the other one.
  defp check_head_guard!(_name, _patterns, nil, _head_bind), do: :ok

  defp check_head_guard!(name, patterns, guard, head_bind) do
    case Vars.read_var_names(guard) -- Map.keys(head_bind) do
      [] ->
        :ok

      outside ->
        raise ArgumentError,
              "the head guard of #{name} reads #{inspect(outside)}, which the head does " <>
                "not bind. A head guard constrains the call, so it reads only what its own " <>
                "patterns bind, which is #{inspect(bind_vars(head_bind))}. " <>
                head_guard_hint(name, patterns, guard, outside)
    end
  end

  # A `_`-prefixed name is discarded by the pattern that writes it, so moving the guard
  # would not help. Say the one thing that does.
  defp head_guard_hint(name, patterns, guard, outside) do
    case Enum.find(outside, &String.starts_with?(Atom.to_string(&1), "_")) do
      nil ->
        "To filter the matches instead, write a rule level guard: `defquery " <>
          "#{name}(#{Enum.map_join(patterns, ", ", &Macro.to_string/1)})(...) when " <>
          "#{Macro.to_string(guard)}`."

      discarded ->
        "A variable whose name starts with `_` is discarded by the pattern that binds it, " <>
          "so nothing can read it. Rename `#{discarded}` to " <>
          "`#{String.trim_leading(Atom.to_string(discarded), "_")}`."
    end
  end

  # A head guard is a test over the bindings, and that is all it is. It prunes the store,
  # which is the one place both ways of reading a query meet. `docs/design/ir.md` §2 has why
  # a guard on the generated clause would add nothing and cost the guard its language.
  defp head_test(_env, nil), do: []

  defp head_test(env, guard) do
    bind = parse_bind(guard)

    [
      %IR.Test{
        bind: bind_vars(bind),
        expr: build_test_expr(env, guard, bind),
        source: :head,
        __ast__: %{guard: guard, bind: bind}
      }
    ]
  end

  # `:params` used to be an option. It is the head of a query now, so it is deliberately
  # absent here: an old-style `params:` is caught below like any other unknown key.
  # `:internal_salience` and `:generated` are set by `Rete.Compiler.Negation` on the
  # helper it extracts, not written by hand. They are listed because they are legal on a
  # production, not because anyone should type them.
  # `:meta` is the one key the engine never reads or validates. It is a deliberate
  # pass-through for the ruleset author's own data, kept in `opts` for `get_rule_data/0`
  # to hand back unchanged.
  @known_opts [:salience, :internal_salience, :generated, :meta]

  defp check_opts!(name, opts) do
    case Keyword.keys(opts) -- @known_opts do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "#{name} sets #{inspect(unknown)}, which is not an option. " <>
                "The options map takes #{inspect(@known_opts)}. If you meant a map fact " <>
                "pattern rather than the options map, declare its type: " <>
                "`%{__type__: :some_type, ...}`."
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

  The generated alpha function matches the fact against the argument pattern. That pattern
  never checks the fact type. The tag slot of a tuple becomes `_`. Every pattern loses its
  `__type__` key, because that key declares a type and is not data to match on. The alpha
  index applies the type later, when it decides which nodes a fact reaches.

  A struct pattern keeps its `__struct__` check only when it needs one:

    * `%Mod{f: v}` drops the check. `Mod` is the type, so the index already applied it.
    * `%Mod{__type__: t, f: v}` keeps the check. Here `t` is the type, so the index no
      longer guarantees the module. The alpha must apply it, and the condition means "a
      `Mod`, **and** a `t`".

  A type is any term except `nil`. This matches `Rete.Taxonomy.default_fact_type/1`. A
  pattern must write the type as a **literal**, because the parser reads it at compile
  time. The alpha index routes on that value, so it cannot come from run time.
  """
  @spec compile_pattern(env(), Macro.t()) :: {term(), Macro.t()}
  def compile_pattern(env, pattern)

  # {type, a} - literal two element tuple
  def compile_pattern(_env, {tag, arg} = pattern) do
    {tag_type!(tag, pattern), {{:_, [], nil}, arg}}
  end

  # {type}, {type, a, b, ...} - any other arity
  def compile_pattern(_env, {:{}, meta, [tag | args]} = pattern) do
    {tag_type!(tag, pattern), {:{}, meta, [{:_, [], nil} | args]}}
  end

  # %Mod{f: v}, and %Mod{__type__: type, f: v} where the declared type wins
  def compile_pattern(env, {:%, struct_meta, [alias_ast, {:%{}, meta, fields}]} = pattern) do
    module = expand_type(env, alias_ast)

    case declared_type(fields) do
      # The module is the type, so the index already applied it. A `__struct__` check
      # would compare every fact and learn nothing. It would also break derivation,
      # because the index routes a descendant type here on purpose.
      :absent ->
        {module, {:%{}, meta, fields}}

      # The declared type routes instead, so the index no longer guarantees the module.
      # Facts of this type may be maps, or other structs. The module is therefore a
      # constraint the alpha must apply, and the struct pattern applies it. The
      # `__type__` value stays dropped: an alpha must never check a type again, or a
      # derived type routed here would stop matching.
      {:ok, type} ->
        rest = Keyword.delete(fields, :__type__)
        {type, {:%, struct_meta, [module, {:%{}, meta, rest}]}}

      :nil_type ->
        nil_type!(pattern)

      :not_literal ->
        not_literal!(fields, pattern)
    end
  end

  # %{__type__: type, f: v}
  def compile_pattern(_env, {:%{}, meta, fields} = pattern) when is_list(fields) do
    case declared_type(fields) do
      {:ok, type} ->
        {type, {:%{}, meta, Keyword.delete(fields, :__type__)}}

      # A map has no module to fall back to, so it must declare a type.
      :absent ->
        raise ArgumentError,
              "a map fact pattern must declare its type with __type__, e.g. " <>
                "%{__type__: :order, id: id}, got: " <> Macro.to_string(pattern)

      :nil_type ->
        nil_type!(pattern)

      :not_literal ->
        not_literal!(fields, pattern)
    end
  end

  def compile_pattern(_env, pattern), do: unsupported!(pattern)

  # Reads the type an AST node writes, at compile time. This is the only place that
  # decides what counts as a written type, for every shape. It returns an answer instead
  # of raising, because each of the three callers treats the answers differently.
  #
  #   {:ok, type}   a literal, and a usable type
  #   :nil_type     a literal `nil`, which declares no type at all
  #   :not_literal  a type is written, but its value is known only at run time
  @spec read_type(Macro.t()) :: {:ok, term()} | :nil_type | :not_literal
  defp read_type(ast) do
    if Macro.quoted_literal?(ast) do
      case literal_value(ast) do
        nil -> :nil_type
        type -> {:ok, type}
      end
    else
      :not_literal
    end
  end

  # Reads the `__type__` a map or struct pattern declares, and adds the one answer a bare
  # AST node cannot give: the key is not there at all. The caller then drops the key from
  # the pattern, so the alpha never matches it as an ordinary field.
  #
  # `fields` is the field list of a map AST. A key need not be an atom, because
  # `%{"id" => id, __type__: :row}` is a valid pattern. `Keyword.fetch/2` and
  # `Keyword.delete/2` both work on any list of two-element tuples.
  @spec declared_type(fields()) :: {:ok, term()} | :absent | :nil_type | :not_literal
  defp declared_type(fields) do
    case Keyword.fetch(fields, :__type__) do
      :error -> :absent
      {:ok, ast} -> read_type(ast)
    end
  end

  # Reads the type from the first element of a tuple pattern. Every tuple pattern has a
  # first element, so there is no `:absent` answer here. A tag whose value is unknown at
  # compile time makes the whole condition unsupported, and that error names the three
  # shapes.
  @spec tag_type!(Macro.t(), Macro.t()) :: term()
  defp tag_type!(ast, pattern) do
    case read_type(ast) do
      {:ok, type} -> type
      :nil_type -> nil_type!(pattern)
      :not_literal -> unsupported!(pattern)
    end
  end

  # A quoted literal is not always equal to its own value. For example, `%{a: 1}` quotes
  # to `{:%{}, [], [a: 1]}`. Evaluation is safe here, because `Macro.quoted_literal?/1`
  # has already confirmed that the AST holds no call and no variable.
  #
  # `Macro.quoted_literal?/1` counts an alias and a struct literal as literals, so this can
  # reach `Mod.__struct__/1` for a type written as `%Mod{}`. That makes the ruleset depend
  # on `Mod` at compile time. A module that is not available yet therefore fails with
  # Elixir's own struct error, not with a message from this module. Writing a struct as a
  # fact type is rare, and the alternative — reimplementing literal evaluation here — would
  # cost more than the better message is worth.
  defp literal_value(ast) do
    {value, _binding} = Code.eval_quoted(ast)
    value
  end

  @spec unsupported!(Macro.t()) :: no_return()
  defp unsupported!(pattern) do
    raise ArgumentError,
          "unsupported condition, expected a tagged tuple such as {:order, id}, a struct " <>
            "such as %Order{id: id}, or a tagged map such as %{__type__: :order, id: id}, got: " <>
            Macro.to_string(pattern)
  end

  # Every shape reports a `nil` type the same way, wherever the `nil` is written. The
  # message matches `Rete.Taxonomy.default_fact_type/1`, which rejects a `nil` type at
  # run time for the same reason.
  @spec nil_type!(Macro.t()) :: no_return()
  defp nil_type!(pattern) do
    raise ArgumentError,
          "nil is not a fact type, so this condition could never match: " <>
            Macro.to_string(pattern) <>
            ". nil means that no type is declared. Write a " <>
            "real type, or on a struct pattern omit __type__ to use the module instead."
  end

  @spec not_literal!(fields(), Macro.t()) :: no_return()
  defp not_literal!(fields, pattern) do
    raise ArgumentError,
          "the __type__ of a fact pattern must be a literal, because the alpha index " <>
            "routes on it at compile time, got: " <>
            Macro.to_string(Keyword.fetch!(fields, :__type__)) <>
            " in " <> Macro.to_string(pattern)
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

  This runs over the head of a query too, where the argument for unwrapping is weaker. A
  pin there becomes an ordinary pattern variable, and so a parameter. `def f(^x)` does not
  compile, so nothing is lost. But `defquery q(^cid)(...)` reads as a match on a value, and
  it is a parameter named `cid`.
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
  have the same behavior. An alias is lexical. `H.ok?(amt)` is the same AST in two
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
