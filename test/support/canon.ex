defmodule Rete.Test.Canon do
  @moduledoc """
  Puts a memory dump into a form two differently-fed sessions can be compared in.

  A collection is kept in **reverse arrival order** (`Rete.Memory.add_to_group/5`), so two
  sessions holding exactly the same members list them differently. `docs/dsl.md` says that
  order is not a contract, and this is what saying so costs: anything carrying a collection
  — a token, and therefore every memory keyed on one — has to be sorted before two feeds
  can be compared.

  Deliberately blunt: it sorts **any** list-valued binding or matched term, not only the
  ones a collection produced. That is sound for these suites because no fact in their
  fixtures carries a list of its own. It hides order and nothing else — multiplicity and
  content still show, so a support imbalance or a lost member is still caught.
  """

  alias Rete.Memory
  alias Rete.Token

  @doc """
  A whole dump, canonicalised: every leaf list sorted, every token's collections sorted.
  """
  @spec dump(Memory.t()) :: map()
  def dump(%Memory{} = memory) do
    dumped = Memory.dump(memory)

    %{
      elements: sort_leaves(dumped.elements),
      tokens: sort_leaves(map_leaves(dumped.tokens, &Enum.map(&1, fn t -> token(t) end))),
      accum: Map.new(dumped.accum, fn {id, by_key} -> {id, sort_leaves(by_key)} end),
      insertions: Map.new(dumped.insertions, fn {id, by_token} -> {id, batches(by_token)} end),
      inserters:
        Map.new(dumped.inserters, fn {fact, refs} ->
          {fact, Map.new(refs, fn {{id, t}, n} -> {{id, token(t)}, n} end)}
        end),
      facts: dumped.facts,
      root_seeded?: dumped.root_seeded?
    }
  end

  @doc """
  One token, with any collection it carries sorted.
  """
  @spec token(Token.t()) :: Token.t()
  def token(%Token{} = token) do
    %Token{
      matches: Enum.map(token.matches, fn {matched, id} -> {sorted(matched), id} end),
      bindings: Map.new(token.bindings, fn {name, value} -> {name, sorted(value)} end)
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

  defp sorted(list) when is_list(list), do: Enum.sort(list)
  defp sorted(other), do: other

  defp map_leaves(store, fun) do
    Map.new(store, fn {node_id, by_key} ->
      {node_id, Map.new(by_key, fn {key, list} -> {key, fun.(list)} end)}
    end)
  end

  defp batches(by_token) do
    Map.new(by_token, fn {t, batches} ->
      {token(t), Enum.sort(Enum.map(batches, &Enum.sort/1))}
    end)
  end
end
