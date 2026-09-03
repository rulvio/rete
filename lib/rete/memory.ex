defmodule Rete.Memory do
  @moduledoc """
  Working memory: everything a session knows, as one immutable value.

  **Internal.** Not part of the public API. It is documented rather than hidden, because
  durability, checkpointing, and advanced tooling will need to reach in here. Treat its
  functions as liable to change.

  Five memories, one index over them, and one flag:

      elements    node_id => join_key => Bucket of Element   right of a beta node
      tokens      node_id => join_key => Bucket of Token     left of a beta node
      accum       node_id => join_key => group_key => [member] what a collection gathered
      insertions  node_id => token => [[fact]]               truth maintenance
      facts       fact => count                              what it was told

      inserters   fact => {node_id, token} => count          `insertions`, reversed

  `inserters` is not a memory. It holds nothing `insertions` does not, indexed the other way,
  for the two readers that ask "which matches inserted *this fact*":
  `Rete.Engine.well_founded/3` on a conclusion already present, and
  `Rete.Inspect.derivations/2`. Answering from `insertions` costs a pass over every insertion
  record, which made two rules concluding one fact quadratic.

  **It is `nil` until something needs it.** A ruleset where no rule re-concludes never
  consults it, so `index_inserters/1` builds it on first use and everything after is
  maintained in step. It is a multiset keyed on `{node_id, token}`, so it does not depend on
  the order the session reached it in. Being a cache, it is left out of `dump/1`.

  Three properties are load-bearing. See `docs/design/engine.md` §4.

    * **Arrival order.** It decides the order tokens propagate, and so the order two
      matches of one rule fire. A bucket that gave items back in a different order would
      reorder every `:activation_fired` event.
    * **Removal collapses the level above.** Every key above the leaf is a value, so an
      entry pointing at an empty leaf leaks. `Rete.Engine.Nodes` also needs "no group" and
      "an empty group" to stay different answers.
    * **Multisets, not sets.** Inserting a fact twice, then retracting once, must leave it
      present. Two rules may each have concluded it.

  `root_seeded?` is not a memory. It records that the beta root's empty token has been
  planted. This must happen exactly once per session. See `docs/design/engine.md` §6.

      iex> alias Rete.Memory
      iex> {memory, :new} = Memory.add_fact(Memory.new(), {:order, 1})
      iex> {memory, :duplicate} = Memory.add_fact(memory, {:order, 1})
      iex> {memory, :remaining} = Memory.remove_fact(memory, {:order, 1})
      iex> Memory.facts(memory)
      [{:order, 1}]
  """

  alias Rete.Bucket
  alias Rete.Element
  alias Rete.Token

  @type node_id :: term()
  @type key :: %{atom() => term()}

  @typedoc "One match at one production, identified by where it fired and what it matched."
  @type inserter :: {node_id(), Token.t()}

  @type t :: %__MODULE__{
          elements: %{node_id() => %{key() => Bucket.t()}},
          tokens: %{node_id() => %{key() => Bucket.t()}},
          accum: %{node_id() => %{key() => %{key() => [term()]}}},
          insertions: %{node_id() => %{Token.t() => [[term()]]}},
          inserters: %{term() => %{inserter() => pos_integer()}} | nil,
          facts: %{term() => pos_integer()},
          root_seeded?: boolean()
        }

  defstruct elements: %{},
            tokens: %{},
            accum: %{},
            insertions: %{},
            inserters: nil,
            facts: %{},
            root_seeded?: false

  @doc """
  An empty memory.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records that the beta root's empty token has been propagated.

  `Rete.Engine.Nodes` seeds only while this is `false`. So a session plants exactly one
  root token, however many times it is asked.
  """
  @spec mark_root_seeded(t()) :: t()
  def mark_root_seeded(%__MODULE__{} = memory), do: %__MODULE__{memory | root_seeded?: true}

  # --- elements (right side) ---------------------------------------------------

  @doc "The elements stored at a node under a join key, in arrival order."
  @spec elements(t(), node_id(), key()) :: [Element.t()]
  def elements(%__MODULE__{elements: elements}, node_id, key) do
    elements |> Map.get(node_id, %{}) |> bucket(key) |> Bucket.to_list()
  end

  @doc """
  Whether a node holds anything under a join key, without building the list.

  A plain `Rete.Network.Node.Negation` has no filter, so "does anything match this token"
  is the same question for every token: is the bucket empty. Answering that with
  `elements/3` would cost a pass over the bucket per arriving element.
  """
  @spec any_elements?(t(), node_id(), key()) :: boolean()
  def any_elements?(%__MODULE__{elements: elements}, node_id, key) do
    case elements |> Map.get(node_id, %{}) |> Map.get(key) do
      nil -> false
      bucket -> not Bucket.empty?(bucket)
    end
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

  An element that was not there is left out of `removed`. So a caller can tell a real
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

  @doc """
  The node id one of a query's indexes stores under.

  A `node_id` is any term, so an index gets a namespace of its own rather than a second
  keying of the query's own store. Two keyings under one id would collide in
  `all_tokens/2`, which unions a node's buckets.
  """
  @spec index_id(node_id(), non_neg_integer()) :: node_id()
  def index_id(node_id, position), do: {node_id, :index, position}

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

  @doc """
  The collection groups at a node under a join key, `group_key => members`.

  A member is whatever the node stored: a plain collection keeps facts, because that is
  what it binds, and a filtered one keeps `Rete.Element`s, because its filter needs the
  bindings the alpha produced. `Rete.Memory` does not interpret them.
  """
  @spec groups(t(), node_id(), key()) :: %{key() => [term()]}
  def groups(%__MODULE__{accum: accum}, node_id, key) do
    accum |> Map.get(node_id, %{}) |> Map.get(key, %{})
  end

  @doc """
  The group keys a node holds under a join key.
  """
  @spec group_keys(t(), node_id(), key()) :: [key()]
  def group_keys(%__MODULE__{} = memory, node_id, key) do
    memory |> groups(node_id, key) |> Map.keys()
  end

  @doc """
  The members of one collection group, or `nil` if there is no such group. O(1).

  `nil` and `[]` are different answers. A group with no members does not exist. An empty
  collection a rule can legitimately see is `[]`, and only `Rete.Engine.Nodes` knows which
  of the two an absent group means. See `remove_from_group/5`.

  This is the list the node hands to the rule, not a view built for the occasion. That is
  the point of it: a member change has to produce the collection's old value and its new
  one, and materializing either would be O(k) on the hottest path there is.
  """
  @spec group(t(), node_id(), key(), key()) :: [term()] | nil
  def group(%__MODULE__{} = memory, node_id, key, group_key) do
    memory |> groups(node_id, key) |> Map.get(group_key)
  end

  @doc """
  Adds one member to a collection group, in front of the ones already there. O(1).

  **Reverse arrival order, and no sort.** The new list shares its whole tail with the old
  one, so adding a member allocates a single cons cell however large the group is.

  Do not reintroduce a sort here. This node used to keep members in term order, so that a
  collection's order — and not merely its membership — was a function of the fact set.
  Nothing asks for that: `docs/dsl.md` has always said a rule may not depend on the
  gathered order, so the sort could only ever help rules that were already outside the
  contract, and it charged O(k) to every member change of every collection to do it. A rule
  that needs a particular order sorts in its own right hand side, once per firing rather
  than once per member.
  """
  @spec add_to_group(t(), node_id(), key(), key(), term()) :: t()
  def add_to_group(%__MODULE__{} = memory, node_id, key, group_key, member) do
    update_group(memory, node_id, key, group_key, &[member | &1 || []])
  end

  @doc """
  Removes one occurrence of a member from a collection group, reporting whether it was
  there. O(position).

  `:absent` rather than a silent no-op, for the same reason `remove_elements/4` leaves an
  absent element out of what it returns: a caller that emitted a retract-and-resend for a
  group nothing actually changed would churn every match downstream of it.

  A group that loses its last member is dropped. The join key that held the last group
  goes with it, and so does the node, if that was its last join key. Both are binding
  values, so leaving them behind would leak one entry per entity the session has seen.
  """
  @spec remove_from_group(t(), node_id(), key(), key(), term()) :: {t(), :removed | :absent}
  def remove_from_group(%__MODULE__{} = memory, node_id, key, group_key, member) do
    case group(memory, node_id, key, group_key) do
      nil ->
        {memory, :absent}

      members ->
        case List.delete(members, member) do
          ^members -> {memory, :absent}
          rest -> {update_group(memory, node_id, key, group_key, fn _ -> rest end), :removed}
        end
    end
  end

  # --- truth maintenance ---------------------------------------------------------

  @doc """
  Records the facts one activation of a production inserted.

  This is stored as a list of lists. The same token can activate a production more than
  once, over a session's life, and each activation owns its own batch.
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

    %__MODULE__{
      memory
      | insertions: insertions,
        inserters: index_add(memory.inserters, {node_id, token}, facts)
    }
  end

  @doc """
  Takes back one batch of facts a token's activation inserted.

  Returns `{memory, facts}`, or `{memory, []}` when the token never inserted anything.
  That case is a production retracted before it fired, or one whose body returned
  nothing.
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
        inserters = index_drop(memory.inserters, {node_id, token}, batch)

        {%__MODULE__{memory | insertions: insertions, inserters: inserters}, batch}
    end
  end

  @doc """
  The matches whose activation inserted `fact`, as `{node_id, token}` pairs.

  Empty for a fact the user asserted. A fact two rules concluded has two entries, and one
  rule may appear twice if it concluded the fact on two activations of the same match.

  This is the index behind well-founded support. Reading it is a map lookup, which is the
  whole point: the answer used to be recomputed from every insertion record in the
  session, on every conclusion that was already present.

  Falls back to that recomputation when the index has not been built, so a one-off reader
  like `Rete.Inspect.derivations/2` gets a correct answer without forcing a build on a
  session that would otherwise never need one. A caller that will ask repeatedly should
  call `index_inserters/1` first and keep what it returns.
  """
  @spec inserters(t(), term()) :: [inserter()]
  def inserters(%__MODULE__{inserters: nil, insertions: insertions}, fact) do
    for {node_id, by_token} <- insertions,
        {token, batches} <- by_token,
        Enum.any?(batches, &(fact in &1)),
        do: {node_id, token}
  end

  def inserters(%__MODULE__{inserters: inserters}, fact) do
    inserters |> Map.get(fact, %{}) |> Map.keys()
  end

  @doc """
  Builds the `inserters` index if it is not built, and returns the memory holding it.

  One pass over every insertion record. After this, `add_insertion/4` and
  `take_insertion/3` keep it in step, so the pass happens at most once per session — and
  not at all in a session where no rule ever concludes what another already concluded,
  which is the only thing that consults it.
  """
  @spec index_inserters(t()) :: t()
  def index_inserters(%__MODULE__{inserters: nil} = memory) do
    index =
      for {node_id, by_token} <- memory.insertions,
          {token, batches} <- by_token,
          batch <- batches,
          fact <- batch,
          reduce: %{} do
        acc -> add_inserter(acc, fact, {node_id, token})
      end

    %__MODULE__{memory | inserters: presence(index)}
  end

  def index_inserters(%__MODULE__{} = memory), do: memory

  # --- the fact multiset ----------------------------------------------------------

  @doc """
  Records a fact, returning `{memory, :new | :duplicate}`.

  Only `:new` propagates. A second insertion of an equal fact bumps its count instead, so
  that one retraction does not remove it. The matches it would make already exist.
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

  Only `:gone` propagates — that is, only the last occurrence.
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

  Use this instead of the struct. A `Rete.Bucket` holds a queue with tombstones in it, so
  two memories that agree on every match can still disagree there. This is the view that is
  meaningful to compare, assert on, and write down.

  Note that `:accum` is **not** canonical even here: a collection group is kept in reverse
  arrival order, so two sessions holding the same members can list them differently. Sort
  it before comparing sessions that were fed differently. See `add_to_group/5`.
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
          {:error, bucket} -> {bucket, removed}
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

  # Both no-ops while the index is unbuilt. `index_inserters/1` reads `insertions`, which
  # is maintained either way, so there is nothing to catch up on when it is built later.
  defp index_add(nil, _ref, _facts), do: nil

  defp index_add(inserters, ref, facts),
    do: Enum.reduce(facts, inserters, &add_inserter(&2, &1, ref))

  defp index_drop(nil, _ref, _facts), do: nil

  # Back to `nil` once it holds nothing. An empty index and no index are the same claim,
  # and collapsing them means a session that drains fully returns to exactly the memory a
  # fresh one starts with — which several invariants compare against directly. Rebuilding
  # from an empty `insertions` costs nothing.
  defp index_drop(inserters, ref, facts) do
    facts |> Enum.reduce(inserters, &drop_inserter(&2, &1, ref)) |> presence()
  end

  # `nil` means "no entries", whether because nothing built the index or because it
  # emptied. Both readings are safe, since an absent index is rebuilt from `insertions`,
  # and collapsing them is what lets a fully drained session compare equal to a fresh one.
  defp presence(index) when index == %{}, do: nil
  defp presence(index), do: index

  # `inserters` mirrors `insertions`, one entry per occurrence of a fact in a batch. A
  # batch that names the same fact twice counts twice, so that taking the batch back
  # leaves nothing behind.
  defp add_inserter(inserters, fact, ref) do
    Map.update(inserters, fact, %{ref => 1}, &Map.update(&1, ref, 1, fn n -> n + 1 end))
  end

  # Tolerates an absent entry rather than raising. `take_insertion/3` is the only caller
  # and cannot reach one, but a mirror that crashes when it disagrees with its source is
  # worse than one that stays quiet: the property test is what catches the disagreement.
  defp drop_inserter(inserters, fact, ref) do
    case Map.get(inserters, fact) do
      nil -> inserters
      refs -> store_at(inserters, fact, unbump(refs, ref))
    end
  end

  defp unbump(counts, key) do
    case Map.get(counts, key) do
      nil -> counts
      1 -> Map.delete(counts, key)
      n -> Map.put(counts, key, n - 1)
    end
  end

  # --- collection groups ------------------------------------------------------------

  # Applies `fun` to one group's members, and collapses every level that empties behind it.
  defp update_group(%__MODULE__{} = memory, node_id, key, group_key, fun) do
    by_key = Map.get(memory.accum, node_id, %{})
    groups = Map.get(by_key, key, %{})
    members = fun.(Map.get(groups, group_key))

    by_key = store_at(by_key, key, store_at(groups, group_key, members))

    %__MODULE__{memory | accum: store_at(memory.accum, node_id, by_key)}
  end
end
