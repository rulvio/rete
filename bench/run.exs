# Scaling benchmarks. `mix bench`
#
# These do not ask "how fast is it". They ask "what shape is it" — the question
# that matters for a Rete engine, where the failure mode is not a slow function
# but an operation that is quadratic in something a session accumulates. Three
# such quadratics were found and fixed at once, and each was invisible until the
# one above it was gone; nothing but a scaling measurement would have shown them.
#
# So a scaling scenario runs at three sizes and reports the empirical exponent: the
# k in O(n^k), read off the growth between one size and the next. Around 1.0 is
# linear and fine. Around 2.0 is quadratic and is a bug unless it is listed as a
# known gap below.
#
# Timing is not asserted on and this is not in CI. Wall-clock thresholds on
# shared runners produce failures that mean nothing, and the number worth
# watching — the exponent — is stable enough to read by eye and too noisy to
# gate on.

defmodule Bench do
  @moduledoc false

  # Enough repeats to median away a stray GC pause, few enough to stay usable.
  @repeats 5

  def scenario(label, sizes, fun, opts \\ []) do
    IO.puts("\n\e[1m#{label}\e[0m")
    for note <- List.wrap(opts[:note]), do: IO.puts("  #{note}")

    results = Enum.map(sizes, fn n -> {n, time(fn -> fun.(n) end)} end)

    results
    |> Enum.with_index()
    |> Enum.each(fn {{n, ms}, index} ->
      IO.puts(
        "  #{pad(n, 7)}  #{pad(fmt(ms), 9)} ms#{growth(Enum.at(results, index - 1), n, ms, index)}"
      )
    end)

    verdict(results, opts[:expect] || :linear)
  end

  # An A/B rather than a shape. `:concurrency` does not change how firing scales, only how
  # long a body blocks for, so the exponent says nothing and the ratio says everything.
  def compare(label, variants, fun, opts \\ []) do
    IO.puts("\n\e[1m#{label}\e[0m")
    for note <- List.wrap(opts[:note]), do: IO.puts("  #{note}")

    results = Enum.map(variants, fn {name, arg} -> {name, time(fn -> fun.(arg) end)} end)
    {_name, baseline} = hd(results)

    Enum.each(results, fn {name, ms} ->
      speedup = if ms > 0, do: "   ×#{fmt(baseline / ms)}", else: ""
      IO.puts("  #{pad(name, 16)}  #{pad(fmt(ms), 9)} ms#{speedup}")
    end)
  end

  # A run is timed after a warm-up pass, because the first call through a fresh
  # network pays for JIT and for the first allocation of every memory it touches.
  defp time(fun) do
    fun.()

    1..@repeats
    |> Enum.map(fn _ ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fun)
      us / 1000
    end)
    |> median()
  end

  defp median(times) do
    times |> Enum.sort() |> Enum.at(div(length(times), 2))
  end

  defp growth(_previous, _n, _ms, 0), do: ""

  defp growth({prev_n, prev_ms}, n, ms, _index) when prev_ms > 0 do
    "   ×#{fmt(ms / prev_ms)}   ~n^#{fmt(exponent(prev_n, prev_ms, n, ms))}"
  end

  defp growth(_previous, _n, _ms, _index), do: "   (too fast to compare)"

  # k such that t2/t1 = (n2/n1)^k.
  defp exponent(n1, t1, n2, t2), do: :math.log(t2 / t1) / :math.log(n2 / n1)

  defp verdict(results, expect) do
    ks =
      results
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [{_, t1}, _] -> t1 > 0 end)
      |> Enum.map(fn [{n1, t1}, {n2, t2}] -> exponent(n1, t1, n2, t2) end)

    case {ks, expect} do
      {[], _} ->
        IO.puts("  \e[33m?\e[0m too fast to judge — raise the sizes")

      {ks, :linear} ->
        worst = Enum.max(ks)

        if worst < 1.5 do
          IO.puts("  \e[32m✓\e[0m linear (worst ~n^#{fmt(worst)})")
        else
          IO.puts("  \e[31m✗\e[0m superlinear: ~n^#{fmt(worst)}, expected about n^1")
        end

      {ks, {:known, why}} ->
        IO.puts("  \e[33m!\e[0m ~n^#{fmt(Enum.max(ks))} — known: #{why}")
    end
  end

  defp fmt(float), do: :erlang.float_to_binary(float * 1.0, decimals: 2)
  defp pad(value, width), do: String.pad_leading(to_string(value), width)

  # The network is compiled once and each run gets an empty session over it.
  # Otherwise every measurement would include compiling the ruleset, which is
  # constant work that has nothing to do with the thing being measured.
  def network(module), do: Rete.Compiler.build([module])
  def session(network), do: Rete.Session.from_network(network)
end

# --- the rulesets ---------------------------------------------------------------
#
# One module per scenario. Sharing a ruleset would mean every scenario's facts
# propagated through every other scenario's rules, and the measurement would be
# of the fixture rather than of the thing named.

defmodule Bench.OneKey do
  @moduledoc false
  use Rete.Ruleset

  # `{:b, y}` shares no variable with `{:a, x}`, so every element lands under the
  # same join key. This is also the shape of every rule's *first* condition,
  # which a root join stores under one key by definition — so a large single
  # bucket is the normal case, not a pathological one.
  defrule pair({:a, x}, {:b, y}) do
    {:pair, x, y}
  end
end

defmodule Bench.ManyKeys do
  @moduledoc false
  use Rete.Ruleset

  defrule paired({:cust, id}, {:order, id, amt}) do
    {:paired, id, amt}
  end
end

defmodule Bench.Agenda do
  @moduledoc false
  use Rete.Ruleset

  defrule note({:seed, i}) do
    {:noted, i}
  end
end

defmodule Bench.Cascade do
  @moduledoc false
  use Rete.Ruleset

  # The bound is a fact rather than a literal so the depth can be varied without
  # recompiling: inserting {:limit, n} and {:n, 0} cascades n deep.
  defrule step({:limit, limit}, {:n, i} when i < limit) do
    {:n, i + 1}
  end
end

defmodule Bench.Chain do
  @moduledoc false
  use Rete.Ruleset

  defrule b({:a, x}), do: {:b, x}
  defrule c({:b, x}), do: {:c, x}
  defrule d({:c, x}), do: {:d, x}
end

defmodule Bench.Collection do
  @moduledoc false
  use Rete.Ruleset

  defrule tally({:cust, id}, orders = [{:order, id, _amt}]) do
    {:tally, id, length(orders)}
  end
end

defmodule Bench.Negation do
  @moduledoc false
  use Rete.Ruleset

  defrule dormant({:cust, id}, {:not, [{:order, id}]}) do
    {:dormant, id}
  end
end

defmodule Bench.UnkeyedNegation do
  @moduledoc false
  use Rete.Ruleset

  # The negated condition shares no variable with the token, so every token and
  # every element lands under one join key. `Bench.Negation` above is the
  # well-keyed case — one token and one element per key — which hides whatever a
  # negation node does per arriving element.
  defrule blocked({:cust, id}, {:not, [{:blocker, _b}]}) do
    {:blocked, id}
  end
end

defmodule Bench.Shared do
  @moduledoc false
  use Rete.Ruleset

  # Two rules concluding the same fact: the textbook truth-maintenance shape.
  # Whichever fires second finds its conclusion already present, which is the
  # only thing that sends `well_founded/3` looking for the support closure.
  defrule from_x({:x, i}), do: {:derived, i}
  defrule from_y({:y, i}), do: {:derived, i}
end

defmodule Bench.Blocking do
  @moduledoc false
  use Rete.Ruleset

  # Stands in for a body that waits on something — a query, a service, a file. That is the
  # only case `:concurrency` is for; a body that builds a tuple is ~1.5% of firing and
  # costs more than that to hand to a task.
  defrule fetch({:job, id}) do
    Process.sleep(5)
    {:fetched, id}
  end
end

# --- the scenarios ---------------------------------------------------------------

alias Bench.{Agenda, Blocking, Cascade, Chain, Collection, ManyKeys, Negation, OneKey}
alias Bench.{Shared, UnkeyedNegation}

one_key = Bench.network(OneKey)
many_keys = Bench.network(ManyKeys)
agenda = Bench.network(Agenda)
cascade = Bench.network(Cascade)
chain = Bench.network(Chain)
collection = Bench.network(Collection)
negation = Bench.network(Negation)
unkeyed_negation = Bench.network(UnkeyedNegation)
shared = Bench.network(Shared)
blocking = Bench.network(Blocking)

IO.puts("\n\e[1m\e[4mrete scaling\e[0m")

Bench.scenario(
  "insert into one join key",
  [1_000, 2_000, 4_000],
  fn n ->
    facts = [{:a, 1} | for(i <- 1..n, do: {:b, i})]

    one_key |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
  end,
  note: "every element under one key — was O(n²) in the bucket's append"
)

Bench.scenario(
  "insert across many join keys",
  [1_000, 2_000, 4_000],
  fn n ->
    facts = for i <- 1..n, do: {:cust, i}
    orders = for i <- 1..n, do: {:order, i, i}

    many_keys
    |> Bench.session()
    |> Rete.Session.insert(facts ++ orders)
    |> Rete.Session.fire_rules()
  end,
  note: "the well-keyed case: n buckets of one, so it exercises grouping instead"
)

Bench.scenario(
  "retract the oldest facts in a bucket",
  [1_000, 2_000, 4_000],
  fn n ->
    facts = for i <- 1..n, do: {:b, i}
    session = one_key |> Bench.session() |> Rete.Session.insert([{:a, 1} | facts])

    session
    |> Rete.Session.retract(Enum.take(facts, 100))
    |> Rete.Session.fire_rules()
  end,
  note: "a fixed 100 retractions, so time must not grow with the bucket at all"
)

Bench.scenario(
  "retract the newest facts in a bucket",
  [1_000, 2_000, 4_000],
  fn n ->
    facts = for i <- 1..n, do: {:b, i}
    session = one_key |> Bench.session() |> Rete.Session.insert([{:a, 1} | facts])

    session
    |> Rete.Session.retract(Enum.take(facts, -100))
    |> Rete.Session.fire_rules()
  end,
  note: "the other end of the same bucket — a list makes one of these two slow"
)

Bench.scenario(
  "pending activations of one rule",
  [1_000, 2_000, 4_000],
  fn n ->
    facts = for i <- 1..n, do: {:seed, i}

    agenda |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
  end,
  note: "every match shares a sort key — was O(n²) inserting into a sorted list"
)

Bench.scenario(
  "cancel n pending activations of one rule",
  [250, 500, 1_000, 2_000],
  fn n ->
    facts = for i <- 1..n, do: {:seed, i}
    session = agenda |> Bench.session() |> Rete.Session.insert(facts)

    session |> Rete.Session.retract(facts) |> Rete.Session.fire_rules()
  end,
  note: "retract the support before firing, so every match leaves the agenda unfired"
)

Bench.scenario(
  "a cascade n rules deep",
  [1_000, 2_000, 4_000],
  fn n ->
    cascade
    |> Bench.session()
    |> Rete.Session.insert([{:limit, n}, {:n, 0}])
    |> Rete.Session.fire_rules()
  end,
  note: "one activation at a time, each concluding the next; a depth test, not a width one"
)

Bench.scenario(
  "truth maintenance through a chain",
  [1_000, 2_000, 4_000],
  fn n ->
    facts = for i <- 1..n, do: {:a, i}

    session =
      chain |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()

    session |> Rete.Session.retract(facts) |> Rete.Session.fire_rules()
  end,
  note: "retracting n facts that each support three conclusions"
)

Bench.scenario(
  "two rules concluding the same fact",
  [125, 250, 500, 1_000],
  fn n ->
    facts = for(i <- 1..n, do: {:x, i}) ++ for(i <- 1..n, do: {:y, i})

    shared |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
  end,
  note:
    "whichever rule fires second re-concludes a fact that is already present, " <>
      "which is the only thing that consults the support index"
)

Bench.scenario(
  "the same two rules over disjoint conclusions",
  [125, 250, 500, 1_000],
  fn n ->
    facts = for(i <- 1..n, do: {:x, i}) ++ for(i <- 1..n, do: {:y, -i})

    shared |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
  end,
  note: "the control for the scenario above — same rules, same fact count, no re-conclusion"
)

Bench.scenario(
  "a negation flipping on and off",
  [500, 1_000, 2_000],
  fn n ->
    custs = for i <- 1..n, do: {:cust, i}
    orders = for i <- 1..n, do: {:order, i}

    session =
      negation |> Bench.session() |> Rete.Session.insert(custs) |> Rete.Session.fire_rules()

    session
    |> Rete.Session.insert(orders)
    |> Rete.Session.fire_rules()
    |> Rete.Session.retract(orders)
    |> Rete.Session.fire_rules()
  end,
  note: "n conclusions suppressed and then released"
)

Bench.scenario(
  "an unkeyed negation taking n blockers",
  [125, 250, 500, 1_000],
  fn n ->
    custs = for i <- 1..n, do: {:cust, i}
    blockers = for i <- 1..n, do: {:blocker, i}

    session =
      unkeyed_negation
      |> Bench.session()
      |> Rete.Session.insert(custs)
      |> Rete.Session.fire_rules()

    session |> Rete.Session.insert(blockers) |> Rete.Session.fire_rules()
  end,
  note: "n tokens and n elements under one key — the scenario above keys them apart"
)

Bench.scenario(
  "filling one collection, no token yet",
  [250, 500, 1_000],
  fn n ->
    orders = for i <- 1..n, do: {:order, 1, i}

    collection
    |> Bench.session()
    |> Rete.Session.insert([{:cust, 1} | orders])
    |> Rete.Session.fire_rules()
  end,
  note:
    "{:cust, 1} is enqueued first, so its token reaches the node behind every order — " <>
      "the members land with nothing to collect for, and nothing reads the group back"
)

Bench.scenario(
  "filling one collection behind a live token",
  [125, 250, 500, 1_000],
  fn n ->
    orders = for i <- 1..n, do: {:order, 1, i}

    session =
      collection
      |> Bench.session()
      |> Rete.Session.insert({:cust, 1})
      |> Rete.Session.fire_rules()

    session |> Rete.Session.insert(orders) |> Rete.Session.fire_rules()
  end,
  note:
    "settle the token first, then one call carrying every member — the group is read " <>
      "back twice for the batch, not twice per member"
)

Bench.scenario(
  "filling one collection one member at a time",
  [125, 250, 500, 1_000],
  fn n ->
    session =
      collection
      |> Bench.session()
      |> Rete.Session.insert({:cust, 1})
      |> Rete.Session.fire_rules()

    Enum.reduce(1..n, session, fn i, session ->
      session |> Rete.Session.insert({:order, 1, i}) |> Rete.Session.fire_rules()
    end)
  end,
  note:
    "the same members through n calls instead of one, so nothing can be batched — " <>
      "this is the shape the scenario above hides",
  expect:
    {:known,
     "the collection binding is the gathered list, so a member change rebuilds it twice: " <>
       "one list to retract the old match by, one to send the new one. " <>
       "See the known gaps in docs/design/engine.md"}
)

Bench.compare(
  "a blocking rule body, by :concurrency",
  [{"1 (default)", 1}, {"4", 4}, {"16", 16}, {"64", 64}],
  fn concurrency ->
    jobs = for i <- 1..64, do: {:job, i}

    blocking
    |> Bench.session()
    |> Rete.Session.insert(jobs)
    |> Rete.Session.fire_rules(concurrency: concurrency)
  end,
  note: "64 activations of a body that sleeps 5 ms — the case :concurrency exists for"
)

IO.puts("")
