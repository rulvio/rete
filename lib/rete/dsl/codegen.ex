defmodule Rete.DSL.Codegen do
  @moduledoc """
  Expression construction and code generation, compile phase **W3**.

  Codegen is the last phase before `Rete.IR.escape/1`. It owns two things:

    * **construction** - building the `Rete.IR.Expr` descriptor of every kind of
      executable the IR needs (`alpha_expr/5`, `test_expr/2`,
      `join_filter_expr/3`), including the stable code and name every one of
      them is identified by;
    * **emission** - turning a classified `Rete.IR.Production` into the quoted
      definitions that are spliced into the ruleset module (`expr_defs/1`,
      `rhs_def/1`, `compile/1`).

  Both halves live here so that the naming and hashing scheme has exactly one
  implementation: `Rete.DSL.Parser` and `Rete.DSL.Bindings` build their
  expressions through this module.

  ## The four generated functions

  | kind | arity | signature | emitted for |
  |---|---|---|---|
  | `:alpha` | 1 | `(fact) -> bindings_map \\| nil` | every `Rete.IR.Fact` and `Rete.IR.Coll` |
  | `:join_filter` | 2 | `(token_bindings, fact_bindings) -> boolean` | a condition whose guard reads an upstream variable |
  | `:test` | 1 | `(bindings_map) -> boolean` | a rule level `when` guard |
  | RHS | 2 | `(hash, bindings_map) -> facts` | every production |

  An alpha function matches a fact of **any** type on purpose: type filtering,
  including the taxonomy declared with `Rete.Ruleset.derive/2`, is applied by
  the alpha index when it decides whether to propagate a fact to a node, never
  inside the expression. The falsy result of an expression therefore depends on
  its kind: an alpha returns `nil` when the fact does not match, while a test
  and a join filter return `false`.

  ## Naming and hashing

      fact_<type>_bind_<v1>_<v2>_..._expr_<hash>        alpha, no guard
      test_fact_<type>_bind_<v1>_..._expr_<hash>        alpha, with guard
      test_bind_<v1>_..._expr_<hash>                    test over bindings only
      join_<type>_bind_<v1>_..._expr_<hash>             join filter

  `<type>` loses its `Elixir.` prefix and its dots (`MyApp.Order` becomes
  `MyApp_Order`), `<v...>` are the variables the expression reads, **sorted**,
  and `<hash>` is `:erlang.phash2/1` of the meta stripped `{args, body}` AST
  pair. The generated function is named `:"__<code>__"`.

  Two expressions with the same code have byte identical behaviour, which is
  what lets the network share nodes: `expr_defs/1` guards every definition with
  `Module.defines?/2`, so two rules of the same module that share a condition
  share one function.

  ## Dedup and the RHS

  The RHS reads the variables of the production's `:bind`, which is a product
  of the pipeline: `Rete.Ruleset.build/4` recomputes it from the **classified**
  LHS, so a variable that only ever appears inside a negation is not in it and
  the RHS never asks for a key no token can carry.

  How each one is read is decided by `Rete.IR.lhs_bindings/1`. A **guaranteed**
  binding is destructured in the head, `%{cid: cid}`; a binding only some
  branches of a disjunction produce is read with `Map.get/2` in the body and is
  `nil` on the branches that do not bind it. Either way only the variables the
  body actually reads are bound - ignoring a join variable is very common - so
  a guaranteed binding the body ignores is emitted as `%{name: _name}` and an
  ignored optional one is not read at all, and the rule still compiles under
  `--warnings-as-errors`. The map *keys* are untouched.
  """

  alias Rete.DSL.Vars
  alias Rete.IR

  @typedoc "The variable ASTs of the bindings an expression destructures."
  @type bind :: %{atom() => Macro.t()}

  # --------------------------------------------------------------------------
  # expression construction
  # --------------------------------------------------------------------------

  @doc """
  Builds the alpha `Rete.IR.Expr` of a condition, `(fact) -> bindings_map | nil`.

  `pattern` is the pattern as written and is only used to compute the stable
  hash, `args_ast` is the compiled argument pattern from
  `Rete.DSL.Parser.compile_pattern/2`, `guard` is the alpha part of the per
  condition guard (or `nil`), and `bind` maps every bound variable to its AST.

  Because the hash is taken over `{pattern, body}`, a condition whose guard was
  wholly lifted into a join filter produces exactly the same code as the same
  condition written without a guard, and shares its alpha node.
  """
  @spec alpha_expr(atom() | module(), Macro.t(), Macro.t(), Macro.t() | nil, bind()) ::
          IR.Expr.t()
  def alpha_expr(type, pattern, args_ast, guard, bind) do
    bind_ast = bind_pattern(bind)

    {prefix, body} =
      case guard do
        nil ->
          {[:fact], bind_ast}

        guard ->
          body =
            quote do
              if unquote(guard) do
                unquote(bind_ast)
              end
            end

          {[:test, :fact], body}
      end

    code = expr_code(prefix ++ [type_code(type), :bind], Map.keys(bind), expr_hash(pattern, body))

    %IR.Expr{
      code: code,
      name: expr_name(code),
      arity: 1,
      kind: :alpha,
      fun: nil,
      __ast__: %{args: args_ast, body: body}
    }
  end

  @doc """
  Builds the `Rete.IR.Expr` of a test over bindings, `(bindings_map) -> boolean`.

  Produced by a rule level guard, `defrule r(...) when <guard> do`.
  """
  @spec test_expr(Macro.t(), bind()) :: IR.Expr.t()
  def test_expr(guard, bind) do
    bind_ast = bind_pattern(bind)
    code = expr_code([:test, :bind], Map.keys(bind), expr_hash(bind_ast, guard))

    %IR.Expr{
      code: code,
      name: expr_name(code),
      arity: 1,
      kind: :test,
      fun: nil,
      __ast__: %{args: bind_ast, body: guard}
    }
  end

  @doc """
  Builds a join filter, `(token_bindings, fact_bindings) -> boolean`.

  This is what makes a cross condition guard work. `local` is the set of
  variables the condition's own pattern binds; every variable the guard reads is
  destructured from the **fact** side when it is local and from the **token**
  side otherwise, so a join variable is never bound twice in the same pattern.

  The body is wrapped in `if ..., do: true, else: false` so that the documented
  boolean contract holds whatever the user wrote.
  """
  @spec join_filter_expr(atom() | module(), MapSet.t(atom()) | [atom()], Macro.t()) ::
          IR.Expr.t()
  def join_filter_expr(type, local, guard) do
    local = if is_list(local), do: local, else: MapSet.to_list(local)

    # A guard is an expression, so ask what it *reads*, not what a pattern would
    # bind. Using the pattern analysis here would destructure a key the token
    # never carries whenever the guard contains its own binder.
    vars =
      guard
      |> Vars.read_var_names()
      |> Map.new(&{&1, Macro.var(&1, nil)})

    {fact_vars, token_vars} = Map.split(vars, local)

    args = [bind_pattern(token_vars), bind_pattern(fact_vars)]
    body = quote(do: if(unquote(guard), do: true, else: false))
    code = expr_code([:join, type_code(type), :bind], Map.keys(vars), expr_hash(args, body))

    %IR.Expr{
      code: code,
      name: expr_name(code),
      arity: 2,
      kind: :join_filter,
      fun: nil,
      __ast__: %{args: args, body: body}
    }
  end

  # Sorted, always. `Map.to_list/1` on an atom keyed map iterates in atom table
  # *interning* order, which depends on what the VM happened to intern first —
  # so the same source text hashed to different codes depending on whether the
  # build was incremental. Codes are the node sharing key, so that silently
  # duplicated alpha nodes on every rebuild. Sorting makes the pattern, and
  # therefore the hash, a function of the source alone.
  defp bind_pattern(bind), do: {:%{}, [], Enum.sort_by(bind, &elem(&1, 0))}

  # --------------------------------------------------------------------------
  # naming and hashing
  # --------------------------------------------------------------------------

  @doc """
  Joins a code prefix, the sorted variable names and the hash into an
  expression code.
  """
  @spec expr_code([atom() | String.t()], [atom()], integer()) :: atom()
  def expr_code(prefix, bind_keys, hash) do
    prefix
    |> Enum.concat(Enum.sort(bind_keys))
    |> Enum.concat([:expr, hash])
    |> Enum.join("_")
    |> String.to_atom()
  end

  @doc """
  The name of the function generated for an expression code, `:"__<code>__"`.
  """
  @spec expr_name(atom()) :: atom()
  def expr_name(code), do: String.to_atom("__#{code}__")

  @doc """
  Renders a fact type for use inside an expression code.

  Module types lose their `Elixir.` prefix and their dots, so `MyApp.Order`
  becomes `MyApp_Order` and codes stay readable.
  """
  @spec type_code(atom() | module()) :: String.t()
  def type_code(type) when is_atom(type) do
    case Atom.to_string(type) do
      "Elixir." <> rest -> String.replace(rest, ".", "_")
      other -> other
    end
  end

  @doc """
  The stable hash of an expression, from its argument pattern and its body.

  Metadata (and therefore line numbers) is stripped first, so the same source
  text always hashes the same wherever it is written.
  """
  @spec expr_hash(Macro.t(), Macro.t()) :: non_neg_integer()
  def expr_hash(args, body), do: ast_hash({args, body})

  @doc """
  The stable hash of an AST fragment.

  Two normalisations run first, and both exist so that the hash is a function of
  what the code *means* rather than of how it was typed:

    * metadata is stripped, so a rule keeps its hash when it moves down a file;
    * discarded variables are canonicalised to `_`, so `{:order, _x}` and
      `{:order, _y}` — which compile to byte identical functions, since a
      `_`-prefixed name is never a binding — share one expression and therefore
      one alpha node.

  A module attribute hashes as its *name*, because its value cannot be known
  here: `@limit` expands to a `Module.__get_attribute__/4` call that only runs
  once the module body is evaluated, which is after every macro in the body has
  expanded. Two conditions over the same pattern therefore share a code whatever
  the attribute is currently worth, which is what keeps them sharing an alpha
  node in the ordinary case where the value has not changed. The case where it
  *has* changed is caught by `check_attr_values!/3` when the body runs.
  """
  @spec ast_hash(Macro.t()) :: non_neg_integer()
  def ast_hash(ast) do
    ast
    |> Macro.postwalk(&canonicalize/1)
    |> Macro.escape()
    |> :erlang.term_to_binary()
    |> :erlang.phash2()
  end

  defp canonicalize({name, _meta, context} = node) when is_atom(name) and is_atom(context) do
    if Vars.discarded?(name), do: {:_, [], context}, else: Macro.update_meta(node, fn _ -> [] end)
  end

  defp canonicalize(node), do: Macro.update_meta(node, fn _ -> [] end)

  # --------------------------------------------------------------------------
  # emission
  # --------------------------------------------------------------------------

  @doc """
  The complete quoted body a `defrule`/`defquery` expands to.

  In order: the expression functions, the escaped production appended to
  `@rule_data`, and the RHS function. The escaped production captures the
  expression functions by name, so it must come after their definitions.
  """
  @spec compile(IR.Production.t()) :: Macro.t()
  def compile(%IR.Production{} = production) do
    quote do
      unquote_splicing(expr_defs(production))

      @rule_data @rule_data ++ [unquote(IR.escape(production))]

      unquote(rhs_def(production))
    end
  end

  @doc """
  The quoted definitions of every expression function of a production.

  Deduplicated by name within the production and guarded with
  `Module.defines?/2` across productions, so a condition shared by two rules of
  the same module is compiled once.
  """
  @spec expr_defs(IR.Production.t()) :: [Macro.t()]
  def expr_defs(%IR.Production{} = production) do
    production
    |> IR.exprs()
    |> Enum.uniq_by(& &1.name)
    |> Enum.map(&expr_def/1)
  end

  @doc """
  The quoted definition of the RHS function, `(hash, bindings_map) -> facts`.

  Its name is the production name, so `defrule loyalty(...)` also defines
  `loyalty/2`.

  The bindings are read in two ways, decided by `Rete.IR.lhs_bindings/1`:

    * a **guaranteed** binding is destructured in the head, `%{cid: cid}`, so a
      token that is missing it raises a `FunctionClauseError` instead of firing
      the rule with a hole in it;
    * an **optional** binding - one only some branches of a disjunction bind -
      is read with `Map.get/2` in the body, because the tokens of the other
      branches genuinely do not carry the key. It is `nil` there.

  Either way only the variables the body actually reads are bound, so a rule
  that ignores a join variable still compiles under `--warnings-as-errors`.
  """
  @spec rhs_def(IR.Production.t()) :: Macro.t()
  def rhs_def(%IR.Production{__ast__: %{bind: bind, body: body}} = production) do
    {_guaranteed, optional} = IR.lhs_bindings(production.lhs)
    {optional, guaranteed} = Map.split(bind, optional)

    used = read_vars(body)
    optional = Enum.filter(optional, fn {name, _ast} -> MapSet.member?(used, name) end)

    {arg, body} = rhs_arg(rhs_bind_pattern(guaranteed, body), optional, body)
    head = {production.name, [], [production.hash, arg]}

    quote do
      Kernel.def(unquote(head), unquote(body))
    end
  end

  # No optional binding is read: the argument is the bindings pattern itself and
  # the body is untouched, which is every production that has no disjunction
  # binding different variables on different branches.
  defp rhs_arg(pattern, [], body), do: {pattern, body}

  defp rhs_arg(pattern, optional, body) do
    bindings = Macro.unique_var(:bindings, __MODULE__)

    reads =
      Enum.map(optional, fn {name, var} ->
        quote(do: unquote(var) = Map.get(unquote(bindings), unquote(name)))
      end)

    body =
      Keyword.update!(body, :do, fn block ->
        quote do
          (unquote_splicing(reads))
          unquote(block)
        end
      end)

    {{:=, [], [pattern, bindings]}, body}
  end

  @doc """
  The quoted definition of a single expression function.

  An arity 1 expression matches the fact (or the bindings map) against its
  argument pattern; an arity 2 join filter matches both sides at once. The
  fallback of a non matching argument is `nil` for an alpha and `false` for a
  test or a join filter, matching each kind's documented return type.
  """
  @spec expr_def(IR.Expr.t()) :: Macro.t()
  def expr_def(%IR.Expr{arity: 1, name: name, __ast__: %{args: args, body: body}} = expr) do
    fallback = fallback(expr)

    quote do
      unquote(attr_check(expr))

      if not Module.defines?(__MODULE__, {unquote(name), 1}) do
        def unquote(name)(args) do
          case args do
            unquote(args) -> unquote(body)
            _ -> unquote(fallback)
          end
        end
      end
    end
  end

  def expr_def(%IR.Expr{arity: 2, name: name, __ast__: %{args: [left, right], body: body}} = expr) do
    fallback = fallback(expr)

    quote do
      unquote(attr_check(expr))

      if not Module.defines?(__MODULE__, {unquote(name), 2}) do
        def unquote(name)(left, right) do
          case {left, right} do
            {unquote(left), unquote(right)} -> unquote(body)
            _ -> unquote(fallback)
          end
        end
      end
    end
  end

  # Two expressions share a generated function when their AST is equal, and a
  # module attribute's AST does not carry its value. So `@limit 5` and a later
  # `@limit 100` over the same pattern would share one function, and the second
  # rule would silently match on 5.
  #
  # Emitted into the module body, where attribute values finally *are*
  # readable, this records what each code saw and rejects a second, different
  # reading. Conditions with no attributes emit nothing and share as before.
  defp attr_check(%IR.Expr{code: code, __ast__: ast}) do
    case attr_names(ast) do
      [] ->
        nil

      names ->
        pairs = Enum.map(names, fn name -> {name, {:@, [], [{name, [], nil}]}} end)

        quote do
          Rete.DSL.Codegen.check_attr_values!(__MODULE__, unquote(code), unquote(pairs))
        end
    end
  end

  defp attr_names(ast) do
    {_, names} =
      ast
      |> Map.take([:args, :body])
      |> Map.values()
      |> Macro.prewalk(MapSet.new(), fn
        {:@, _, [{name, _, context}]} = node, acc when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    Enum.sort(names)
  end

  @doc """
  Asserts that an expression code always sees the same module attribute values.

  Called from the ruleset module's body, where attribute values are readable,
  once per generated expression that mentions an attribute. Raises when a code
  that was already generated is reached again with a different value, which
  would otherwise silently reuse the first rule's compiled function.
  """
  @spec check_attr_values!(module(), atom(), keyword()) :: :ok
  def check_attr_values!(module, code, values) do
    seen = Module.get_attribute(module, :rete_expr_attrs) || %{}

    case Map.fetch(seen, code) do
      {:ok, ^values} ->
        :ok

      {:ok, previous} ->
        changed =
          values
          |> Enum.reject(fn {name, value} -> previous[name] == value end)
          |> Enum.map_join("\n", fn {name, value} ->
            "    @#{name} was #{inspect(previous[name])}, is now #{inspect(value)}"
          end)

        raise ArgumentError, """
        two conditions in #{inspect(module)} are written identically but read \
        different module attribute values:

        #{changed}

        An attribute's value is not part of a condition's identity - only its \
        name is - so both conditions would compile to one function and the \
        second would match on the first value. Write the values literally, or \
        use a differently named attribute for each.
        """

      :error ->
        Module.put_attribute(module, :rete_expr_attrs, Map.put(seen, code, values))
        :ok
    end
  end

  # An alpha signals "no match" with nil, because nil is distinguishable from
  # the empty bindings map an arity 0 pattern returns. A test and a join filter
  # are predicates.
  defp fallback(%IR.Expr{kind: :alpha}), do: nil
  defp fallback(%IR.Expr{}), do: false

  # The RHS destructures every variable bound on the LHS. A variable the body
  # never reads is renamed to _var in the pattern so the rule still compiles
  # under --warnings-as-errors; the map key is untouched.
  defp rhs_bind_pattern(bind, body) do
    used = read_vars(body)

    fields =
      Enum.map(bind, fn
        {name, {name, meta, ctx}} ->
          if MapSet.member?(used, name) do
            {name, {name, meta, ctx}}
          else
            {name, {String.to_atom("_#{name}"), meta, ctx}}
          end

        field ->
          field
      end)

    {:%{}, [], fields}
  end

  defp read_vars(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    vars
  end
end
