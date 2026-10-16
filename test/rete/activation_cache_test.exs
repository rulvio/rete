defmodule Rete.ActivationCacheTest do
  @moduledoc """
  A prior session as the cache of a fire. See `Rete.ActivationCache`.

  A body sends a message to the process that fires, so a test counts the bodies that ran
  by counting messages.
  """

  use ExUnit.Case, async: true

  alias Rete.ActivationCache
  alias Rete.Listener.Collect
  alias Rete.Network
  alias Rete.Session

  defmodule Cached do
    use Rete.Ruleset

    defrule enrich(%{cache: true}, {:customer, cid}) do
      send(self(), {:ran, :enrich, cid})
      {:profile, cid}
    end

    defrule tag(%{cache: true}, {:customer, cid}) do
      send(self(), {:ran, :tag, cid})
      {:tagged, cid}
    end

    defrule live({:customer, cid}) do
      send(self(), {:ran, :live, cid})
      {:seen, cid}
    end

    defrule maybe(%{cache: true}, {:order, cid, amt}) do
      send(self(), {:ran, :maybe, cid})
      if amt > 100, do: {:big, cid}
    end

    defrule chained(%{cache: true}, {:profile, cid}) do
      send(self(), {:ran, :chained, cid})
      {:ready, cid}
    end
  end

  defmodule Tasks do
    use Rete.Ruleset

    defrule fetch(%{cache: true}, {:job, id}) do
      send(self(), {:ran, :fetch, id})
      Task.async(fn -> {:done, id} end)
    end
  end

  defmodule Other do
    use Rete.Ruleset

    defrule unrelated({:widget, id}), do: {:built, id}
  end

  defmodule ModuleDefaults do
    use Rete.Ruleset, default_rule_opts: %{cache: true, salience: 5}

    defrule plain({:a, x}), do: {:b, x}
    defrule opted_out(%{cache: false}, {:a, x}), do: {:c, x}
    defrule louder(%{salience: 9}, {:a, x}), do: {:d, x}

    defquery bs({:b, x}), do: x
  end

  defmodule NoDefaults do
    use Rete.Ruleset

    defrule plain({:a, x}), do: {:b, x}
    defrule opted_out(%{cache: false}, {:a, x}), do: {:c, x}
    defrule negates({:a, x}, {:not, [{:b, x}, {:c, x}]}), do: {:lonely, x}
  end

  defp ran do
    receive do
      {:ran, rule, id} -> [{rule, id} | ran()]
    after
      0 -> []
    end
  end

  defp fire(modules, facts, opts \\ []) do
    modules |> Session.new() |> Session.insert(facts) |> Session.fire_rules(opts)
  end

  defp cache(session), do: ActivationCache.from_session(session)

  defp sorted_facts(session), do: session |> Session.facts() |> Enum.sort()

  defp cache_flags(session) do
    for node <- session |> Session.network() |> Network.production_nodes(),
        into: %{},
        do: {node.name, node.cache}
  end

  describe "a hit" do
    test "replays the prior conclusion, and the body does not run" do
      facts = [{:customer, 1}, {:customer, 2}]
      prior = fire([Cached], facts)

      assert Enum.sort(ran()) ==
               Enum.sort(for r <- [:enrich, :tag, :live, :chained], c <- [1, 2], do: {r, c})

      next = fire([Cached], facts, activation_cache: cache(prior))

      assert sorted_facts(next) == sorted_facts(prior)
      assert Enum.sort(ran()) == [live: 1, live: 2]
    end

    test "is truth-maintained like a firing" do
      prior = fire([Cached], [{:customer, 1}])
      ran()

      next = fire([Cached], [{:customer, 1}], activation_cache: cache(prior))
      assert {:profile, 1} in Session.facts(next)

      emptied = next |> Session.retract({:customer, 1}) |> Session.fire_rules()
      assert Session.facts(emptied) == []
    end

    test "makes the new session a cache for the next fire" do
      a = fire([Cached], [{:customer, 1}])
      b = fire([Cached], [{:customer, 1}], activation_cache: cache(a))
      ran()

      c = fire([Cached], [{:customer, 1}], activation_cache: cache(b))

      assert ran() == [live: 1]
      assert sorted_facts(c) == sorted_facts(a)
    end

    test "is marked in the listener event, and a live firing is not" do
      prior = fire([Cached], [{:customer, 1}])

      fired =
        [Cached]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:customer, 1})
        |> Session.fire_rules(activation_cache: cache(prior))
        |> Collect.by_tag(:activation_fired)
        |> Map.new(fn {_tag, source, _token, _facts} -> {elem(source.rule, 1), source} end)

      assert fired.enrich.cached == true
      assert fired.chained.cached == true
      refute Map.has_key?(fired.live, :cached)
    end

    test "comes from a session loaded from a snapshot" do
      key = "rete-activation-cache-test"
      prior = [Cached] |> fire([{:customer, 1}]) |> Session.dump!(key) |> Session.load!(key)
      ran()

      fire([Cached], [{:customer, 1}], activation_cache: cache(prior))

      assert ran() == [live: 1]
    end

    test "comes from a cache that was saved and loaded" do
      saved = [Cached] |> fire([{:customer, 1}]) |> cache() |> :erlang.term_to_binary()
      ran()

      loaded = :erlang.binary_to_term(saved, [:safe])
      next = fire([Cached], [{:customer, 1}], activation_cache: loaded)

      assert ran() == [live: 1]
      assert {:profile, 1} in Session.facts(next)
    end

    test "works across networks whose node ids differ" do
      prior = fire([Other, Cached], [{:customer, 1}, {:widget, 1}])
      ran()

      fire([Cached], [{:customer, 1}], activation_cache: cache(prior))

      assert ran() == [live: 1]
    end

    test "answers for a body that concluded nothing" do
      prior = fire([Cached], [{:order, 1, 5}])
      assert ran() == [maybe: 1]

      fired =
        [Cached]
        |> Session.new()
        |> Session.with_listener(Collect, [])
        |> Session.insert({:order, 1, 5})
        |> Session.fire_rules(activation_cache: cache(prior))
        |> Collect.by_tag(:activation_fired)

      assert ran() == []
      assert [{:activation_fired, %{cached: true}, _token, []}] = fired
    end

    test "of an empty conclusion is taken back with its match" do
      prior = fire([Cached], [{:order, 1, 5}])

      drained =
        [Cached]
        |> fire([{:order, 1, 5}], activation_cache: cache(prior))
        |> Session.retract({:order, 1, 5})
        |> Session.fire_rules()

      assert Session.facts(drained) == []
      assert drained.state.memory.insertions == %{}
    end

    test "happens under concurrency, for a body that returns a task" do
      prior = fire([Tasks], [{:job, 1}, {:job, 2}], concurrency: 2)
      assert Enum.sort(ran()) == [fetch: 1, fetch: 2]

      next = fire([Tasks], [{:job, 1}, {:job, 2}], concurrency: 2, activation_cache: cache(prior))

      assert ran() == []
      assert sorted_facts(next) == sorted_facts(prior)
    end
  end

  describe "from_session/2" do
    test "holds the rules that opted in, keyed by identity" do
      cache = [Cached] |> fire([{:customer, 1}]) |> cache()

      names = for {{Cached, name, hash, true}, _entries} <- cache, is_integer(hash), do: name
      assert Enum.sort(names) == [:chained, :enrich, :tag]
    end

    test "holds the facts concluded, under the default key" do
      cache = [Cached] |> fire([{:customer, 1}]) |> cache()

      {_identity, entries} = Enum.find(cache, &match?({{Cached, :enrich, _, _}, _}, &1))
      assert entries == %{{[{:customer, 1}], %{cid: 1}} => [{:profile, 1}]}
    end

    test "holds a firing that concluded nothing" do
      cache = [Cached] |> fire([{:order, 1, 5}]) |> cache()

      assert [{{Cached, :maybe, _hash, true}, entries}] = Map.to_list(cache)
      assert Map.values(entries) == [[]]
    end

    test "is empty for a session that never fired" do
      assert %{} == [Cached] |> Session.new() |> Session.insert({:customer, 1}) |> cache()
    end
  end

  describe "a miss" do
    test "runs a rule that did not opt in" do
      prior = fire([Cached], [{:customer, 1}])
      ran()

      fire([Cached], [{:customer, 1}], activation_cache: cache(prior))

      assert {:live, 1} in ran()
    end

    test "runs the body for facts the prior session did not see" do
      prior = fire([Cached], [{:customer, 1}])
      ran()

      fire([Cached], [{:customer, 2}], activation_cache: cache(prior))

      assert Enum.sort(ran()) == [chained: 2, enrich: 2, live: 2, tag: 2]
    end

    test "keeps two rules over equal facts apart" do
      prior = fire([Cached], [{:customer, 1}])
      next = fire([Cached], [{:customer, 1}], activation_cache: cache(prior))

      assert {:profile, 1} in Session.facts(next)
      assert {:tagged, 1} in Session.facts(next)
    end

    test "runs a body whose conclusion lost its support in the prior session" do
      prior =
        [Cached]
        |> fire([{:customer, 1}])
        |> Session.retract({:customer, 1})
        |> Session.fire_rules()

      ran()

      fire([Cached], [{:customer, 1}], activation_cache: cache(prior))

      assert {:enrich, 1} in ran()
    end

    test "runs a rule whose code changed since the prior session" do
      source = fn body ->
        """
        defmodule Rete.ActivationCacheTest.Changed do
          use Rete.Ruleset
          defrule r(%{cache: true}, {:x, id}) do
            send(self(), {:ran, :r, id})
            #{body}
          end
        end
        """
      end

      compile = fn code ->
        ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(code) end)
      end

      compile.(source.("{:y, id}"))
      prior = fire([Rete.ActivationCacheTest.Changed], [{:x, 1}])
      ran()

      compile.(source.("{:z, id}"))
      next = fire([Rete.ActivationCacheTest.Changed], [{:x, 1}], activation_cache: cache(prior))

      assert ran() == [r: 1]
      assert Session.facts(next) |> Enum.sort() == [{:x, 1}, {:z, 1}]
    end

    test "is the whole fire when no prior session is given" do
      fire([Cached], [{:customer, 1}], activation_cache: nil)
      assert length(ran()) == 4
    end
  end

  describe "the key function" do
    test "replaces the key on both sides" do
      prior = fire([Cached], [{:customer, 1}])
      ran()

      # Every activation of a rule gets one key, so customer 2 hits on customer 1.
      by_rule = fn %{rule: rule} -> rule end

      next =
        fire([Cached], [{:customer, 2}],
          activation_cache: ActivationCache.from_session(prior, key_fn: by_rule),
          activation_cache_key_fn: by_rule
        )

      assert ran() == [live: 2]
      assert {:profile, 1} in Session.facts(next)
    end

    test "misses when the fire keys differently from the cache" do
      prior = fire([Cached], [{:customer, 1}])
      ran()

      fire([Cached], [{:customer, 1}],
        activation_cache: cache(prior),
        activation_cache_key_fn: fn %{rule: rule} -> rule end
      )

      assert Enum.sort(ran()) == [chained: 1, enrich: 1, live: 1, tag: 1]
    end

    test "of the cache can leave an activation out" do
      prior = fire([Cached], [{:customer, 1}, {:customer, 2}])
      ran()

      skip_two = fn %{token: token} = activation ->
        if token.bindings.cid == 2, do: nil, else: ActivationCache.key(activation)
      end

      fire([Cached], [{:customer, 1}, {:customer, 2}],
        activation_cache: ActivationCache.from_session(prior, key_fn: skip_two)
      )

      assert Enum.sort(ran()) == [chained: 2, enrich: 2, live: 1, live: 2, tag: 2]
    end

    test "gets the rule, the hash, the cache value and the token" do
      test = self()
      prior = fire([Cached], [{:customer, 1}])

      key_fn = fn activation ->
        send(test, {:key, activation})
        Rete.ActivationCache.key(activation)
      end

      fire([Cached], [{:customer, 1}],
        activation_cache: cache(prior),
        activation_cache_key_fn: key_fn
      )

      assert_received {:key,
                       %{
                         rule: {Cached, :enrich},
                         hash: hash,
                         cache: true,
                         token: %Rete.Token{} = token
                       }}

      assert is_integer(hash)
      assert token.bindings == %{cid: 1}
    end

    test "skips the cache for one activation when it returns nil" do
      prior = fire([Cached], [{:customer, 1}, {:customer, 2}])
      ran()

      key_fn = fn %{token: token} = activation ->
        if token.bindings.cid == 2, do: nil, else: Rete.ActivationCache.key(activation)
      end

      fire([Cached], [{:customer, 1}, {:customer, 2}],
        activation_cache: cache(prior),
        activation_cache_key_fn: key_fn
      )

      assert Enum.sort(ran()) == [chained: 2, enrich: 2, live: 1, live: 2, tag: 2]
    end
  end

  describe "invalid options" do
    test "a session given as the cache is refused, and the error names from_session" do
      prior = fire([Cached], [{:customer, 1}])

      assert_raise ArgumentError, ~r/Rete.ActivationCache.from_session\(session\)/, fn ->
        fire([Cached], [], activation_cache: prior)
      end
    end

    test "a cache that is not a map is refused" do
      assert_raise ArgumentError, ~r/:activation_cache must be a map/, fn ->
        fire([Cached], [], activation_cache: :bogus)
      end

      assert_raise ArgumentError, ~r/:activation_cache must be a map/, fn ->
        fire([Cached], [], activation_cache: %Rete.Token{})
      end
    end

    test "an empty map is a cache with nothing in it" do
      fire([Cached], [{:customer, 1}], activation_cache: %{})
      assert length(ran()) == 4
    end

    test "a key function of the wrong arity is refused by from_session" do
      assert_raise ArgumentError, ~r/:key_fn must be a function of arity 1/, fn ->
        ActivationCache.from_session(fire([Cached], []), key_fn: fn -> :key end)
      end
    end

    test "a key function of the wrong arity is refused" do
      assert_raise ArgumentError, ~r/:activation_cache_key_fn must be a function/, fn ->
        fire([Cached], [], activation_cache_key_fn: fn -> :key end)
      end
    end
  end

  describe "the cache value" do
    defp fire_built(build_opts, facts, opts \\ []) do
      [NoDefaults]
      |> Session.new(build_opts)
      |> Session.insert(facts)
      |> Session.fire_rules(opts)
    end

    defp hits(session) do
      for {_tag, %{cached: true} = source, _token, _facts} <-
            Collect.by_tag(session, :activation_fired),
          do: elem(source.rule, 1)
    end

    defp fire_observed(build_opts, facts, prior) do
      [NoDefaults]
      |> Session.new(build_opts)
      |> Session.with_listener(Collect, [])
      |> Session.insert(facts)
      |> Session.fire_rules(activation_cache: cache(prior))
    end

    test "any value other than nil or false opts in" do
      for value <- [2, :v2, "2026-10", {:version, 2}] do
        prior = fire_built([default_rule_opts: %{cache: value}], [{:a, 1}])
        next = fire_observed([default_rule_opts: %{cache: value}], [{:a, 1}], prior)

        assert :plain in hits(next), "cache: #{inspect(value)} did not hit"
      end
    end

    test "a new value is a new version, and misses" do
      prior = fire_built([default_rule_opts: %{cache: 2}], [{:a, 1}])
      next = fire_observed([default_rule_opts: %{cache: 3}], [{:a, 1}], prior)

      assert hits(next) == []
      assert Session.facts(next) |> Enum.sort() == Session.facts(prior) |> Enum.sort()
    end

    test "a prior rule that did not opt in is not a cache" do
      prior = fire_built([], [{:a, 1}])
      next = fire_observed([default_rule_opts: %{cache: true}], [{:a, 1}], prior)

      assert hits(next) == []
    end

    test "nil and false opt out" do
      prior = fire_built([default_rule_opts: %{cache: nil}], [{:a, 1}])
      assert hits(fire_observed([default_rule_opts: %{cache: nil}], [{:a, 1}], prior)) == []

      prior = fire_built([default_rule_opts: %{cache: false}], [{:a, 1}])
      assert hits(fire_observed([default_rule_opts: %{cache: false}], [{:a, 1}], prior)) == []
    end

    test "a value written in the rule reaches the node as written" do
      Code.compile_string("""
      defmodule Rete.ActivationCacheTest.Versioned do
        use Rete.Ruleset
        defrule r(%{cache: {:v, 7}}, {:x, id}), do: {:y, id}
      end
      """)

      assert cache_flags(Session.new([Rete.ActivationCacheTest.Versioned])) == %{r: {:v, 7}}
    end
  end

  describe "default rule options" do
    test "a module default reaches every rule, and a rule's own options win" do
      flags = cache_flags(Session.new([ModuleDefaults]))
      assert flags == %{plain: true, opted_out: false, louder: true}

      salience =
        for node <-
              [ModuleDefaults] |> Session.new() |> Session.network() |> Network.production_nodes(),
            into: %{},
            do: {node.name, node.salience}

      assert salience == %{plain: 5, opted_out: 5, louder: 9}
    end

    test "a module default does not reach a query" do
      query = Enum.find(Rete.get_rule_data([ModuleDefaults]), &(&1.name == :bs))
      assert query.opts == []
    end

    test "a session default reaches every rule, beneath the module and the rule" do
      flags = cache_flags(Session.new([NoDefaults], default_rule_opts: %{cache: true}))
      assert flags.plain == true
      assert flags.opted_out == false
      assert flags.negates == true

      assert cache_flags(Session.new([NoDefaults])).plain == nil

      flags = cache_flags(Session.new([ModuleDefaults], default_rule_opts: [cache: false]))
      assert flags == %{plain: true, opted_out: false, louder: true}
    end

    test "a generated negation helper never caches" do
      flags = cache_flags(Session.new([NoDefaults], default_rule_opts: %{cache: true}))

      helpers = Map.drop(flags, [:plain, :opted_out, :negates])
      assert map_size(helpers) > 0
      assert Enum.all?(helpers, fn {_name, cache} -> cache == nil end)
    end

    test "a session default enables the cache" do
      prior =
        [NoDefaults]
        |> Session.new(default_rule_opts: %{cache: true})
        |> Session.insert({:a, 1})
        |> Session.fire_rules()

      next = Session.new([NoDefaults], default_rule_opts: %{cache: true})

      hits =
        next
        |> Session.with_listener(Collect, [])
        |> Session.insert({:a, 1})
        |> Session.fire_rules(activation_cache: cache(prior))
        |> Collect.by_tag(:activation_fired)
        |> Enum.filter(fn {_tag, source, _token, _facts} -> Map.get(source, :cached) end)
        |> Enum.map(fn {_tag, source, _token, _facts} -> elem(source.rule, 1) end)

      assert :plain in hits
      refute :opted_out in hits
    end

    test "an unknown or reserved key is refused at the session" do
      assert_raise ArgumentError, ~r/sets \[:internal_salience\], which a default cannot/, fn ->
        Session.new([NoDefaults], default_rule_opts: %{internal_salience: 1})
      end

      assert_raise ArgumentError, ~r/must be a map or a keyword list/, fn ->
        Session.new([NoDefaults], default_rule_opts: :cache)
      end
    end

    test "an unknown key is refused at the module" do
      assert_raise ArgumentError, ~r/sets \[:cachee\], which a default cannot/, fn ->
        Code.compile_string("""
        defmodule Rete.ActivationCacheTest.BadDefaults do
          use Rete.Ruleset, default_rule_opts: %{cachee: true}
        end
        """)
      end
    end
  end
end
