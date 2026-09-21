defmodule Rete.Agenda do
  @moduledoc """
  The activations waiting to fire, most salient first.

  **Internal.** Not part of the public API. It is documented rather than hidden, because
  durability, checkpointing, and scheduling work will need to reach in here. Treat its
  functions as liable to change.

  Ordering is `{salience, internal_salience}` descending, then compile order ascending.
  Two matches of the same rule fire in the order they arrived.

  Every activation of one production node shares a sort key. The agenda is thus a small
  number of ordered buckets, and not one sorted list. Each bucket is a `Rete.Bucket`,
  which is the same tombstoned ordered multiset that working memory keys per join key. The
  buckets sit in a `:gb_trees`, so `add/2`, `pop/1` and `remove/2` cost O(log r) in the
  rules pending, and O(1) amortized in the bucket. `remove/2` used to be linear in one
  bucket, which is one rule's pending matches, so retracting the support of a rule with
  many of them was quadratic. See `docs/design/engine.md` §7.

  What makes the bucket half of `remove/2` O(1) is the bucket's index, and a bucket builds
  that only when something is first taken from it. An agenda that is only ever added to and
  drained — a session that never retracts — never builds one.

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

  @type t :: %__MODULE__{buckets: :gb_trees.tree(key(), Bucket.t())}

  @enforce_keys [:buckets]
  defstruct [:buckets]

  @doc "An empty agenda."
  @spec new() :: t()
  # `:gb_trees.empty/0` is called here rather than given as a struct default, for the reason
  # `Rete.Bucket.new/1` records: a compile-time default loses the opaque type.
  def new, do: %__MODULE__{buckets: :gb_trees.empty()}

  @doc """
  How many activations are waiting.

  Counted over the buckets, so O(r) in the rules pending. Nothing in the engine asks, and
  a stored count would be a second version of what the buckets already hold.

      iex> alias Rete.{Activation, Agenda}
      iex> Agenda.new() |> Agenda.add(%Activation{node_id: :n1}) |> Agenda.size()
      1
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{buckets: buckets}) do
    buckets
    |> :gb_trees.values()
    |> Enum.reduce(0, fn bucket, total -> total + Bucket.size(bucket) end)
  end

  @doc "Adds an activation, behind the ones already queued for its rule."
  @spec add(t(), Activation.t()) :: t()
  def add(%__MODULE__{} = agenda, %Activation{} = activation) do
    key = Activation.key(activation)

    buckets =
      case :gb_trees.lookup(key, agenda.buckets) do
        {:value, bucket} ->
          :gb_trees.update(key, Bucket.push_one(bucket, activation), agenda.buckets)

        :none ->
          :gb_trees.insert(key, Bucket.new([activation]), agenda.buckets)
      end

    %__MODULE__{agenda | buckets: buckets}
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

    case :gb_trees.lookup(key, agenda.buckets) do
      :none ->
        {agenda, :missing}

      {:value, bucket} ->
        case Bucket.take(bucket, activation) do
          {:ok, bucket} ->
            {store(agenda, key, bucket), :removed}

          # The bucket comes back too, because the miss is what built its index.
          {:error, bucket} ->
            {%__MODULE__{agenda | buckets: :gb_trees.update(key, bucket, agenda.buckets)},
             :missing}
        end
    end
  end

  @doc """
  Takes the most salient activation, or `:empty`.

      iex> Rete.Agenda.pop(Rete.Agenda.new())
      :empty
  """
  @spec pop(t()) :: {:ok, Activation.t(), t()} | :empty
  def pop(%__MODULE__{} = agenda) do
    if :gb_trees.is_empty(agenda.buckets) do
      :empty
    else
      {key, bucket} = :gb_trees.smallest(agenda.buckets)
      {:ok, activation, rest} = Bucket.pop(bucket)

      {:ok, activation, store(agenda, key, rest)}
    end
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
  def peek_group(%__MODULE__{buckets: buckets}) do
    case buckets |> :gb_trees.iterator() |> :gb_trees.next() do
      :none ->
        []

      {{salience, internal, _order}, bucket, iterator} ->
        take_group(iterator, salience, internal, [Bucket.to_list(bucket)])
    end
  end

  @doc "Every pending activation, in firing order."
  @spec to_list(t()) :: [Activation.t()]
  def to_list(%__MODULE__{buckets: buckets}) do
    buckets |> :gb_trees.values() |> Enum.flat_map(&Bucket.to_list/1)
  end

  # An iterator, because a group is a prefix: reading every bucket would cost the rules that
  # never get a turn. The two ways to stop are spelled out so that a key of any other shape
  # raises. Absorbing one would answer `[]` for a group that has activations in it, and a
  # fire above `concurrency: 1` would then return with matches still pending.
  defp take_group(iterator, salience, internal, acc) do
    case :gb_trees.next(iterator) do
      {{^salience, ^internal, _order}, bucket, iterator} ->
        take_group(iterator, salience, internal, [Bucket.to_list(bucket) | acc])

      {{_salience, _internal, _order}, _bucket, _iterator} ->
        firing_order(acc)

      :none ->
        firing_order(acc)
    end
  end

  defp firing_order(buckets), do: buckets |> Enum.reverse() |> Enum.concat()

  # Drops the key when the bucket empties. The tree records which buckets exist, so an
  # empty one left behind would make `pop/1` hand back nothing.
  #
  # Takes a bucket, not a list. Round-tripping through a list here would put an O(bucket)
  # cost on `pop/1`, which has to stay O(1) in one rule's pending matches.
  defp store(%__MODULE__{} = agenda, key, remaining) do
    buckets =
      if Bucket.empty?(remaining) do
        :gb_trees.delete(key, agenda.buckets)
      else
        :gb_trees.update(key, remaining, agenda.buckets)
      end

    %__MODULE__{agenda | buckets: buckets}
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
