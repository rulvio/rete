defmodule Rete.Network.Node do
  @moduledoc """
  The node descriptions the engine runs.

  A node is **data**, not behaviour: it holds the join keys and captured
  expression functions the engine needs and nothing else. Activation is
  implemented in `Rete.Engine.Nodes`, against these structs.

  ## Children are edges, not fields

  No node carries its children. They live in `Rete.Compiler.BetaGraph`'s forward
  edges, for two reasons: a node is shared between rules precisely when it is
  *equal*, and equality must not depend on how many rules happen to have hung
  children off it yet; and the graph is built parent-first, so a node would have
  to be rewritten every time a child appeared.

  ## Sharing

  `sharing_key/1` is what decides whether two conditions collapse onto one node.
  It is built from expression **codes**, never from the captured functions —
  The front end guarantees a code is deterministic across compilations and equal exactly
  when behaviour is equal, whereas two closures are never equal and a struct
  holding `:__ast__` would compare quoted AST that is not part of identity.

  Note that an equal key is necessary but *not sufficient*: the graph also
  requires an identical parent set. See `Rete.Compiler.BetaGraph`.

  ## `:id` is `nil` until the node is in a graph

  A node is described first and inserted second: `Rete.Compiler.BetaGraph`
  builds the struct, asks `sharing_key/1` whether an equal node already sits
  under the same parents, and assigns an id only when it has to create one. So
  `:id` is `non_neg_integer() | nil`, where `nil` means "a description, not yet
  a node". Every node reachable from a built `Rete.Network` has an id.
  """

  defmodule Alpha do
    @moduledoc """
    Matches one condition against a single fact, independently of any token.

    `:fun` is arity 1, `(fact) -> bindings_map | nil`. It matches a fact of
    **any** type on purpose: which alpha nodes a fact reaches is decided by
    `Rete.Taxonomy`'s type index, so that `derive(:premium, :customer)` lets a
    `:premium` fact reach a condition written against `:customer`.
    """
    @type t :: %__MODULE__{id: non_neg_integer() | nil, type: atom(), code: atom(), fun: fun()}
    defstruct [:id, :type, :code, :fun]
  end

  defmodule RootJoin do
    @moduledoc """
    The first condition of a rule. Has no token to join against, so it turns
    each matching element straight into a token.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            type: atom(),
            alpha_code: atom(),
            fact_binding: atom() | nil,
            new_bind: [atom()]
          }
    defstruct [:id, :type, :alpha_code, :fact_binding, new_bind: []]
  end

  defmodule HashJoin do
    @moduledoc """
    Joins tokens to elements on equality of `:join_bind`. The common case: no
    guard reaches across conditions, so the join is a hash lookup.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            type: atom(),
            alpha_code: atom(),
            fact_binding: atom() | nil,
            join_bind: [atom()],
            new_bind: [atom()]
          }
    defstruct [:id, :type, :alpha_code, :fact_binding, join_bind: [], new_bind: []]
  end

  defmodule ExprJoin do
    @moduledoc """
    A hash join plus a filter that needs the token and the fact together.

    Produced when a per-condition guard reads a variable bound upstream, e.g.
    `{:order, amt} when amt > t`. `:filter` is arity 2,
    `(token_bindings, fact_bindings) -> boolean`, and runs only on candidates
    that already agree on `:join_bind`.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            type: atom(),
            alpha_code: atom(),
            fact_binding: atom() | nil,
            join_bind: [atom()],
            new_bind: [atom()],
            filter_code: atom(),
            filter: fun()
          }
    defstruct [
      :id,
      :type,
      :alpha_code,
      :fact_binding,
      :filter_code,
      :filter,
      join_bind: [],
      new_bind: []
    ]
  end

  defmodule Negation do
    @moduledoc """
    Propagates a token only while **no** element matches it on `:join_bind`.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            type: atom(),
            alpha_code: atom(),
            join_bind: [atom()]
          }
    defstruct [:id, :type, :alpha_code, join_bind: []]
  end

  defmodule NegationJoin do
    @moduledoc """
    A negation whose match also depends on a cross-condition guard.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            type: atom(),
            alpha_code: atom(),
            join_bind: [atom()],
            filter_code: atom(),
            filter: fun()
          }
    defstruct [:id, :type, :alpha_code, :filter_code, :filter, join_bind: []]
  end

  defmodule Accumulate do
    @moduledoc """
    A collection binding: gathers every element matching the token into a list.

    `:propagates_empty?` records the locked empty-collection rule. When the
    pattern introduces no new variables, every variable it uses is already fixed
    by the token, so there is exactly one group and the node propagates `[]`
    when nothing matches — the rule fires with an empty list. When it *does*
    introduce a new variable it groups by that variable, and a group only exists
    where a fact created it, so there is no empty group to propagate.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            type: atom(),
            alpha_code: atom(),
            coll_binding: atom() | nil,
            join_bind: [atom()],
            new_bind: [atom()],
            propagates_empty?: boolean()
          }
    defstruct [
      :id,
      :type,
      :alpha_code,
      :coll_binding,
      join_bind: [],
      new_bind: [],
      propagates_empty?: false
    ]
  end

  defmodule AccumulateJoin do
    @moduledoc """
    A collection binding whose membership also depends on a cross-condition
    guard, so the candidates cannot be reduced until a token is known.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            type: atom(),
            alpha_code: atom(),
            coll_binding: atom() | nil,
            join_bind: [atom()],
            new_bind: [atom()],
            propagates_empty?: boolean(),
            filter_code: atom(),
            filter: fun()
          }
    defstruct [
      :id,
      :type,
      :alpha_code,
      :coll_binding,
      :filter_code,
      :filter,
      join_bind: [],
      new_bind: [],
      propagates_empty?: false
    ]
  end

  defmodule Test do
    @moduledoc """
    A predicate over the token's bindings, with no fact input. Produced by a
    rule level `when` guard.
    """
    @type t :: %__MODULE__{id: non_neg_integer() | nil, code: atom(), fun: fun()}
    defstruct [:id, :code, :fun]
  end

  defmodule Production do
    @moduledoc """
    A terminal node for a rule. Firing it calls `:rhs` with the token's bindings
    and logically inserts whatever comes back.

    `:salience` is the user's ordering. `:internal_salience` breaks ties in
    favour of machinery the user did not write: an extracted negation helper has
    to run before the rule that negates its marker, or that rule fires once
    against an absence that was merely not computed yet.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            name: atom(),
            module: module(),
            hash: integer(),
            rhs: fun(),
            bind: [atom()],
            salience: integer(),
            internal_salience: integer(),
            generated?: boolean()
          }
    defstruct [
      :id,
      :name,
      :module,
      :hash,
      :rhs,
      :bind,
      salience: 0,
      internal_salience: 0,
      generated?: false
    ]
  end

  defmodule Query do
    @moduledoc """
    A terminal node for a query. Holds the tokens that reached it, to be read
    back by name.

    There is no parameter list: a query is its conditions and its body, and
    `Rete.Engine.query/3` lets the caller constrain any variable in `:bind`.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            name: atom(),
            module: module(),
            hash: integer(),
            rhs: fun(),
            bind: [atom()]
          }
    defstruct [:id, :name, :module, :hash, :rhs, bind: []]
  end

  @type t ::
          Alpha.t()
          | RootJoin.t()
          | HashJoin.t()
          | ExprJoin.t()
          | Negation.t()
          | NegationJoin.t()
          | Accumulate.t()
          | AccumulateJoin.t()
          | Test.t()
          | Production.t()
          | Query.t()

  @doc """
  The value that decides whether two conditions collapse onto one node.

  Built from expression codes and join keys — never from captured functions,
  which are never equal, and never from `:id`, which is assigned after the
  sharing decision.

  A terminal node keys on its production's identity, so two rules that happen to
  have an identical left hand side still get their own terminal and fire
  independently.
  """
  @spec sharing_key(t()) :: term()
  def sharing_key(%RootJoin{} = n), do: {:root_join, n.type, n.alpha_code, n.fact_binding}

  def sharing_key(%HashJoin{} = n),
    do: {:hash_join, n.type, n.alpha_code, n.fact_binding, n.join_bind, n.new_bind}

  def sharing_key(%ExprJoin{} = n),
    do: {:expr_join, n.type, n.alpha_code, n.fact_binding, n.join_bind, n.new_bind, n.filter_code}

  def sharing_key(%Negation{} = n), do: {:negation, n.type, n.alpha_code, n.join_bind}

  def sharing_key(%NegationJoin{} = n),
    do: {:negation_join, n.type, n.alpha_code, n.join_bind, n.filter_code}

  def sharing_key(%Accumulate{} = n),
    do:
      {:accumulate, n.type, n.alpha_code, n.coll_binding, n.join_bind, n.new_bind,
       n.propagates_empty?}

  def sharing_key(%AccumulateJoin{} = n),
    do:
      {:accumulate_join, n.type, n.alpha_code, n.coll_binding, n.join_bind, n.new_bind,
       n.propagates_empty?, n.filter_code}

  def sharing_key(%Test{} = n), do: {:test, n.code}
  def sharing_key(%Production{} = n), do: {:production, n.module, n.name, n.hash}
  def sharing_key(%Query{} = n), do: {:query, n.module, n.name, n.hash}
  def sharing_key(%Alpha{} = n), do: {:alpha, n.code}

  @doc """
  Whether a node is a terminal, i.e. a production or a query.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%Production{}), do: true
  def terminal?(%Query{}), do: true
  def terminal?(_), do: false

  @doc """
  How a terminal names itself in a listener event.

      %{node: 12, rule: {MyRuleset, :flag}}

  The node id alone is unresolvable from inside `c:Rete.Listener.handle_event/2`,
  which is handed an event and its own state and has no way to reach the
  network. `{module, name}` is the identity everything else uses — a query is
  run by it, `Rete.Inspect.why_not/2` takes it — and the id is kept alongside
  because it is what `Rete.Inspect` reports and what a propagation event
  carries.

  A map rather than a wider tuple, so that a field can be added later without
  changing the shape of every event a listener matches on.
  """
  @spec source(Production.t() | Query.t()) :: %{node: term(), rule: {module(), atom()}}
  def source(%{id: id, module: module, name: name}), do: %{node: id, rule: {module, name}}

  @doc """
  Puts an id on a node.
  """
  @spec put_id(t(), non_neg_integer()) :: t()
  def put_id(node, id), do: Map.put(node, :id, id)
end
