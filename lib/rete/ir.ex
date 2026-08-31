defmodule Rete.IR do
  @moduledoc """
  The intermediate representation (IR) shared by every compile phase of `Rete`.

  **Internal.** Produced by `Rete.DSL.Parser`, refined in place by the later phases, and
  escaped into the defining module for the network builder to read at runtime.

      quoted DSL
        |> Rete.DSL.Parser.parse_production/4      # AST -> IR
        |> Rete.DSL.Normalize.normalize_lhs/1      # gates -> conditions
        |> Rete.Compiler.Sort.sort/1               # topological condition order
        |> Rete.DSL.Bindings.classify/2            # join keys, guard splitting
        |> Rete.IR.escape/1                        # emitted into the ruleset module
        |> Rete.Compiler.build/2                   # the network, at build time

  Every phase consumes and produces `%Rete.IR.Production{}`, so a struct carries fields a
  later phase fills in. Each struct records which are `nil` after parsing.

  `:__ast__` holds the raw quoted fragments the later phases need. It is **compile-time
  only**, and `escape/1` drops it so quoted AST never reaches the compiled module.

  A condition's `:type` is the *declared* fact type. It is never a runtime check baked
  into the alpha expression, which matches a fact of any type on purpose. The alpha index
  applies the taxonomy. See `docs/design/w1-ir.md` §2.
  """

  defmodule Expr do
    @moduledoc """
    A compile-time generated named function that lives in the ruleset module.

    Expressions are the only executable part of the IR. They are emitted as public
    side-effect-free functions in the module that used `Rete.Ruleset`, so they can be
    captured, compared and shared between rules.

    `:code` is a stable, readable unique id. Two structurally identical conditions in one
    module context produce the same code, which is what lets the network share nodes.
    `:kind` fixes the calling convention: `:alpha` is `(fact) -> bindings_map | nil`,
    `:test` is `(bindings_map) -> boolean`, and `:join_filter` is
    `(token_bindings, fact_bindings) -> boolean`. `:fun` is `nil` until the expression is
    escaped, and `:__ast__` is compile-time only.
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

    Fields are typed by `t:t/0`. Three are not obvious:

      * `:fact_binding` is **not** part of `:bind`, because the alpha does not return it.
        The engine adds it when it builds a token.
      * `:bind` excludes `_`-prefixed names, pinned values and module attributes.
      * `:join_filter`, `:join_bind` and `:new_bind` are `nil` after parsing.
        `Rete.DSL.Bindings` fills them in. See `docs/design/w1-ir.md` §2.
    """

    @typedoc """
    Raw quoted fragments kept for the later phases: the pattern as written without the
    fact binding or the `when` guard, the guard AST or `nil`, the variable AST of every
    entry of `:bind`, and the whole element as written for error messages.
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

    A collection binding is the engine's only accumulator, and it is always *collect
    all*. Aggregation is the right hand side's job.

    A condition that introduces no new variable propagates `[]`, and the rule fires with
    zero matches. One that introduces a new variable groups by it, so only non-empty
    groups exist. `:new_bind` decides between the two.

    Fields are those of `Rete.IR.Fact`, plus `:coll_binding`, the variable the collected
    *list* binds to. `:alpha` is applied per element, not to the list.
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

    Produced by the rule level guard, `defrule r(...) when <guard> do`, and by guards
    lifted out of a condition because they only reference variables bound upstream.
    `:bind` is what the guard **reads**, not what it introduces.
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

    A **parser placeholder**. `Rete.DSL.Normalize` rewrites gates into plain conditions,
    `Rete.IR.Negation` nodes and `{:or, [[condition, ...], ...]}` disjunctions.

    `:gate` is one of `:and`, `:or`, `:not`, `:nand`, `:nor`, `:xor`, `:xnor`. n-ary
    `:xor` means *exactly one* argument holds, `:xnor` is its negation, and `:not` with
    several arguments negates their conjunction. `:code` identifies the gate by structure.
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

    Not produced by the parser. `Rete.DSL.Normalize` creates negations while normalizing
    `Rete.IR.Gate` nodes. `:condition` is always a single `Rete.IR.Fact` or
    `Rete.IR.Coll`. The negation of a *conjunction* is a `Rete.IR.CompoundNegation`.
    """

    @type t :: %__MODULE__{condition: Rete.IR.Fact.t() | Rete.IR.Coll.t()}

    defstruct [:condition]
  end

  defmodule CompoundNegation do
    @moduledoc """
    The negation of a *conjunction*: "no match satisfies all of these at once".

    Never de Morganed, because the conjuncts share existentially quantified variables.
    `{:nand, [{:order, x}, {:refund, x}]}` means "there is no `x` with both", while the de
    Morganed form means "there are no orders at all, or no refunds at all", which is false
    whenever one `x` has an order and a different `x` has a refund.

    `Rete.Compiler.Negation` extracts it into a helper production whose RHS inserts a
    marker fact. Nothing else in the pipeline can evaluate one. It binds nothing
    downstream, but its inner conditions are still classified, because the helper needs
    their join keys.
    """

    @type t :: %__MODULE__{conditions: [Rete.IR.condition()]}

    defstruct conditions: []
  end

  defmodule Production do
    @moduledoc """
    A rule or a query.

    Fields are typed by `t:t/0`. Three are not obvious:

      * `:name` names the production, but the generated RHS function is `rhs_name/1` of
        it, because a query owns its own name in its module.
      * `:bind` is computed from the **classified** LHS by `lhs_bindings/1`, so it excludes
        a negation's variables and is the *union* over a disjunction's branches. A variable
        only some branches bind is not in every token, so the RHS reads it defensively.
      * `:rhs` is `nil` until the production is escaped. Its return value is logically
        inserted and truth maintained, and `nil` or `[]` inserts nothing.
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

  @doc """
  The name of the function a production's right hand side compiles to.

      iex> Rete.IR.rhs_name(:loyalty)
      :__rhs_loyalty__

  Deliberately not the production's own name. A query is *called* by name, so the name
  has to stay free for the arity 2 function that runs it.
  """
  @spec rhs_name(atom()) :: atom()
  def rhs_name(name), do: :"__rhs_#{name}__"

  @typedoc """
  A single LHS condition.
  """
  @type condition ::
          Fact.t() | Coll.t() | Test.t() | Gate.t() | Negation.t() | CompoundNegation.t()

  @typedoc """
  One element of a left hand side.

  Either a single condition or a disjunction of conjunctions. A branch is itself a list
  of elements, so branches may nest.
  """
  @type element :: condition() | {:or, [[element()]]}

  @typedoc """
  The left hand side of a production.

  An **ordered** list, never flattened to DNF, which explodes combinatorially. A
  disjunction fans out from the current parents and re-converges before the next element.
  The parser emits only plain conditions and `Rete.IR.Gate` placeholders.
  """
  @type lhs :: [element()]

  @doc """
  All variables a condition makes visible downstream.

  `:bind` plus the fact or collection binding. A `Rete.IR.Test` and a negation bind
  nothing.

      iex> Rete.IR.bound_vars(%Rete.IR.Fact{bind: [:id], fact_binding: :f})
      [:id, :f]
      iex> Rete.IR.bound_vars(%Rete.IR.Negation{condition: %Rete.IR.Fact{bind: [:id]}})
      []
  """
  @spec bound_vars(condition()) :: [atom()]
  def bound_vars(%Fact{bind: bind, fact_binding: nil}), do: bind
  def bound_vars(%Fact{bind: bind, fact_binding: f}), do: bind ++ [f]
  def bound_vars(%Coll{} = coll), do: coll_bound_vars(coll)
  def bound_vars(%Test{}), do: []
  def bound_vars(%Negation{}), do: []
  def bound_vars(%CompoundNegation{}), do: []
  def bound_vars(%Gate{args: args}), do: args |> Enum.flat_map(&bound_vars/1) |> Enum.uniq()

  # A collection's pattern variables are local to it unless something outside reads them.
  # See `Rete.DSL.Bindings.mark_inert/1`. An inert one stays in `:bind`, because the alpha
  # has to return it for the join filter, but it binds nothing downstream.
  defp coll_bound_vars(%Coll{bind: bind, inert: inert, coll_binding: c}) do
    visible = bind -- (inert || [])
    if c, do: visible ++ [c], else: visible
  end

  @doc """
  The variables a classified LHS makes visible to the right hand side, split
  into `{guaranteed, optional}`.

  Both lists are sorted and disjoint, and together they are the production's `:bind`. A
  **guaranteed** binding is in every token that reaches the RHS. An **optional** one is
  bound on some branch of a disjunction but not all, so the RHS reads it with `Map.get/2`.

  Run this on the **classified** LHS. On a raw parsed one it answers with the union of a
  `Rete.IR.Gate`'s arguments, the over-approximation it exists to avoid.

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

  # `{:or, []}` is *false*. Nothing past it is reachable, so nothing is bound.
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

  An alpha comes before the join filter of the same condition. Not deduplicated: use
  `Enum.uniq_by(& &1.name)` when emitting functions.
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
  """
  @spec expr_data(Production.t()) :: [{atom(), (... -> any())}]
  def expr_data(production) do
    production |> exprs() |> Enum.map(&{&1.code, &1.fun})
  end

  @doc """
  Turns a parsed production into quoted code that rebuilds it inside the defining module.

  Splice the result into the module body **after** the expression functions are defined,
  because it captures them by name. `:__ast__` is dropped, `:fun` and `:rhs` become
  `Function.capture/3` calls, and `:opts` is kept unescaped so option values are
  evaluated in the module scope.
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
      rhs: quote(do: Function.capture(__MODULE__, unquote(rhs_name(name)), 2)),
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
