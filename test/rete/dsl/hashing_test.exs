defmodule Rete.DSL.HashingTest do
  @moduledoc """
  Regression tests for expression identity: the code an expression is given
  decides which conditions share a generated function, and — from W2 on — which
  conditions share an alpha node.

  Two failure directions matter, and they are not symmetric:

    * two conditions that behave the same getting *different* codes only costs
      a duplicated node;
    * two conditions that behave *differently* getting the same code is silent
      wrongness, because the second one is never compiled and the first one's
      function runs in its place.
  """

  use ExUnit.Case, async: true

  alias Rete.DSL.Codegen

  defp quoted(source), do: Code.string_to_quoted!(source)

  defp alpha_code(bind_pairs) do
    bind = Map.new(bind_pairs)

    Codegen.alpha_expr(:order, quoted("{:order, a, b}"), quoted("{_, a, b}"), nil, bind).code
  end

  describe "codes are deterministic" do
    # `Map.to_list/1` on an atom keyed map iterates in atom table *interning*
    # order, not sorted order, so the hash used to depend on what the VM
    # happened to intern first. The same source text then produced different
    # codes on a full build and on an incremental one, silently duplicating
    # every alpha node on rebuild.
    test "the bind map's construction order does not affect the code" do
      forward = alpha_code(a: Macro.var(:a, nil), b: Macro.var(:b, nil))
      backward = alpha_code(b: Macro.var(:b, nil), a: Macro.var(:a, nil))

      assert forward == backward
    end

    test "the generated bindings pattern is sorted" do
      bind = Map.new(zeta: Macro.var(:zeta, nil), alpha: Macro.var(:alpha, nil))

      expr = Codegen.alpha_expr(:order, quoted("{:order, a}"), quoted("{_, a}"), nil, bind)
      {:%{}, _, pairs} = expr.__ast__.body

      assert [:alpha, :zeta] == Enum.map(pairs, &elem(&1, 0))
    end

    test "the same source hashes the same however many times it is built" do
      codes = for _ <- 1..5, do: alpha_code(a: Macro.var(:a, nil), b: Macro.var(:b, nil))
      assert 1 == codes |> Enum.uniq() |> length()
    end
  end

  describe "codes ignore differences that do not change behaviour" do
    defmodule Discarded do
      use Rete.Ruleset

      defrule(a({:order, _x, id}), do: {:a, id})
      defrule(b({:order, _y, id}), do: {:b, id})
    end

    # `_x` and `_y` are never bindings, so both conditions compile to byte
    # identical functions and must share one alpha node.
    test "discarded variables are canonicalised" do
      assert [one] =
               Discarded.get_rule_data()
               |> Enum.map(&hd(&1.lhs).alpha.code)
               |> Enum.uniq()

      assert "fact_order_bind_id_expr_" <> _ = Atom.to_string(one)
    end

    defmodule Moved do
      use Rete.Ruleset

      defrule(r({:a, x}), do: {:o, x})
    end

    defmodule MovedDown do
      use Rete.Ruleset

      defrule(r({:a, x}), do: {:o, x})
    end

    test "a production keeps its hash when it moves lines" do
      assert hd(Moved.get_rule_data()).hash == hd(MovedDown.get_rule_data()).hash
    end
  end

  describe "module attribute values" do
    defmodule SameValue do
      use Rete.Ruleset

      @limit 5
      defrule(a({:order, amt} when amt > @limit), do: {:a, amt})
      defrule(b({:order, amt} when amt > @limit), do: {:b, amt})
    end

    test "two conditions reading the same attribute value share one expression" do
      assert [_one] = SameValue.get_expr_data() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    end

    # An attribute's value cannot be known while macros expand: `@limit`
    # expands to a Module.__get_attribute__/4 call that only runs when the
    # module body is evaluated. So the AST — and therefore the code — is
    # identical either side of a reassignment, and `high` below would have
    # silently reused `low`'s function and matched on 5.
    test "a reassigned attribute behind one code is rejected at compile time" do
      source = """
      defmodule Rete.DSL.HashingTest.Hazard do
        use Rete.Ruleset

        @limit 5
        defrule low({:order, amt} when amt > @limit), do: {:low, amt}
        @limit 100
        defrule high({:order, amt} when amt > @limit), do: {:high, amt}
      end
      """

      error = assert_raise ArgumentError, fn -> Code.compile_string(source) end

      assert error.message =~ "read different module attribute values"
      assert error.message =~ "@limit was 5, is now 100"
    end

    defmodule DistinctNames do
      use Rete.Ruleset

      @low 5
      @high 100
      defrule(a({:order, amt} when amt > @low), do: {:a, amt})
      defrule(b({:order, amt} when amt > @high), do: {:b, amt})
    end

    test "distinct attribute names give distinct expressions with the right values" do
      [a, b] = DistinctNames.get_rule_data()

      refute hd(a.lhs).alpha.code == hd(b.lhs).alpha.code
      assert %{amt: 50} == hd(a.lhs).alpha.fun.({:order, 50})
      assert nil == hd(b.lhs).alpha.fun.({:order, 50})
      assert %{amt: 500} == hd(b.lhs).alpha.fun.({:order, 500})
    end
  end
end
