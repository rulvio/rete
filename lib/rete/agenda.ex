defmodule Rete.Agenda do
  @moduledoc """
  The activations waiting to fire, most salient first.

  **Internal.** Not part of the public API. It is documented rather than hidden, because
  durability, checkpointing, and scheduling work will need to reach in here. Treat its
  functions as liable to change.

  Ordering is `{salience, internal_salience}` descending, then compile order ascending.
  Two matches of the same rule fire in the order they arrived.

  Every activation of one production node shares a sort key. The agenda is thus a small
  number of ordered buckets, and not one sorted list of matches. Each bucket is a
  `Rete.Bucket`, which is the same tombstoned ordered multiset that working memory keys per
  join key. `remove/2` used to be linear in one bucket, which is one rule's pending matches,
  so retracting the support of a rule with many of them was quadratic. See
  `docs/design/engine.md` §7.

  The buckets are held in a `:gb_trees`, ordered by that sort key. So `add/2`, `pop/1` and
  `remove/2` cost O(log r) in the **rules** pending, and O(1) amortized in the bucket.

  That replaced a sorted list of the keys, which was the wrong shape in one direction.
  Activations reach the agenda in compile order, which is the order the keys sort in, so
  each new rule's first activation walked the whole list. Fed in reverse, each key went at
  the front instead. Firing one match of each of 1,024 rules therefore cost 19.22 ms one
  way and 6.03 ms the other. A tree is level: 8.71 ms and 8.66 ms. Both scenarios are in
  `bench/run.exs`.

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

  @typedoc "One `Rete.Bucket` per sort key, ordered by it."
  @type t :: %__MODULE__{buckets: :gb_trees.tree(key(), Bucket.t())}

  # `new/0` is the only way to build one. Without this, `%Rete.Agenda{}` gives a struct with
  # no buckets, and the first `pop/1` on it fails inside `:gb_trees` rather than where the
  # mistake was made.
  @enforce_keys [:buckets]
  defstruct [:buckets]

  @doc "An empty agenda."
  @spec new() :: t()
  # `:gb_trees.empty/0` is called here rather than given as a struct default, the same way
  # `Rete.Bucket.new/1` builds its queue. Elixir evaluates a default at compile time and
  # embeds the literal it produces. That throws away the opaqueness of `:gb_trees.tree/2`,
  # and every later call on the field then looks like a type violation.
  def new, do: %__MODULE__{buckets: :gb_trees.empty()}

  @doc """
  How many activations are waiting.

  Counted on demand, over the buckets. This is O(r) in the rules pending, since
  `Rete.Bucket.size/1` is O(1). Nothing in the engine asks, because `pop/1` and
  `peek_group/1` test the buckets for emptiness instead. A stored counter would thus be a
  second version of a truth the buckets already hold, kept in step for no reader.

  Note that `:gb_trees.size/1` would answer a different question: how many **rules** have
  something waiting.

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
  # `:gb_trees.smallest/1` and not an iterator, which is the opposite of what `peek_group/1`
  # does. That one has to keep walking, so it needs an iterator anyway and takes the leading
  # bucket out of it for nothing. This one stops at the first bucket, and an iterator would
  # allocate a spine it never reads. `:gb_trees.is_empty/1` is O(1), so the guard is free.
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
  # The leading bucket is taken from the iterator rather than by `:gb_trees.smallest/1`,
  # which would walk down to it a second time. It also decides the group, so it seeds the
  # accumulator and `take_group/4` carries on from behind it.
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
  # `:gb_trees.values/1` rather than `to_list/1`: both walk the whole tree in key order, and
  # only this one leaves the keys behind. Nothing here reads a key.
  def to_list(%__MODULE__{buckets: buckets}) do
    buckets |> :gb_trees.values() |> Enum.flat_map(&Bucket.to_list/1)
  end

  # Walks the buckets in key order and stops at the first key outside the leading group. An
  # iterator rather than `:gb_trees.to_list/1`, because a group is a prefix: reading every
  # bucket to return the front of them would cost the rules that never get a turn.
  #
  # The two ways to stop are spelled out rather than caught together, so that a key of any
  # other shape raises here. Absorbing one would return `[]` for a group that has
  # activations in it. `Rete.Engine.next_cycle/2` reads that as an empty agenda, so a fire
  # above `concurrency: 1` would return with matches pending and report nothing.
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

  # Each bucket is prepended as it is walked, so the accumulator runs backwards through the
  # keys. One reverse and one concat put it back into firing order.
  defp firing_order(buckets), do: buckets |> Enum.reverse() |> Enum.concat()

  # Drops the key when its bucket empties, because a key is what records that a bucket
  # exists. An empty one left behind would make `pop/1` hand back a bucket with nothing
  # in it.
  #
  # Takes a bucket, not a list. Round-tripping through a list here would put an O(bucket)
  # cost on `pop/1`, which has to stay O(1) in the pending matches of one rule.
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
