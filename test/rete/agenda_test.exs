defmodule Rete.AgendaTest do
  use ExUnit.Case, async: true

  alias Rete.Activation
  alias Rete.Agenda
  alias Rete.Token

  defp activation(opts) do
    %Activation{
      node_id: Keyword.get(opts, :node_id, :n),
      token: %Token{bindings: Keyword.get(opts, :bindings, %{})},
      salience: Keyword.get(opts, :salience, 0),
      internal_salience: Keyword.get(opts, :internal_salience, 0),
      order: Keyword.get(opts, :order, 0)
    }
  end

  defp drain(agenda, acc \\ []) do
    case Agenda.pop(agenda) do
      :empty -> Enum.reverse(acc)
      {:ok, activation, rest} -> drain(rest, [activation.node_id | acc])
    end
  end

  # Each tier is exercised on its own, because in a real network they correlate:
  # a generated negation helper gets both a higher :internal_salience and a lower
  # node id, so a bug in either tier is invisible while the other still ranks it
  # first. These build the activations directly so the tiers can disagree.
  describe "ordering tiers" do
    test "salience comes first, highest wins" do
      agenda =
        Enum.reduce(
          [
            activation(node_id: :low, salience: 1, order: 0),
            activation(node_id: :high, salience: 100, order: 1),
            activation(node_id: :mid, salience: 50, order: 2)
          ],
          Agenda.new(),
          &Agenda.add(&2, &1)
        )

      assert [:high, :mid, :low] == drain(agenda)
    end

    test "internal salience breaks a salience tie, even against compile order" do
      agenda =
        Enum.reduce(
          [
            activation(node_id: :user_rule, salience: 0, internal_salience: 0, order: 0),
            activation(node_id: :helper, salience: 0, internal_salience: 1, order: 99)
          ],
          Agenda.new(),
          &Agenda.add(&2, &1)
        )

      # The helper was compiled last and still goes first.
      assert [:helper, :user_rule] == drain(agenda)
    end

    test "user salience outranks internal salience" do
      agenda =
        Enum.reduce(
          [
            activation(node_id: :helper, salience: 0, internal_salience: 9),
            activation(node_id: :urgent, salience: 10, internal_salience: 0)
          ],
          Agenda.new(),
          &Agenda.add(&2, &1)
        )

      assert [:urgent, :helper] == drain(agenda)
    end

    test "compile order breaks a full tie" do
      agenda =
        Enum.reduce(
          [
            activation(node_id: :third, order: 3),
            activation(node_id: :first, order: 1),
            activation(node_id: :second, order: 2)
          ],
          Agenda.new(),
          &Agenda.add(&2, &1)
        )

      assert [:first, :second, :third] == drain(agenda)
    end

    test "nested negation helpers order inner before outer" do
      # Rete.Compiler.Negation gives depth as internal salience, so an inner
      # helper outranks the outer one that negates its marker.
      agenda =
        Enum.reduce(
          [
            activation(node_id: :rule, internal_salience: 0),
            activation(node_id: :outer, internal_salience: 1),
            activation(node_id: :inner, internal_salience: 2)
          ],
          Agenda.new(),
          &Agenda.add(&2, &1)
        )

      assert [:inner, :outer, :rule] == drain(agenda)
    end
  end

  describe "removal" do
    test "an activation is removed by value, not identity" do
      original = activation(node_id: :n, bindings: %{x: 1})
      agenda = Agenda.add(Agenda.new(), original)

      twin = activation(node_id: :n, bindings: %{x: 1})
      assert {agenda, :removed} = Agenda.remove(agenda, twin)
      assert [] == Agenda.to_list(agenda)
      assert 0 == Agenda.size(agenda), "the count has to come back down with the list"
    end

    test "removing one that already fired reports it as missing" do
      assert {_agenda, :missing} = Agenda.remove(Agenda.new(), activation(node_id: :n))
    end

    test "removal takes one from the middle and leaves the order intact" do
      agenda =
        Enum.reduce(
          [
            activation(node_id: :a, order: 1),
            activation(node_id: :b, order: 2),
            activation(node_id: :c, order: 3)
          ],
          Agenda.new(),
          &Agenda.add(&2, &1)
        )

      {agenda, :removed} = Agenda.remove(agenda, activation(node_id: :b, order: 2))
      assert [:a, :c] == drain(agenda)
    end
  end
end
