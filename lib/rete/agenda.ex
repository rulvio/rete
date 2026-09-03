defmodule Rete.Agenda do
  @moduledoc """
  The activations waiting to fire, most salient first.

  **Internal.** Not part of the public API. It is documented rather than hidden, because
  durability, checkpointing, and scheduling work will need to reach in here. Treat its
  functions as liable to change.

  Ordering is `{salience, internal_salience}` descending, then compile order ascending.
  Two matches of the same rule fire in the order they arrived.

  Every activation of one production node shares a sort key. So the agenda is a small
  number of ordered buckets, not one sorted list, and each bucket is a `Rete.Bucket` — the
  same tombstoned ordered multiset working memory keys per join key. `add/2`, `pop/1` and
  `remove/2` are all O(1) amortized. `remove/2` used to be linear in one bucket, which is
  one rule's pending matches, so retracting the support of a rule with many of them was
  quadratic. See `docs/design/engine.md` §7.

  What makes `remove/2` O(1) is the bucket's index, and a bucket builds that only when
  something is first taken from it. An agenda that is only ever added to and drained —
  a session that never retracts — never builds one.

      iex> alias Rete.{Activation, Agenda}
      iex> urgent = %Activation{node_id: :n1, salience: 10}
      iex> normal = %Activation{node_id: :n2, salience: 0}
      iex> agenda = Agenda.new() |> Agenda.add(normal) |> Agenda.add(urgent)
      iex> Agenda.to_list(agenda) |> Enum.map(& &1.node_id)
      [:n1, :n2]
  """

  alias Rete.Activation
  alias Rete.Bucket

  @type key :: {integer(), integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          keys: [key()],
          buckets: %{key() => Bucket.t()},
          size: non_neg_integer()
        }

  defstruct keys: [], buckets: %{}, size: 0

  @doc "An empty agenda."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  How many activations are waiting.

  The agenda counts activations as they arrive, so reporting the size of a runaway agenda
  is cheap.

      iex> alias Rete.{Activation, Agenda}
      iex> Agenda.new() |> Agenda.add(%Activation{node_id: :n1}) |> Agenda.size()
      1
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "Adds an activation, behind the ones already queued for its rule."
  @spec add(t(), Activation.t()) :: t()
  def add(%__MODULE__{} = agenda, %Activation{} = activation) do
    key = Activation.key(activation)

    case Map.fetch(agenda.buckets, key) do
      {:ok, bucket} ->
        %__MODULE__{
          agenda
          | buckets: Map.put(agenda.buckets, key, Bucket.push_one(bucket, activation)),
            size: agenda.size + 1
        }

      :error ->
        %__MODULE__{
          keys: insert_key(agenda.keys, key),
          buckets: Map.put(agenda.buckets, key, Bucket.new([activation])),
          size: agenda.size + 1
        }
    end
  end

  @doc """
  Removes an activation by value.

  Returns `{agenda, :removed}` when the activation was still pending. Returns `{agenda,
  :missing}` when it had already fired. The caller must tell the two apart. An activation
  that never fired inserted nothing, so there is nothing to retract. One that fired has
  facts that truth maintenance must take back.

      iex> alias Rete.{Activation, Agenda}
      iex> pending = %Activation{node_id: :n1}
      iex> {_agenda, verdict} = Agenda.new() |> Agenda.add(pending) |> Agenda.remove(pending)
      iex> verdict
      :removed
      iex> {_agenda, verdict} = Agenda.remove(Agenda.new(), pending)
      iex> verdict
      :missing
  """
  @spec remove(t(), Activation.t()) :: {t(), :removed | :missing}
  def remove(%__MODULE__{} = agenda, %Activation{} = activation) do
    key = Activation.key(activation)

    case Map.fetch(agenda.buckets, key) do
      :error ->
        {agenda, :missing}

      {:ok, bucket} ->
        case Bucket.take(bucket, activation) do
          {:ok, bucket} ->
            {store(agenda, key, bucket), :removed}

          # The bucket comes back too, because the miss is what built its index. Kept
          # without going through `store/3`, which would also decrement the size.
          {:error, bucket} ->
            {%__MODULE__{agenda | buckets: Map.put(agenda.buckets, key, bucket)}, :missing}
        end
    end
  end

  @doc """
  Takes the most salient activation, or `:empty`.

      iex> Rete.Agenda.pop(Rete.Agenda.new())
      :empty
  """
  @spec pop(t()) :: {:ok, Activation.t(), t()} | :empty
  def pop(%__MODULE__{keys: []}), do: :empty

  def pop(%__MODULE__{keys: [key | _]} = agenda) do
    {:ok, activation, rest} = agenda.buckets |> Map.fetch!(key) |> Bucket.pop()

    {:ok, activation, store(agenda, key, rest)}
  end

  @doc """
  Every activation of the most salient **group**, in firing order, without removing them.

  A group is every bucket sharing the leading `{salience, internal_salience}` of the sort
  key. So it spans the rules that would fire before any less salient one. One group is one
  cycle of the fire loop, however many activations it holds.

  **Peeked rather than popped.** A caller firing the group removes each activation with
  `remove/2`, as it applies it. So an activation that an earlier conclusion in the same
  group invalidates is still found and cancelled. Taking them all out up front would leave
  a later retraction nothing to cancel. The conclusion would then be inserted against a
  token that no longer exists — a fact no retraction could ever take back.

      iex> alias Rete.{Activation, Agenda}
      iex> agenda =
      ...>   Agenda.new()
      ...>   |> Agenda.add(%Activation{node_id: :a, salience: 10, order: 0})
      ...>   |> Agenda.add(%Activation{node_id: :b, salience: 10, order: 1})
      ...>   |> Agenda.add(%Activation{node_id: :c, salience: 0, order: 2})
      iex> Agenda.peek_group(agenda) |> Enum.map(& &1.node_id)
      [:a, :b]
      iex> Agenda.size(agenda)
      3
  """
  @spec peek_group(t()) :: [Activation.t()]
  def peek_group(%__MODULE__{keys: []}), do: []

  def peek_group(%__MODULE__{keys: [{salience, internal, _order} | _]} = agenda) do
    agenda.keys
    |> Enum.take_while(fn {s, i, _order} -> s == salience and i == internal end)
    |> Enum.flat_map(&(agenda.buckets |> Map.fetch!(&1) |> Bucket.to_list()))
  end

  @doc "Every pending activation, in firing order."
  @spec to_list(t()) :: [Activation.t()]
  def to_list(%__MODULE__{keys: keys, buckets: buckets}) do
    Enum.flat_map(keys, fn key -> buckets |> Map.fetch!(key) |> Bucket.to_list() end)
  end

  # Drops the key when the bucket empties. `keys` records which buckets exist, so an
  # empty one left behind would make `pop/1` reach for a value that is not there.
  #
  # Takes a bucket, not a list. Round-tripping through a list here would put an O(bucket)
  # cost on `pop/1`, which has to stay O(1).
  defp store(%__MODULE__{} = agenda, key, remaining) do
    if Bucket.empty?(remaining) do
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

  # The key list is as long as the ruleset has production nodes. So a linear insertion
  # costs nothing that grows with the session.
  defp insert_key([], key), do: [key]

  defp insert_key([head | tail] = keys, key) do
    if key < head, do: [key | keys], else: [head | insert_key(tail, key)]
  end

  # Two activations are the same when they are the same rule, reached by the same match.
  # `remove/2` is always handed a freshly built activation rather than the stored one, so
  # the comparison has to be by value — which is what a `Rete.Bucket` does, since it keys
  # its multiset on the item itself.
  #
  # Comparing the whole struct is the same test as comparing `:node_id` and `:token`
  # alone. `:order` and the salience fields all come from the node, so they cannot differ
  # when the node does not. That is also why the one looked for lands in the bucket of the
  # one stored: the bucket key is derived from those same three fields.
end
