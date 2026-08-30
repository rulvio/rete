defmodule Rete.Agenda do
  @moduledoc """
  The activations waiting to fire, most salient first.

  Ordering is `{salience, internal_salience}` descending, then compile order
  ascending. Two rules of equal salience fire in the order they were written
  rather than in whatever order a map happened to iterate — a rules engine whose
  output depends on map ordering is impossible to reason about.

  ## Why activations are removed as well as added

  An activation is a *pending* match. Before it fires, the facts behind it can be
  retracted, and then it must not fire at all. So `remove/2` has to find an
  activation by value and take it out of the middle of the queue, which is why
  this is a sorted structure rather than a heap: removal by value is the common
  operation, not an afterthought.

  Removal is by value: the same rule and the same token is the same activation,
  whether or not it is the same term.
  """

  alias Rete.Activation

  @type t :: %__MODULE__{pending: [Activation.t()]}

  defstruct pending: []

  @doc "An empty agenda."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether anything is waiting."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{pending: pending}), do: pending == []

  @doc "How many activations are waiting."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{pending: pending}), do: length(pending)

  @doc """
  Adds an activation in priority order.

  Insertion keeps the list sorted, so `pop/1` is O(1) and the cost lands on the
  operation that can absorb it.
  """
  @spec add(t(), Activation.t()) :: t()
  def add(%__MODULE__{pending: pending}, %Activation{} = activation) do
    %__MODULE__{pending: insert_sorted(pending, activation, Activation.key(activation))}
  end

  @doc """
  Removes an activation by value.

  Returns `{agenda, :removed}` when it was still pending, `{agenda, :missing}`
  when it had already fired. The caller needs to tell the two apart: an
  activation that never fired inserted nothing, so there is nothing to retract,
  whereas one that did fire has facts that truth maintenance must now take back.
  """
  @spec remove(t(), Activation.t()) :: {t(), :removed | :missing}
  def remove(%__MODULE__{pending: pending} = agenda, %Activation{} = activation) do
    case Enum.split_while(pending, &(not same?(&1, activation))) do
      {_before, []} -> {agenda, :missing}
      {before, [_hit | rest]} -> {%__MODULE__{pending: before ++ rest}, :removed}
    end
  end

  @doc """
  Takes the most salient activation, or `:empty`.
  """
  @spec pop(t()) :: {:ok, Activation.t(), t()} | :empty
  def pop(%__MODULE__{pending: []}), do: :empty
  def pop(%__MODULE__{pending: [head | rest]}), do: {:ok, head, %__MODULE__{pending: rest}}

  @doc "Every pending activation, in firing order."
  @spec to_list(t()) :: [Activation.t()]
  def to_list(%__MODULE__{pending: pending}), do: pending

  # Two activations are the same when they are the same rule reached by the same
  # match. `:order` and the salience fields are derived from the node, so they
  # cannot differ when the node does not.
  defp same?(a, b), do: a.node_id == b.node_id and a.token == b.token

  defp insert_sorted([], activation, _key), do: [activation]

  defp insert_sorted([head | tail] = pending, activation, key) do
    if key < Activation.key(head) do
      [activation | pending]
    else
      [head | insert_sorted(tail, activation, key)]
    end
  end
end
