# A struct must be compiled before a rule can pattern-match on it. These therefore live at
# the top of the file, not inside the test module.
defmodule ReteFactShapes.Order do
  @moduledoc false
  defstruct [:id, :cid, :amount]
end

defmodule ReteFactShapes.Customer do
  @moduledoc false
  defstruct [:id, :name]
end

defmodule ReteFactShapes.Adjustment do
  @moduledoc false
  defstruct [:id, :amount]
end

defmodule ReteFactShapes.Refund do
  @moduledoc false
  defstruct [:id, :amount]
end

defmodule ReteFactShapes.Mislabelled do
  @moduledoc false
  defstruct [:__type__, :id]
end

defmodule Rete.FactShapesTest do
  @moduledoc """
  A fact is a tagged tuple, a struct, or a tagged map — three shapes, one engine.

  `test/rete/dsl/parser_test.exs` checks that a struct or tagged map *pattern* compiles to
  the right alpha, by calling the generated function directly. Everything else in the
  suite then inserts tuples. This file inserts the other two shapes into a real session
  and fires, so the shapes are tested where they are actually used: joins, guards,
  collections, negations, truth maintenance, queries, and the taxonomy.

  Where a behavior is already pinned for tuples, the test names the tuple original it
  mirrors.
  """

  use ExUnit.Case, async: true

  alias Rete.Compiler
  alias Rete.Inspect
  alias Rete.Network
  alias Rete.Session
  alias ReteFactShapes.Adjustment
  alias ReteFactShapes.Customer
  alias ReteFactShapes.Mislabelled
  alias ReteFactShapes.Order
  alias ReteFactShapes.Refund

  defp run(mod, facts) do
    [mod] |> Session.new() |> Session.insert(facts) |> Session.fire_rules()
  end

  defp typed(session, type) do
    session
    |> Session.facts()
    |> Enum.filter(&(is_map(&1) and Map.get(&1, :__type__) == type))
    |> Enum.sort()
  end

  defp structs(session, module) do
    session |> Session.facts() |> Enum.filter(&is_struct(&1, module)) |> Enum.sort()
  end

  # --- tagged maps ----------------------------------------------------------------------

  describe "tagged map facts" do
    defmodule Maps do
      use Rete.Ruleset

      defrule large(%{__type__: :order, id: id, amount: amt} when amt > 100) do
        %{__type__: :large, id: id}
      end

      defrule spend(%{__type__: :customer, id: cid, name: name}, {:order, cid, amt}) do
        {:spend, name, amt}
      end

      defrule matched({:threshold, amt}, %{__type__: :order, id: id, amount: ^amt}) do
        {:matched, id}
      end

      defrule counted(
                %{__type__: :customer, id: cid},
                orders = [%{__type__: :order, cid: cid}]
              ) do
        %{__type__: :counted, cid: cid, n: length(orders)}
      end

      defrule dormant(%{__type__: :customer, id: cid}, {:not, [%{__type__: :order, cid: cid}]}) do
        %{__type__: :dormant, cid: cid}
      end
    end

    test "a rule over one tagged map concludes a tagged map" do
      session = run(Maps, [%{__type__: :order, id: 1, cid: 1, amount: 250}])

      assert [%{__type__: :large, id: 1}] == typed(session, :large)
    end

    test "a per condition guard filters tagged maps" do
      session = run(Maps, [%{__type__: :order, id: 1, cid: 1, amount: 50}])

      assert [] == typed(session, :large)
    end

    test "a tagged map joins a tagged tuple on a shared variable" do
      session =
        run(Maps, [
          %{__type__: :customer, id: 1, name: "ann"},
          {:order, 1, 250},
          {:order, 2, 10}
        ])

      assert [{:spend, "ann", 250}] ==
               session |> Session.facts() |> Enum.filter(&match?({:spend, _, _}, &1))
    end

    # The tuple version of this test is test/rete/dsl/pinning_test.exs:45. The parser
    # removes a pin before the condition becomes its own function, so the pinned value has
    # to become a join key. A map pattern takes a different branch of
    # Rete.DSL.Vars.pattern_vars/1 than a tuple, so it needs its own test.
    test "a pinned upstream variable in a map pattern is a join key" do
      session =
        run(Maps, [
          {:threshold, 250},
          %{__type__: :order, id: 1, cid: 1, amount: 250},
          %{__type__: :order, id: 2, cid: 1, amount: 10}
        ])

      assert [{:matched, 1}] ==
               session |> Session.facts() |> Enum.filter(&match?({:matched, _}, &1))
    end

    test "a collection gathers tagged maps, and fires empty when there are none" do
      session =
        run(Maps, [
          %{__type__: :customer, id: 1, name: "ann"},
          %{__type__: :customer, id: 2, name: "bo"},
          %{__type__: :order, id: 1, cid: 1, amount: 10},
          %{__type__: :order, id: 2, cid: 1, amount: 20}
        ])

      assert [
               %{__type__: :counted, cid: 1, n: 2},
               %{__type__: :counted, cid: 2, n: 0}
             ] == typed(session, :counted)
    end

    test "a negation over tagged maps withdraws when a matching map arrives" do
      customer = %{__type__: :customer, id: 1, name: "ann"}
      order = %{__type__: :order, id: 1, cid: 1, amount: 10}

      assert [%{__type__: :dormant, cid: 1}] == typed(run(Maps, [customer]), :dormant)
      assert [] == typed(run(Maps, [customer, order]), :dormant)
    end

    test "retracting the supporting map withdraws the conclusion" do
      order = %{__type__: :order, id: 1, cid: 1, amount: 250}

      session =
        Maps
        |> run([order])
        |> Session.retract(order)
        |> Session.fire_rules()

      assert [] == typed(session, :large)
    end

    test "an explanation names the supporting map fact" do
      order = %{__type__: :order, id: 1, cid: 1, amount: 250}
      session = run(Maps, [order])

      assert [%{origin: :derived, rule: :large, supports: [%{fact: ^order}]}] =
               Inspect.explain(session, %{__type__: :large, id: 1})
    end

    # The tuple original is test/rete/behavior_test.exs:180. Facts are a multiset whatever
    # shape they take.
    test "an equal map inserted twice needs two retractions" do
      order = %{__type__: :order, id: 1, cid: 1, amount: 250}

      session =
        Maps
        |> run([order, order])
        |> Session.retract(order)
        |> Session.fire_rules()

      assert [%{__type__: :large, id: 1}] == typed(session, :large)

      session = session |> Session.retract(order) |> Session.fire_rules()

      assert [] == typed(session, :large)
    end
  end

  # --- structs --------------------------------------------------------------------------

  describe "struct facts" do
    defmodule Structs do
      use Rete.Ruleset

      defrule large(%Order{id: id, amount: amt} when amt > 100) do
        %{__type__: :large, id: id}
      end

      defrule spend(%Customer{id: cid, name: name}, %Order{cid: cid, amount: amt}) do
        {:spend, name, amt}
      end

      defrule mixed(%Customer{id: cid, name: name}, %{__type__: :note, cid: cid, body: body}) do
        {:noted, name, body}
      end

      defrule matched({:threshold, amt}, %Order{id: id, amount: ^amt}) do
        {:matched, id}
      end

      defrule counted(%Customer{id: cid}, orders = [%Order{cid: cid}]) do
        %{__type__: :counted, cid: cid, n: length(orders)}
      end

      defrule dormant(%Customer{id: cid}, {:not, [%Order{cid: cid}]}) do
        %{__type__: :dormant, cid: cid}
      end

      defrule rebate(%Order{id: id, amount: amt} when amt > 100) do
        %Refund{id: id, amount: div(amt, 10)}
      end
    end

    test "a rule over one struct concludes" do
      session = run(Structs, [%Order{id: 1, cid: 1, amount: 250}])

      assert [%{__type__: :large, id: 1}] == typed(session, :large)
    end

    test "a per condition guard filters structs" do
      session = run(Structs, [%Order{id: 1, cid: 1, amount: 50}])

      assert [] == typed(session, :large)
    end

    test "two structs join on a shared variable" do
      session =
        run(Structs, [
          %Customer{id: 1, name: "ann"},
          %Order{id: 1, cid: 1, amount: 250},
          %Order{id: 2, cid: 2, amount: 10}
        ])

      assert [{:spend, "ann", 250}] ==
               session |> Session.facts() |> Enum.filter(&match?({:spend, _, _}, &1))
    end

    test "a struct joins a tagged map on a shared variable" do
      session =
        run(Structs, [
          %Customer{id: 1, name: "ann"},
          %{__type__: :note, cid: 1, body: "vip"},
          %{__type__: :note, cid: 2, body: "other"}
        ])

      assert [{:noted, "ann", "vip"}] ==
               session |> Session.facts() |> Enum.filter(&match?({:noted, _, _}, &1))
    end

    test "a pinned upstream variable in a struct pattern is a join key" do
      session =
        run(Structs, [
          {:threshold, 250},
          %Order{id: 1, cid: 1, amount: 250},
          %Order{id: 2, cid: 1, amount: 10}
        ])

      assert [{:matched, 1}] ==
               session |> Session.facts() |> Enum.filter(&match?({:matched, _}, &1))
    end

    test "a collection gathers structs, and fires empty when there are none" do
      session =
        run(Structs, [
          %Customer{id: 1, name: "ann"},
          %Customer{id: 2, name: "bo"},
          %Order{id: 1, cid: 1, amount: 10},
          %Order{id: 2, cid: 1, amount: 20}
        ])

      assert [
               %{__type__: :counted, cid: 1, n: 2},
               %{__type__: :counted, cid: 2, n: 0}
             ] == typed(session, :counted)
    end

    test "a negation over structs withdraws when a matching struct arrives" do
      customer = %Customer{id: 1, name: "ann"}
      order = %Order{id: 1, cid: 1, amount: 10}

      assert [%{__type__: :dormant, cid: 1}] == typed(run(Structs, [customer]), :dormant)
      assert [] == typed(run(Structs, [customer, order]), :dormant)
    end

    test "a rule may conclude a struct, and it is a fact like any other" do
      session = run(Structs, [%Order{id: 1, cid: 1, amount: 250}])

      assert [%Refund{id: 1, amount: 25}] == structs(session, Refund)
    end

    test "retracting the supporting struct withdraws the conclusion" do
      order = %Order{id: 1, cid: 1, amount: 250}

      session =
        Structs
        |> run([order])
        |> Session.retract(order)
        |> Session.fire_rules()

      assert [] == typed(session, :large)
      assert [] == structs(session, Refund)
    end

    test "an explanation names the supporting struct fact" do
      order = %Order{id: 1, cid: 1, amount: 250}
      session = run(Structs, [order])

      assert [%{origin: :derived, rule: :rebate, supports: [%{fact: ^order}]}] =
               Inspect.explain(session, %Refund{id: 1, amount: 25})
    end

    test "an equal struct inserted twice needs two retractions" do
      order = %Order{id: 1, cid: 1, amount: 250}

      session =
        Structs
        |> run([order, order])
        |> Session.retract(order)
        |> Session.fire_rules()

      assert [%{__type__: :large, id: 1}] == typed(session, :large)

      session = session |> Session.retract(order) |> Session.fire_rules()

      assert [] == typed(session, :large)
    end
  end

  # --- whole fact bindings --------------------------------------------------------------

  describe "binding the whole fact" do
    defmodule Bound do
      use Rete.Ruleset

      defquery map_ref(o = %{__type__: :inner, n: _n}, %{__type__: :outer, ref: o}) do
        o
      end

      defquery struct_ref(o = %Order{id: _id}, %{__type__: :outer, ref: o}) do
        o
      end
    end

    # The tuple version of this test is test/rete/behavior_test.exs:253. Once a bound fact
    # is in the token it is an ordinary value, so a later condition may join on it.
    test "a bound tagged map can be the join key of a later condition" do
      inner = %{__type__: :inner, n: 1}

      session =
        run(Bound, [inner, %{__type__: :outer, ref: inner}, %{__type__: :outer, ref: :other}])

      assert [inner] == Bound.map_ref(session)
    end

    test "a bound struct can be the join key of a later condition" do
      order = %Order{id: 1, cid: 1, amount: 10}

      session =
        run(Bound, [order, %{__type__: :outer, ref: order}, %{__type__: :outer, ref: :other}])

      assert [order] == Bound.struct_ref(session)
    end
  end

  # --- queries --------------------------------------------------------------------------

  describe "queries over maps and structs" do
    defmodule Plain do
      use Rete.Ruleset

      defquery map_rows(%{__type__: :rec, cid: cid, tid: tid}), do: {cid, tid}
      defquery struct_rows(%Order{cid: cid, amount: amt}), do: {cid, amt}
    end

    defmodule Indexed do
      use Rete.Ruleset

      defquery map_rows(%{__type__: :rec, cid: cid, tid: tid}), do: {cid, tid}
      defquery struct_rows(%Order{cid: cid, amount: amt}), do: {cid, amt}

      index :map_rows, [:cid]
      index :struct_rows, [:cid]
    end

    defp rec_facts do
      for i <- 1..20, do: %{__type__: :rec, cid: rem(i, 4), tid: rem(i, 3)}
    end

    defp order_facts do
      for i <- 1..20, do: %Order{id: i, cid: rem(i, 4), amount: i}
    end

    test "a filter answers the same rows indexed and unindexed" do
      facts = rec_facts() ++ order_facts()
      plain = run(Plain, facts)
      indexed = run(Indexed, facts)

      for filters <- [[], [cid: 2], [tid: 1], [cid: 2, tid: 1], [cid: 99]] do
        assert Plain.map_rows(plain, filters) == Indexed.map_rows(indexed, filters),
               "map_rows disagreed on #{inspect(filters)}"
      end

      for filters <- [[], [cid: 2], [amt: 6], [cid: 2, amt: 6], [cid: 99]] do
        assert Plain.struct_rows(plain, filters) == Indexed.struct_rows(indexed, filters),
               "struct_rows disagreed on #{inspect(filters)}"
      end
    end

    test "the declared index is the one a matching filter uses" do
      indexed = run(Indexed, rec_facts() ++ order_facts())

      assert {:index, [:cid]} == Inspect.query_plan(indexed, {Indexed, :map_rows}, cid: 2)
      assert {:index, [:cid]} == Inspect.query_plan(indexed, {Indexed, :struct_rows}, cid: 2)
      assert :scan == Inspect.query_plan(indexed, {Indexed, :map_rows}, tid: 1)
    end
  end

  # --- typing and the taxonomy ----------------------------------------------------------

  describe "typing and derivation" do
    defmodule Derived do
      use Rete.Ruleset

      derive Refund, Adjustment
      derive :express_note, :note

      defquery adjustments(%Adjustment{id: id}), do: id
      defquery notes(%{__type__: :note, id: id}), do: id
    end

    # docs/dsl.md documents this, and no test covered it end to end.
    test "a struct type derives from another struct type" do
      session = run(Derived, [%Refund{id: 1, amount: 5}, %Adjustment{id: 2, amount: 5}])

      assert [1, 2] == Enum.sort(Derived.adjustments(session))
    end

    test "a derived struct does not reach a condition written against the descendant" do
      session = run(Derived, [%Adjustment{id: 2, amount: 5}])

      assert [2] == Derived.adjustments(session)
    end

    test "a tagged map type derives like any other" do
      session =
        run(Derived, [%{__type__: :express_note, id: 1}, %{__type__: :note, id: 2}])

      assert [1, 2] == Enum.sort(Derived.notes(session))
    end

    defmodule AcrossShapes do
      use Rete.Ruleset

      derive Refund, :adjustment

      defquery adjustments(%{__type__: :adjustment, id: id}), do: id
      defquery refunds(%Refund{id: id}), do: id
    end

    # A derivation relates two types, and it says nothing about shapes. A condition's
    # argument pattern does not check a shape either: `%{__type__: :adjustment, id: id}`
    # compiles to `%{id: id}`, and a struct matches that. So a struct that derives from a
    # tag reaches the tag's conditions, through the fields they share.
    test "a struct type may derive from a tagged map type, and cross-matches on shape" do
      session =
        run(AcrossShapes, [%Refund{id: 1, amount: 5}, %{__type__: :adjustment, id: 2}])

      assert [1, 2] == Enum.sort(AcrossShapes.adjustments(session))
    end

    test "the derivation does not run the other way" do
      session = run(AcrossShapes, [%{__type__: :adjustment, id: 2}])

      assert [] == AcrossShapes.refunds(session)
    end

    defmodule MissingField do
      use Rete.Ruleset

      derive Refund, :adjustment

      defquery reasons(%{__type__: :adjustment, id: id, reason: reason}), do: {id, reason}
    end

    # This is the limit of the behaviour above, and you need to know it before you depend
    # on the behaviour. The fact still reaches the alpha. But if the parent's pattern names
    # a field that the child does not have, the fact does not match. This is not an error.
    test "a derived struct missing a field the condition names does not match" do
      session =
        run(MissingField, [
          %Refund{id: 1, amount: 5},
          %{__type__: :adjustment, id: 2, reason: "late"}
        ])

      assert [{2, "late"}] == MissingField.reasons(session)
    end

    defmodule ByModule do
      use Rete.Ruleset

      defquery by_module(%Mislabelled{id: id}), do: id
      defquery by_tag(%{__type__: :express, id: id}), do: id
      defquery on_struct(%Mislabelled{__type__: :express, id: id}), do: id
    end

    # An explicit `__type__` is a declaration, so it takes precedence over the module.
    # The struct answers the query written against the tag. It does not answer the query
    # written against its module.
    test "a struct with a __type__ set is typed by that field, not its module" do
      session = run(ByModule, [%Mislabelled{__type__: :express, id: 1}])

      assert [1] == ByModule.by_tag(session)
      assert [] == ByModule.by_module(session)
    end

    # `__type__` is never ordinary data. `Rete.DSL.Parser.compile_pattern/2` strips it from
    # a struct pattern exactly as it does from a tagged map, so writing it on a struct
    # declares the type rather than matching a field.
    test "a struct pattern naming __type__ declares the type, it does not match a field" do
      session = run(ByModule, [%Mislabelled{__type__: :express, id: 1}])

      assert [1] == ByModule.on_struct(session)
    end

    # Both parts are constraints. The index routes on the declared type, so it no longer
    # guarantees the module. If `%Mod{...}` matched a value that is not a `Mod`, the module
    # in the condition would mean nothing. The struct pattern therefore keeps its
    # `__struct__` check, and a plain map of the same type does not match.
    test "a struct pattern with a declared type constrains the module too" do
      session =
        run(ByModule, [%Mislabelled{__type__: :express, id: 1}, %{__type__: :express, id: 2}])

      assert [1, 2] == Enum.sort(ByModule.by_tag(session))
      assert [1] == ByModule.on_struct(session)
    end

    # The alpha still does not check the type again. An alpha never applies the taxonomy,
    # so a descendant type routed here matches, exactly as it does for a tagged map.
    defmodule DerivedStruct do
      use Rete.Ruleset

      derive :express, :shipment

      defquery shipments(%Mislabelled{__type__: :shipment, id: id}), do: id
    end

    test "a declared type on a struct pattern still widens through derive" do
      session =
        run(DerivedStruct, [
          %Mislabelled{__type__: :express, id: 1},
          %Mislabelled{__type__: :shipment, id: 2},
          %{__type__: :express, id: 3}
        ])

      assert [1, 2] == Enum.sort(DerivedStruct.shipments(session))
    end

    test "a struct pattern may not bind __type__, because it is not data" do
      source = """
      defmodule Rete.FactShapesTest.BindsType do
        use Rete.Ruleset
        defquery q(%ReteFactShapes.Mislabelled{__type__: t, id: id}), do: {t, id}
      end
      """

      error = assert_raise ArgumentError, fn -> Code.compile_string(source) end

      assert error.message =~ "__type__ of a fact pattern must be a literal"
    end

    # `nil` means that a fact declares no type, and a struct field defaults to `nil`. An
    # unset `__type__` must therefore count as unwritten, not as the type `nil`.
    test "a struct whose __type__ is unset falls back to its module" do
      session = run(ByModule, [%Mislabelled{id: 1}, %Mislabelled{__type__: nil, id: 2}])

      assert [1, 2] == Enum.sort(ByModule.by_module(session))
      assert [] == ByModule.by_tag(session)
    end

    test "inserting a map with no __type__ raises" do
      assert_raise ArgumentError, ~r/cannot determine the fact type/, fn ->
        run(ByModule, [%{id: 1}])
      end
    end

    # Rete.DSL.Parser rejects `%{__type__: nil}` as a pattern, so you cannot write a
    # condition against the type `nil`. A fact typed `nil` would therefore match nothing,
    # and it would do so silently. default_fact_type/1 raises to prevent that.
    test "inserting a map whose __type__ is nil raises" do
      assert_raise ArgumentError, ~r/cannot determine the fact type/, fn ->
        run(ByModule, [%{__type__: nil, id: 1}])
      end
    end

    defmodule BadRhs do
      use Rete.Ruleset

      defrule untyped({:seed}), do: %{id: 1}
    end

    test "a rule whose body returns an untyped map is blamed for it" do
      error = assert_raise ArgumentError, fn -> run(BadRhs, [{:seed}]) end

      assert error.message =~ "which is not a fact"
      assert error.message =~ "__type__"
    end

    defmodule CustomTyped do
      use Rete.Ruleset

      defquery rows(%{__type__: :row, id: id}), do: id
    end

    # docs/dsl.md:69 offers `:fact_type_fn` for facts that carry their type some other
    # way. Nothing exercised it against a map shape.
    test "a custom fact_type_fn can type a map by a different key" do
      session =
        [CustomTyped]
        |> Session.new(fact_type_fn: fn %{kind: kind} -> kind end)
        |> Session.insert([%{kind: :row, id: 1}, %{kind: :other, id: 2}])
        |> Session.fire_rules()

      assert [1] == CustomTyped.rows(session)
    end
  end

  # --- shape routing and node sharing ---------------------------------------------------

  describe "shape routing" do
    defmodule SameTag do
      use Rete.Ruleset

      defquery tuples({:order, id}), do: {:tuple, id}
      defquery maps(%{__type__: :order, id: id}), do: {:map, id}
    end

    # Two shapes may share one type tag. The alpha index routes on the type alone, so it
    # offers both facts to both alphas. Each alpha must then reject the shape it was not
    # written for. Rete.DSL.Codegen documents that an alpha matches a fact of any type, and
    # an alpha that checked nothing at all would match both facts here.
    test "a tuple and a tagged map under one type tag do not match each other" do
      session = run(SameTag, [{:order, 1}, %{__type__: :order, id: 2}])

      assert [{:tuple, 1}] == SameTag.tuples(session)
      assert [{:map, 2}] == SameTag.maps(session)
    end

    test "both alphas are offered both facts, and reject on shape" do
      net = Compiler.build([SameTag])

      assert 2 == length(Network.alphas_for(net, {:order, 1}))
      assert 2 == length(Network.alphas_for(net, %{__type__: :order, id: 2}))
    end

    defmodule SameFields do
      use Rete.Ruleset

      defquery from_struct(%Order{id: id}), do: {:struct, id}
      defquery from_map(%{__type__: :order, id: id}), do: {:map, id}
    end

    # Both conditions compile to the same argument pattern, `%{id: id}`. A struct pattern
    # loses its `__struct__` check, and a tagged map loses its `__type__` key. Only the
    # type separates them. They must therefore stay on two alpha nodes, and a struct must
    # not answer a query written against the tag.
    test "a struct condition and a tagged map condition with the same fields stay apart" do
      session = run(SameFields, [%Order{id: 1, cid: 1, amount: 10}, %{__type__: :order, id: 2}])

      assert [{:struct, 1}] == SameFields.from_struct(session)
      assert [{:map, 2}] == SameFields.from_map(session)

      net = Compiler.build([SameFields])

      assert 1 == length(Network.alphas_for(net, %Order{id: 1}))
      assert 1 == length(Network.alphas_for(net, %{__type__: :order, id: 2}))
    end

    test "a struct no condition names reaches no alpha" do
      net = Compiler.build([SameFields])

      assert [] == Network.alphas_for(net, %Customer{id: 1, name: "ann"})
    end

    defmodule StructA do
      use Rete.Ruleset

      defrule a(%Order{id: id, amount: amt} when amt > 100), do: {:a, id}
    end

    defmodule StructB do
      use Rete.Ruleset

      defrule b(%Order{id: id, amount: amt} when amt > 100), do: {:b, id}
    end

    # The tuple version of this test is test/rete/network_test.exs:393. Two conditions
    # share a node when they share an expression code, and that code contains the type.
    # Rete.DSL.Codegen.type_label/1 renders a module into it.
    test "two modules writing the same struct condition share one alpha" do
      net = Compiler.build([StructA, StructB])

      assert 1 == length(Network.alphas_for(net, %Order{id: 1, cid: 1, amount: 250}))
    end
  end

  # --- gates ----------------------------------------------------------------------------

  describe "gates over maps and structs" do
    defmodule Gates do
      use Rete.Ruleset

      defrule either({:or, [%{__type__: :note, id: id}, %Order{id: id}]}) do
        {:either, id}
      end

      defrule neither(
                %Customer{id: cid},
                {:not, [%Order{cid: cid}, %{__type__: :note, cid: cid}]}
              ) do
        {:neither, cid}
      end

      defrule guarded(%Customer{id: cid}, %{__type__: :note, cid: cid, weight: w})
              when w > 10 do
        {:guarded, cid}
      end
    end

    defp tagged(session, tag) do
      session
      |> Session.facts()
      |> Enum.filter(&(is_tuple(&1) and elem(&1, 0) == tag))
      |> Enum.sort()
    end

    # Rete.DSL.Normalize parses each branch again through Rete.DSL.Parser.parse_element/2.
    # A branch that is not a tuple takes a different path through that function.
    test "a disjunction may mix a tagged map branch and a struct branch" do
      session = run(Gates, [%{__type__: :note, id: 1}, %Order{id: 2, cid: 2, amount: 5}])

      assert [{:either, 1}, {:either, 2}] == tagged(session, :either)
    end

    # The compiler moves a compound negation into a generated helper rule, which concludes
    # a marker fact. The conditions inside it are a struct and a map here.
    test "a compound negation may mix a struct and a tagged map condition" do
      customer = %Customer{id: 1, name: "ann"}

      assert [{:neither, 1}] == tagged(run(Gates, [customer]), :neither)

      both = [customer, %Order{id: 1, cid: 1, amount: 5}, %{__type__: :note, cid: 1}]

      assert [] == tagged(run(Gates, both), :neither)
    end

    test "a rule level guard runs over bindings a map condition contributed" do
      customer = %Customer{id: 1, name: "ann"}

      assert [{:guarded, 1}] ==
               tagged(run(Gates, [customer, %{__type__: :note, cid: 1, weight: 20}]), :guarded)

      assert [] ==
               tagged(run(Gates, [customer, %{__type__: :note, cid: 1, weight: 5}]), :guarded)
    end
  end

  # --- patterns that constrain nothing ---------------------------------------------------

  describe "a pattern with no fields" do
    defmodule Empty do
      use Rete.Ruleset

      defquery any_order(%Order{}), do: :order
      defquery any_note(%{__type__: :note}), do: :note
    end

    # `%Order{}` compiles to the argument pattern `%{}`, and that matches every map. Only
    # the alpha index limits the condition to orders.
    test "an empty struct pattern matches every fact of that module and nothing else" do
      session =
        run(Empty, [
          %Order{id: 1, cid: 1, amount: 10},
          %Order{id: 2, cid: 2, amount: 20},
          %Customer{id: 1, name: "ann"},
          %{__type__: :note, id: 1}
        ])

      assert [:order, :order] == Empty.any_order(session)
      assert [:note] == Empty.any_note(session)
    end
  end

  # --- types that are not atoms -----------------------------------------------------------

  describe "a fact type may be any term except nil" do
    defmodule AnyTerm do
      use Rete.Ruleset

      derive "express", "shipment"
      derive {:tenant, 7}, {:tenant, :any}

      defrule flag(%{__type__: "shipment", id: id}), do: {:flagged, id}
      defquery tuple_tag({"order", id}), do: id
      defquery numeric({42, id}), do: id
      defquery tenant(%{__type__: {:tenant, :any}, id: id}), do: id
    end

    test "a string type routes like an atom one" do
      session =
        run(AnyTerm, [%{__type__: "shipment", id: 1}, %{__type__: "other", id: 2}])

      assert [{:flagged, 1}] ==
               session |> Session.facts() |> Enum.filter(&match?({:flagged, _}, &1))
    end

    test "a tuple tag need not be an atom" do
      session = run(AnyTerm, [{"order", 1}, {"other", 2}, {42, 3}])

      assert [1] == AnyTerm.tuple_tag(session)
      assert [3] == AnyTerm.numeric(session)
    end

    test "derive relates non-atom types like any other" do
      session = run(AnyTerm, [%{__type__: "express", id: 1}])

      assert [{:flagged, 1}] ==
               session |> Session.facts() |> Enum.filter(&match?({:flagged, _}, &1))
    end

    test "a tuple is a usable type, and derives" do
      session =
        run(AnyTerm, [%{__type__: {:tenant, 7}, id: 1}, %{__type__: {:tenant, :any}, id: 2}])

      assert [1, 2] == Enum.sort(AnyTerm.tenant(session))
    end

    defmodule Collide do
      use Rete.Ruleset

      # `Rete.DSL.Codegen.type_label/1` renders both of these as the same name, and that
      # name is part of the expression code. The expression code is also the alpha node id.
      # Only the rest of the code separates them: it ends in a hash over the raw pattern,
      # and the pattern holds the type. If that stops being true, these two queries share
      # one alpha node, and each one returns the other's rows as well as its own.
      defquery dash(%{__type__: "a-b", id: id}), do: {:dash, id}
      defquery under(%{__type__: "a_b", id: id}), do: {:under, id}
    end

    test "two types with the same slug do not collapse onto one node" do
      session = run(Collide, [%{__type__: "a-b", id: 1}, %{__type__: "a_b", id: 2}])

      assert [{:dash, 1}] == Collide.dash(session)
      assert [{:under, 2}] == Collide.under(session)
      assert 1 == length(Network.alphas_for(Compiler.build([Collide]), %{__type__: "a-b", id: 1}))
    end

    test "nil is the one term that is not a type" do
      assert_raise ArgumentError, ~r/nil is not a fact type/, fn ->
        run(AnyTerm, [%{__type__: nil, id: 1}])
      end

      assert_raise ArgumentError, ~r/cannot determine the fact type/, fn ->
        run(AnyTerm, [{nil, 1}])
      end
    end
  end

  # --- keys and nesting -------------------------------------------------------------------

  describe "map keys other than atoms" do
    defmodule StringKeys do
      use Rete.Ruleset

      defquery rows(%{"id" => id, "name" => name, __type__: :row}), do: {id, name}
    end

    # `Rete.DSL.Parser.compile_pattern/2` reads and drops `__type__` with `Keyword.fetch/2`
    # and `Keyword.delete/2`. A string key makes the field list a non-keyword list, and
    # both functions must still work on it. A fact decoded from JSON has this shape.
    # Elixir also requires the keyword-style entry last in a mixed map, so this is the case
    # where `__type__` is not the first field `Rete.DSL.Parser.parse_args/1` sees.
    test "a tagged map may carry string keys alongside __type__" do
      session =
        run(StringKeys, [
          %{"id" => 1, "name" => "ann", __type__: :row},
          %{"id" => 2, __type__: :row}
        ])

      assert [{1, "ann"}] == StringKeys.rows(session)
    end
  end

  describe "nested patterns" do
    defmodule Nested do
      use Rete.Ruleset

      defquery owner(%Order{id: id, cid: %Customer{name: name}}), do: {id, name}
      defquery tagged_inner(%{__type__: :wrap, inner: %{__type__: :inner, n: n}}), do: n
    end

    # Only the outermost pattern is a fact pattern. A struct nested inside it is an
    # ordinary value pattern, and it keeps its `__struct__` check. A plain map in that
    # position must therefore not match.
    test "a struct nested inside a fact pattern keeps its struct check" do
      session =
        run(Nested, [
          %Order{id: 1, cid: %Customer{id: 9, name: "ann"}},
          %Order{id: 2, cid: %{id: 9, name: "ann"}},
          %Order{id: 3, cid: 9}
        ])

      assert [{1, "ann"}] == Nested.owner(session)
    end

    # A nested `__type__` is an ordinary key, not a type declaration. The alpha matches it
    # instead of dropping it.
    test "a nested tagged map is matched on its __type__ key like any other key" do
      session =
        run(Nested, [
          %{__type__: :wrap, inner: %{__type__: :inner, n: 1}},
          %{__type__: :wrap, inner: %{__type__: :other, n: 2}},
          %{__type__: :wrap, inner: %{n: 3}}
        ])

      assert [1] == Nested.tagged_inner(session)
    end
  end
end
