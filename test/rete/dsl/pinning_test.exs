defmodule Rete.DSL.PinningTest do
  @moduledoc """
  Regression tests for LHS forms that used to fail to compile, each naming a
  generated function in the error rather than the rule the user wrote.

  Every condition becomes its own function in the ruleset module, so anything
  that depends on the surrounding scope has to be resolved before it gets
  there.
  """

  use ExUnit.Case, async: true

  defmodule Pins do
    use Rete.Ruleset

    @lim 5

    defrule(attr({:order, ^@lim, x}), do: {:attr, x})
    defrule(literal({:order, ^7, x}), do: {:literal, x})
    defrule(upstream({:threshold, amt}, {:order, ^amt}), do: {:upstream, amt})
  end

  defp rule(mod, name), do: Enum.find(mod.get_rule_data(), &(&1.name == name))
  defp alpha(mod, name), do: hd(rule(mod, name).lhs).alpha

  describe "pinning" do
    test "a pinned module attribute matches its value" do
      fun = alpha(Pins, :attr).fun

      assert %{x: 1} == fun.({:order, 5, 1})
      assert nil == fun.({:order, 9, 1})
    end

    test "a pinned literal matches that literal" do
      fun = alpha(Pins, :literal).fun

      assert %{x: 1} == fun.({:order, 7, 1})
      assert nil == fun.({:order, 9, 1})
    end

    # Sharing a variable between conditions is already how this DSL spells a
    # join, so pinning one is the explicit spelling of the same thing and has
    # to produce the same join key. This used to fail to compile entirely:
    # `undefined variable ^amt ... in __fact_order_bind_expr_N__/1`.
    test "a pinned upstream variable is a hash join key, not a filter" do
      order = Enum.at(rule(Pins, :upstream).lhs, 1)

      assert [:amt] == order.join_bind
      assert [] == order.new_bind
      assert nil == order.join_filter
      assert %{amt: 3} == order.alpha.fun.({:order, 3})
    end
  end

  defmodule Guards do
    use Rete.Ruleset

    defrule(anon_fn({:order, amts} when Enum.all?(amts, fn v -> v > 0 end)), do: {:ok, amts})
    defrule(comprehension({:cfg, xs} when Enum.any?(for x <- xs, do: x > 0)), do: {:ok, xs})
    defrule(bitstring({:msg, <<a::8, rest::binary>>}), do: {:msg, a, rest})
  end

  describe "a guard that introduces its own binders stays in the alpha" do
    # The fn parameter used to be collected as a rule binding, which made the
    # guard look non local. It was lifted into an arity 2 join filter that
    # destructured `v` from a token that can never carry it, so the filter was
    # always false and the rule could never fire.
    test "an anonymous function parameter is not a rule binding" do
      condition = hd(rule(Guards, :anon_fn).lhs)

      assert [:amts] == condition.bind
      assert nil == condition.join_filter
      assert %{amts: [1, 2]} == condition.alpha.fun.({:order, [1, 2]})
      assert nil == condition.alpha.fun.({:order, [-1]})
    end

    test "a comprehension generator is not a rule binding" do
      condition = hd(rule(Guards, :comprehension).lhs)

      assert [:xs] == condition.bind
      assert nil == condition.join_filter
    end

    # `rest :: binary` used to record `binary` as a binding, so the generated
    # function referred to an undefined variable and the module did not compile.
    test "a bitstring type modifier is not a rule binding" do
      condition = hd(rule(Guards, :bitstring).lhs)

      assert [:a, :rest] == condition.bind
      assert %{a: 1, rest: "xy"} == condition.alpha.fun.({:msg, <<1, "xy">>})
    end
  end

  describe "rejected forms" do
    # This used to compile to a collection of facts whose type tag was the atom
    # :or, matching a fact literally shaped {_, [{:a, x}, {:b, x}]}. No warning.
    test "a gate inside a collection is rejected" do
      source = """
      defmodule Rete.DSL.PinningTest.GateInColl do
        use Rete.Ruleset
        defrule r([{:or, [{:a, x}, {:b, x}]}]), do: {:o, x}
      end
      """

      error = assert_raise ArgumentError, fn -> Code.compile_string(source) end

      assert error.message =~ "or gate cannot appear inside a collection"
    end
  end
end
