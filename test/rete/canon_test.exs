defmodule Rete.CanonTest do
  @moduledoc """
  `Rete.Test.Canon` decides what the property suite is allowed to see, so what it
  normalizes away has to be pinned as carefully as any engine behavior. A canon
  that sorted too much would hide real ordering bugs and every suite would stay
  green.
  """

  use ExUnit.Case, async: true

  alias Rete.Session
  alias Rete.Test.Canon

  defmodule Lists do
    use Rete.Ruleset

    # `items` is a list the *fact* carries. Nothing about its order is the
    # engine's doing, so nothing may reorder it.
    defrule carried({:box, id, items}) do
      {:carried, id, length(items)}
    end

    # `items` again, and deliberately: the same variable name, this time bound by
    # a collection. One name, two meanings, in one session.
    defrule gathered({:crate, id}, items = [{:part, id, _n}]) do
      {:gathered, id, length(items)}
    end

    defquery carried_q({:box, id, items}), do: {id, items}

    # A query over a collection, so a query row is kept against a token that carries one.
    defquery gathered_q({:crate, id}, parts = [{:part, id, _n}]), do: {id, length(parts)}
  end

  defp tokens(session) do
    session
    |> Canon.dump()
    |> Map.fetch!(:tokens)
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.concat()
    |> Enum.map(fn
      {token, _row} -> token
      token -> token
    end)
  end

  defp binding(session, name) do
    for token <- tokens(session), value = token.bindings[name], do: value
  end

  describe "what is left alone" do
    test "a list a fact carries is not sorted" do
      session =
        [Lists]
        |> Session.new()
        |> Session.insert({:box, 1, [3, 1, 2]})
        |> Session.fire_rules()

      assert [[3, 1, 2]] == binding(session, :items)
    end

    test "and it still reaches the rule and the query in the order it was given" do
      session =
        [Lists]
        |> Session.new()
        |> Session.insert({:box, 1, [3, 1, 2]})
        |> Session.fire_rules()

      assert [{1, [3, 1, 2]}] == Lists.carried_q(session)
    end
  end

  describe "what is normalized" do
    test "a collection binding is sorted" do
      # Fed in descending order, so reverse arrival order is ascending and a
      # canon that did nothing would still look sorted. Assert against the
      # feed instead: both orders have to canonicalize the same way.
      parts = [{:part, 1, 1}, {:part, 1, 2}, {:part, 1, 3}]

      forwards = build(Lists, [{:crate, 1} | parts])
      backwards = build(Lists, [{:crate, 1} | Enum.reverse(parts)])

      assert Canon.dump(forwards) == Canon.dump(backwards)
      refute forwards.state.memory == backwards.state.memory
    end
  end

  describe "what still shows" do
    # A query keeps its rows apart from its bucket. A canon that left them out would let a
    # wrong row pass every comparison.
    test "a query row shows" do
      session = build(Lists, [{:box, 1, [3, 1, 2]}])
      rows = session.state.memory.query_rows

      assert map_size(rows) == 1

      changed =
        put_in(session.state.memory.query_rows, map_lists(rows, fn _rows -> [:other] end))

      refute Canon.dump(session) == Canon.dump(changed)
    end

    # One session cannot hold two tokens that differ only in the order of a collection. So
    # the second token is put in by hand. A canon that let one replace the other would lose
    # a batch and a row, and multiplicity would no longer show.
    test "two tokens equal up to collection order keep both of their lists" do
      session = build(Lists, [{:crate, 1}, {:part, 1, 1}, {:part, 1, 2}])
      memory = session.state.memory

      changed =
        put_in(session.state.memory, %{
          memory
          | insertions: with_reversed(memory.insertions),
            query_rows: with_reversed(memory.query_rows)
        })

      dumped = Canon.dump(session)
      doubled = Canon.dump(changed)

      for store <- [:insertions, :query_rows] do
        assert map_lists(dumped[store], &Enum.sort(&1 ++ &1)) == doubled[store],
               "#{store} lost the list of one token"
      end
    end
  end

  describe "one name, two meanings" do
    # The reason `Rete.Test.Canon` reads a token's own matches rather than
    # collecting every collection binding name in the network: `items` is a
    # collection in one rule and a fact's own field in another, and only the
    # first may be sorted.
    test "the fact's list is untouched while the collection's is sorted" do
      facts = [{:box, 1, [3, 1, 2]}, {:crate, 1}, {:part, 1, 1}, {:part, 1, 2}]

      forwards = build(Lists, facts)
      backwards = build(Lists, Enum.reverse(facts))

      assert Canon.dump(forwards) == Canon.dump(backwards),
             "the collection made two feeds differ after canonicalizing"

      assert [3, 1, 2] in binding(forwards, :items),
             "the fact's own list was sorted"
    end
  end

  defp map_lists(store, fun) do
    Map.new(store, fn {id, by_token} ->
      {id, Map.new(by_token, fn {token, list} -> {token, fun.(list)} end)}
    end)
  end

  # Adds, for each token, a copy with its lists reversed. In these sessions every list in
  # a token is a collection, because no fact carries one.
  defp with_reversed(store) do
    Map.new(store, fn {id, by_token} ->
      copies =
        for {token, list} <- by_token,
            reversed = reverse(token),
            reversed != token,
            into: %{},
            do: {reversed, list}

      assert map_size(copies) == map_size(by_token), "a token had no collection to reverse"
      {id, Map.merge(by_token, copies)}
    end)
  end

  defp reverse(%Rete.Token{} = token) do
    flip = fn
      list when is_list(list) -> Enum.reverse(list)
      other -> other
    end

    %Rete.Token{
      matches: Enum.map(token.matches, fn {matched, id} -> {flip.(matched), id} end),
      bindings: Map.new(token.bindings, fn {name, value} -> {name, flip.(value)} end)
    }
  end

  defp build(module, facts) do
    [module] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end
end
