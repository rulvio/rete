defmodule Rete.IR do
  @moduledoc """
  The intermediate representation (IR) shared by every compile phase of `Rete`.

  The IR is produced by `Rete.DSL.Parser` from the quoted arguments of
  `Rete.Ruleset.defrule/2` and `Rete.Ruleset.defquery/2`, is refined in place by
  the later compile phases, and is finally escaped into the defining module so
  the network builder can read it at runtime.

  ## Pipeline

      quoted DSL
        |> Rete.DSL.Parser.parse_production/4      # W1 - this phase
        |> normalize gates / classify bindings     # W2
        |> split guards into alpha + join filters  # W3
        |> Rete.IR.escape/1                        # emitted into the ruleset module
        |> beta network construction               # W4

  Every phase consumes and produces `%Rete.IR.Production{}` values, so a struct
  carries fields that a later phase fills in. Fields that are `nil` after
  parsing are documented as such on each struct.

  ## Compile-time vs runtime

  Each struct that is produced by the parser carries an `:__ast__` field holding
  the raw quoted fragments the later phases need (the pattern, the guard, the
  binding variable AST). `:__ast__` is **compile-time only**: `escape/1` drops it
  so that quoted ASTs never reach the compiled module.

  ## Fact types and the alpha network

  A condition's `:type` is the *declared* fact type, never a runtime check baked
  into the alpha expression. Alpha expressions match a fact of **any** type on
  purpose; the taxonomy (`derive/2`, `underive/2`) is applied by the alpha index
  when it decides whether a fact should be propagated to a node. Concretely:

    * `{:order, id, amt}` declares type `:order` and compiles to the pattern
      `{_, id, amt}`
    * `%Order{id: id}` declares type `Order` and compiles to the pattern
      `%{id: id}`
    * `%{__type__: :order, id: id}` declares type `:order` and compiles to the
      pattern `%{id: id}`
  """

  defmodule Expr do
    @moduledoc """
    A compile-time generated named function that lives in the ruleset module.

    Expressions are the only executable part of the IR. They are emitted as
    public zero-side-effect functions in the module that used `Rete.Ruleset` so
    that they can be captured, compared and shared between rules.

    ## Fields

      * `:code` - stable, human readable unique id of the expression, e.g.
        `:fact_order_bind_amt_id_expr_44631555`. Two structurally identical
        conditions (in the same module context) produce the same `:code`, which
        is what lets the network share nodes.
      * `:name` - the name of the generated function, always
        `:"__<code>__"`.
      * `:arity` - arity of the generated function (`1` or `2`).
      * `:kind` - what the expression is used for, `:alpha`, `:test` or
        `:join_filter`. It fixes the calling convention below, and it is what
        `Rete.DSL.Codegen` dispatches on to decide whether a non matching
        argument yields `nil` or `false`.
      * `:fun` - the captured function. `nil` until the expression is escaped
        into the defining module; populated from then on.
      * `:__ast__` - `%{args: quoted, body: quoted}`, the argument pattern and
        the body used to emit the function. Compile-time only, dropped by
        `Rete.IR.escape/1`.

    ## Calling conventions

      * `:alpha`, arity 1: `(fact) -> bindings_map | nil`. Returns `nil` when
        the fact does not match the pattern or fails the guard.
      * `:test`, arity 1: `(bindings_map) -> boolean`.
      * `:join_filter`, arity 2: `(token_bindings, fact_bindings) -> boolean`.
    """

    @typedoc "What an expression is used for; fixes its calling convention."
    @type kind :: :alpha | :test | :join_filter

    @type t :: %__MODULE__{
            code: atom(),
            name: atom(),
            arity: 1 | 2,
            kind: kind() | nil,
            fun: (... -> any()) | nil,
            __ast__: %{args: Macro.t(), body: Macro.t()} | nil
          }

    defstruct [:code, :name, :arity, :kind, :fun, :__ast__]
  end

  defmodule Fact do
    @moduledoc """
    A single fact condition, e.g. `{:order, id, amt}`, `%Order{id: id}` or
    `f = {:order, id} when amt > 0`.

    ## Fields

      * `:type` - `atom | module`, the declared fact type. Taxonomy is applied
        later, by the alpha index, never by `:alpha`.
      * `:fact_binding` - `atom | nil`, the variable the *whole* fact binds to
        (the `f` in `f = {:order, id}`). It is not part of `:bind` because the
        alpha expression does not return it; the engine adds it when it builds a
        token.
      * `:bind` - `[atom]`, the variables bound by the pattern itself, sorted.
        Variables whose name starts with `_` are excluded, as are pinned (`^x`)
        and module attribute (`@x`) values.
      * `:alpha` - `%Rete.IR.Expr{arity: 1}`, `(fact) -> bindings_map | nil`.
      * `:join_filter` - `%Rete.IR.Expr{arity: 2} | nil`,
        `(token_bindings, fact_bindings) -> boolean`. `nil` after parsing; W3
        fills it in when a per-condition guard refers to variables bound by an
        earlier condition.
      * `:join_bind` - `[atom] | nil`, variables shared with upstream conditions,
        used as hash join keys. `nil` after parsing, filled in by W2.
      * `:new_bind` - `[atom] | nil`, variables first introduced by this
        condition. `nil` after parsing, filled in by W2.
      * `:__ast__` - see `t:ast/0`. Compile-time only.
    """

    @typedoc """
    Raw quoted fragments kept for the later phases.

      * `:pattern` - the pattern as written, without the fact binding and
        without the `when` guard, e.g. `{:order, id, amt}`.
      * `:guard` - the per-condition guard AST, or `nil`.
      * `:bind` - `%{atom => quoted_var}`, the variable AST for every entry of
        `:bind`.
      * `:source` - the whole element as written, for error messages.
    """
    @type ast :: %{
            pattern: Macro.t(),
            guard: Macro.t() | nil,
            bind: %{atom() => Macro.t()},
            source: Macro.t()
          }

    @type t :: %__MODULE__{
            type: atom() | module(),
            fact_binding: atom() | nil,
            bind: [atom()],
            alpha: Rete.IR.Expr.t(),
            join_filter: Rete.IR.Expr.t() | nil,
            join_bind: [atom()] | nil,
            new_bind: [atom()] | nil,
            __ast__: ast() | nil
          }

    defstruct [
      :type,
      :fact_binding,
      :bind,
      :alpha,
      :join_filter,
      :join_bind,
      :new_bind,
      :__ast__
    ]
  end

  defmodule Coll do
    @moduledoc """
    A collection binding, e.g. `[{:order, id}]` or
    `orders = [{:order, id} when amt > 0]`.

    A collection binding is the engine's only accumulator and it is always
    *collect all*: every fact matching the condition is gathered into a list.
    Aggregation (sum, count, min, ...) is the right hand side's job.

    ## Empty collection semantics

    If the condition introduces no new variable (all of its pattern variables
    are bound upstream or pinned) it propagates `[]` and the rule still fires
    with zero matches. If it does introduce a new variable it groups by that
    variable, so only non-empty groups exist. `:new_bind` (computed in W2) is
    what decides between the two.

    ## Fields

    Identical to `Rete.IR.Fact` except:

      * `:coll_binding` - `atom | nil`, the variable the collected *list* binds
        to (the `orders` in `orders = [{:order, id}]`). `nil` for an anonymous
        collection such as `[{:order, id}]`, which still constrains the match
        but does not surface the list to the RHS.

    `:alpha` has the same `(fact) -> bindings_map | nil` shape as a
    `Rete.IR.Fact` alpha: it is applied per element, not to the list.
    """

    @type t :: %__MODULE__{
            type: atom() | module(),
            coll_binding: atom() | nil,
            bind: [atom()],
            alpha: Rete.IR.Expr.t(),
            join_filter: Rete.IR.Expr.t() | nil,
            join_bind: [atom()] | nil,
            new_bind: [atom()] | nil,
            inert: [atom()],
            __ast__: Rete.IR.Fact.ast() | nil
          }

    defstruct [
      :type,
      :coll_binding,
      :bind,
      :alpha,
      :join_filter,
      :join_bind,
      :new_bind,
      :__ast__,
      inert: []
    ]
  end

  defmodule Test do
    @moduledoc """
    A guard over bindings only, with no fact input.

    Produced by the rule level guard, `defrule r(...) when <guard> do`, and (from
    W3 on) by guards that were lifted out of a condition because they only
    reference variables bound upstream.

    ## Fields

      * `:bind` - `[atom]`, the variables the guard reads, sorted.
      * `:expr` - `%Rete.IR.Expr{arity: 1}`, `(bindings_map) -> boolean`.
      * `:__ast__` - `%{guard: quoted, bind: %{atom => quoted_var}}`.
        Compile-time only.
    """

    @type t :: %__MODULE__{
            bind: [atom()],
            expr: Rete.IR.Expr.t(),
            __ast__: %{guard: Macro.t(), bind: %{atom() => Macro.t()}} | nil
          }

    defstruct [:bind, :expr, :__ast__]
  end

  defmodule Gate do
    @moduledoc """
    An unnormalized logical gate, `{gate, [condition, ...]}`.

    This is a **W1 placeholder**. The parser recognises the gate and parses its
    arguments, but performs no normalization: W2 rewrites gates into de Morgan
    normal form and replaces them with plain conditions, `Rete.IR.Negation`
    nodes and `{:or, [[condition, ...], ...]}` disjunctions.

    `:gate` is one of `:and`, `:or`, `:not`, `:nand`, `:nor`, `:xor`, `:xnor`.
    n-ary `:xor` means *exactly one* argument holds; `:xnor` is its negation.
    `:not` with several arguments is the negation of the conjunction of them.

    ## Fields

      * `:gate` - the gate atom.
      * `:args` - the parsed argument conditions (`Fact`, `Coll`, `Test` or a
        nested `Gate`).
      * `:code` - a nested list `[gate | arg codes]` uniquely identifying the
        gate by structure, used for node sharing.
    """

    @type t :: %__MODULE__{
            gate: :and | :or | :not | :nand | :nor | :xor | :xnor,
            args: [Rete.IR.condition()],
            code: [atom() | list()]
          }

    defstruct [:gate, :args, :code]
  end

  defmodule Negation do
    @moduledoc """
    The negation of a single condition.

    Not produced by the parser: `Rete.DSL.Normalize` creates negations while
    normalizing `Rete.IR.Gate` nodes. `:condition` is always a single
    `Rete.IR.Fact` or `Rete.IR.Coll`; the negation of a *conjunction* is a
    `Rete.IR.CompoundNegation` instead.
    """

    @type t :: %__MODULE__{condition: Rete.IR.Fact.t() | Rete.IR.Coll.t()}

    defstruct [:condition]
  end

  defmodule CompoundNegation do
    @moduledoc """
    The negation of a *conjunction* of conditions - "no match satisfies all of
    these at once".

    Produced by `Rete.DSL.Normalize` for `{:not, [...]}`, `{:nand, [...]}` and
    everything that desugars to a negated conjunction. It exists because de
    Morgan is **not** sound here. `not(and(a, b))` = `or(not a, not b)` holds
    propositionally, but the conjuncts of a rule condition share existentially
    quantified variables:

        {:nand, [{:order, x}, {:refund, x}]}

    means "there is no `x` with both an order and a refund". De Morganed it
    would mean "there are no orders at all, or no refunds at all" - a different
    statement, false whenever one `x` has an order and a *different* `x` has a
    refund.

    ## What W4 has to do with it

    Extract it, exactly as Clara's `get-complex-negation` does: generate a
    helper production whose LHS is `:conditions` and whose RHS inserts a marker
    fact carrying the variables the negation joins on, then replace the
    `CompoundNegation` with a plain `Rete.IR.Negation` of that marker. Nothing
    else in the pipeline can evaluate one.

    ## Fields

      * `:conditions` - the conjunction being negated, in author order, at
        least two elements. Each is a `Rete.IR.Fact`, `Rete.IR.Coll`,
        `Rete.IR.Test`, `Rete.IR.Negation` or a nested `Rete.IR.CompoundNegation`
        - never a `Rete.IR.Gate` and never a `{:or, ...}`, because normalization
        has already distributed those away.

    Like a `Rete.IR.Negation` it binds nothing downstream: `Rete.IR.bound_vars/1`
    returns `[]`. Its inner conditions are still classified, because the
    extracted helper production needs their join keys.
    """

    @type t :: %__MODULE__{conditions: [Rete.IR.condition()]}

    defstruct conditions: []
  end

  defmodule Production do
    @moduledoc """
    A rule or a query.

    ## Fields

      * `:name` - the name given in `defrule`/`defquery`; also the name of the
        generated RHS function.
      * `:type` - `:rule` or `:query`.
      * `:hash` - `:erlang.phash2/1` of the declaration and body AST, stable for
        a given source text, used to identify the production.
      * `:opts` - keyword list from the optional leading options map, e.g.
        `[salience: 100]`.
      * `:bind` - `[atom]`, every variable the LHS can make visible to the RHS,
        sorted, including fact and collection bindings. Computed from the
        **classified** LHS by `Rete.IR.lhs_bindings/1`, so it excludes the
        variables of a negation (which binds nothing downstream) and of a rule
        level guard, and it is the *union* over the branches of a disjunction.
        A variable only some branches bind is not in every token, so the RHS
        reads it defensively; see `lhs_bindings/1`.
      * `:lhs` - the ordered condition list, see `t:Rete.IR.lhs/0`.
      * `:rhs` - the captured RHS function, `(hash, bindings_map) -> facts`.
        `nil` until the production is escaped into its module. Its return value
        is logically inserted and truth maintained; `nil` or `[]` inserts
        nothing.
      * `:module` - the module the production was defined in.
      * `:__ast__` - `%{bind: %{atom => quoted_var}, decl: quoted, body: quoted}`.
        Compile-time only.
    """

    @type t :: %__MODULE__{
            name: atom(),
            type: :rule | :query,
            hash: integer(),
            opts: keyword(),
            bind: [atom()],
            lhs: Rete.IR.lhs(),
            rhs: (integer(), map() -> any()) | nil,
            module: module(),
            __ast__: map() | nil
          }

    defstruct [:name, :type, :hash, :opts, :bind, :lhs, :rhs, :module, :__ast__]
  end

  @typedoc """
  A single LHS condition.
  """
  @type condition ::
          Fact.t() | Coll.t() | Test.t() | Gate.t() | Negation.t() | CompoundNegation.t()

  @typedoc """
  One element of a left hand side.

  Either a single condition or a disjunction of conjunctions. A branch of a
  disjunction is itself a list of elements, so branches may nest: binding
  classification absorbs the elements that follow a disjunction into its
  branches when they classify differently on each one.
  """
  @type element :: condition() | {:or, [[element()]]}

  @typedoc """
  The left hand side of a production.

  An **ordered** list, never flattened to DNF (that explodes combinatorially).
  Normalization is per condition, so an element is either a single condition or
  a disjunction of conjunctions, `{:or, [[condition, ...], ...]}`, that fans out
  from the current parents and re-converges before the next element. The parser
  only ever emits plain conditions and `Rete.IR.Gate` placeholders; the `{:or,
  ...}` form appears from W2 on.
  """
  @type lhs :: [element()]

  @doc """
  All variables a condition makes visible downstream.

  This is `:bind` plus the fact or collection binding, which the alpha
  expression does not return but the engine adds to the token.

  A `Rete.IR.Test` has no fact input and a negation never matches a fact, so
  all three of them bind nothing: a `Test`'s `:bind` is what its guard *reads*,
  not what it introduces.
  """
  @spec bound_vars(condition()) :: [atom()]
  def bound_vars(%Fact{bind: bind, fact_binding: nil}), do: bind
  def bound_vars(%Fact{bind: bind, fact_binding: f}), do: bind ++ [f]
  def bound_vars(%Coll{} = coll), do: coll_bound_vars(coll)
  def bound_vars(%Test{}), do: []
  def bound_vars(%Negation{}), do: []
  def bound_vars(%CompoundNegation{}), do: []
  def bound_vars(%Gate{args: args}), do: args |> Enum.flat_map(&bound_vars/1) |> Enum.uniq()

  # A collection's pattern variables are local to it unless something outside
  # reads them - see `Rete.DSL.Bindings.mark_inert/1`. An inert one is still in
  # `:bind`, because the alpha has to return it for the join filter to test, but
  # it binds nothing downstream and groups nothing.
  defp coll_bound_vars(%Coll{bind: bind, inert: inert, coll_binding: c}) do
    visible = bind -- (inert || [])
    if c, do: visible ++ [c], else: visible
  end

  @doc """
  The variables a classified LHS makes visible to the right hand side, split
  into `{guaranteed, optional}`.

  Both lists are sorted and disjoint; together they are the `:bind` of the
  production.

    * **guaranteed** - bound on every path through the LHS, so the key is
      present in every token that reaches the RHS.
    * **optional** - bound on some branch of a disjunction but not on all of
      them. The key is missing from the tokens of the other branches, so the
      RHS reads it with `Map.get/2` and sees `nil` there.

  Only the *intersection* of the branches of a disjunction is guaranteed,
  because the branches re-converge; a negation and a `Rete.IR.Test` contribute
  nothing, because neither makes a fact available downstream.

  Run this on the **classified** LHS. On a raw parsed one it still answers
  correctly for gates, since `bound_vars/1` of a `Rete.IR.Gate` is the union of
  its arguments, but that union is exactly the over-approximation this function
  exists to avoid.

      iex> alias Rete.IR
      iex> user = %IR.Fact{bind: [:id]}
      iex> admin = %IR.Fact{bind: [:level]}
      iex> IR.lhs_bindings([{:or, [[user], [admin]]}])
      {[], [:id, :level]}
  """
  @spec lhs_bindings(lhs()) :: {[atom()], [atom()]}
  def lhs_bindings(lhs) do
    {guaranteed, all} = collect_bindings(lhs, {MapSet.new(), MapSet.new()})
    {Enum.sort(guaranteed), all |> MapSet.difference(guaranteed) |> Enum.sort()}
  end

  defp collect_bindings(elements, acc), do: Enum.reduce(elements, acc, &collect_element/2)

  # `{:or, []}` is *false*: no branch, so nothing past it is reachable and
  # nothing is bound.
  defp collect_element({:or, []}, acc), do: acc

  defp collect_element({:or, branches}, {guaranteed, all}) do
    branches = Enum.map(branches, &collect_bindings(&1, {MapSet.new(), MapSet.new()}))

    branch_guaranteed =
      branches |> Enum.map(&elem(&1, 0)) |> Enum.reduce(&MapSet.intersection/2)

    branch_all = branches |> Enum.map(&elem(&1, 1)) |> Enum.reduce(&MapSet.union/2)

    {MapSet.union(guaranteed, branch_guaranteed), MapSet.union(all, branch_all)}
  end

  defp collect_element(condition, {guaranteed, all}) do
    vars = MapSet.new(bound_vars(condition))
    {MapSet.union(guaranteed, vars), MapSet.union(all, vars)}
  end

  @doc """
  Every `Rete.IR.Expr` reachable from a production or condition, in LHS order.

  Alpha expressions come before the join filter of the same condition. The list
  is not deduplicated; use `Enum.uniq_by(&(&1.name))` when emitting functions.
  """
  @spec exprs(Production.t() | element()) :: [Expr.t()]
  def exprs(%Production{lhs: lhs}), do: Enum.flat_map(lhs, &exprs/1)
  def exprs(%Fact{alpha: alpha, join_filter: jf}), do: Enum.reject([alpha, jf], &is_nil/1)
  def exprs(%Coll{alpha: alpha, join_filter: jf}), do: Enum.reject([alpha, jf], &is_nil/1)
  def exprs(%Test{expr: expr}), do: [expr]
  def exprs(%Negation{condition: condition}), do: exprs(condition)

  def exprs(%CompoundNegation{conditions: conditions}), do: Enum.flat_map(conditions, &exprs/1)

  def exprs(%Gate{args: args}), do: Enum.flat_map(args, &exprs/1)

  def exprs({:or, branches}),
    do: Enum.flat_map(branches, &Enum.flat_map(&1, fn c -> exprs(c) end))

  @doc """
  The `{code, fun}` pairs of every expression of a production.

  Used by the `get_expr_data/0` function generated in each ruleset module.
  """
  @spec expr_data(Production.t()) :: [{atom(), (... -> any())}]
  def expr_data(production) do
    production |> exprs() |> Enum.map(&{&1.code, &1.fun})
  end

  @doc """
  Turns a parsed production into quoted code that rebuilds it inside the
  defining module.

  The generated code must be spliced into the module body *after* the
  expression functions have been defined, because it captures them by name. The
  `:__ast__` fields are dropped, `:fun` fields become
  `Function.capture(__MODULE__, name, arity)`, `:rhs` becomes
  `Function.capture(__MODULE__, name, 2)` and `:opts` is kept unescaped so that
  option values are evaluated in the module scope.
  """
  @spec escape(Production.t()) :: Macro.t()
  def escape(%Production{} = production) do
    %Production{name: name, type: type, hash: hash, opts: opts, bind: bind, lhs: lhs} = production

    struct_ast(Production,
      name: Macro.escape(name),
      type: Macro.escape(type),
      hash: Macro.escape(hash),
      opts: opts,
      bind: Macro.escape(bind),
      lhs: Enum.map(lhs, &escape_condition/1),
      rhs: quote(do: Function.capture(__MODULE__, unquote(name), 2)),
      module: quote(do: __MODULE__)
    )
  end

  defp escape_condition(%Fact{} = fact) do
    struct_ast(Fact,
      type: Macro.escape(fact.type),
      fact_binding: Macro.escape(fact.fact_binding),
      bind: Macro.escape(fact.bind),
      alpha: escape_expr(fact.alpha),
      join_filter: escape_expr(fact.join_filter),
      join_bind: Macro.escape(fact.join_bind),
      new_bind: Macro.escape(fact.new_bind)
    )
  end

  defp escape_condition(%Coll{} = coll) do
    struct_ast(Coll,
      type: Macro.escape(coll.type),
      coll_binding: Macro.escape(coll.coll_binding),
      bind: Macro.escape(coll.bind),
      alpha: escape_expr(coll.alpha),
      join_filter: escape_expr(coll.join_filter),
      join_bind: Macro.escape(coll.join_bind),
      new_bind: Macro.escape(coll.new_bind),
      inert: Macro.escape(coll.inert)
    )
  end

  defp escape_condition(%Test{} = test) do
    struct_ast(Test, bind: Macro.escape(test.bind), expr: escape_expr(test.expr))
  end

  defp escape_condition(%Negation{condition: condition}) do
    struct_ast(Negation, condition: escape_condition(condition))
  end

  defp escape_condition(%CompoundNegation{conditions: conditions}) do
    struct_ast(CompoundNegation, conditions: Enum.map(conditions, &escape_condition/1))
  end

  defp escape_condition(%Gate{gate: gate, args: args, code: code}) do
    struct_ast(Gate,
      gate: Macro.escape(gate),
      args: Enum.map(args, &escape_condition/1),
      code: Macro.escape(code)
    )
  end

  defp escape_condition({:or, branches}) do
    {:{}, [], [:or, Enum.map(branches, fn b -> Enum.map(b, &escape_condition/1) end)]}
  end

  defp escape_expr(nil), do: nil

  defp escape_expr(%Expr{code: code, name: name, arity: arity, kind: kind}) do
    struct_ast(Expr,
      code: Macro.escape(code),
      name: Macro.escape(name),
      arity: Macro.escape(arity),
      kind: Macro.escape(kind),
      fun: quote(do: Function.capture(__MODULE__, unquote(name), unquote(arity)))
    )
  end

  defp struct_ast(module, fields) do
    alias_ast =
      {:__aliases__, [alias: false], Module.split(module) |> Enum.map(&String.to_atom/1)}

    {:%, [], [alias_ast, {:%{}, [], fields}]}
  end
end
