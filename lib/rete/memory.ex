defmodule Rete.Memory.Bucket do
  @moduledoc """
  One join key's worth of elements or tokens: an ordered multiset.

  **Internal.** Everything above it sees a list in arrival order, which `to_list/1`
  produces. Adding and removing one occurrence are both O(1) amortised however large the
  bucket grows, and a list cannot have both. Buckets are routinely large: a
  `Rete.Network.Node.RootJoin` has nothing to join on, so it stores every matching fact
  under one key.

  `:stack` holds every item ever pushed, newest first. `:counts` holds live occurrences
  per value and `:dead` holds retracted ones still in the stack. Removing tombstones
  instead of rebuilding, and `to_list/1` skips the first `dead[value]` occurrences of each
  value in arrival order, so the **oldest** occurrence is the one that went. Tombstones
  are compacted once they outnumber the living. See `docs/design/w3-engine.md` §7.

      iex> alias Rete.Memory.Bucket
      iex> {:ok, bucket} = Bucket.new([:a, :b, :a]) |> Bucket.take(:a)
      iex> Bucket.to_list(bucket)
      [:b, :a]
      iex> Bucket.take(bucket, :never_stored)
      :error
  """

  @type t :: %__MODULE__{
          stack: [term()],
          counts: %{term() => pos_integer()},
          dead: %{term() => pos_integer()},
          live: non_neg_integer(),
          dead_total: non_neg_integer()
        }

  defstruct stack: [], counts: %{}, dead: %{}, live: 0, dead_total: 0

  @doc "A bucket holding `items`, in arrival order."
  @spec new([term()]) :: t()
  def new(items \\ []), do: push(%__MODULE__{}, items)

  @doc "Adds items behind the ones already there. O(1) per item."
  @spec push(t(), [term()]) :: t()
  def push(%__MODULE__{} = bucket, []), do: bucket

  def push(%__MODULE__{} = bucket, items) do
    %__MODULE__{
      bucket
      | stack: Enum.reverse(items) ++ bucket.stack,
        counts: Enum.reduce(items, bucket.counts, &bump(&2, &1)),
        live: bucket.live + length(items)
    }
  end

  @doc """
  Removes the oldest live occurrence of `target`, or `:error` if there is none.

  `:error` rather than a silent no-op. A caller that propagated a retraction of something
  the bucket never held would corrupt every count below it.
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

  @doc "The live items, in arrival order."
  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{dead_total: 0, stack: stack}), do: Enum.reverse(stack)

  def to_list(%__MODULE__{stack: stack, dead: dead}) do
    stack |> Enum.reverse() |> skip_dead(dead, [])
  end

  @doc "Whether anything live is left."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{live: live}), do: live == 0

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

  # A rebuild costs a pass, and cannot happen again until the dead outnumber the living a
  # second time. Each one is paid for by the removals that caused it.
  defp compact(%__MODULE__{dead_total: dead_total, live: live} = bucket)
       when dead_total > live do
    %__MODULE__{bucket | stack: bucket |> to_list() |> Enum.reverse(), dead: %{}, dead_total: 0}
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

defmodule Rete.Memory do
  @moduledoc """
  Working memory: everything a session knows, as one immutable value.

  **Internal.** Not part of the public API, and documented rather than hidden because
  durability, checkpointing and advanced tooling will need to reach in here. Treat its
  functions as liable to change.

  Five memories, plus one flag:

      elements    node_id => join_key => Bucket of Element   right of a beta node
      tokens      node_id => join_key => Bucket of Token     left of a beta node
      accum       node_id => join_key => group_key => [fact]
      insertions  node_id => token => [[fact]]               truth maintenance
      facts       fact => count                              what it was told

  Three properties are load bearing. See `docs/design/w3-engine.md` §4.

    * **Arrival order.** It decides the order tokens propagate, and so the order two
      matches of one rule fire. A bucket that gave items back in another order would
      reorder every `:activation_fired` event.
    * **Removal collapses the level above.** Every key above the leaf is a value, so an
      entry pointing at an empty leaf leaks. `Rete.Engine.Nodes` also needs "no group" and
      "an empty group" to stay different answers.
    * **Multisets, not sets.** Inserting a fact twice and retracting once must leave it
      present. Two rules may each have concluded it.

  `root_seeded?` is not a memory. It records that the beta root's empty token has been
  planted, which must happen exactly once per session. See `docs/design/w3-engine.md` §6.

      iex> alias Rete.Memory
      iex> {memory, :new} = Memory.add_fact(Memory.new(), {:order, 1})
      iex> {memory, :duplicate} = Memory.add_fact(memory, {:order, 1})
      iex> {memory, :remaining} = Memory.remove_fact(memory, {:order, 1})
      iex> Memory.facts(memory)
      [{:order, 1}]
  """

  alias Rete.Element
  alias Rete.Memory.Bucket
  alias Rete.Token

  @type node_id :: term()
  @type key :: %{atom() => term()}

  @type t :: %__MODULE__{
          elements: %{node_id() => %{key() => Bucket.t()}},
          tokens: %{node_id() => %{key() => Bucket.t()}},
          accum: %{node_id() => %{key() => %{key() => [term()]}}},
          insertions: %{node_id() => %{Token.t() => [[term()]]}},
          facts: %{term() => pos_integer()},
          root_seeded?: boolean()
        }

  defstruct elements: %{},
            tokens: %{},
            accum: %{},
            insertions: %{},
            facts: %{},
            root_seeded?: false

  @doc """
  An empty memory.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records that the beta root's empty token has been propagated.

  `Rete.Engine.Nodes` seeds only while this is `false`, so a session plants exactly one
  root token however many times it is asked.
  """
  @spec mark_root_seeded(t()) :: t()
  def mark_root_seeded(%__MODULE__{} = memory), do: %__MODULE__{memory | root_seeded?: true}

  # --- elements (right side) ---------------------------------------------------

  @doc "The elements stored at a node under a join key, in arrival order."
  @spec elements(t(), node_id(), key()) :: [Element.t()]
  def elements(%__MODULE__{elements: elements}, node_id, key) do
    elements |> Map.get(node_id, %{}) |> bucket(key) |> Bucket.to_list()
  end

  @doc "Every element at a node, whatever its join key."
  @spec all_elements(t(), node_id()) :: [Element.t()]
  def all_elements(%__MODULE__{elements: elements}, node_id) do
    elements |> Map.get(node_id, %{}) |> Map.values() |> Enum.flat_map(&Bucket.to_list/1)
  end

  @doc "Adds elements at a node under a join key."
  @spec add_elements(t(), node_id(), key(), [Element.t()]) :: t()
  def add_elements(memory, _node_id, _key, []), do: memory

  def add_elements(%__MODULE__{} = memory, node_id, key, new) do
    %__MODULE__{memory | elements: push(memory.elements, node_id, key, new)}
  end

  @doc """
  Removes one occurrence of each given element, returning `{memory, removed}`.

  An element that was not there is left out of `removed`, so a caller can tell a real
  retraction from a no-op. Propagating a retraction that never happened would corrupt the
  counts downstream.
  """
  @spec remove_elements(t(), node_id(), key(), [Element.t()]) :: {t(), [Element.t()]}
  def remove_elements(memory, _node_id, _key, []), do: {memory, []}

  def remove_elements(%__MODULE__{} = memory, node_id, key, targets) do
    {elements, removed} = pop(memory.elements, node_id, key, targets)
    {%__MODULE__{memory | elements: elements}, removed}
  end

  # --- tokens (left side) ------------------------------------------------------

  @doc "The tokens stored at a node under a join key, in arrival order."
  @spec tokens(t(), node_id(), key()) :: [Token.t()]
  def tokens(%__MODULE__{tokens: tokens}, node_id, key) do
    tokens |> Map.get(node_id, %{}) |> bucket(key) |> Bucket.to_list()
  end

  @doc "Every token at a node, whatever its join key."
  @spec all_tokens(t(), node_id()) :: [Token.t()]
  def all_tokens(%__MODULE__{tokens: tokens}, node_id) do
    tokens |> Map.get(node_id, %{}) |> Map.values() |> Enum.flat_map(&Bucket.to_list/1)
  end

  @doc "Adds tokens at a node under a join key."
  @spec add_tokens(t(), node_id(), key(), [Token.t()]) :: t()
  def add_tokens(memory, _node_id, _key, []), do: memory

  def add_tokens(%__MODULE__{} = memory, node_id, key, new) do
    %__MODULE__{memory | tokens: push(memory.tokens, node_id, key, new)}
  end

  @doc """
  Removes one occurrence of each given token, returning what was found.
  """
  @spec remove_tokens(t(), node_id(), key(), [Token.t()]) :: {t(), [Token.t()]}
  def remove_tokens(memory, _node_id, _key, []), do: {memory, []}

  def remove_tokens(%__MODULE__{} = memory, node_id, key, targets) do
    {tokens, removed} = pop(memory.tokens, node_id, key, targets)
    {%__MODULE__{memory | tokens: tokens}, removed}
  end

  # --- accumulated collections --------------------------------------------------

  @doc "The collection groups at a node under a join key, `group_key => facts`."
  @spec groups(t(), node_id(), key()) :: %{key() => [term()]}
  def groups(%__MODULE__{accum: accum}, node_id, key) do
    accum |> Map.get(node_id, %{}) |> Map.get(key, %{})
  end

  @doc "Replaces the facts of one collection group."
  @spec put_group(t(), node_id(), key(), key(), [term()]) :: t()
  def put_group(%__MODULE__{} = memory, node_id, key, group_key, facts) do
    accum =
      Map.update(
        memory.accum,
        node_id,
        %{key => %{group_key => facts}},
        &Map.update(&1, key, %{group_key => facts}, fn groups ->
          Map.put(groups, group_key, facts)
        end)
      )

    %__MODULE__{memory | accum: accum}
  end

  @doc """
  Drops a collection group entirely.

  A group with no facts is not a group holding `[]`. The first does not exist. The second
  is an empty collection the rule can legitimately see. Only a grouping collection ever
  drops to nothing.

  The join key that held the last group goes with it, and the node with the last join key.
  Both are binding values, so leaving them behind would leak one entry per entity the
  session has seen.
  """
  @spec drop_group(t(), node_id(), key(), key()) :: t()
  def drop_group(%__MODULE__{} = memory, node_id, key, group_key) do
    by_key = Map.get(memory.accum, node_id, %{})
    groups = by_key |> Map.get(key, %{}) |> Map.delete(group_key)
    by_key = store_at(by_key, key, groups)

    %__MODULE__{memory | accum: store_at(memory.accum, node_id, by_key)}
  end

  # --- truth maintenance ---------------------------------------------------------

  @doc """
  Records the facts one activation of a production inserted.

  Stored as a list of lists. The same token can activate a production more than once over
  a session's life, and each activation owns its own batch.
  """
  @spec add_insertion(t(), node_id(), Token.t(), [term()]) :: t()
  def add_insertion(%__MODULE__{} = memory, node_id, token, facts) do
    insertions =
      Map.update(
        memory.insertions,
        node_id,
        %{token => [facts]},
        &Map.update(&1, token, [facts], fn batches -> batches ++ [facts] end)
      )

    %__MODULE__{memory | insertions: insertions}
  end

  @doc """
  Takes back one batch of facts a token's activation inserted.

  Returns `{memory, facts}`, or `{memory, []}` when the token never inserted anything.
  That is a production retracted before it fired, or one whose body returned nothing.
  """
  @spec take_insertion(t(), node_id(), Token.t()) :: {t(), [term()]}
  def take_insertion(%__MODULE__{} = memory, node_id, token) do
    by_token = Map.get(memory.insertions, node_id, %{})

    case Map.get(by_token, token, []) do
      [] ->
        {memory, []}

      [batch | rest] ->
        by_token = store_at(by_token, token, rest)
        insertions = store_at(memory.insertions, node_id, by_token)

        {%__MODULE__{memory | insertions: insertions}, batch}
    end
  end

  # --- the fact multiset ----------------------------------------------------------

  @doc """
  Records a fact, returning `{memory, :new | :duplicate}`.

  Only `:new` is propagated. A second insertion of an equal fact bumps its count so that
  one retraction does not remove it. The matches it would make already exist.
  """
  @spec add_fact(t(), term()) :: {t(), :new | :duplicate}
  def add_fact(%__MODULE__{facts: facts} = memory, fact) do
    case Map.get(facts, fact) do
      nil -> {%__MODULE__{memory | facts: Map.put(facts, fact, 1)}, :new}
      n -> {%__MODULE__{memory | facts: Map.put(facts, fact, n + 1)}, :duplicate}
    end
  end

  @doc """
  Drops one occurrence of a fact, returning `{memory, :gone | :remaining | :absent}`.

  Only `:gone` — the last occurrence — is propagated.
  """
  @spec remove_fact(t(), term()) :: {t(), :gone | :remaining | :absent}
  def remove_fact(%__MODULE__{facts: facts} = memory, fact) do
    case Map.get(facts, fact) do
      nil -> {memory, :absent}
      1 -> {%__MODULE__{memory | facts: Map.delete(facts, fact)}, :gone}
      n -> {%__MODULE__{memory | facts: Map.put(facts, fact, n - 1)}, :remaining}
    end
  end

  @doc """
  Every distinct fact the session holds.
  """
  @spec facts(t()) :: [term()]
  def facts(%__MODULE__{facts: facts}), do: Map.keys(facts)

  # --- reading the whole thing -------------------------------------------------------

  @doc """
  The whole memory as plain data, every bucket rendered as a list in arrival order.

  Reach for this instead of the struct. A `Rete.Memory.Bucket` holds a stack with
  tombstones in it, and two memories that agree on every match can still disagree there.
  This is the view that is meaningful to compare, assert on and write down.
  """
  @spec dump(t()) :: %{
          elements: %{node_id() => %{key() => [Element.t()]}},
          tokens: %{node_id() => %{key() => [Token.t()]}},
          accum: %{node_id() => %{key() => %{key() => [term()]}}},
          insertions: %{node_id() => %{Token.t() => [[term()]]}},
          facts: %{term() => pos_integer()},
          root_seeded?: boolean()
        }
  def dump(%__MODULE__{} = memory) do
    %{
      elements: listed(memory.elements),
      tokens: listed(memory.tokens),
      accum: memory.accum,
      insertions: memory.insertions,
      facts: memory.facts,
      root_seeded?: memory.root_seeded?
    }
  end

  defp listed(store) do
    Map.new(store, fn {node_id, by_key} ->
      {node_id, Map.new(by_key, fn {key, bucket} -> {key, Bucket.to_list(bucket)} end)}
    end)
  end

  # --- shared helpers ---------------------------------------------------------------

  defp bucket(by_key, key), do: Map.get(by_key, key) || Bucket.new()

  defp push(store, node_id, key, new) do
    Map.update(store, node_id, %{key => Bucket.new(new)}, fn by_key ->
      Map.update(by_key, key, Bucket.new(new), &Bucket.push(&1, new))
    end)
  end

  # Removes one occurrence of each target, by value. Anything not present is left out of
  # `removed`, so the caller never propagates a phantom retraction.
  defp pop(store, node_id, key, targets) do
    by_key = Map.get(store, node_id, %{})

    {bucket, removed} =
      Enum.reduce(targets, {bucket(by_key, key), []}, fn target, {bucket, removed} ->
        case Bucket.take(bucket, target) do
          {:ok, bucket} -> {bucket, [target | removed]}
          :error -> {bucket, removed}
        end
      end)

    by_key =
      if Bucket.empty?(bucket), do: Map.delete(by_key, key), else: Map.put(by_key, key, bucket)

    {store_at(store, node_id, by_key), Enum.reverse(removed)}
  end

  # Stores a level, or removes it when nothing is left in it. Every key above the leaf is
  # a binding value, so an entry pointing at nothing leaks.
  defp store_at(map, key, contents) when contents in [[], %{}], do: Map.delete(map, key)
  defp store_at(map, key, contents), do: Map.put(map, key, contents)
end
