defmodule Rete.TaxonomyTest.Fixture do
  @moduledoc false
  use Rete.Ruleset

  derive(:premium, :customer)
  derive(:standard, :customer)
  underive(:standard, :customer)

  defrule anyone({:customer, cid}) do
    {:seen, cid}
  end
end

defmodule Rete.TaxonomyTest.Order do
  @moduledoc false
  defstruct [:id]
end

defmodule Rete.TaxonomyTest do
  use ExUnit.Case, async: true

  alias Rete.Taxonomy
  alias Rete.TaxonomyTest.Order

  doctest Rete.Taxonomy

  # A three deep chain with a second branch, used by most of the index tests:
  #
  #   poodle -> dog -> mammal -> animal
  #   cat -----^
  #
  defp chain do
    [
      {:derive, :poodle, :dog},
      {:derive, :dog, :mammal},
      {:derive, :cat, :mammal},
      {:derive, :mammal, :animal}
    ]
  end

  # ---------------------------------------------------------------------------
  # Folding declarations
  # ---------------------------------------------------------------------------

  describe "new/2" do
    test "an empty taxonomy expands a type to itself" do
      taxonomy = Taxonomy.new()

      assert [:order] == Taxonomy.expand(taxonomy, :order)
      assert [] == Taxonomy.ancestors(taxonomy, :order)
      assert [] == Taxonomy.alpha_ids(taxonomy, {:order, 1})
    end

    test "a derivation chain of depth three gives every ancestor, transitively" do
      taxonomy = Taxonomy.new(chain())

      assert [:animal, :dog, :mammal] == Taxonomy.ancestors(taxonomy, :poodle)
      assert [:poodle, :animal, :dog, :mammal] == Taxonomy.expand(taxonomy, :poodle)
      assert Taxonomy.is_a?(taxonomy, :poodle, :animal)
    end

    test "a type with two parents gets both branches of ancestors" do
      taxonomy =
        Taxonomy.new([
          {:derive, :premium, :customer},
          {:derive, :premium, :employee},
          {:derive, :employee, :person}
        ])

      assert [:customer, :employee, :person] == Taxonomy.ancestors(taxonomy, :premium)
    end

    test "an underive undoes a derive declared earlier in the same list" do
      taxonomy =
        Taxonomy.new([
          {:derive, :premium, :customer},
          {:derive, :standard, :customer},
          {:underive, :standard, :customer}
        ])

      assert [:customer] == Taxonomy.ancestors(taxonomy, :premium)
      assert [] == Taxonomy.ancestors(taxonomy, :standard)
      refute Taxonomy.is_a?(taxonomy, :standard, :customer)
    end

    test "an underive of an intermediate link cuts the chain below it" do
      taxonomy = Taxonomy.new(chain() ++ [{:underive, :dog, :mammal}])

      assert [:dog] == Taxonomy.ancestors(taxonomy, :poodle)
      assert [:animal, :mammal] == Taxonomy.ancestors(taxonomy, :cat)
    end

    test "a cyclic derivation raises" do
      assert_raise RuntimeError, ~r/Cyclic derivation/, fn ->
        Taxonomy.new([
          {:derive, :dog, :mammal},
          {:derive, :mammal, :animal},
          {:derive, :animal, :dog}
        ])
      end
    end

    test "deriving a type from itself raises" do
      assert_raise ArgumentError, fn -> Taxonomy.new([{:derive, :dog, :dog}]) end
    end

    test "an unrecognised declaration raises naming it" do
      assert_raise ArgumentError,
                   ~r/unsupported taxonomy declaration \{:isa, :dog, :mammal\}/,
                   fn ->
                     Taxonomy.new([{:isa, :dog, :mammal}])
                   end
    end

    test "a :fact_type_fn that is not a one-argument function raises" do
      assert_raise ArgumentError, ~r/:fact_type_fn must be a function of arity 1/, fn ->
        Taxonomy.new([], fact_type_fn: :type)
      end
    end
  end

  describe "from_modules/2" do
    test "folds the declarations of ruleset modules in order" do
      taxonomy = Taxonomy.from_modules([Rete.TaxonomyTest.Fixture])

      assert [:customer] == Taxonomy.ancestors(taxonomy, :premium)
      assert [] == Taxonomy.ancestors(taxonomy, :standard)
    end
  end

  # ---------------------------------------------------------------------------
  # Fact types
  # ---------------------------------------------------------------------------

  describe "default_fact_type/1" do
    test "types the three fact shapes" do
      assert :order == Taxonomy.default_fact_type({:order, 1, 99})
      assert :tick == Taxonomy.default_fact_type({:tick})
      assert Order == Taxonomy.default_fact_type(%Order{id: 1})
      assert :order == Taxonomy.default_fact_type(%{__type__: :order, id: 1})
    end

    test "a struct is typed by its module even when it carries a __type__ field" do
      assert Order == Taxonomy.default_fact_type(%Order{id: 1})
    end

    test "an untypable value raises naming it" do
      for fact <- [%{id: 1}, {"order", 1}, [:order, 1], :order, 42, "order"] do
        assert_raise ArgumentError, ~r/cannot determine the fact type of/, fn ->
          Taxonomy.default_fact_type(fact)
        end
      end
    end

    test "a tagged map whose __type__ is not an atom raises" do
      assert_raise ArgumentError, ~r/cannot determine the fact type of/, fn ->
        Taxonomy.default_fact_type(%{__type__: "order"})
      end
    end
  end

  describe "fact_type/2" do
    test "uses the default function unless one is given" do
      taxonomy = Taxonomy.new()

      assert :order == Taxonomy.fact_type(taxonomy, {:order, 1})
      assert Order == Taxonomy.fact_type(taxonomy, %Order{id: 1})
    end

    test "a custom :fact_type_fn replaces it entirely" do
      taxonomy =
        Taxonomy.new([{:derive, :premium, :customer}],
          alphas: %{customer: [:a1]},
          fact_type_fn: fn %{"kind" => kind} -> String.to_atom(kind) end
        )

      assert :premium == Taxonomy.fact_type(taxonomy, %{"kind" => "premium", "id" => 1})
      assert [:a1] == Taxonomy.alpha_ids(taxonomy, %{"kind" => "premium", "id" => 1})
    end
  end

  # ---------------------------------------------------------------------------
  # The index
  # ---------------------------------------------------------------------------

  describe "alpha_ids/2" do
    setup do
      alphas = %{poodle: [:p1], dog: [:d1, :d2], mammal: [:m1], animal: [:a1], bird: [:b1]}
      {:ok, taxonomy: Taxonomy.new(chain(), alphas: alphas)}
    end

    # The classic bug: a condition written against the ancestor must see the
    # descendant's facts, and a condition written against the descendant must
    # NOT see the ancestor's. Every dog is a mammal. Not every mammal is a dog.
    test "a condition on an ancestor sees a descendant's facts", %{taxonomy: taxonomy} do
      assert [:p1, :a1, :d1, :d2, :m1] == Taxonomy.alpha_ids(taxonomy, {:poodle, 1})
    end

    test "a condition on a descendant does not see an ancestor's facts", %{taxonomy: taxonomy} do
      assert [:a1] == Taxonomy.alpha_ids(taxonomy, {:animal, 1})
      assert [:m1, :a1] == Taxonomy.alpha_ids(taxonomy, {:mammal, 1})

      refute :d1 in Taxonomy.alpha_ids(taxonomy, {:mammal, 1})
      refute :p1 in Taxonomy.alpha_ids(taxonomy, {:dog, 1})
    end

    test "a sibling's nodes are not reachable", %{taxonomy: taxonomy} do
      refute :p1 in Taxonomy.alpha_ids(taxonomy, {:cat, 1})
      assert [:a1, :m1] == Taxonomy.alpha_ids(taxonomy, {:cat, 1})
    end

    test "a type that is an ancestor of nothing only reaches its own nodes",
         %{taxonomy: taxonomy} do
      assert [:b1] == Taxonomy.alpha_ids(taxonomy, {:bird, 1})
    end

    test "a fact of a type in no taxonomy and in no condition reaches nothing",
         %{taxonomy: taxonomy} do
      assert [] == Taxonomy.alpha_ids(taxonomy, {:meteorite, 1})
    end

    # An unseen type must not be memoized on lookup: a session that inserts
    # arbitrary foreign facts would otherwise grow the index without bound.
    test "an unseen type does not grow the index", %{taxonomy: taxonomy} do
      before = taxonomy.index

      for i <- 1..50, do: assert([] == Taxonomy.alpha_ids(taxonomy, {:"foreign_#{i}", i}))

      assert before == taxonomy.index
      refute Map.has_key?(taxonomy.index, :foreign_1)
    end

    test "the order is the type's own nodes first, then its ancestors', deterministically",
         %{taxonomy: taxonomy} do
      assert [:p1, :a1, :d1, :d2, :m1] == Taxonomy.alpha_ids(taxonomy, {:poodle, 1})

      other = Taxonomy.new(Enum.reverse(chain()), alphas: taxonomy.alphas)
      assert Taxonomy.alpha_ids(taxonomy, {:poodle, 1}) == Taxonomy.alpha_ids(other, {:poodle, 1})
    end

    test "struct and tagged map facts are indexed by the same types" do
      taxonomy =
        Taxonomy.new([{:derive, Order, :sellable}, {:derive, :quote, :sellable}],
          alphas: %{Order => [:o1], sellable: [:s1]}
        )

      assert [:o1, :s1] == Taxonomy.alpha_ids(taxonomy, %Order{id: 1})
      assert [:s1] == Taxonomy.alpha_ids(taxonomy, %{__type__: :quote, id: 1})
    end
  end

  describe "index/2" do
    test "a node id shared by two ancestors is offered once" do
      taxonomy =
        Taxonomy.new([{:derive, :premium, :customer}, {:derive, :premium, :person}],
          alphas: %{customer: [:shared], person: [:shared, :p1]}
        )

      assert [:shared, :p1] == Taxonomy.alpha_ids(taxonomy, {:premium, 1})
    end

    test "MapSet valued alphas are accepted" do
      taxonomy =
        Taxonomy.new([{:derive, :premium, :customer}],
          alphas: %{customer: MapSet.new([:a1])}
        )

      assert [:a1] == Taxonomy.alpha_ids(taxonomy, {:premium, 1})
    end

    test "types that reach no node are kept out of the index" do
      taxonomy = Taxonomy.new(chain(), alphas: %{dog: [:d1]})

      assert [:dog, :poodle] == taxonomy.index |> Map.keys() |> Enum.sort()
      assert [] == Taxonomy.alpha_ids(taxonomy, {:mammal, 1})
    end

    test "a condition type outside the taxonomy is still indexed" do
      taxonomy = Taxonomy.new([{:derive, :dog, :mammal}], alphas: %{tick: [:t1]})

      assert [:t1] == Taxonomy.alpha_ids(taxonomy, {:tick})
    end

    test "reindexing replaces the previous alphas" do
      taxonomy = Taxonomy.new(chain(), alphas: %{mammal: [:m1]})
      assert [:m1] == Taxonomy.alpha_ids(taxonomy, {:dog, 1})

      taxonomy = Taxonomy.index(taxonomy, %{animal: [:a1]})
      assert [:a1] == Taxonomy.alpha_ids(taxonomy, {:dog, 1})
      assert %{animal: [:a1]} == taxonomy.alphas
    end

    test "an underive narrows what a descendant reaches" do
      alphas = %{customer: [:c1], premium: [:p1]}
      derived = Taxonomy.new([{:derive, :premium, :customer}], alphas: alphas)

      undone =
        Taxonomy.new([{:derive, :premium, :customer}, {:underive, :premium, :customer}],
          alphas: alphas
        )

      assert [:p1, :c1] == Taxonomy.alpha_ids(derived, {:premium, 1})
      assert [:p1] == Taxonomy.alpha_ids(undone, {:premium, 1})
    end
  end
end
