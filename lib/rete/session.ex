defmodule Rete.Session do
  @moduledoc """
  A session is an immutable value: every operation returns a new one.

  A session can be held, compared, kept as a checkpoint and sent between processes. The
  compiled network inside it is shared rather than copied, so two sessions built from the
  same rules differ only in their working memory. `dump/2` and `load/2` move a session to
  another node.

  Facts you insert stay until you retract them. Facts a *rule* concludes are logical: the
  engine holds them only while the match behind them holds. That is why a rule's right
  hand side only inserts. It is also why retracting a fact removes anything concluded from
  it too, transitively.

  `fire_rules/2` is the only call that matches anything. `insert/2` and `retract/2` record
  facts and queue the work. So a session you have not fired holds facts, and no matches.

  The examples here run against this ruleset:

      defmodule Rete.Doc.Orders do
        use Rete.Ruleset

        derive :premium, :customer

        defrule large_order({:customer, cid}, {:order, cid, amt} when amt > 100) do
          {:flagged, cid, amt}
        end

        defquery flagged_for(cid)({:flagged, cid, amt}), do: {cid, amt}
      end

      iex> alias Rete.Session
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> Session.facts(session) |> Enum.sort()
      [{:customer, 1}, {:flagged, 1, 250}, {:order, 1, 250}]
      iex> Rete.Doc.Orders.flagged_for(session, 1)
      [{1, 250}]

  See `docs/dsl.md` for writing rules and `docs/design/engine.md` §8 for truth
  maintenance.
  """

  alias Rete.Compiler
  alias Rete.Engine
  alias Rete.Engine.State
  alias Rete.Image
  alias Rete.Network
  alias Rete.Snapshot

  @type t :: %__MODULE__{state: State.t()}

  defstruct [:state]

  @doc """
  Builds a session from ruleset modules.

  Options go to `Rete.Compiler.build/2`. Compiling the network is the expensive part, so
  a long-lived application should do it once and use `from_network/1`.

  By default, the session calls the ruleset modules. `target_images: true` makes it run the
  image of each ruleset module. Then it keeps its rules after a hot upgrade of the module,
  until you build it again.

  **With hot code upgrades, build with `target_images: true`.** Call `latest?/1` after each
  upgrade, and build a new session when it returns `false`.

  With `target_images: true`, raises `ArgumentError` if the image of a ruleset module did
  not compile or does not load. See `Rete.Compiler.build/2`.

  `default_rule_opts: %{cache: true}` gives every rule these options. The defaults of a
  ruleset module, and the options map of a rule, both win over it.

      iex> Rete.Session.new([Rete.Doc.Orders]) |> Rete.Session.facts()
      []
  """
  @spec new([module()], keyword()) :: t()
  def new(modules, opts \\ []) when is_list(modules) do
    modules |> Compiler.build(opts) |> from_network()
  end

  @doc """
  Builds an empty session over an already compiled network.

  The network is immutable, so one can back any number of independent sessions.
  """
  @spec from_network(Network.t()) :: t()
  def from_network(%Network{} = network), do: %__MODULE__{state: Engine.new(network)}

  @doc """
  Inserts one fact or a list of them, returning a new session.

  Facts are a multiset, and every occurrence matches. Inserting a fact equal to one already
  present gives the rules a second match of it, and it takes a second retraction to remove.

  Inserting does not match anything. It records the fact and queues the work.
  `fire_rules/2` is what matches, and until you call it no rule has seen the fact.

  Raises `ArgumentError` for a fact whose type a compound negation generated. Only the
  engine inserts those.

      iex> alias Rete.Session
      iex> session = Session.new([Rete.Doc.Orders]) |> Session.insert({:customer, 1})
      iex> Session.facts(session)
      [{:customer, 1}]
  """
  @spec insert(t(), term() | [term()]) :: t()
  def insert(session, facts), do: update(session, &Engine.insert(&1, List.wrap(facts)))

  @doc """
  Retracts one fact or a list of them, returning a new session.

  Anything concluded from them is retracted too, transitively. Retracting a fact that is
  not present does nothing. A fact whose type a compound negation generated raises
  `ArgumentError`, as in `insert/2`.

  Like `insert/2`, this queues the work rather than doing it. The fact leaves at once, and
  the conclusions that rested on it leave when `fire_rules/2` drains the queue.

      iex> alias Rete.Session
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      ...>   |> Session.retract({:customer, 1})
      ...>   |> Session.fire_rules()
      iex> Session.facts(session)
      [{:order, 1, 250}]
  """
  @spec retract(t(), term() | [term()]) :: t()
  def retract(session, facts), do: update(session, &Engine.retract(&1, List.wrap(facts)))

  @doc """
  Fires rules until the agenda is empty, returning a new session.

  Options:

    * `:max_cycles` — how many **cycles** one call may fire. A cycle is one pass of the
      fire loop: one activation at the default concurrency, one whole activation group
      above it. `100_000` by default, which no settling ruleset has reached. A ruleset that
      exceeds it raises with the rules that fired most. One that fires the whole allowance
      and then settles is fine. Give it a smaller integer to catch a loop sooner, or
      `:infinity` to remove the cap. See `docs/design/observability.md` §3 for how to pick
      a number.
    * `:concurrency` — how many tasks that rule bodies returned may run at once. `1` by
      default. A body that does I/O can return a `Task` instead of its facts, and the
      result of the task is the facts. At `1`, the engine awaits each task before the next
      body runs. Above `1`, it runs the bodies of one activation group in turn, and awaits
      up to this many of their tasks together. It applies their conclusions in group
      order. Every body runs in the calling process. So a body that blocks without a task
      never overlaps another.
    * `:timeout` — milliseconds the engine waits for one returned task, or `:infinity`, the
      default. A task that takes longer is shut down, and the call raises.
    * `:activation_cache` — a plain map from `Rete.ActivationCache.from_session/2`, or
      `nil`, the default. Any other value raises, a session included. A rule or a query can
      set `:cache` to a value other than `nil` or `false`. It then takes what the cache
      holds for an equal activation, and its body does not run. The option applies to
      this call only.
    * `:activation_cache_key_fn` — an arity-1 function that gives the key of an
      activation. It gets `%{rule: {module, name}, hash: hash, cache: cache, token: token}`.
      When it returns `nil`, that activation runs without the cache.
      `Rete.ActivationCache.key/1` by default. Give the same function that built the cache.

  Start a returned task in the body itself, because only its owner can await it. It is an
  ordinary `Task`. When the engine sees it exit, the call raises an error that names the
  rule.

  **This is the only call that propagates.** `insert/2` and `retract/2` queue work. Firing
  drains that queue, matches everything waiting, runs the rules that match, and returns at
  quiescence. So a session you have not fired holds facts but no matches.

      iex> alias Rete.Session
      iex> queued =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      iex> Rete.Doc.Orders.flagged_for(queued, 1)
      []
      iex> Rete.Doc.Orders.flagged_for(Session.fire_rules(queued), 1)
      [{1, 250}]
  """
  @spec fire_rules(t(), keyword()) :: t()
  def fire_rules(session, opts \\ []), do: update(session, &Engine.fire_rules(&1, opts))

  @doc """
  Whether the session has no work waiting for `fire_rules/2`.

  `false` means `insert/2` or `retract/2` recorded a fact that no rule has seen yet. A
  query on such a session answers as though the fact never arrived, so this is the check
  to make when you did not write the `insert/2` yourself.

  A session fresh from `new/1` is **not** settled. `new/1` queues the root token, which
  the first fire plants. So a rule with no conditions has not fired yet either.

      iex> alias Rete.Session
      iex> queued = Session.new([Rete.Doc.Orders]) |> Session.insert({:customer, 1})
      iex> Session.settled?(queued)
      false
      iex> Session.settled?(Session.fire_rules(queued))
      true
  """
  @spec settled?(t()) :: boolean()
  def settled?(%__MODULE__{state: state}), do: Engine.settled?(state)

  @doc """
  Runs a query by `{module, name}`: one result per match, computed by its body.

  **Usually you would not write this.** `defquery flagged_for(...)` defines
  `flagged_for/2` in its own module, so the same call reads
  `Rete.Doc.Orders.flagged_for(session, 1)`, which the compiler checks. Use this form
  when the query is decided at runtime.

  `params` gives a value for every binding that the head of the query makes, and for no
  other name. Write it as a keyword list or a map. A query with no head takes no
  parameters. A partial key, an extra key or an unknown key raises an error. It does not
  answer `[]`.

  **This takes the bindings, and not the head.** The head of a query is a pattern, and the
  generated function matches it. This call is dispatched by `{module, name}` at run time,
  so it cannot know that pattern. It takes the names the pattern binds instead. For a head
  of `({cid, tid})`, the generated function takes `{1, 2}` and this one takes
  `%{cid: 1, tid: 2}`. A head guard holds here too, so a value it rejects answers `[]`.
  See `Rete.Ruleset.defquery/2`.

  **A query answers as of the most recent fire.** On a session you never fired that is
  `[]`. On one you fired and then inserted into, it is the answer from before that insert,
  which is stale rather than empty. A query reads propagated state either way, and it does
  not raise, where `Rete.Inspect.why_not/2` does. Call `settled?/1` to tell the two cases
  apart.

  Row order is **unspecified**. Rows come back in the order the facts arrived, so the same
  facts fed in a different order answer in a different order. The *set* of rows never
  varies. Sort the result yourself if order matters to you.

  A parameter matches a binding by **term equality**, in the same way as a map key. `1` and
  `1.0` are therefore different parameter values, but `==` reports that they are equal.

      iex> alias Rete.Session
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> Session.query(session, {Rete.Doc.Orders, :flagged_for}, cid: 1)
      [{1, 250}]

  A second order, queued and not yet fired. The answer is the one from before it, not
  `[]`:

      iex> alias Rete.Session
      iex> stale =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      ...>   |> Session.insert({:order, 1, 900})
      iex> Session.settled?(stale)
      false
      iex> Session.query(stale, {Rete.Doc.Orders, :flagged_for}, cid: 1)
      [{1, 250}]
      iex> fired = Session.fire_rules(stale)
      iex> fired |> Session.query({Rete.Doc.Orders, :flagged_for}, cid: 1) |> Enum.sort()
      [{1, 250}, {1, 900}]
  """
  @spec query(t(), {module(), atom()}, keyword() | %{atom() => term()}) :: [term()]
  def query(%__MODULE__{state: state}, ref, params \\ []),
    do: Engine.query(state, ref, params)

  @doc """
  Every fact the session holds, inserted or concluded, one entry for each occurrence.

  Unordered. A session is a multiset of facts, not a sequence. A fact held twice appears
  twice here, whether two inserts put it there or two matches concluded it.

  The two halves answer on different clocks. `insert/2` and `retract/2` update working
  memory at once, so an inserted fact appears here before anything matches it. A concluded
  fact is as of the most recent fire, because concluding one is what `fire_rules/2` does.
  So a session with a queued retract shows the conclusions that rested on the fact it took
  out. `settled?/1` reports whether a fire is owed.
  """
  @spec facts(t()) :: [term()]
  def facts(%__MODULE__{state: state}), do: Engine.facts(state)

  @doc """
  Attaches a listener, returning a new session.

  The listener sees every event from now on. Read what it accumulated with
  `listener_state/2`. Attaching several is fine, and they see events in attachment order.

      iex> alias Rete.Session
      iex> Session.new([Rete.Doc.Orders])
      ...> |> Session.with_listener(Rete.Listener.Collect, [])
      ...> |> Session.insert({:customer, 1})
      ...> |> Rete.Listener.Collect.by_tag(:fact_inserted)
      [{:fact_inserted, {:customer, 1}, {Rete.Session, :insert}}]
  """
  @spec with_listener(t(), module(), term()) :: t()
  def with_listener(session, module, init \\ nil),
    do: update(session, &Engine.with_listener(&1, module, init))

  @doc """
  What a listener has accumulated, or `nil` if it is not attached.
  """
  @spec listener_state(t(), module()) :: term()
  def listener_state(%__MODULE__{state: state}, module),
    do: Engine.listener_state(state, module)

  @doc """
  The compiled network behind a session.
  """
  @spec network(t()) :: Network.t()
  def network(%__MODULE__{state: state}), do: state.network

  @doc """
  Whether the session runs the rules that its ruleset modules hold now.

  For a session built with `target_images: true`, or a loaded session, it is `false` after a
  hot upgrade changes the code that the rules reach. A session built with
  `target_images: true` keeps running its own rules, consistently. Build a new session
  with `new/2` to run the new rules. The facts do not move to it, so insert them again.

  **With hot code upgrades, build with `target_images: true`, and call this after each
  upgrade.** A session built without target images records no images, so it is the latest.
  It calls the ruleset modules, and it is not safe across a hot upgrade.

  A dump points the rules at the images and records them. So a loaded session is not the
  latest when this node runs another version of a module, or none. It still runs the rules
  it was dumped with.

  Each call reads the image that each ruleset module offers now. It does not check a call
  to another module, a `:fact_type_fn` that no rule calls, or a capture inside a fact.

      iex> Rete.Session.new([Rete.Doc.Orders]) |> Rete.Session.latest?()
      true
  """
  @spec latest?(t()) :: boolean()
  def latest?(%__MODULE__{state: state}) do
    Enum.all?(state.network.built_images, fn {module, image} -> Image.name(module) == image end)
  end

  @doc """
  Turns a session into a binary that `load/2` reads on another node.

  The binary holds the working memory, the network and the compiled code of every rule. A
  node that loads it runs **these** rules, even if it defines other versions of the
  ruleset modules, or none of them. A session that is not `latest?/1` dumps the rules it
  was built with, and not the rules its modules hold now. A `:fact_type_fn`, and a call
  from a rule to another module, run the version on the node that loads it.

  `secret` is a binary key. The snapshot carries an HMAC-SHA256 under it, and `load/2`
  refuses the snapshot without the same key. Use a random key, such as
  `:crypto.strong_rand_bytes(32)`, and keep it in your secret store.

  **A snapshot is signed, not encrypted.** Anyone who has the binary can read every fact in
  it. That can include a fact that was retracted, because the session keeps it internally
  for a time. A loaded session is in exactly the state that was dumped, apart from the
  network. A dump points the rules of a session built without target images at the images.
  Work that `fire_rules/2` has not done yet travels too, such as a pending retract.

  Listeners do not travel. Attach them again with `with_listener/3` after `load/2`.

  Returns `{:ok, binary}`, or `{:error, reason}`:

    * `{:not_portable, fun}` — the session holds an anonymous function, such as an
      anonymous `:fact_type_fn`. Only a remote capture, `&Mod.fun/arity`, works on another
      node.
    * `{:no_image, module, detail}` — the image of a ruleset module did not compile.
      `detail` is the cause that the compile gave.
    * `{:no_beam, image}` — the session runs an image that this node never compiled or
      loaded, such as a session that arrived by distribution.

  Raises `ArgumentError` if `secret` is empty or is not a binary. See
  `docs/design/snapshot.md`.

      iex> alias Rete.Session
      iex> session =
      ...>   Session.new([Rete.Doc.Orders])
      ...>   |> Session.insert([{:customer, 1}, {:order, 1, 250}])
      ...>   |> Session.fire_rules()
      iex> key = "a key from your secret store"
      iex> {:ok, binary} = Session.dump(session, key)
      iex> {:ok, loaded} = Session.load(binary, key)
      iex> Rete.Doc.Orders.flagged_for(loaded, 1)
      [{1, 250}]
  """
  @spec dump(t(), binary()) :: {:ok, binary()} | {:error, term()}
  def dump(%__MODULE__{state: state}, secret), do: Snapshot.dump(state, secret)

  @doc """
  Turns a session into a binary, as `dump/2` does, and returns the binary.

  Raises `ArgumentError` where `dump/2` returns `{:error, reason}`. The message says what
  went wrong.

      iex> alias Rete.Session
      iex> key = "a key from your secret store"
      iex> binary = [Rete.Doc.Orders] |> Session.new() |> Session.dump!(key)
      iex> is_binary(binary)
      true
  """
  @spec dump!(t(), binary()) :: binary()
  def dump!(%__MODULE__{} = session, secret) do
    case dump(session, secret) do
      {:ok, binary} -> binary
      {:error, reason} -> failed!("dump the session", reason)
    end
  end

  @doc """
  Reads a binary that `dump/2` wrote, and loads the rule code it holds.

  The session runs the rules it was dumped with, and has no listener. A query keeps its
  `{module, name}`, so `query/3` reaches it on any node.

  **A snapshot holds code, and loading it runs that code.** `load/2` checks the signature
  before it decodes the body. So a binary that was written or changed without `secret`
  loads nothing. Keep the key apart from the place that stores the snapshots.

  Returns `{:ok, session}`, or `{:error, reason}`:

    * `:invalid` — the value is not a snapshot. This includes a value that is not a binary.
    * `:signature` — the signature does not match `secret`. Another key signed the
      snapshot, or someone changed it.
    * `{:format, n}` — another release of rete wrote it, with a format this one cannot
      read.
    * `:undecodable` — the signature matches, but this node cannot read the body. Another
      release of OTP or of rete probably wrote it.
    * `{:image, image, reason, otp}` — an image did not load. `otp` is the release that
      compiled that image, or `nil` when the beam does not record it. A beam from a newer
      OTP may not load on an older one.
    * `{:missing, mfas}` — the rules call functions that this node does not define.

  An image stays loaded, also after an error, because another session can need it. A rule
  that calls another module runs the version on **this** node.

  Raises `ArgumentError` if `secret` is empty or is not a binary. See
  `docs/design/snapshot.md`.
  """
  @spec load(term(), binary()) :: {:ok, t()} | {:error, term()}
  def load(binary, secret) do
    with {:ok, state} <- Snapshot.load(binary, secret), do: {:ok, %__MODULE__{state: state}}
  end

  @doc """
  Reads a binary that `dump/2` wrote, as `load/2` does, and returns the session.

  Raises `ArgumentError` where `load/2` returns `{:error, reason}`. The message says what
  went wrong.

      iex> alias Rete.Session
      iex> key = "a key from your secret store"
      iex> binary = [Rete.Doc.Orders] |> Session.new() |> Session.dump!(key)
      iex> %Session{} = Session.load!(binary, key)
  """
  @spec load!(term(), binary()) :: t()
  def load!(binary, secret) do
    case load(binary, secret) do
      {:ok, session} -> session
      {:error, reason} -> failed!("load the snapshot", reason)
    end
  end

  @spec failed!(String.t(), term()) :: no_return()
  defp failed!(what, reason),
    do: raise(ArgumentError, "cannot #{what}. " <> Snapshot.message(reason))

  defp update(%__MODULE__{state: state}, fun), do: %__MODULE__{state: fun.(state)}
end
