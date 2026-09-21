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

  The buckets themselves sit in a `:gb_trees`, keyed by sort key. So `add/2`, `pop/1` and
  `remove/2` cost O(log r) in the **rules** pending, and O(1) amortized in the bucket.

  That tree replaced a sorted list of the keys, which was the wrong shape in one direction.
  Activations reach the agenda in compile order, which is the order the keys sort in, so
  each new rule's first activation walked the whole list. Fed in reverse, each key went at
  the front instead. Firing one match of each of 1,024 rules therefore cost 19.49 ms one
  way and 6.86 ms the other. A tree is level: 8.32 ms and 7.89 ms. Both scenarios are in
  `bench/run.exs`.

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
          tree: :gb_trees.tree(key(), Bucket.t()),
          size: non_neg_integer()
        }

  defstruct [:tree, size: 0]

  @doc "An empty agenda."
  @spec new() :: t()
  # `:gb_trees.empty/0` is called here rather than given as a struct default, the same way
  # `Rete.Bucket.new/1` builds its queue. Elixir evaluates a default at compile time and
  # embeds the literal it produces, which throws away the opaqueness of `:gb_trees.tree/2`
  # and makes every later call on the field look like a type violation.
  def new, do: %__MODULE__{tree: :gb_trees.empty()}

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

    tree =
      case :gb_trees.lookup(key, agenda.tree) do
        {:value, bucket} ->
          :gb_trees.update(key, Bucket.push_one(bucket, activation), agenda.tree)

        :none ->
          :gb_trees.insert(key, Bucket.new([activation]), agenda.tree)
      end

    %__MODULE__{agenda | tree: tree, size: agenda.size + 1}
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

    case :gb_trees.lookup(key, agenda.tree) do
      :none ->
        {agenda, :missing}

      {:value, bucket} ->
        case Bucket.take(bucket, activation) do
          {:ok, bucket} ->
            {store(agenda, key, bucket), :removed}

          # The bucket comes back too, because the miss is what built its index. Kept
          # without going through `store/3`, which would also decrement the size.
          {:error, bucket} ->
            {%__MODULE__{agenda | tree: :gb_trees.update(key, bucket, agenda.tree)}, :missing}
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
    if :gb_trees.is_empty(agenda.tree) do
      :empty
    else
      {key, bucket} = :gb_trees.smallest(agenda.tree)
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
  def peek_group(%__MODULE__{} = agenda) do
    if :gb_trees.is_empty(agenda.tree) do
      []
    else
      {{salience, internal, _order}, _bucket} = :gb_trees.smallest(agenda.tree)

      agenda.tree |> :gb_trees.iterator() |> take_group(salience, internal, [])
    end
  end

  # Walks the tree in key order and stops at the first key outside the leading group. An
  # iterator rather than `:gb_trees.to_list/1`, because a group is a prefix: reading the
  # whole tree to return the front of it would cost the rules that never get a turn.
  defp take_group(iterator, salience, internal, acc) do
    case :gb_trees.next(iterator) do
      {{^salience, ^internal, _order}, bucket, iterator} ->
        take_group(iterator, salience, internal, [Bucket.to_list(bucket) | acc])

      _past_the_group ->
        acc |> Enum.reverse() |> Enum.concat()
    end
  end

  @doc "Every pending activation, in firing order."
  @spec to_list(t()) :: [Activation.t()]
  def to_list(%__MODULE__{tree: tree}) do
    tree
    |> :gb_trees.to_list()
    |> Enum.flat_map(fn {_key, bucket} -> Bucket.to_list(bucket) end)
  end

  # Drops the key when the bucket empties. The tree records which buckets exist, so an
  # empty one left behind would make `pop/1` hand back a bucket with nothing in it.
  #
  # Takes a bucket, not a list. Round-tripping through a list here would put an O(bucket)
  # cost on `pop/1`, which has to stay O(1) in the pending matches of one rule.
  defp store(%__MODULE__{} = agenda, key, remaining) do
    tree =
      if Bucket.empty?(remaining) do
        :gb_trees.delete(key, agenda.tree)
      else
        :gb_trees.update(key, remaining, agenda.tree)
      end

    %__MODULE__{agenda | tree: tree, size: agenda.size - 1}
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
