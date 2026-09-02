defmodule Rete.CanonTest do
  @moduledoc """
  `Rete.Test.Canon` decides what the property suite is allowed to see, so what it
  normalises away has to be pinned as carefully as any engine behaviour. A canon
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
  end

  defp tokens(session) do
    session
    |> Canon.dump()
    |> Map.fetch!(:tokens)
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.concat()
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

  describe "what is normalised" do
    test "a collection binding is sorted" do
      # Fed in descending order, so reverse arrival order is ascending and a
      # canon that did nothing would still look sorted. Assert against the
      # feed instead: both orders have to canonicalise the same way.
      parts = [{:part, 1, 1}, {:part, 1, 2}, {:part, 1, 3}]

      forwards = build(Lists, [{:crate, 1} | parts])
      backwards = build(Lists, [{:crate, 1} | Enum.reverse(parts)])

      assert Canon.dump(forwards) == Canon.dump(backwards)
      refute forwards.state.memory == backwards.state.memory
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
             "the collection made two feeds differ after canonicalising"

      assert [3, 1, 2] in binding(forwards, :items),
             "the fact's own list was sorted"
    end
  end

  defp build(module, facts) do
    [module] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end
end
