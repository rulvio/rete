defmodule Rete.Taxonomy do
  @moduledoc """
  Decides which alpha nodes a fact must be offered to.

  **Internal.** A condition declares the fact type it is written against, but the alpha
  expression it compiles to matches a fact of *any* shape. Type filtering happens here
  instead, at propagation time, so `derive/2` and `underive/2` widen what a condition sees
  without recompiling an expression.

  `derive(:premium, :customer)` reads "a premium *is a* customer". A `:premium` fact
  reaches every condition written against `:customer`. A `:customer` fact must **not**
  reach a condition written against `:premium`. So a fact of type `t` is offered to `t`
  plus its ancestors, never its descendants.

      iex> taxonomy =
      ...>   Rete.Taxonomy.new([{:derive, :premium, :customer}],
      ...>     alphas: %{customer: [:a1], premium: [:a2]}
      ...>   )
      iex> Rete.Taxonomy.alpha_ids(taxonomy, {:premium, 1})
      [:a2, :a1]
      iex> Rete.Taxonomy.alpha_ids(taxonomy, {:customer, 1})
      [:a1]

  `alpha_ids/2` runs for every inserted fact, so `index/2` precomputes the whole
  `type => ids` map. Empty entries are dropped, and a type absent from the index is
  answered `[]` without allocating. That keeps a session that inserts foreign facts from
  leaking. See `docs/design/network.md` §2.
  """

  @typedoc "A fact type: an atom tag, or a module for a struct fact."
  @type fact_type :: atom() | module()

  @typedoc "An ordered taxonomy declaration, as returned by `Rete.get_taxo_data/1`."
  @type declaration :: {:derive, fact_type(), fact_type()} | {:underive, fact_type(), fact_type()}

  @typedoc "Alpha node ids, keyed by the fact type the condition is written against."
  @type alphas :: %{optional(fact_type()) => [term()]}

  @typedoc """
  Fields:

    * `:taxo` - the folded `Taxo` hierarchy.
    * `:fact_type_fn` - one-argument function returning a fact's type.
    * `:alphas` - the `condition type => alpha node ids` map last indexed.
    * `:index` - the memoized `fact type => alpha node ids` map. Never holds an
      empty entry; a type absent from it propagates to nothing.
  """
  @type t :: %__MODULE__{
          taxo: %Taxo{},
          fact_type_fn: (term() -> fact_type()),
          alphas: alphas(),
          index: %{optional(fact_type()) => [term()]}
        }

  defstruct taxo: nil, fact_type_fn: nil, alphas: %{}, index: %{}

  @doc """
  Builds a taxonomy from an ordered list of declarations.

  Options:

    * `:fact_type_fn` - a one-argument function returning a fact's type,
      `default_fact_type/1` by default.
    * `:alphas` - the `condition type => alpha node ids` map to `index/2` right away.
      `%{}` by default, which makes every lookup answer `[]`.

  Declarations are folded in order, so a later `:underive` undoes an earlier `:derive`.
  Raises if a declaration is neither tuple, and lets `Taxo` raise on a cyclic derivation.

      iex> taxonomy = Rete.Taxonomy.new([{:derive, :dog, :mammal}, {:derive, :mammal, :animal}])
      iex> Rete.Taxonomy.ancestors(taxonomy, :dog)
      [:animal, :mammal]
  """
  @spec new([declaration()], keyword()) :: t()
  def new(taxo_data \\ [], opts \\ []) when is_list(taxo_data) and is_list(opts) do
    fact_type_fn = Keyword.get(opts, :fact_type_fn, &__MODULE__.default_fact_type/1)

    unless is_function(fact_type_fn, 1) do
      raise ArgumentError,
            ":fact_type_fn must be a function of arity 1, got: #{inspect(fact_type_fn)}"
    end

    taxo = Enum.reduce(taxo_data, Taxo.new(), &declare/2)

    %__MODULE__{taxo: taxo, fact_type_fn: fact_type_fn}
    |> index(Keyword.get(opts, :alphas, %{}))
  end

  @doc """
  Builds a taxonomy from the `derive`/`underive` declarations of ruleset modules.

  The declarations of all the modules are concatenated in module order, so a
  module can only undo a derivation declared by a module before it.
  """
  @spec from_modules([module()], keyword()) :: t()
  def from_modules(modules, opts \\ []) when is_list(modules) do
    modules |> Rete.get_taxo_data() |> new(opts)
  end

  defp declare({:derive, child, parent}, taxo), do: Taxo.derive(taxo, child, parent)
  defp declare({:underive, child, parent}, taxo), do: Taxo.underive(taxo, child, parent)

  defp declare(other, _taxo) do
    raise ArgumentError,
          "unsupported taxonomy declaration #{inspect(other)}, expected " <>
            "{:derive, child, parent} or {:underive, child, parent}"
  end

  @doc """
  Precomputes the `fact type => alpha node ids` index for `alphas`.

  `alphas` maps the type a condition is written against to the ids of the alpha
  nodes built for it. The result answers `alpha_ids/2` in one map lookup.
  """
  @spec index(t(), alphas()) :: t()
  def index(%__MODULE__{taxo: taxo} = taxonomy, alphas) when is_map(alphas) do
    index =
      taxo
      |> declared_types()
      |> MapSet.union(MapSet.new(Map.keys(alphas)))
      |> Map.new(fn type -> {type, collect(taxo, alphas, type)} end)
      |> Map.reject(fn {_type, ids} -> ids == [] end)

    %{taxonomy | alphas: alphas, index: index}
  end

  defp declared_types(%Taxo{parents: parents}) do
    Enum.reduce(parents, MapSet.new(), fn {child, direct}, acc ->
      acc |> MapSet.put(child) |> MapSet.union(direct)
    end)
  end

  defp collect(taxo, alphas, type) do
    taxo
    |> expand_type(type)
    |> Enum.flat_map(&Enum.to_list(Map.get(alphas, &1, [])))
    |> Enum.uniq()
  end

  @doc """
  The ids of the alpha nodes `fact` must be offered to.

  Answers `[]` for a fact whose type no condition is written against, directly or through
  a derivation.
  """
  @spec alpha_ids(t(), term()) :: [term()]
  def alpha_ids(%__MODULE__{} = taxonomy, fact) do
    alpha_ids_for_type(taxonomy, fact_type(taxonomy, fact))
  end

  @doc """
  The ids of the alpha nodes a fact of type `type` must be offered to.

  See `alpha_ids/2`, which derives `type` from a fact.
  """
  @spec alpha_ids_for_type(t(), fact_type()) :: [term()]
  def alpha_ids_for_type(%__MODULE__{index: index}, type), do: Map.get(index, type, [])

  @doc """
  The type of `fact`, according to the taxonomy's `:fact_type_fn`.
  """
  @spec fact_type(t(), term()) :: fact_type()
  def fact_type(%__MODULE__{fact_type_fn: fact_type_fn}, fact), do: fact_type_fn.(fact)

  @doc """
  The condition types a fact of type `type` must be matched against.

  `type` first, then its ancestors, sorted. The order does not depend on the order the
  derivations were declared in.

      iex> taxonomy = Rete.Taxonomy.new([{:derive, :dog, :mammal}, {:derive, :mammal, :animal}])
      iex> Rete.Taxonomy.expand(taxonomy, :dog)
      [:dog, :animal, :mammal]
      iex> Rete.Taxonomy.expand(taxonomy, :rock)
      [:rock]
  """
  @spec expand(t(), fact_type()) :: [fact_type()]
  def expand(%__MODULE__{taxo: taxo}, type), do: expand_type(taxo, type)

  defp expand_type(%Taxo{} = taxo, type),
    do: [type | taxo |> Taxo.ancestors(type) |> Enum.sort()]

  @doc """
  The ancestors of `type`, sorted. `[]` for a type in no derivation.
  """
  @spec ancestors(t(), fact_type()) :: [fact_type()]
  def ancestors(%__MODULE__{taxo: taxo}, type), do: taxo |> Taxo.ancestors(type) |> Enum.sort()

  @doc """
  Whether a fact of type `child` reaches a condition written against `parent`.

  True when the two are the same type, and when `child` derives from `parent` directly or
  transitively.

      iex> taxonomy = Rete.Taxonomy.new([{:derive, :dog, :mammal}])
      iex> {Rete.Taxonomy.is_a?(taxonomy, :dog, :mammal), Rete.Taxonomy.is_a?(taxonomy, :mammal, :dog)}
      {true, false}
  """
  # Named after `Taxo.is_a?/3`, which it wraps. Renaming it to satisfy the credo
  # convention would leave the wrapper and the wrapped with different names.
  @spec is_a?(t(), fact_type(), fact_type()) :: boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_a?(%__MODULE__{taxo: taxo}, child, parent) do
    child == parent or Taxo.is_a?(taxo, child, parent)
  end

  @doc """
  The default `:fact_type_fn`.

    * a struct is typed by its module,
    * a tagged tuple `{:type, ...}` of any arity by its first element,
    * a tagged map `%{__type__: type}` by that value.

  Anything else raises. Typing a fact by accident would make it match nothing, silently,
  with no way to tell that from a rule that does not apply.

      iex> Rete.Taxonomy.default_fact_type({:order, 1, 99})
      :order
      iex> Rete.Taxonomy.default_fact_type(%{__type__: :order, id: 1})
      :order
      iex> Rete.Taxonomy.default_fact_type(%Rete.IR.Test{})
      Rete.IR.Test
  """
  @spec default_fact_type(term()) :: fact_type()
  def default_fact_type(%module{}), do: module
  def default_fact_type(%{__type__: type}) when is_atom(type), do: type

  def default_fact_type(fact)
      when is_tuple(fact) and tuple_size(fact) > 0 and is_atom(elem(fact, 0)),
      do: elem(fact, 0)

  def default_fact_type(fact) do
    raise ArgumentError,
          "cannot determine the fact type of #{inspect(fact)}: expected a struct, " <>
            "a tagged tuple {:type, ...} or a tagged map %{__type__: type}"
  end
end
