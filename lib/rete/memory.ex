defmodule Rete.Memory do
  @moduledoc """
  Working memory: everything a session knows, as one immutable value.

  **Internal.** Not part of the public API. It is documented rather than hidden, because
  durability, checkpointing, and advanced tooling will need to reach in here. Treat its
  functions as liable to change.

  Six memories, plus one flag:

      elements    node_id => join_key => Bucket of Element   right of a beta node
      tokens      node_id => join_key => Bucket of Token     left of a beta node
      accum       node_id => join_key => group_key => tree   what a collection gathered
      insertions  node_id => token => [[fact]]               truth maintenance
      inserters   fact => {node_id, token} => count          the same, read backwards
      facts       fact => count                              what it was told

  `inserters` holds nothing `insertions` does not. It is the same relation indexed the
  other way, and it is maintained in step rather than derived on demand, because the two
  readers both ask "which matches inserted *this fact*" — `Rete.Engine.well_founded/3` on
  every conclusion that is already present, and `Rete.Inspect.derivations/2` per fact. Both
  used to answer that with a pass over every insertion record in the session, which made
  two rules concluding one fact quadratic. It is a multiset keyed on `{node_id, token}`,
  rather than a list, so that two memories holding the same matches compare equal whatever
  order they were reached in.

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

  @typedoc """
  One collection group: its members as an ordered multiset, keyed on `{fact, bindings}`.

  A tree rather than a list, so that adding and removing a member cost O(log k) instead of
  a walk. Filling one collection was quadratic while it was a list, because ordered
  insertion had to find the position by walking. Read it with `group/4` or `groups/3`,
  which render it as a list.
  """
  @type member_tree :: :gb_trees.tree({term(), key()}, {Element.t(), pos_integer()})

  @type t :: %__MODULE__{
          elements: %{node_id() => %{key() => Bucket.t()}},
          tokens: %{node_id() => %{key() => Bucket.t()}},
          accum: %{node_id() => %{key() => %{key() => member_tree()}}},
          insertions: %{node_id() => %{Token.t() => [[term()]]}},
          inserters: %{term() => %{inserter() => pos_integer()}},
          facts: %{term() => pos_integer()},
          root_seeded?: boolean()
        }

  defstruct elements: %{},
            tokens: %{},
            accum: %{},
            insertions: %{},
            inserters: %{},
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
  The collection groups at a node under a join key, `group_key => elements`.

  Each group comes back as a list, in member order. Building that list is O(k), so a
  caller that wants one group should ask for `group/4` instead of filtering this.
  """
  @spec groups(t(), node_id(), key()) :: %{key() => [Element.t()]}
  def groups(%__MODULE__{accum: accum}, node_id, key) do
    accum
    |> Map.get(node_id, %{})
    |> Map.get(key, %{})
    |> Map.new(fn {group_key, tree} -> {group_key, members(tree)} end)
  end

  @doc """
  The group keys a node holds under a join key, without reading any of the groups.
  """
  @spec group_keys(t(), node_id(), key()) :: [key()]
  def group_keys(%__MODULE__{accum: accum}, node_id, key) do
    accum |> Map.get(node_id, %{}) |> Map.get(key, %{}) |> Map.keys()
  end

  @doc """
  The members of one collection group, in member order, or `nil` if there is no such
  group.

  `nil` and `[]` are different answers. A group with no members does not exist; an empty
  collection a rule can legitimately see is `[]`, and only `Rete.Engine.Nodes` knows which
  of the two an absent group means. See `remove_from_group/5`.
  """
  @spec group(t(), node_id(), key(), key()) :: [Element.t()] | nil
  def group(%__MODULE__{} = memory, node_id, key, group_key) do
    case tree(memory, node_id, key, group_key) do
      nil -> nil
      tree -> members(tree)
    end
  end

  @doc """
  The facts of one collection group, in member order, or `nil` if there is no such group.

  The same list `group/4` returns, with the bindings left off. A collection with no filter
  binds the facts and nothing reads the bindings, and that is the common case on the
  hottest path there is — a group is read twice on every member change, so building an
  `Rete.Element` per member and mapping it away again costs two passes that buy nothing.
  """
  @spec group_facts(t(), node_id(), key(), key()) :: [term()] | nil
  def group_facts(%__MODULE__{} = memory, node_id, key, group_key) do
    case tree(memory, node_id, key, group_key) do
      nil -> nil
      tree -> collect(:gb_trees.iterator(tree), [], & &1.fact)
    end
  end

  @doc """
  Adds one element to a collection group. O(log k).
  """
  @spec add_to_group(t(), node_id(), key(), key(), Element.t()) :: t()
  def add_to_group(%__MODULE__{} = memory, node_id, key, group_key, element) do
    update_group(memory, node_id, key, group_key, fn tree ->
      member = order_key(element)

      :gb_trees.enter(member, {element, occurrences(tree, member) + 1}, tree)
    end)
  end

  @doc """
  Removes one occurrence of an element from a collection group, reporting whether it was
  there. O(log k).

  `:absent` rather than a silent no-op, for the same reason `remove_elements/4` leaves an
  absent element out of what it returns: a caller that emitted a retract-and-resend for a
  group nothing actually changed would churn every match downstream of it.

  A group that loses its last member is dropped. The join key that held the last group
  goes with it, and so does the node, if that was its last join key. Both are binding
  values, so leaving them behind would leak one entry per entity the session has seen.
  """
  @spec remove_from_group(t(), node_id(), key(), key(), Element.t()) ::
          {t(), :removed | :absent}
  def remove_from_group(%__MODULE__{} = memory, node_id, key, group_key, element) do
    member = order_key(element)
    tree = tree(memory, node_id, key, group_key)

    case tree && occurrences(tree, member) do
      falsy when falsy in [nil, false, 0] ->
        {memory, :absent}

      1 ->
        {update_group(memory, node_id, key, group_key, &:gb_trees.delete(member, &1)), :removed}

      n ->
        {update_group(
           memory,
           node_id,
           key,
           group_key,
           &:gb_trees.update(member, {element, n - 1}, &1)
         ), :removed}
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

    ref = {node_id, token}

    %__MODULE__{
      memory
      | insertions: insertions,
        inserters: Enum.reduce(facts, memory.inserters, &add_inserter(&2, &1, ref))
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
        ref = {node_id, token}
        inserters = Enum.reduce(batch, memory.inserters, &drop_inserter(&2, &1, ref))

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
  """
  @spec inserters(t(), term()) :: [inserter()]
  def inserters(%__MODULE__{inserters: inserters}, fact) do
    inserters |> Map.get(fact, %{}) |> Map.keys()
  end

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

  Use this instead of the struct. Two memories that agree on every match can still disagree
  underneath: a `Rete.Bucket` holds a queue with tombstones in it, and a collection group
  is a tree whose shape depends on the order its members arrived. This is the view that is
  meaningful to compare, assert on, and write down.
  """
  @spec dump(t()) :: %{
          elements: %{node_id() => %{key() => [Element.t()]}},
          tokens: %{node_id() => %{key() => [Token.t()]}},
          accum: %{node_id() => %{key() => %{key() => [Element.t()]}}},
          insertions: %{node_id() => %{Token.t() => [[term()]]}},
          inserters: %{term() => %{inserter() => pos_integer()}},
          facts: %{term() => pos_integer()},
          root_seeded?: boolean()
        }
  def dump(%__MODULE__{} = memory) do
    %{
      elements: listed(memory.elements),
      tokens: listed(memory.tokens),
      accum: listed_groups(memory.accum),
      insertions: memory.insertions,
      inserters: memory.inserters,
      facts: memory.facts,
      root_seeded?: memory.root_seeded?
    }
  end

  defp listed(store) do
    Map.new(store, fn {node_id, by_key} ->
      {node_id, Map.new(by_key, fn {key, bucket} -> {key, Bucket.to_list(bucket)} end)}
    end)
  end

  defp listed_groups(accum) do
    Map.new(accum, fn {node_id, by_key} ->
      {node_id,
       Map.new(by_key, fn {key, groups} ->
         {key, Map.new(groups, fn {group_key, tree} -> {group_key, members(tree)} end)}
       end)}
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

  # A group is kept in the term order of its members, not arrival order. What a rule
  # concludes has to be a function of the fact set. Under arrival order, `hd(orders)` would
  # depend on how the session was fed, and a retract-and-reinsert round trip would move a
  # member to the end and change the conclusion.
  #
  # The fact comes first, because that is what the rule sees. The bindings break ties
  # between two elements over the same fact, which makes the order total. Ordering on the
  # `Rete.Element` struct itself would not do the same thing: a struct is a map, so term
  # order would compare `:bindings` before `:fact`.
  defp order_key(%Element{fact: fact, bindings: bindings}), do: {fact, bindings}

  # The element is stored alongside its count, rather than rebuilt from the key it was
  # derived from. Reading a group is on the hot path of every collection change, and
  # allocating a struct per member there costs more than holding one does.
  defp members(tree), do: collect(:gb_trees.iterator(tree), [], & &1)

  # Walks the tree in member order in one pass. `Enum.flat_map/2` over `:gb_trees.values/1`
  # would build the intermediate list as well as the result, and both of those are per
  # member.
  defp collect(iterator, acc, project) do
    case :gb_trees.next(iterator) do
      :none ->
        Enum.reverse(acc)

      {_member, {element, 1}, iterator} ->
        collect(iterator, [project.(element) | acc], project)

      {_member, {element, n}, iterator} ->
        # Equal members, so their order among themselves cannot be observed.
        collect(iterator, List.duplicate(project.(element), n) ++ acc, project)
    end
  end

  defp tree(%__MODULE__{accum: accum}, node_id, key, group_key) do
    accum |> Map.get(node_id, %{}) |> Map.get(key, %{}) |> Map.get(group_key)
  end

  defp occurrences(tree, member) do
    case :gb_trees.lookup(member, tree) do
      {:value, {_element, n}} -> n
      :none -> 0
    end
  end

  # Applies `fun` to one group's tree, and collapses every level that empties behind it.
  defp update_group(%__MODULE__{} = memory, node_id, key, group_key, fun) do
    by_key = Map.get(memory.accum, node_id, %{})
    groups = Map.get(by_key, key, %{})
    tree = fun.(Map.get(groups, group_key) || :gb_trees.empty())

    groups =
      if :gb_trees.is_empty(tree),
        do: Map.delete(groups, group_key),
        else: Map.put(groups, group_key, tree)

    by_key = store_at(by_key, key, groups)

    %__MODULE__{memory | accum: store_at(memory.accum, node_id, by_key)}
  end
end
