defmodule Rete.ActivationCache do
  @moduledoc """
  Lets a cache, built from an earlier session, stand in for the body of a rule.

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
  that lost its support is gone from that record, so the cache holds only what is still
  true in the session it came from.

  The cache is a plain map. Save it in the way that suits you, and load it before a fire:

      File.write!(path, :erlang.term_to_binary(cache))
      cache = path |> File.read!() |> :erlang.binary_to_term([:safe])

  `[:safe]` refuses an atom that the node does not know. So load the ruleset modules before
  the cache. **A cache inserts facts, and no rule checks them. Load a cache only from
  storage you trust.** A session from `Rete.Session.load/2` gives a cache too. You need
  the whole session only to inspect it.

  Two activations are equal when two things agree:

    * the rule. Its module, its name, its hash and its `:cache` value must be equal. The
      hash covers the left hand side, the options map and the body, as written. So an edit
      to the rule makes a miss. A new `:cache` value makes a miss too, also when a default
      gives it. So the value acts as a version.
    * the key. `key/1` gives the facts that the activation matched, and its bindings.
      `from_session/2` takes `:key_fn` to replace it, and `fire_rules/2` takes
      `:activation_cache_key_fn`. Give both the same function, or nothing hits.

  The rule is found by these values and not by node ids. So a cache serves sessions from
  other builds, and from other sets of modules. Only the rules that both have can hit.

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
          optional({module(), atom(), integer(), term()}) => %{optional(term()) => [term()]}
        }

  @doc """
  The default key of an activation: the facts it matched, in match order, and its
  bindings.

  The key holds the full terms and not a hash of them. So two keys are equal only when the
  activations are. The node ids of the match are not in it, so the key does not change
  from one network to another.

      iex> token = %Rete.Token{matches: [{{:order, 1}, 7}], bindings: %{id: 1}}
      iex> Rete.ActivationCache.key(%{rule: {MyRules, :r}, hash: 1, cache: true, token: token})
      {[{:order, 1}], %{id: 1}}
  """
  @spec key(activation()) :: term()
  def key(%{token: %Token{} = token}), do: {Token.facts(token), token.bindings}

  @doc """
  Builds a cache from what a session concluded.

  It holds every rule of the session that opted in, and every match that rule fired on
  and that still holds. A match that concluded nothing is in it too, so it hits as well.
  Fire the session first, because a session that never fired holds no conclusions.

  Options:

    * `:key_fn` — an arity-1 function that gives the key of an activation, or `nil` to
      leave it out. `key/1` by default. Give `fire_rules/2` the same function as
      `:activation_cache_key_fn`.

      iex> alias Rete.Session
      iex> [Rete.Doc.Orders]
      ...> |> Session.new(default_rule_opts: %{cache: true})
      ...> |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...> |> Session.fire_rules()
      ...> |> Rete.ActivationCache.from_session()
      ...> |> Enum.map(fn {{module, name, _hash, cache}, entries} ->
      ...>   {module, name, cache, Map.values(entries)}
      ...> end)
      [{Rete.Doc.Orders, :large_order, true, [[{:flagged, 1, 250}]]}]
  """
  @spec from_session(Rete.Session.t(), keyword()) :: t()
  def from_session(%Rete.Session{state: %State{} = state}, opts \\ []) do
    key_fn = opts |> Keyword.get(:key_fn, &key/1) |> validate_key_fn!()
    %State{network: network, memory: %Memory{insertions: insertions}} = state

    # Any batch of a token will do. `Rete.Memory.add_insertion/4` says why they are equal.
    for %Node.Production{cache: cache} = node <- Network.production_nodes(network),
        cache not in [nil, false],
        by_token = Map.get(insertions, node.id, %{}),
        map_size(by_token) > 0,
        into: %{} do
      entries =
        for {token, [batch | _]} <- by_token,
            key = key_fn.(activation(node, token)),
            key != nil,
            into: %{},
            do: {key, batch}

      {identity(node), entries}
    end
  end

  defp validate_key_fn!(fun) when is_function(fun, 1), do: fun

  defp validate_key_fn!(other) do
    raise ArgumentError, ":key_fn must be a function of arity 1, got: #{inspect(other)}"
  end

  @doc false
  @spec lookup(t(), Node.Production.t(), Token.t(), (activation() -> term())) ::
          {:ok, [term()]} | :error
  def lookup(cache, %Node.Production{} = node, token, key_fn) do
    with {:ok, entries} <- Map.fetch(cache, identity(node)),
         key when key != nil <- key_fn.(activation(node, token)) do
      Map.fetch(entries, key)
    else
      _ -> :error
    end
  end

  defp identity(%Node.Production{module: module, name: name, hash: hash, cache: cache}),
    do: {module, name, hash, cache}

  defp activation(%Node.Production{} = node, token),
    do: %{rule: {node.module, node.name}, hash: node.hash, cache: node.cache, token: token}
end
