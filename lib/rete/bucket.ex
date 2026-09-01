defmodule Rete.Bucket do
  @moduledoc """
  An ordered multiset: add, remove one occurrence, and read back in arrival order.

  **Internal.** Everything above it sees a list in arrival order, which `to_list/1`
  produces. Adding and removing one occurrence are both O(1) amortised, however large the
  bucket grows — a plain list cannot do both, and neither can a queue on its own.

  Two things in the engine need exactly this, which is why it is one module rather than
  two. `Rete.Memory` keys a bucket per join key: a `Rete.Network.Node.RootJoin` has nothing
  to join on, so it stores every matching fact under one key. `Rete.Agenda` keys a bucket
  per sort key, which is one rule's pending matches, and cancels from it by value when
  truth maintenance takes a match back.

  `:queue` holds every item ever pushed. `:counts` holds live occurrences per value, and
  `:dead` holds retracted ones still in the queue. Removal tombstones an occurrence,
  instead of rebuilding. `to_list/1` and `pop/1` then skip the first `dead[value]`
  occurrences of each value, in arrival order — so the **oldest** occurrence is the one
  that went. Tombstones are compacted once they outnumber the living occurrences. See
  `docs/design/engine.md` §7.

      iex> alias Rete.Bucket
      iex> {:ok, bucket} = Bucket.new([:a, :b, :a]) |> Bucket.take(:a)
      iex> Bucket.to_list(bucket)
      [:b, :a]
      iex> Bucket.take(bucket, :never_stored)
      :error
      iex> {:ok, :b, _rest} = Bucket.pop(bucket)
  """

  @type t :: %__MODULE__{
          queue: :queue.queue(term()),
          counts: %{term() => pos_integer()},
          dead: %{term() => pos_integer()},
          live: non_neg_integer(),
          dead_total: non_neg_integer()
        }

  defstruct [:queue, counts: %{}, dead: %{}, live: 0, dead_total: 0]

  @doc "A bucket holding `items`, in arrival order."
  @spec new([term()]) :: t()
  # `:queue.new/0` is called here rather than given as a struct default, the same way
  # `Rete.Engine.State` builds its queue. Elixir evaluates a default at compile time and
  # embeds the literal it produces, which throws away the opaqueness of `:queue.queue/0`
  # and makes every later call on the field look like a type violation.
  def new(items \\ []), do: push(%__MODULE__{queue: :queue.new()}, items)

  @doc "Adds items behind the ones already there. O(1) per item."
  @spec push(t(), [term()]) :: t()
  def push(%__MODULE__{} = bucket, []), do: bucket
  def push(%__MODULE__{} = bucket, [item]), do: push_one(bucket, item)

  def push(%__MODULE__{} = bucket, items) do
    %__MODULE__{
      bucket
      | queue: Enum.reduce(items, bucket.queue, &:queue.in/2),
        counts: Enum.reduce(items, bucket.counts, &bump(&2, &1)),
        live: bucket.live + length(items)
    }
  end

  @doc """
  Adds one item behind the ones already there.

  The single-item clause of `push/2` delegates here, because that is the common call: an
  agenda takes one activation at a time, and so does an alpha node feeding one fact. The
  list form walks its argument three times and takes its length; this does neither.
  """
  @spec push_one(t(), term()) :: t()
  def push_one(%__MODULE__{} = bucket, item) do
    %__MODULE__{
      bucket
      | queue: :queue.in(item, bucket.queue),
        counts: bump(bucket.counts, item),
        live: bucket.live + 1
    }
  end

  @doc """
  Removes the oldest live occurrence of `target`, or `:error` if there is none.

  This returns `:error`, instead of silently doing nothing. A caller that propagated a
  retraction of something the bucket never held would corrupt every count below it, and
  `Rete.Agenda` tells a cancelled activation from an already-fired one by exactly this.
  """
  @spec take(t(), term()) :: {:ok, t()} | :error
  def take(%__MODULE__{counts: counts} = bucket, target) do
    if Map.has_key?(counts, target) do
      {:ok,
       compact(%__MODULE__{
         bucket
         | counts: unbump(counts, target),
           dead: bump(bucket.dead, target),
           live: bucket.live - 1,
           dead_total: bucket.dead_total + 1
       })}
    else
      :error
    end
  end

  @doc """
  Takes the oldest live item, or `:empty`.

  Discards the tombstones it walks past, so the cost of skipping one is paid once.
  """
  @spec pop(t()) :: {:ok, term(), t()} | :empty
  def pop(%__MODULE__{live: 0}), do: :empty

  def pop(%__MODULE__{} = bucket) do
    {item, %__MODULE__{} = bucket} = pop_live(bucket)

    {:ok, item, %__MODULE__{bucket | counts: unbump(bucket.counts, item), live: bucket.live - 1}}
  end

  @doc "The live items, in arrival order."
  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{dead_total: 0, queue: queue}), do: :queue.to_list(queue)

  def to_list(%__MODULE__{queue: queue, dead: dead}) do
    queue |> :queue.to_list() |> skip_dead(dead, [])
  end

  @doc "Whether anything live is left."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{live: live}), do: live == 0

  @doc "How many live items there are. O(1)."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{live: live}), do: live

  # `live > 0` is the caller's guarantee, so the queue always yields a value here.
  #
  # A bucket that has never had anything taken from it cannot be holding a tombstone, so
  # it skips the lookup entirely. That is the ordinary agenda: activations are added and
  # fired, and only truth maintenance cancels one. `to_list/1` carries the same fast path.
  defp pop_live(%__MODULE__{dead_total: 0, queue: queue} = bucket) do
    {{:value, item}, rest} = :queue.out(queue)

    {item, %__MODULE__{bucket | queue: rest}}
  end

  defp pop_live(%__MODULE__{queue: queue, dead: dead} = bucket) do
    {{:value, item}, rest} = :queue.out(queue)

    case Map.get(dead, item) do
      nil ->
        {item, %__MODULE__{bucket | queue: rest}}

      n ->
        dead = if n == 1, do: Map.delete(dead, item), else: Map.put(dead, item, n - 1)

        pop_live(%__MODULE__{
          bucket
          | queue: rest,
            dead: dead,
            dead_total: bucket.dead_total - 1
        })
    end
  end

  # Drops the first `dead[item]` occurrences of each value. Walking arrival order is what
  # makes those the oldest ones.
  defp skip_dead([], _dead, acc), do: Enum.reverse(acc)

  defp skip_dead([item | rest], dead, acc) do
    case Map.get(dead, item) do
      nil -> skip_dead(rest, dead, [item | acc])
      1 -> skip_dead(rest, Map.delete(dead, item), acc)
      n -> skip_dead(rest, Map.put(dead, item, n - 1), acc)
    end
  end

  # A rebuild costs a pass. It cannot happen again until the dead outnumber the living a
  # second time. Each removal that causes a rebuild pays for it.
  defp compact(%__MODULE__{dead_total: dead_total, live: live} = bucket)
       when dead_total > live do
    %__MODULE__{
      bucket
      | queue: bucket |> to_list() |> :queue.from_list(),
        dead: %{},
        dead_total: 0
    }
  end

  defp compact(%__MODULE__{} = bucket), do: bucket

  defp bump(counts, value), do: Map.update(counts, value, 1, &(&1 + 1))

  defp unbump(counts, value) do
    case Map.fetch!(counts, value) do
      1 -> Map.delete(counts, value)
      n -> Map.put(counts, value, n - 1)
    end
  end
end
