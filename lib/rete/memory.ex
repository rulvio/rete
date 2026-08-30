defmodule Rete.Memory do
  @moduledoc """
  Working memory: everything a session knows, as one immutable value.

  Clara keeps two memories — a mutable "transient" one used while rules fire and
  a persistent one between calls — and converts between them. That duality is a
  JVM performance artifact. Here there is one immutable struct threaded through
  the propagation loop, which is both simpler and what makes a session a value
  you can hold, compare and share.

  ## The five memories

      elements    node_id => join_key => [Element]   right side of a beta node
      tokens      node_id => join_key => [Token]     left side of a beta node
      accum       node_id => join_key => group_key => [fact]
      insertions  node_id => token => [[fact]]       truth maintenance
      facts       fact => count                      what the session was told

  `elements` and `tokens` are keyed twice: by node, then by the join key, so a
  join is a map lookup rather than a scan. `accum` is keyed three times because
  a collection binding that introduces a new variable groups by it.

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
  applies to `elements` and `tokens`, which are lists rather than sets and are
  retracted one occurrence at a time.
  """

  alias Rete.Element
  alias Rete.Token

  @type node_id :: term()
  @type key :: %{atom() => term()}

  @type t :: %__MODULE__{
          elements: %{node_id() => %{key() => [Element.t()]}},
          tokens: %{node_id() => %{key() => [Token.t()]}},
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

  @doc "The elements stored at a node under a join key."
  @spec elements(t(), node_id(), key()) :: [Element.t()]
  def elements(%__MODULE__{elements: elements}, node_id, key) do
    elements |> Map.get(node_id, %{}) |> Map.get(key, [])
  end

  @doc "Every element at a node, whatever its join key."
  @spec all_elements(t(), node_id()) :: [Element.t()]
  def all_elements(%__MODULE__{elements: elements}, node_id) do
    elements |> Map.get(node_id, %{}) |> Map.values() |> List.flatten()
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

  @doc "The tokens stored at a node under a join key."
  @spec tokens(t(), node_id(), key()) :: [Token.t()]
  def tokens(%__MODULE__{tokens: tokens}, node_id, key) do
    tokens |> Map.get(node_id, %{}) |> Map.get(key, [])
  end

  @doc "Every token at a node, whatever its join key."
  @spec all_tokens(t(), node_id()) :: [Token.t()]
  def all_tokens(%__MODULE__{tokens: tokens}, node_id) do
    tokens |> Map.get(node_id, %{}) |> Map.values() |> List.flatten()
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

  # --- shared helpers ---------------------------------------------------------------

  defp push(store, node_id, key, new) do
    Map.update(store, node_id, %{key => new}, fn by_key ->
      Map.update(by_key, key, new, &(&1 ++ new))
    end)
  end

  # Removes one occurrence of each target, by value. Anything not present is
  # left out of `removed`, so the caller never propagates a phantom retraction.
  defp pop(store, node_id, key, targets) do
    by_key = Map.get(store, node_id, %{})
    stored = Map.get(by_key, key, [])

    {remaining, removed} =
      Enum.reduce(targets, {stored, []}, fn target, {remaining, removed} ->
        case delete_first(remaining, target) do
          {:ok, rest} -> {rest, [target | removed]}
          :error -> {remaining, removed}
        end
      end)

    by_key = store_at(by_key, key, remaining)

    {store_at(store, node_id, by_key), Enum.reverse(removed)}
  end

  # Stores a level, or removes it when nothing is left in it. Every key above the
  # leaf is a binding value, so an entry left pointing at nothing is a leak that
  # grows with the number of entities the session has seen, not a tidy-up.
  defp store_at(map, key, contents) when contents in [[], %{}], do: Map.delete(map, key)
  defp store_at(map, key, contents), do: Map.put(map, key, contents)

  defp delete_first(list, target) do
    case Enum.split_while(list, &(&1 != target)) do
      {_before, []} -> :error
      {before, [_hit | rest]} -> {:ok, before ++ rest}
    end
  end
end
