defmodule Rete.Token do
  @moduledoc """
  A partial match travelling down the beta network.

  A token is what a rule has established so far: the facts it matched and the
  variables they bound. Every beta node either extends a token with one more
  fact or drops it.

  ## Fields

    * `:matches` — `[{fact, node_id}]`, the facts behind this match and the node
      each was matched at, **in order**. Order is part of the token's identity:
      truth maintenance retracts by value, and two tokens over the same facts in
      a different order are different matches.
    * `:bindings` — `%{name => value}`, the variables bound so far.

  Tokens are compared by value. Two tokens with equal matches and equal bindings
  are the same match, whoever produced them, which is what makes retraction work
  when the fact that caused it is a different term with the same value.
  """

  @type t :: %__MODULE__{matches: [{term(), term()}], bindings: %{atom() => term()}}

  defstruct matches: [], bindings: %{}

  @doc """
  Extends a token with one more matched fact and the bindings it contributed.
  """
  @spec extend(t(), term(), term(), %{atom() => term()}) :: t()
  def extend(%__MODULE__{} = token, fact, node_id, bindings) do
    %__MODULE__{
      matches: token.matches ++ [{fact, node_id}],
      bindings: Map.merge(token.bindings, bindings)
    }
  end

  @doc """
  The subset of a token's bindings used as a join key.

      iex> token = %Rete.Token{bindings: %{cid: 1, amt: 5}}
      iex> Rete.Token.join_key(token, [:cid])
      %{cid: 1}
  """
  @spec join_key(t(), [atom()]) :: %{atom() => term()}
  def join_key(%__MODULE__{bindings: bindings}, keys), do: Map.take(bindings, keys)

  @doc """
  The facts behind a token, in match order.
  """
  @spec facts(t()) :: [term()]
  def facts(%__MODULE__{matches: matches}), do: Enum.map(matches, &elem(&1, 0))
end

defmodule Rete.Element do
  @moduledoc """
  A fact that matched one condition, with the bindings that match produced.

  Elements live on the right side of a beta node: they are what an alpha node
  emits, and what a join pairs with tokens arriving from the left.
  """

  @type t :: %__MODULE__{fact: term(), bindings: %{atom() => term()}}

  defstruct [:fact, bindings: %{}]

  @doc """
  The subset of an element's bindings used as a join key.
  """
  @spec join_key(t(), [atom()]) :: %{atom() => term()}
  def join_key(%__MODULE__{bindings: bindings}, keys), do: Map.take(bindings, keys)
end

defmodule Rete.Activation do
  @moduledoc """
  A rule whose left hand side is satisfied, waiting to fire.

  Activations are ordered by `:salience` descending, then `:internal_salience`
  descending, then `:order` ascending — the order the rules were compiled in, so
  that two rules of equal salience fire predictably rather than by map iteration
  order.

  `:internal_salience` is what makes an extracted negation helper run before the
  rule that negates its marker. See `Rete.Compiler.Negation`.
  """

  alias Rete.Token

  @type t :: %__MODULE__{
          node_id: term(),
          token: Token.t(),
          salience: integer(),
          internal_salience: integer(),
          order: non_neg_integer()
        }

  defstruct [:node_id, :token, salience: 0, internal_salience: 0, order: 0]

  @doc """
  The sort key of an activation: most salient first, then compile order.
  """
  @spec key(t()) :: {integer(), integer(), non_neg_integer()}
  def key(%__MODULE__{} = activation) do
    {-activation.salience, -activation.internal_salience, activation.order}
  end
end
