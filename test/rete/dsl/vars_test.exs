defmodule Rete.DSL.VarsTest do
  use ExUnit.Case, async: true

  doctest Rete.DSL.Vars

  alias Rete.DSL.Vars

  defp reads(source), do: source |> Code.string_to_quoted!() |> Vars.read_var_names()
  defp binds(source), do: source |> Code.string_to_quoted!() |> Vars.pattern_var_names()

  # A traversal that simply collects every {name, meta, nil} node reports the
  # binders a guard introduces for itself. That is not cosmetic: the spurious
  # name is not among the condition's own bindings, so the guard is judged non
  # local, lifted into a join filter, and destructured from a token that can
  # never carry it. The rule then never fires, or fails to compile naming a
  # generated function.
  describe "read_vars/1 ignores binders introduced inside the expression" do
    test "anonymous function parameters" do
      assert [:amts] == reads("Enum.all?(amts, fn v -> v > 0 end)")
      assert [:amts] == reads("Enum.all?(amts, fn v when v > 0 -> true end)")
      assert [:amts, :lim] == reads("Enum.all?(amts, fn v -> v > lim end)")
    end

    test "comprehension and with generators" do
      assert [:amts] == reads("for a <- amts, do: a > 0")
      assert [:amts, :lim] == reads("for a <- amts, do: a > lim")
      assert [:key] == reads("with {:ok, v} <- fetch(key), do: v > 0")
    end

    test "case, cond and receive clause heads" do
      assert [:amt] == reads("case amt do x -> x end")
      assert [:amt, :lim] == reads("case amt do x when x > lim -> x end")
      assert [:amt] == reads("cond do amt > 0 -> 1 end")
    end

    test "bitstring type modifiers are types, not variables" do
      refute :binary in reads("<<a::8, rest::binary>>")
      refute :integer in reads("<<a::integer-signed>>")
      # ... but a modifier may still call out to a real variable.
      assert :n in reads("<<a::size(n)>>")
    end

    test "a match earlier in a block binds for what follows" do
      assert [:y, :z] == reads("(x = f(y); x > z)")
    end
  end

  describe "read_vars/1 keeps genuine reads" do
    test "plain variables" do
      assert [:amt, :t] == reads("amt > t")
    end

    # `_t` really is read here. Treating it as local would inline the guard into
    # the arity 1 alpha, where `_t` is not in scope.
    test "underscore prefixed names, but not the anonymous underscore" do
      assert [:_t, :amt] == reads("amt > _t")
      assert [:amt] == reads("amt > 1")
    end

    test "compile time constants are not reads" do
      assert [:amt] == reads("amt > ^lim")
      assert [:amt] == reads("amt > @limit")
    end
  end

  describe "pattern_vars/1" do
    test "discarded names never bind" do
      assert [:id] == binds("{:order, id, _ignored}")
      assert [] == binds("{:order, _, _x}")
    end

    test "bitstring segments bind, their modifiers do not" do
      assert [:a, :rest] == binds("<<a::8, rest::binary>>")
    end

    test "struct and map keys do not bind, values do" do
      assert [:id] == binds("%Order{id: id}")
      assert [:v] == binds("%{:k => v}")
    end

    test "pinned values do not bind" do
      assert [:x] == binds("{:order, ^lim, x}")
    end

    test "nested destructuring" do
      assert [:h, :id, :t] == binds("{:order, %{id: id}, [h | t]}")
    end
  end
end
