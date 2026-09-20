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
      facts       fact => occurrences                        what it was told

      inserters   fact => {node_id, token} => count          `insertions`, reversed
      dependents  fact => derived fact => count              `insertions`, as fact edges

  Neither of the last two is a memory. Both are `insertions` read another way, and both
  are left out of `dump/1`, being caches. `inserters` answers "which matches inserted *this
  fact*". `dependents` answers "which facts were concluded by a match resting on *this
  fact*", which is the same graph one step in the other direction.

  Both are `nil` until `index_support/1` builds them, and they are `nil` or built
  **together**. `nil` means "nothing is indexed", which is a claim about the records and
  not about either map. `dependents` comes out empty on records that do exist, because a
  rule anchored on the root token rests on nothing.

  **Arrival order is load-bearing.** A bucket decides the order tokens propagate, so it
  decides the order two matches of one rule fire. One that gave items back in a different
  order would reorder every `:activation_fired` event.

  `docs/design/engine.md` §4 has the other two properties, and why the index is built late.

  `root_seeded?` is not a memory. It records that the beta root's empty token has been
  planted. This must happen exactly once per session. See `docs/design/engine.md` §6.

      iex> alias Rete.Memory
      iex> memory = Memory.add_fact(Memory.new(), {:order, 1})
      iex> memory = Memory.add_fact(memory, {:order, 1})
      iex> Memory.facts(memory)
      [{:order, 1}, {:order, 1}]
      iex> {memory, :removed} = Memory.remove_fact(memory, {:order, 1})
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
          dependents: %{term() => %{term() => pos_integer()}} | nil,
          facts: %{term() => pos_integer()},
          root_seeded?: boolean()
        }

  defstruct elements: %{},
            tokens: %{},
            accum: %{},
            insertions: %{},
            inserters: nil,
            dependents: nil,
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
  The collection groups at a node under a join key, `group_key => members`.

  A member is whatever the node stored. A plain collection keeps facts, because that is
  what it binds. A filtered one keeps `Rete.Element`s, because its filter needs the bindings
  that the alpha produced. `Rete.Memory` does not interpret them.
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

  This is the list that the node gives to the rule. It is not a view built for one call.
  That is deliberate: a member change must produce the old value of the collection and the
  new one. To build either one would be O(k), on the path that runs most often.
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
  Nothing asks for that. `docs/dsl.md` has always said that a rule may not depend on the
  gathered order. The sort could thus help only the rules that were already outside the
  contract, and it charged O(k) to every member change of every collection. A rule
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

  This returns `:absent`, and not a no-op with no message. `remove_elements/4` leaves an
  absent element out of what it returns for the same reason. A caller could otherwise emit a
  retract-and-resend for a group that did not change, and disturb every match below it.

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
  once, and each activation owns its own batch. Two equal facts do that on one fire: they
  are two occurrences, so they make two matches that this store cannot tell apart.

  **Newest first.** `take_insertion/3` therefore gives back the newest batch, and the order
  is not observable. Every batch under one key is the conclusion of an equal match at one
  node. A rule body is a pure function of its bindings, so those batches are equal. The
  list used to be appended to, which cost a pass over it per activation — quadratic in the
  occurrences of one fact.
  """
  @spec add_insertion(t(), node_id(), Token.t(), [term()]) :: t()
  def add_insertion(%__MODULE__{} = memory, node_id, token, facts) do
    insertions =
      Map.update(
        memory.insertions,
        node_id,
        %{token => [facts]},
        &Map.update(&1, token, [facts], fn batches -> [facts | batches] end)
      )

    %__MODULE__{
      memory
      | insertions: insertions,
        inserters: index_add(memory.inserters, {node_id, token}, facts),
        dependents: edges_add(memory.dependents, token, facts)
    }
  end

  @doc """
  Takes back the newest batch of facts a token's activation inserted.

  Returns `{memory, facts}`, or `{memory, []}` when the token never inserted anything.
  That case is a production retracted before it fired, or one whose body returned
  nothing. See `add_insertion/4` for why the newest is as good as any.
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

        {inserters, dependents} =
          if insertions == %{} do
            {nil, nil}
          else
            {index_drop(memory.inserters, {node_id, token}, batch),
             edges_drop(memory.dependents, token, batch)}
          end

        memory = %__MODULE__{
          memory
          | insertions: insertions,
            inserters: inserters,
            dependents: dependents
        }

        {memory, batch}
    end
  end

  @doc """
  The matches whose activation inserted `fact`, as `{node_id, token}` pairs.

  Empty for a fact the user asserted. A fact two rules concluded has two entries, and one
  rule may appear twice if it concluded the fact on two activations of the same match.

  This is the index behind well-founded support. To read it is a map lookup, and that is
  the purpose of it. Before, the engine recomputed the answer from every insertion record in
  the session, for every conclusion that was already present.

  This falls back to that recomputation when the index is not built, so a reader that asks
  one time gets a correct answer without forcing a build on a session that would never need
  one. **A caller that asks repeatedly must call `index_support/1` first, and keep what it
  returns.** The fallback is a pass over every insertion record, so asking per fact without
  the index is quadratic in the size of the session. `Rete.Inspect.explain/1,2` builds it
  for that reason.
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
  The facts that were concluded by a match resting on `fact`.

  Empty for a fact no rule has matched, and for one whose matches concluded nothing. This
  is `inserters/2` pointed the other way, one step at a time: `inserters/2` asks what a
  fact rests **on**, and this asks what rests **on it**.

  `Rete.Engine` walks this to decide whether a conclusion supports itself. It walks down
  from the conclusion rather than up from the match on purpose. A fact with `k` supports
  has `k` ancestors to visit, and usually no descendants at all. It is also `k` occurrences,
  so a rule below it fires `k` times. Walking up would cost `O(k)` on each of those
  firings. See `docs/design/engine.md` §8.

  The same fallback and the same warning as `inserters/2`: call `index_support/1` first.
  """
  @spec dependents(t(), term()) :: [term()]
  def dependents(%__MODULE__{dependents: nil, insertions: insertions}, fact) do
    for {_node_id, by_token} <- insertions,
        {token, batches} <- by_token,
        fact in Token.rests_on(token),
        batch <- batches,
        derived <- batch,
        uniq: true,
        do: derived
  end

  def dependents(%__MODULE__{dependents: dependents}, fact) do
    dependents |> Map.get(fact, %{}) |> Map.keys()
  end

  @doc """
  Builds the support indexes if they are not built, and returns the memory holding them.

  One pass over every insertion record, building `inserters` and `dependents` together.
  After this, `add_insertion/4` and `take_insertion/3` keep both in step. The pass thus
  happens one time in a session at most. It does not happen at all in a session where no
  rule concludes what another rule already concluded, because only that consults them.
  """
  @spec index_support(t()) :: t()
  def index_support(%__MODULE__{inserters: nil} = memory) do
    {inserters, dependents} = build_support(memory.insertions)

    %__MODULE__{memory | inserters: inserters, dependents: dependents}
  end

  def index_support(%__MODULE__{} = memory), do: memory

  # `nil` for both, or a map for both. Having no records to index is what decides it, and
  # not either map coming out empty. `dependents` is legitimately empty on records that are
  # there: a rule anchored on the root token rests on nothing, so it writes no edge. Reading
  # that emptiness as "not built" would leave the index `nil` next to live records, and
  # every later edge would be dropped on the floor by `edges_add/3`.
  defp build_support(insertions) when insertions == %{}, do: {nil, nil}

  defp build_support(insertions) do
    for {node_id, by_token} <- insertions,
        {token, batches} <- by_token,
        rests_on = Token.rests_on(token),
        batch <- batches,
        fact <- batch,
        reduce: {%{}, %{}} do
      {inserters, dependents} ->
        {add_inserter(inserters, fact, {node_id, token}),
         Enum.reduce(rests_on, dependents, &add_inserter(&2, &1, fact))}
    end
  end

  # --- the fact multiset ----------------------------------------------------------

  @doc """
  Records one occurrence of a fact.

  Every occurrence counts, and every occurrence propagates. A fact equal to one already
  present is a second occurrence of it, not a repeat of the first.
  """
  @spec add_fact(t(), term()) :: t()
  def add_fact(%__MODULE__{facts: facts} = memory, fact) do
    %__MODULE__{memory | facts: Map.update(facts, fact, 1, &(&1 + 1))}
  end

  @doc """
  Drops one occurrence of a fact, returning `{memory, :removed | :absent}`.

  Only `:removed` propagates. `:absent` says the session never held the fact, so there is
  no match to take back.
  """
  @spec remove_fact(t(), term()) :: {t(), :removed | :absent}
  def remove_fact(%__MODULE__{facts: facts} = memory, fact) do
    case Map.get(facts, fact) do
      nil -> {memory, :absent}
      1 -> {%__MODULE__{memory | facts: Map.delete(facts, fact)}, :removed}
      n -> {%__MODULE__{memory | facts: Map.put(facts, fact, n - 1)}, :removed}
    end
  end

  @doc """
  Every fact the session holds, one entry for each occurrence.
  """
  @spec facts(t()) :: [term()]
  def facts(%__MODULE__{facts: facts}) do
    Enum.flat_map(facts, fn {fact, count} -> List.duplicate(fact, count) end)
  end

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

  # Both no-ops while the index is unbuilt. `index_support/1` reads `insertions`, which
  # is maintained either way, so there is nothing to catch up on when it is built later.
  defp index_add(nil, _ref, _facts), do: nil

  defp index_add(inserters, ref, facts),
    do: Enum.reduce(facts, inserters, &add_inserter(&2, &1, ref))

  defp index_drop(nil, _ref, _facts), do: nil

  # No collapse to `nil` here. `take_insertion/3` decides that, for both indexes together,
  # on whether any record is left. See `build_support/1`.
  defp index_drop(inserters, ref, facts) do
    Enum.reduce(facts, inserters, &drop_inserter(&2, &1, ref))
  end

  # `dependents` is the same shape one level over: `fact => derived fact => count`. One
  # edge per (fact the match rested on, fact it concluded), so a match resting on three
  # facts and concluding two writes six. `add_inserter/3` builds both, the "ref" being a
  # match in one and a concluded fact in the other.
  defp edges_add(nil, _token, _facts), do: nil

  defp edges_add(dependents, token, facts) do
    for rested <- Token.rests_on(token), derived <- facts, reduce: dependents do
      acc -> add_inserter(acc, rested, derived)
    end
  end

  defp edges_drop(nil, _token, _facts), do: nil

  defp edges_drop(dependents, token, facts) do
    for rested <- Token.rests_on(token), derived <- facts, reduce: dependents do
      acc -> drop_inserter(acc, rested, derived)
    end
  end

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
