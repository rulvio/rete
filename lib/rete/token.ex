defmodule Rete.Token do
  @moduledoc """
  A partial match travelling down the beta network: what a rule has established so far.

  **Internal**, but its fields reach you through `Rete.Listener` events. Read them
  freely. Do not depend on its functions.

    * `:matches` — `[{fact, node_id}]`, in match order. Order is part of the token's
      identity. Two tokens over the same facts in a different order are different matches.
    * `:bindings` — `%{name => value}`, the variables bound so far.

  Tokens are compared by value, which is what makes retraction work when the fact that
  caused it is a different term with the same value.
  """

  @type t :: %__MODULE__{matches: [{term(), term()}], bindings: %{atom() => term()}}

  defstruct matches: [], bindings: %{}

  @doc """
  Extends a token with one more matched fact and the bindings it contributed.

      iex> Rete.Token.extend(%Rete.Token{}, {:order, 1}, :n3, %{cid: 1})
      %Rete.Token{matches: [{{:order, 1}, :n3}], bindings: %{cid: 1}}
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

      iex> token = %Rete.Token{matches: [{{:customer, 1}, :n1}, {{:order, 1, 250}, :n3}]}
      iex> Rete.Token.facts(token)
      [{:customer, 1}, {:order, 1, 250}]
  """
  @spec facts(t()) :: [term()]
  def facts(%__MODULE__{matches: matches}), do: Enum.map(matches, &elem(&1, 0))
end

defmodule Rete.Element do
  @moduledoc """
  A fact that matched one condition, with the bindings that match produced.

  **Internal.** Elements live on the right side of a beta node. An alpha node emits them,
  and a join pairs them with tokens arriving from the left.
  """

  @type t :: %__MODULE__{fact: term(), bindings: %{atom() => term()}}

  defstruct [:fact, bindings: %{}]

  @doc """
  The subset of an element's bindings used as a join key.

      iex> element = %Rete.Element{fact: {:order, 1, 250}, bindings: %{cid: 1, amt: 250}}
      iex> Rete.Element.join_key(element, [:cid])
      %{cid: 1}
  """
  @spec join_key(t(), [atom()]) :: %{atom() => term()}
  def join_key(%__MODULE__{bindings: bindings}, keys), do: Map.take(bindings, keys)
end

defmodule Rete.Activation do
  @moduledoc """
  A rule whose left hand side is satisfied, waiting to fire.

  **Internal**, but `Rete.Session.pending/1` returns these. Read their fields freely. Do
  not depend on their functions.

  Ordered by `:salience` descending, then `:internal_salience` descending, then `:order`
  ascending. `:order` is compile order, so two rules of equal salience fire in the order
  they were written. `:internal_salience` makes an extracted negation helper run before
  the rule that negates its marker. See `Rete.Compiler.Negation`.
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

      iex> Rete.Activation.key(%Rete.Activation{salience: 10, order: 3})
      {-10, 0, 3}
  """
  @spec key(t()) :: {integer(), integer(), non_neg_integer()}
  def key(%__MODULE__{} = activation) do
    {-activation.salience, -activation.internal_salience, activation.order}
  end
end
