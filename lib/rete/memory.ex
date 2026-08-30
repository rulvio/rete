defmodule Rete.Memory.Bucket do
  @moduledoc """
  One join key's worth of elements or tokens: an ordered multiset.

  **Internal**, and the one place in the engine where the obvious data structure
  is the wrong one. Everything above it sees a list in arrival order; `to_list/1`
  is what produces that.

  ## Why not a list

  A join key's bucket is asked to do three things, and a list is good at one:

  | | list | here |
  |---|---|---|
  | add | O(n) appending, O(1) prepending | O(1) |
  | remove one occurrence, by value | O(position) | O(1) amortised |
  | read in arrival order | O(1) | O(n) |

  Reading is O(n) either way in practice, because everything that asks for a
  bucket is about to iterate all of it. The other two are what matter, and a
  list cannot have both: appending is what made inserting n facts under one join
  key cost O(n²), and prepending only moves the cost — the *oldest* occurrence
  is then the far end of the list, so removing it walks the lot.

  Buckets are routinely large. Every rule's first condition stores all its
  matching facts under one key, `%{}`, because a `Rete.Network.Node.RootJoin`
  has nothing to join on — so a session holding ten thousand customers has a
  ten-thousand element bucket, and both adding and retracting are ordinary.

  ## How

  Three parts, none of which is walked to add or remove:

    * `:stack` — every item ever pushed, newest first. Prepending is O(1).
    * `:counts` — `value => live occurrences`. Answers "is this here?" in one
      lookup, which is what a removal needs to report honestly.
    * `:dead` — `value => occurrences retracted but still in the stack`.

  Removing does not touch the stack: it decrements `:counts` and increments
  `:dead`. `to_list/1` walks the stack in arrival order and skips the first
  `dead[value]` occurrences of each value it meets — the *first* ones, so the
  oldest occurrence is the one that went, which is what a list would have done.

  Tombstones are compacted away once they outnumber the living, which costs a
  pass and can only happen after at least that many removals, so removal stays
  O(1) amortised.
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
  Removes the oldest live occurrence of `target`, or reports that there is none.

  `:error` rather than a silent no-op: a caller that propagated a retraction of
  something the bucket never held would corrupt every count below it.
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

  # Walks arrival order, dropping the first `dead[item]` occurrences of each
  # value. Arrival order is what makes those the oldest ones.
  defp skip_dead([], _dead, acc), do: Enum.reverse(acc)

  defp skip_dead([item | rest], dead, acc) do
    case Map.get(dead, item) do
      nil -> skip_dead(rest, dead, [item | acc])
      1 -> skip_dead(rest, Map.delete(dead, item), acc)
      n -> skip_dead(rest, Map.put(dead, item, n - 1), acc)
    end
  end

  # Rebuilding costs a pass over the bucket, and cannot happen again until the
  # dead outnumber the living a second time — so each rebuild is paid for by the
  # removals that caused it, and removal stays O(1) amortised.
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

  **Internal.** Not part of the public API — see the README — but documented
  rather than hidden, because durability, checkpointing and advanced tooling
  will need to reach in here. Treat its functions as liable to change.

  Clara keeps two memories — a mutable "transient" one used while rules fire and
  a persistent one between calls — and converts between them. That duality is a
  JVM performance artifact. Here there is one immutable struct threaded through
  the propagation loop, which is both simpler and what makes a session a value
  you can hold, compare and share.

  ## The five memories

      elements    node_id => join_key => Bucket of Element   right of a beta node
      tokens      node_id => join_key => Bucket of Token     left of a beta node
      accum       node_id => join_key => group_key => [fact]
      insertions  node_id => token => [[fact]]               truth maintenance
      facts       fact => count                              what it was told

  `elements` and `tokens` are keyed twice: by node, then by the join key, so a
  join is a map lookup rather than a scan. `accum` is keyed three times because
  a collection binding that introduces a new variable groups by it.

  A bucket is an ordered multiset rather than a list, so that adding and
  retracting are both O(1) however large it grows — see `Rete.Memory.Bucket`,
  which is where the interesting part is. Everything here hands out plain lists
  in arrival order; `dump/1` renders the whole memory that way.

  **Arrival order is load bearing.** It decides the order tokens propagate,
  which decides the order two matches of the *same* rule reach the agenda, and
  `Rete.Activation.key/1` is per node rather than per token — so `Rete.Agenda`
  leaves them in the order they arrived. A bucket that gave items back in some
  other order would silently reorder every `:activation_fired` event and every
  cascade of conclusions.

  Every key above the leaf is a *value* — a join key and a group key hold the
  bindings they were built from — so an entry left pointing at an empty leaf is
  not tidy-up work, it is a leak that grows with the number of distinct entities
  a session has ever seen. Removal therefore collapses the level above it, and
  `Rete.Engine.Nodes` relies on that: "no group" and "an empty group" are
  different answers, and only a level that really is gone may disappear.

  ## `root_seeded?`

  The one flag that is not a memory. Classic Rete seeds the beta root with a
  single empty token so that a rule opening with a negation, a collection or a
  test has a left input before any fact exists. It is planted once per session
  and never retracted; this records whether that has happened, because doing it
  twice would give every such rule two supports.

  ## Why counts, not sets

  `facts` is a multiset. Inserting the same fact twice and retracting it once
  must leave it present: two independent rules may each have concluded it, and
  one of them being invalidated does not make it false. The same reasoning
  applies to `elements` and `tokens`, which hold occurrences rather than
  distinct values and are retracted one occurrence at a time.
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

  Idempotent by construction: `Rete.Engine.Nodes` seeds only while this is
  `false`, so a session plants exactly one root token however many times it is
  asked.
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
  Removes one occurrence of each given element, returning what was found.

  Returns `{memory, removed}`. An element that was not there is not reported, so
  a caller can tell a real retraction from a no-op — propagating a retraction
  that never happened would corrupt the counts downstream.
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

  A group with no facts is not the same as a group holding `[]`: the first does
  not exist, the second is an empty collection the rule can legitimately see.
  Only a grouping collection ever drops to nothing.

  The join key that held the last group goes with it, and the node with the last
  join key. Both are binding values, so leaving them behind would accumulate one
  empty entry per entity the session has ever seen — the very leak dropping the
  group was meant to avoid, one level up.
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

  Stored as a list of lists: the same token can activate a production more than
  once over a session's life, and each activation owns its own batch.
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

  Returns `{memory, facts}`, or `{memory, []}` when the token never inserted
  anything — a production that was activated but retracted before it fired, or
  one whose right hand side returned nothing.
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

  Only a genuinely new fact is propagated. A second insertion of an equal fact
  bumps its count so that one retraction does not remove it, but sends nothing
  through the network — the matches it would make already exist.
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
  The whole memory as plain data, with every bucket rendered as a list in
  arrival order.

  What to reach for instead of the struct. `:elements` and `:tokens` hold
  `Rete.Memory.Bucket` structs whose internals — a stack with tombstones in it —
  say nothing about what the session holds, and two memories that agree on every
  match can disagree on them. This is the view that is meaningful to compare, to
  assert on, and to write down somewhere.
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

  # Removes one occurrence of each target, by value. Anything not present is
  # left out of `removed`, so the caller never propagates a phantom retraction.
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

  # Stores a level, or removes it when nothing is left in it. Every key above the
  # leaf is a binding value, so an entry left pointing at nothing is a leak that
  # grows with the number of entities the session has seen, not a tidy-up.
  defp store_at(map, key, contents) when contents in [[], %{}], do: Map.delete(map, key)
  defp store_at(map, key, contents), do: Map.put(map, key, contents)
end
