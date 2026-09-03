defmodule Rete.Test.Canon do
  @moduledoc """
  Puts a session's memory into a form two differently-fed sessions can be compared in.

  A collection is kept in **reverse arrival order** (`Rete.Memory.add_to_group/5`), so two
  sessions holding the same members list them differently. That order is not a contract.
  Anything carrying a collection has to be sorted before two feeds can be compared, which
  means a token, and every memory keyed on one.

  **Only collections are sorted.** This takes a session rather than a memory, so it can ask
  the network which nodes are collections. A token's matches are `{matched, node_id}` pairs,
  so the node that produced each one is known. A binding is sorted only when that same token
  has a match at a collection node writing that name. A rule binding a list out of a fact's
  own field is left alone, and so is a rule that reuses a collection's variable name.

  Order is all it hides. Multiplicity and content still show, so a lost member, a duplicated
  one, or a support imbalance is still caught.

  `Rete.Memory.dump/1` already leaves out `:inserters`, a cache built on first use rather
  than part of what a session is. It has its own properties.
  """

  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Session
  alias Rete.Token

  @typedoc "Collection node id => the binding name it writes, or `nil` if it writes none."
  @type collections :: %{term() => atom() | nil}

  @doc """
  A whole memory, canonicalized: every leaf list sorted, every collection sorted.
  """
  @spec dump(Session.t()) :: map()
  def dump(%Session{state: %{memory: memory}} = session) do
    collections = collections(session)
    dumped = Memory.dump(memory)

    %{
      elements: sort_leaves(dumped.elements),
      tokens:
        sort_leaves(map_leaves(dumped.tokens, &Enum.map(&1, fn t -> token(t, collections) end))),
      accum: Map.new(dumped.accum, fn {id, by_key} -> {id, sort_leaves(by_key)} end),
      insertions:
        Map.new(dumped.insertions, fn {id, by_token} ->
          {id, batches(by_token, collections)}
        end),
      facts: dumped.facts,
      root_seeded?: dumped.root_seeded?
    }
  end

  @doc """
  The collection nodes of a session's network, as `node_id => binding name or nil`.
  """
  @spec collections(Session.t()) :: collections()
  def collections(%Session{} = session) do
    session
    |> Session.network()
    |> Network.beta_nodes()
    |> Enum.filter(&collection?/1)
    |> Map.new(&{&1.id, &1.coll_binding})
  end

  @doc """
  One token, with the collections it carries sorted and nothing else touched.
  """
  @spec token(Token.t(), collections()) :: Token.t()
  def token(%Token{} = token, collections) do
    # The names this particular token got from a collection. Read off its own matches
    # rather than from the network at large, so a name another rule uses for something
    # that is not a collection is not swept up with it.
    names =
      for {_matched, id} <- token.matches,
          name = Map.get(collections, id),
          into: MapSet.new(),
          do: name

    %Token{
      matches:
        Enum.map(token.matches, fn {matched, id} ->
          {sorted(matched, Map.has_key?(collections, id)), id}
        end),
      bindings:
        Map.new(token.bindings, fn {name, value} ->
          {name, sorted(value, MapSet.member?(names, name))}
        end)
    }
  end

  @doc """
  Sorts every leaf list of a nested `key => ... => [item]` map.
  """
  @spec sort_leaves(map()) :: map()
  def sort_leaves(by_key) do
    Map.new(by_key, fn
      {key, list} when is_list(list) -> {key, Enum.sort(list)}
      {key, map} when is_map(map) -> {key, sort_leaves(map)}
    end)
  end

  defp collection?(%Node.Accumulate{}), do: true
  defp collection?(%Node.AccumulateJoin{}), do: true
  defp collection?(_node), do: false

  # The `is_list/1` guard is belt and braces: a collection binding is always a list, so
  # reaching this with anything else would mean the node ids or names disagreed with the
  # token, and sorting is not the place to find that out.
  defp sorted(list, true) when is_list(list), do: Enum.sort(list)
  defp sorted(value, _collection?), do: value

  defp map_leaves(store, fun) do
    Map.new(store, fn {node_id, by_key} ->
      {node_id, Map.new(by_key, fn {key, list} -> {key, fun.(list)} end)}
    end)
  end

  defp batches(by_token, collections) do
    Map.new(by_token, fn {t, batches} ->
      {token(t, collections), Enum.sort(Enum.map(batches, &Enum.sort/1))}
    end)
  end
end
