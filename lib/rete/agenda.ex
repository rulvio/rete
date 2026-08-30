defmodule Rete.Agenda do
  @moduledoc """
  The activations waiting to fire, most salient first.

  **Internal.** Not part of the public API — see the README — but documented
  rather than hidden, because durability, checkpointing and scheduling work will
  need to reach in here. Treat its functions as liable to change.

  Ordering is `{salience, internal_salience}` descending, then compile order
  ascending. Two rules of equal salience fire in the order they were written
  rather than in whatever order a map happened to iterate — a rules engine whose
  output depends on map ordering is impossible to reason about. Two *matches of
  the same rule* fire in the order they arrived.

  ## Why activations are removed as well as added

  An activation is a *pending* match. Before it fires, the facts behind it can be
  retracted, and then it must not fire at all. So `remove/2` has to find an
  activation by value and take it out of the middle of the queue — removal is a
  first-class operation here, not an afterthought, which is what rules out an
  ordinary heap.

  Removal is by value: the same rule and the same token is the same activation,
  whether or not it is the same term.

  ## Buckets, not one sorted list

  Every activation of one production node has the *same* sort key — salience,
  internal salience and compile order all come from the node, none from the
  match. So the agenda is a small number of ordered buckets, one per key, each
  holding its activations in arrival order:

      keys     [key]                        sorted, only the non-empty ones
      buckets  %{key => :queue of activation}

  The number of distinct keys is bounded by the number of production nodes in
  the ruleset, not by how many facts a session holds. That is what makes this
  worth the extra structure: inserting into a single sorted list walked past
  every activation already queued for the same rule, so filling an agenda with n
  matches of one rule cost O(n²). Here `add/2` is O(1) into the bucket plus at
  most one insertion into the short key list, and `pop/1` is O(1).

  `remove/2` is still linear in one bucket — a queue has to be searched — but a
  bucket is one rule's pending matches rather than the whole agenda.
  """

  alias Rete.Activation

  @type key :: {integer(), integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          keys: [key()],
          buckets: %{key() => :queue.queue(Activation.t())},
          size: non_neg_integer()
        }

  defstruct keys: [], buckets: %{}, size: 0

  @doc "An empty agenda."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  How many activations are waiting.

  Counted as they arrive rather than by walking, so that reporting the size of a
  runaway agenda is not itself expensive — which is what it is for.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  Adds an activation, behind the ones already queued for its rule.
  """
  @spec add(t(), Activation.t()) :: t()
  def add(%__MODULE__{} = agenda, %Activation{} = activation) do
    key = Activation.key(activation)

    case Map.fetch(agenda.buckets, key) do
      {:ok, bucket} ->
        %__MODULE__{
          agenda
          | buckets: Map.put(agenda.buckets, key, :queue.in(activation, bucket)),
            size: agenda.size + 1
        }

      :error ->
        %__MODULE__{
          keys: insert_key(agenda.keys, key),
          buckets: Map.put(agenda.buckets, key, :queue.from_list([activation])),
          size: agenda.size + 1
        }
    end
  end

  @doc """
  Removes an activation by value.

  Returns `{agenda, :removed}` when it was still pending, `{agenda, :missing}`
  when it had already fired. The caller needs to tell the two apart: an
  activation that never fired inserted nothing, so there is nothing to retract,
  whereas one that did fire has facts that truth maintenance must now take back.
  """
  @spec remove(t(), Activation.t()) :: {t(), :removed | :missing}
  def remove(%__MODULE__{} = agenda, %Activation{} = activation) do
    key = Activation.key(activation)

    with {:ok, bucket} <- Map.fetch(agenda.buckets, key),
         {:ok, rest} <- drop_first(:queue.to_list(bucket), activation) do
      {store(agenda, key, :queue.from_list(rest)), :removed}
    else
      _ -> {agenda, :missing}
    end
  end

  @doc """
  Takes the most salient activation, or `:empty`.
  """
  @spec pop(t()) :: {:ok, Activation.t(), t()} | :empty
  def pop(%__MODULE__{keys: []}), do: :empty

  def pop(%__MODULE__{keys: [key | _]} = agenda) do
    {{:value, activation}, rest} = agenda.buckets |> Map.fetch!(key) |> :queue.out()

    {:ok, activation, store(agenda, key, rest)}
  end

  @doc "Every pending activation, in firing order."
  @spec to_list(t()) :: [Activation.t()]
  def to_list(%__MODULE__{keys: keys, buckets: buckets}) do
    Enum.flat_map(keys, fn key -> buckets |> Map.fetch!(key) |> :queue.to_list() end)
  end

  # Puts a bucket back after one activation left it, dropping the key entirely
  # when nothing is left — `keys` is the record of which buckets exist, so an
  # empty one left behind would make `pop/1` reach for a value that is not there.
  #
  # Takes a queue rather than a list on purpose. Round-tripping through
  # `:queue.to_list/1` here would put an O(bucket) cost on `pop/1`, which is the
  # one operation on the firing path that has to stay O(1).
  defp store(%__MODULE__{} = agenda, key, remaining) do
    if :queue.is_empty(remaining) do
      %__MODULE__{
        keys: List.delete(agenda.keys, key),
        buckets: Map.delete(agenda.buckets, key),
        size: agenda.size - 1
      }
    else
      %__MODULE__{
        agenda
        | buckets: Map.put(agenda.buckets, key, remaining),
          size: agenda.size - 1
      }
    end
  end

  # The key list is as long as the ruleset has production nodes, so a linear
  # insertion into it costs nothing that grows with the session.
  defp insert_key([], key), do: [key]

  defp insert_key([head | tail] = keys, key) do
    if key < head, do: [key | keys], else: [head | insert_key(tail, key)]
  end

  # Two activations are the same when they are the same rule reached by the same
  # match. `:order` and the salience fields are derived from the node, so they
  # cannot differ when the node does not — which is also why the activation
  # being looked for lands in the same bucket as the one stored.
  defp drop_first([], _activation), do: :error

  defp drop_first([head | tail], activation) do
    if same?(head, activation) do
      {:ok, tail}
    else
      case drop_first(tail, activation) do
        {:ok, rest} -> {:ok, [head | rest]}
        :error -> :error
      end
    end
  end

  defp same?(a, b), do: a.node_id == b.node_id and a.token == b.token
end
