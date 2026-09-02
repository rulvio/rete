defmodule Rete.Network.Node do
  @moduledoc """
  The node descriptions the engine runs.

  **Internal.** A node is **data**, not behaviour. It holds the join keys and captured
  expression functions the engine needs, and nothing else. `Rete.Engine.Nodes` implements
  activation against these structs.

  **No node carries its children.** They are forward edges in `Rete.Compiler.BetaGraph`
  instead. A node is shared between rules exactly when it is equal. Equality must not
  depend on how many rules have hung children off it yet.

  **`:id` is `nil` until the node is in a graph.** A node is described first and inserted
  second, so `nil` means "a description, not yet a node". Every node reachable from a
  built `Rete.Network` has an id. See `docs/design/network.md` §3.
  """

  defmodule Alpha do
    @moduledoc """
    Matches one condition against a single fact, independently of any token.

    `:fun` is arity 1: `(fact) -> bindings_map | nil`. It matches a fact of
    **any** type, on purpose. `Rete.Taxonomy`'s type index decides which alpha
    nodes a fact reaches. This is what lets `derive(:premium, :customer)` make a
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

    Produced when a per-condition guard reads a variable bound upstream — for
    example, `{:order, amt} when amt > t`. `:filter` is arity 2:
    `(token_bindings, fact_bindings) -> boolean`. It runs only on candidates
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

    `:propagates_empty?` records the empty-collection rule. A pattern that introduces no
    new variables has every variable fixed by the token. So it has exactly one group, and
    it propagates `[]` when nothing matches. A pattern that introduces one groups by it
    instead, and a group exists only where a fact created it — so there is no empty group
    to propagate.
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
    A terminal node for a rule. Firing it calls `:rhs` with the token's bindings, and
    logically inserts whatever comes back.

    `:salience` is the user's ordering. `:internal_salience` breaks ties in favour of
    machinery the user did not write. An extracted negation helper has to run before the
    rule that negates its marker. Otherwise, that rule fires once against an absence that
    had merely not been computed yet.
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
    A terminal node for a query. Holds the tokens that reached it, to be read back by
    name.

    There is no parameter list. A query is its conditions and its body.
    `Rete.Engine.query/3` lets the caller constrain any variable in `:bind`.

    `:index` is the key sets `Rete.Ruleset.index/2` declared, each sorted. A filter whose
    keys are a superset of one of them reads a bucket instead of every match. It changes
    speed and nothing else, so an empty list only means every filter scans.
    """
    @type t :: %__MODULE__{
            id: non_neg_integer() | nil,
            name: atom(),
            module: module(),
            hash: integer(),
            rhs: fun(),
            bind: [atom()],
            index: [[atom()]]
          }
    defstruct [:id, :name, :module, :hash, :rhs, bind: [], index: []]
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

  Built from expression codes and join keys. Never built from captured functions, since
  two functions are never equal to each other. Never built from `:id` either, since that
  is assigned after the sharing decision. An equal key is necessary, but not sufficient:
  `Rete.Compiler.BetaGraph` also requires an identical parent set.

  A terminal keys on its production's identity. So two rules with an identical left hand
  side still get their own terminal, and each fires independently.

      iex> alias Rete.Network.Node
      iex> Node.sharing_key(%Node.Negation{type: :order, alpha_code: :a1, join_bind: [:cid]})
      {:negation, :order, :a1, [:cid]}
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
  Whether a node is a terminal: a production or a query.

      iex> Rete.Network.Node.terminal?(%Rete.Network.Node.Query{})
      true
      iex> Rete.Network.Node.terminal?(%Rete.Network.Node.HashJoin{})
      false
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%Production{}), do: true
  def terminal?(%Query{}), do: true
  def terminal?(_), do: false

  @doc """
  How a terminal names itself in a listener event.

  `c:Rete.Listener.handle_event/2` cannot reach the network, so a node id alone would be
  unresolvable. `{module, name}` is the identity everything else uses. This is a map, not
  a wider tuple, so a field can be added later without changing the shape every listener
  matches on.

      iex> node = %Rete.Network.Node.Production{id: 12, module: MyRules, name: :flag}
      iex> Rete.Network.Node.source(node)
      %{node: 12, rule: {MyRules, :flag}}
  """
  @spec source(Production.t() | Query.t()) :: %{node: term(), rule: {module(), atom()}}
  def source(%{id: id, module: module, name: name}), do: %{node: id, rule: {module, name}}

  @doc """
  Puts an id on a node.
  """
  @spec put_id(t(), non_neg_integer()) :: t()
  def put_id(node, id), do: Map.put(node, :id, id)
end
