defmodule Rete.ActivationCache do
  @moduledoc """
  Lets a cache, built from an earlier session, take the place of the body of a rule.

  A rule opts in when its `:cache` option is a value other than `nil` or `false`, such as
  `%{cache: true}` or `%{cache: 2}`. A ruleset can give that option to all its rules with
  `use Rete.Ruleset, default_rule_opts: %{cache: true}`. A build can give it with
  `Rete.Session.new(modules, default_rule_opts: %{cache: true})`.

  Build the cache from a session that fired, and give it to `Rete.Session.fire_rules/2`:

      cache = Rete.ActivationCache.from_session(prior)
      next = Rete.Session.fire_rules(session, activation_cache: cache)

  An activation of a rule that opted in looks for an equal activation in the cache. If it
  finds one, the engine inserts the facts that were concluded for it, and the body does not
  run. If not, the body runs as usual.

  **The cache is built from the memory of a session.** A session records what each
  activation concluded, because truth maintenance needs that record. `from_session/2` reads
  that record. So there is no store to fill. A hit is concluded in the normal way, and the
  new session records it too. So `from_session(next)` holds the hits as well. A conclusion
  that lost its support is gone from that record, so it is not in the cache. The cache
  holds what each match concluded, for every match that still holds. A fact that you
  retract yourself stays in it while its match holds.

  The cache is a plain map. Save it in the way that suits you, and load it before a fire:

      File.write!(path, :erlang.term_to_binary(cache))
      cache = path |> File.read!() |> :erlang.binary_to_term([:safe])

  `[:safe]` refuses an atom that the node does not know. So load the ruleset modules before
  the cache. **A cache inserts facts, and no rule checks them. Load a cache only from
  storage you trust.** A session from `Rete.Session.load/2` gives a cache too. You need
  the whole session only to inspect it.

  Two activations are equal when two things agree:

    * the rule. Its module, its name, its hash and its `:cache` value must be equal. The
      hash covers the left hand side, the options map and the body, as written. It also
      covers whether the production is a rule or a query. So an edit to the rule makes a
      miss. A new `:cache` value makes a miss too, also when a default gives it. So the
      value acts as a version.
    * the key. `key/1` gives the bindings of the activation. `from_session/2` takes
      `:key_fn` to replace it, and `fire_rules/2` takes `:activation_cache_key_fn`. Give
      both the same function, or nothing hits. When the function returns `nil`, that
      activation is left out of the cache, or runs without it.

  The rule is found by these values and not by node ids. So a cache serves sessions from
  other builds, and from other sets of modules. Only the rules that both have can hit.

  A query can opt in too. A query fires as a rule does, and the session keeps the row
  that its body gives. So a hit gives the row, and the body does not run. The session
  keeps no reference to the cache after the fire.

  A lookup builds the key and hashes it, so its cost grows with the size of the bindings.
  Use the cache for a body that costs more than that, such as one that calls a service.

  These limits apply:

    * the hash does not see the code of a function that the body calls.
    * the hash does not see the value of a module attribute. It sees only the name.

  For both, change the `:cache` value, for example from `1` to `2`. Or give a key function
  that adds what the body depends on.

  The cache is sound only because the return value of a body follows from its bindings.
  `docs/dsl.md` requires that of every rule.
  """

  alias Rete.Engine.State
  alias Rete.Memory
  alias Rete.Network
  alias Rete.Network.Node
  alias Rete.Token

  @typedoc "What a key function receives for one activation."
  @type activation :: %{
          rule: {module(), atom()},
          hash: integer(),
          cache: term(),
          token: Token.t()
        }

  @typedoc """
  A cache: rule identity, then key, then the facts concluded for that activation.

  The identity is `{module, name, hash, cache}`.
  """
  @type t :: %{
          optional({module(), atom(), integer(), term()}) => %{optional(term()) => term()}
        }

  @doc """
  The default key of an activation: its bindings.

  A body reads only the variables that its left hand side binds. Its return value must
  follow from them, and the hash of the rule covers its code. So the bindings are all that
  the result depends on. The matched facts are not in the key. Two branches of a
  disjunction can match the same facts and bind different variables, so the facts alone
  would not be a sound key. A collection bound to a variable is in the bindings once.

  The key holds the full terms and not a hash of them. So two keys are equal only when the
  bindings are. It holds no node ids, so it does not change from one network to another.

      iex> token = %Rete.Token{matches: [{{:order, 1}, 7}], bindings: %{id: 1}}
      iex> Rete.ActivationCache.key(%{rule: {MyRules, :r}, hash: 1, cache: true, token: token})
      %{id: 1}
  """
  @spec key(activation()) :: term()
  def key(%{token: %Token{bindings: bindings}}), do: bindings

  @doc """
  Builds a cache from what a session concluded.

  It holds every rule and query of the session that opted in, and every match that rule
  fired on and that still holds. A match that concluded nothing is in it too, so it hits as well.
  Fire the session first, because a session that never fired holds no conclusions.

  Options:

    * `:key_fn` — an arity-1 function that gives the key of an activation. When it returns
      `nil`, that activation is left out of the cache. `key/1` by default. Give
      `fire_rules/2` the same function as `:activation_cache_key_fn`.

      iex> alias Rete.Session
      iex> [Rete.Doc.Orders]
      ...> |> Session.new(default_rule_opts: %{cache: true})
      ...> |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...> |> Session.fire_rules()
      ...> |> Rete.ActivationCache.from_session()
      ...> |> Enum.map(fn {{module, name, _hash, cache}, entries} ->
      ...>   {module, name, cache, Map.values(entries)}
      ...> end)
      ...> |> Enum.sort()
      [
        {Rete.Doc.Orders, :flagged_for, true, [{1, 250}]},
        {Rete.Doc.Orders, :large_order, true, [[{:flagged, 1, 250}]]}
      ]
  """
  @spec from_session(Rete.Session.t(), keyword()) :: t()
  def from_session(%Rete.Session{state: %State{} = state}, opts \\ []) do
    key_fn = opts |> Keyword.get(:key_fn, &key/1) |> validate_key_fn!()
    %State{network: network, memory: memory} = state

    for node <- Network.beta_nodes(network),
        cached?(node),
        entries = entries(node, memory, key_fn),
        map_size(entries) > 0,
        into: %{},
        do: {identity(node), entries}
  end

  # Any batch of a token will do. `Rete.Memory.add_insertion/4` says why they are equal.
  defp entries(%Node.Production{} = node, %Memory{insertions: insertions}, key_fn) do
    for {token, [batch | _]} <- Map.get(insertions, node.id, %{}),
        key <- [key_fn.(activation(node, token))],
        key != nil,
        into: %{},
        do: {key, batch}
  end

  defp entries(%Node.Query{} = node, %Memory{} = memory, key_fn) do
    for {token, [row | _]} <- Memory.rows(memory, node.id),
        key <- [key_fn.(activation(node, token))],
        key != nil,
        into: %{},
        do: {key, row}
  end

  defp entries(_node, _memory, _key_fn), do: %{}

  defp validate_key_fn!(fun) when is_function(fun, 1), do: fun

  defp validate_key_fn!(other) do
    raise ArgumentError, ":key_fn must be a function of arity 1, got: #{inspect(other)}"
  end

  @doc false
  # `cache` is what `Rete.Engine.fire_rules/2` puts on the state for one call: the map and
  # the key function, or `nil` when the call has no cache.
  @spec lookup(
          {t(), (activation() -> term())} | nil,
          Node.Production.t() | Node.Query.t(),
          Token.t()
        ) ::
          {:ok, term()} | :error
  def lookup(nil, _node, _token), do: :error

  def lookup({cache, key_fn}, node, token) do
    with true <- cached?(node),
         {:ok, entries} <- Map.fetch(cache, identity(node)),
         key when key != nil <- key_fn.(activation(node, token)),
         {:ok, value} <- entries |> check_entries!(node) |> Map.fetch(key) do
      {:ok, check_value!(value, node)}
    else
      _ -> :error
    end
  end

  # `from_session/2` never writes these shapes. A cache from storage can hold them, and
  # without a check the error would name neither the rule nor the cache.
  defp check_entries!(entries, _node) when is_map(entries), do: entries
  defp check_entries!(entries, node), do: raise(ArgumentError, bad_shape(node, entries, "a map"))

  defp check_value!(value, %Node.Production{} = node) do
    if is_list(value) and not List.improper?(value),
      do: value,
      else: raise(ArgumentError, bad_shape(node, value, "a list of facts"))
  end

  defp check_value!(row, _query), do: row

  defp bad_shape(node, value, expected) do
    "The activation cache holds #{inspect(value, limit: 5)} for " <>
      "#{Network.ref_string({node.module, node.name})}, where it must hold #{expected}. " <>
      "Build it again with `Rete.ActivationCache.from_session/2`."
  end

  # A pattern rather than a field read, so a node from a snapshot that predates the field
  # is a node that did not opt in.
  defp cached?(%{cache: cache}), do: cache not in [nil, false]
  defp cached?(_node), do: false

  defp identity(%{module: module, name: name, hash: hash, cache: cache}),
    do: {module, name, hash, cache}

  defp activation(node, token),
    do: %{rule: {node.module, node.name}, hash: node.hash, cache: node.cache, token: token}
end
