# Scaling benchmarks. `mix bench`
#
# These do not ask "how fast is it". They ask "what shape is it" — the question
# that matters for a Rete engine, where the failure mode is not a slow function
# but an operation that is quadratic in something a session accumulates. Three
# such quadratics were found and fixed at once, and each was invisible until the
# one above it was gone. Nothing but a scaling measurement would have shown them.
#
# So a scaling scenario runs at three or four sizes and reports the empirical exponent: the
# k in O(n^k). Around 1.0 is linear and fine. Around 2.0 is quadratic and is a bug.
# Every scenario is judged the same way, and there is no way to exempt one.
#
# Two numbers decide it, and `verdict/2` says why each one is there. The **fit** is
# k over every size at once, and it is the verdict. The **last pair** guards the top
# end, because a fit is an average and it would dilute a scenario that only turns
# quadratic at the largest size.
#
# A scenario that allocates a whole structure per call takes `isolate: true`. The heap of
# the bench process grows as that structure grows, and this keeps the measurement clear of
# it. See `time_isolated/1`.
#
# **The exponent gates CI.** A run that finds a superlinear scenario exits non-zero, and
# `finish/0` names it. An exponent is a ratio between two timings, so the speed of the
# machine has no effect on it. Measured at 2 and at 4 schedulers, and under 3x CPU
# oversubscription, the worst of the readings stayed near n^1.2. It moves more between two
# runs of one configuration than between the configurations. The gate is n^1.5.
#
# **Wall clock is asserted on nowhere.** A duration threshold on a shared runner fails for
# reasons that mean nothing. Every millisecond figure this prints is there to be read, and
# not to be compared against a bound.

defmodule Bench do
  @moduledoc false

  # Enough repeats to median away a stray GC pause, few enough to stay usable.
  @repeats 5

  # How long one repeat of an isolated scenario may run. The slowest of them takes a few
  # milliseconds, so this is far above anything healthy. It is a backstop against a hang,
  # and not a timing threshold. Breaching it aborts the run, so the whole bench costs this
  # once and not once per repeat.
  @isolated_timeout :timer.minutes(2)

  def scenario(label, sizes, fun, opts \\ []) do
    IO.puts("\n\e[1m#{label}\e[0m")
    for note <- List.wrap(opts[:note]), do: IO.puts("  #{note}")

    timer = if opts[:isolate], do: &time_isolated/1, else: &time/1
    results = Enum.map(sizes, fn n -> {n, timer.(fn -> fun.(n) end)} end)

    results
    |> Enum.with_index()
    |> Enum.each(fn {{n, ms}, index} ->
      IO.puts(
        "  #{pad(n, 7)}  #{pad(fmt(ms), 9)} ms#{growth(Enum.at(results, index - 1), n, ms, index)}"
      )
    end)

    tally(:scenarios)
    verdict(label, results)
  end

  # --- the exit status ----------------------------------------------------------------
  #
  # CI runs this, so a scenario that turns superlinear has to fail the build rather than
  # print a red cross nobody reads.
  #
  # Every `scenario/4` call runs in the process of the script. The `(fn -> ... end).()`
  # wrappers around some of them are ordinary calls, and `time_isolated/1` is the one thing
  # that spawns. So the counts live in the process dictionary, and no result has to be
  # threaded back through a thousand lines of call sites.

  @tally :bench_tally
  @failed :bench_failed

  # How long a graceful shutdown may take before `finish/0` stops waiting for it. A backstop
  # against a node that will not stop, and not a budget: `System.stop/1` takes milliseconds.
  @stop_timeout :timer.seconds(60)

  defp tally(key) do
    counts = Process.get(@tally, %{})
    Process.put(@tally, Map.update(counts, key, 1, &(&1 + 1)))
  end

  defp count(key), do: Process.get(@tally, %{}) |> Map.get(key, 0)

  defp record_failure(label) do
    Process.put(@failed, [label | Process.get(@failed, [])])
  end

  @doc false
  # The last statement of the script. A `?` does not fail: it reports that a scenario has
  # grown too fast to measure itself, which needs a person to raise its sizes rather than a
  # red build.
  def finish do
    unjudged = count(:unjudged)

    if unjudged > 0 do
      IO.puts("\n\e[33m?\e[0m #{unjudged} scenario(s) too fast to judge. Raise their sizes.")
    end

    case Process.get(@failed, []) |> Enum.reverse() do
      [] ->
        IO.puts("\n\e[32m✓\e[0m #{passed(unjudged)}")

      labels ->
        IO.puts(
          "\n\e[31m✗\e[0m #{length(labels)} of #{count(:scenarios)} scenarios are " <>
            "not linear:"
        )

        Enum.each(labels, &IO.puts("  #{&1}"))

        # `System.stop/1` shuts the node down gracefully, so everything above reaches the
        # terminal. `System.halt/1` is documented as not flushing ports. Stopping is
        # asynchronous, so the script has to stay alive for it to take effect.
        #
        # The wait is bounded, and `halt/1` is the backstop. A shutdown that never arrives
        # would otherwise hang the run. Reaching the backstop means output may be cut, and
        # that is still better than a hang.
        #
        # A minute, so that the backstop fires well inside the CI job's own limit whatever
        # the run cost before this point. A longer wait would let the job time out first,
        # and a job killed from outside reports no scenario at all.
        System.stop(1)
        Process.sleep(@stop_timeout)
        System.halt(1)
    end
  end

  # Says what was measured, and not more. A scenario too fast to judge is not a scenario
  # found to be linear, so it is not counted as one.
  defp passed(0), do: "all #{count(:scenarios)} scenarios are linear"

  defp passed(unjudged) do
    "#{count(:scenarios) - unjudged} of #{count(:scenarios)} scenarios are linear, and " <>
      "#{unjudged} could not be judged"
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

  # Rows a scenario measured for itself, printed as a table. `scenario/4` and `compare/4`
  # both own their measurement; this owns none of it. A scenario reaches for this when its
  # columns are not one timing — a cost by cardinality, or a count next to a duration.
  #
  # `rows` is `{label, [value]}`, already formatted. Values are right-aligned under their
  # header, so a column of numbers reads down the page.
  def table(label, headers, rows, opts \\ []) do
    IO.puts("\n\e[1m#{label}\e[0m")
    for note <- List.wrap(opts[:note]), do: IO.puts("  #{note}")

    name_width =
      rows |> Enum.map(&(&1 |> elem(0) |> to_string() |> String.length())) |> Enum.max()

    widths = Enum.map(headers, &String.length/1)

    IO.puts("  #{pad_trailing("", name_width)}  #{cells(headers, widths)}")

    Enum.each(rows, fn {name, values} ->
      IO.puts("  #{pad_trailing(name, name_width)}  #{cells(values, widths)}")
    end)
  end

  defp cells(values, widths) do
    values
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {value, width} -> pad(value, width) end)
  end

  defp pad_trailing(value, width), do: String.pad_trailing(to_string(value), width)

  # A run is timed after a warm-up pass, because the first call through a fresh
  # network pays for JIT and for the first allocation of every memory it touches.
  def time(fun) do
    fun.()

    1..@repeats
    |> Enum.map(fn _ ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fun)
      us / 1000
    end)
    |> median()
  end

  # `time/1`, with each repeat on its own process. `scenario/4` takes this for `isolate:
  # true`.
  #
  # `:erlang.garbage_collect/0` returns a process to a clean heap, but not to a *small* one.
  # A function that allocates a whole structure per call grows the heap of the bench
  # process. Collection then costs more at every later size. The measurement reads as
  # superlinear while the function under it is linear. Compiling 1,024 rules measured
  # ~n^1.34 this way, and ~n^1.05 on a fresh heap.
  #
  # The warm-up moves inside the process, because the heap is the thing being isolated.
  #
  # **This is not the default, and it suits few scenarios.** Spawning copies the closure. A
  # scenario that holds a loaded session would thus copy it at every repeat. Building a
  # network is the case this fits, because an application builds one time at start.
  def time_isolated(fun) do
    1..@repeats |> Enum.map(fn _ -> isolated_repeat(fun) end) |> median()
  end

  # One repeat, on its own process, with no way to wait forever.
  #
  # Three things have to be right, and a bare `spawn` with a bare `receive` gets none of
  # them. `spawn_monitor` means a scenario that raises reports the crash, where an unlinked
  # `spawn` would die in silence. The reply carries a `make_ref/0`, so a stray message is
  # not mistaken for a timing and fed to `median/1`. The `after` clause bounds the wait, so
  # a scenario that hangs fails the run rather than holding the CI job open until its own
  # limit. Each of those failures aborts the script, which is what a broken measurement
  # deserves.
  defp isolated_repeat(fun) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        fun.()
        # The warm-up allocated one whole structure on this heap, so collect before timing
        # for the same reason `time/1` does.
        :erlang.garbage_collect()
        {us, _} = :timer.tc(fun)
        send(caller, {ref, us / 1000})
      end)

    receive do
      {^ref, ms} ->
        Process.demonitor(monitor, [:flush])
        ms

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "an isolated scenario crashed: #{Exception.format_exit(reason)}"
    after
      @isolated_timeout ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)

        raise "an isolated scenario ran longer than #{@isolated_timeout}ms"
    end
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

  # What the shape is judged on. Two numbers, because one of them cannot do both jobs.
  #
  # `fit` is the **verdict**. It is `k` over every size at once, so one noisy measurement
  # moves it a little rather than deciding it. The worst pair used to be the verdict. It is
  # the worst of three ratios, so it is biased upward and it swings. Over six runs of one
  # unchanged scenario it read 1.45 to 1.89, where the fit read 1.32 to 1.36.
  #
  # `last` is the **guard on the top end**. A fit is an average, so a scenario that is linear
  # up to the largest size and quadratic at it comes out near 1.43 over four points, and
  # passes. That is the failure this file exists to catch. A quadratic last step puts `last`
  # near 2.0, and every reading of a healthy scenario is far below the bound.
  @linear_fit 1.5
  @linear_last 1.8

  # Every scenario is judged the same way, and there is no way to exempt one. A scenario
  # that cannot hold the line is one to fix or to delete. An exemption nobody uses is an
  # untested branch in the thing that gates the build.
  defp verdict(label, results) do
    ks =
      results
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [{_, t1}, _] -> t1 > 0 end)
      |> Enum.map(fn [{n1, t1}, {n2, t2}] -> exponent(n1, t1, n2, t2) end)

    case {ks, results |> log_points() |> fit()} do
      {[], _fit} ->
        unjudged()

      {_ks, nil} ->
        unjudged()

      {ks, fit} ->
        report(label, fit, List.last(ks), Enum.max(ks))
    end
  end

  defp unjudged do
    tally(:unjudged)
    IO.puts("  \e[33m?\e[0m too fast to judge — raise the sizes")
  end

  defp report(label, fit, _last, worst) when fit >= @linear_fit do
    record_failure(label)

    IO.puts(
      "  \e[31m✗\e[0m superlinear: fit ~n^#{fmt(fit)}, over the bound of " <>
        "n^#{fmt(@linear_fit)} (worst pair ~n^#{fmt(worst)})"
    )
  end

  defp report(label, fit, last, _worst) when last >= @linear_last do
    record_failure(label)

    IO.puts(
      "  \e[31m✗\e[0m the top end is superlinear: last pair ~n^#{fmt(last)}, over the " <>
        "bound of n^#{fmt(@linear_last)} (fit ~n^#{fmt(fit)})"
    )
  end

  defp report(_label, fit, _last, worst) do
    IO.puts("  \e[32m✓\e[0m linear (fit ~n^#{fmt(fit)}, worst pair ~n^#{fmt(worst)})")
  end

  # `k` in `t = c * n^k`, by least squares on log t against log n. A size whose timing is
  # zero carries no ratio, so it is dropped rather than turned into an infinity.
  # `nil` when the points cannot carry a slope. A size whose timing is zero is dropped
  # above, so one size may be all that is left, and one point has no slope. The variance
  # underneath would be zero, and the fit would raise where it is asked to judge. That is
  # the "too fast to judge" case arriving by a second route, so `verdict/2` reports it as
  # one rather than failing a build on it.
  defp fit([]), do: nil

  defp fit(points) do
    {xs, ys} = Enum.unzip(points)
    mean_x = Enum.sum(xs) / length(xs)
    mean_y = Enum.sum(ys) / length(ys)
    variance = xs |> Enum.map(fn x -> (x - mean_x) * (x - mean_x) end) |> Enum.sum()

    if variance > 0 do
      covariance =
        points |> Enum.map(fn {x, y} -> (x - mean_x) * (y - mean_y) end) |> Enum.sum()

      covariance / variance
    end
  end

  # The log-log points a fit is taken over. A timing of zero has no logarithm, so it is
  # dropped rather than turned into an infinity.
  defp log_points(results), do: for({n, t} <- results, t > 0, do: {:math.log(n), :math.log(t)})

  defp fmt(float), do: :erlang.float_to_binary(float * 1.0, decimals: 2)

  # Small durations and large ratios both lose their meaning at two decimals. A read that
  # costs 0.0001 ms prints as 0.00, and a 1,500× ratio needs no decimals at all.
  def sig(float) when float >= 100, do: :erlang.float_to_binary(float * 1.0, decimals: 0)
  def sig(float) when float >= 1, do: :erlang.float_to_binary(float * 1.0, decimals: 2)

  def sig(float) do
    decimals = max(2, 2 - trunc(:math.log10(max(float, 1.0e-9))))

    float
    |> Kernel.*(1.0)
    |> :erlang.float_to_binary(decimals: min(decimals, 6))
    |> String.replace(~r/(\.\d*?)0+$/, "\\1")
    |> String.replace(~r/\.$/, "")
  end

  defp pad(value, width), do: String.pad_leading(to_string(value), width)

  # The network is compiled once and each run gets an empty session over it.
  # Otherwise every measurement would include compiling the ruleset, which is
  # constant work that has nothing to do with the thing being measured.
  def network(module), do: Rete.Compiler.build([module])
  def session(network), do: Rete.Session.from_network(network)

  # How many buckets the token store of a query holds. This is the cardinality of its head
  # over the facts it was given, which is what a parameter costs. `Rete.Network` keys
  # `:queries` on `{module, name}` and gives the node id.
  def query_buckets(session, ref) do
    state = session.state
    id = Map.fetch!(state.network.queries, ref)

    state.memory.tokens |> Map.get(id, %{}) |> map_size()
  end

  # `:erts_debug.size_shared/1` counts a shared subterm once, which is the honest measure
  # for a structure that shares as heavily as this one. `docs/design/engine.md` §13
  # "Memory" reports the same way. Working memory only: the network is the same value for
  # every variant being compared, so including it would add a constant to each row.
  def memory_kb(session) do
    :erts_debug.size_shared(session.state.memory) * :erlang.system_info(:wordsize) / 1024
  end
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
  # Each of the two matches holds its own occurrence, so the conclusion is held
  # twice and needs two retractions.
  defrule from_x({:x, i}), do: {:derived, i}
  defrule from_y({:y, i}), do: {:derived, i}
end

defmodule Bench.FanIn do
  @moduledoc false
  use Rete.Ruleset

  # n matches concluding one fact, and a second rule downstream of it. Working
  # memory is a multiset, so `{:total}` is held n times, and `tally` therefore
  # fires n times and concludes n occurrences of its own.
  #
  # The cost per firing must not grow with the supports already recorded. Every
  # firing writes one insertion record, and they all share a key, because the n
  # tokens reaching `tally` are equal. See `Rete.Memory.add_insertion/4`.
  defrule total({:m, _i}), do: {:total}
  defrule tally({:total}), do: {:tallied}
end

defmodule Bench.Width do
  @moduledoc false

  # r rules, each a distinct condition on one fact type, so no alpha is shared and
  # every one of them hangs off the beta root. Generated rather than written out,
  # because the shape only shows at a width nobody writes by hand.
  #
  # This measures **compile** time, not firing. Sharing a beta node requires the same
  # sharing key and the same parent set, and looking that up used to be a scan of
  # every sibling — quadratic in the number of rules over one type.
  def module(r) do
    name = Module.concat(Bench.Width.Generated, "R#{r}")

    defs =
      for i <- 1..r do
        quote do
          defrule unquote(:"r#{i}")({:ping, x} when rem(x, unquote(i)) == 0) do
            {:pong, unquote(i), x}
          end
        end
      end

    Module.create(
      name,
      quote do
        use Rete.Ruleset
        unquote_splicing(defs)
      end,
      Macro.Env.location(__ENV__)
    )

    name
  end
end

defmodule Bench.Rules do
  @moduledoc false

  # r rules, each on a fact type of its own, each activated exactly once. Generated,
  # because the shape only shows at a rule count nobody writes by hand.
  #
  # This measures **firing**, and specifically the agenda. Every rule has its own sort key,
  # so r rules pending at once means r keys in the agenda. No other scenario reaches that
  # dimension. `Bench.Agenda` has one rule, and `Bench.Width` fires nothing.
  #
  # One type per rule is the whole point of the fixture. r rules over *one* type route
  # every fact to all r alphas, which is O(r²) by design — see §13, "firing is linear in
  # the rule count, and inherently so". That cost would bury the one being measured. A
  # distinct type per rule keeps the taxonomy lookup at one alpha per fact.
  def module(r) do
    name = Module.concat(Bench.Rules.Generated, "R#{r}")

    defs =
      for i <- 1..r do
        quote do
          defrule unquote(:"r#{i}")({unquote(:"f#{i}"), x}) do
            {:out, unquote(i), x}
          end
        end
      end

    Module.create(
      name,
      quote do
        use Rete.Ruleset
        unquote_splicing(defs)
      end,
      Macro.Env.location(__ENV__)
    )

    name
  end

  # One fact per rule, so each of the r rules gets exactly one match.
  def facts(r), do: for(i <- 1..r, do: {:"f#{i}", 1})

  # Through `:persistent_term`, for the reason `Bench.Explain` gives. The scaling scenario
  # takes `isolate: true`, spawning copies the closure, and a closure over a map of r
  # networks would copy every one of them at every repeat. A `:persistent_term` is read
  # without copying. Written once, and never updated, so the global cost of an update is
  # not paid.
  def put(r), do: :persistent_term.put({__MODULE__, r}, Rete.Compiler.build([module(r)]))
  def get(r), do: :persistent_term.get({__MODULE__, r})
end

defmodule Bench.Spread do
  @moduledoc false

  # k modules, each writing the *same* two conditions. Generated, because the shape only
  # shows at a module count nobody writes by hand.
  #
  # This measures **matching**, not firing. The second condition never matches, so no rule
  # fires and nothing is concluded: what is left is the cost of offering each fact to the
  # alpha network and storing the tokens it produces.
  #
  # Every module writes a plain pattern and a literal guard, so nothing ties the condition
  # to the module that wrote it and all k collapse onto one alpha and one root join. Flat
  # is the goal. Before cross-module sharing this was linear in k — the same fact was
  # matched once per module.
  def modules(k) do
    for i <- 1..k do
      name = Module.concat(Bench.Spread.Generated, "M#{k}_#{i}")

      Module.create(
        name,
        quote do
          use Rete.Ruleset

          defrule unquote(:"r#{i}")({:ping, x} when x > 0, {:never, x}) do
            {:pong, unquote(i), x}
          end
        end,
        Macro.Env.location(__ENV__)
      )

      name
    end
  end
end

defmodule Bench.Query do
  @moduledoc false
  use Rete.Ruleset

  defquery rows({:rec, cid, amt}), do: {cid, amt}
end

defmodule Bench.KeyedQuery do
  @moduledoc false
  use Rete.Ruleset

  defquery rows(cid)({:rec, cid, amt}), do: {cid, amt}
end

# The four head shapes, over one fact type. What separates them is the cardinality of what
# they key on, which is the thing a head costs. The facts decide that, not the ruleset:
# `Bench.WideQuery` keys on a field the caller fills with 4 values or with 4,000.
defmodule Bench.WideQuery do
  @moduledoc false
  use Rete.Ruleset

  defquery rows(a)({:rec, a, _b, _c}), do: a
end

defmodule Bench.WideHeadlessQuery do
  @moduledoc false
  use Rete.Ruleset

  defquery rows({:rec, a, _b, _c}), do: a
end

defmodule Bench.ThreeKeyQuery do
  @moduledoc false
  use Rete.Ruleset

  defquery rows(a, b, c)({:rec, a, b, c}), do: {a, b, c}
end

# A body that does enough work to be worth skipping. The point of a head is that the body
# runs for the rows it returns and not for the rows it passes over, and a body returning a
# tuple of what it already has is too cheap to show that.
defmodule Bench.FatQuery do
  @moduledoc false
  use Rete.Ruleset

  defquery rows({:rec, a, b, c}) do
    %{id: a, label: "record #{a}/#{b}", b: b, c: c, tags: Enum.map(1..4, &{&1, a + &1})}
  end
end

defmodule Bench.FatKeyedQuery do
  @moduledoc false
  use Rete.Ruleset

  defquery rows(a)({:rec, a, b, c}) do
    %{id: a, label: "record #{a}/#{b}", b: b, c: c, tags: Enum.map(1..4, &{&1, a + &1})}
  end
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

alias Bench.{Agenda, Blocking, Cascade, Chain, Collection, FanIn, ManyKeys, Negation, OneKey}
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
fan_in = Bench.network(FanIn)
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
    "each conclusion is held twice, by two matches at two different productions, " <>
      "so every fact here carries two truth-maintenance records"
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
  "n matches concluding one fact, read by another rule",
  [125, 250, 500, 1_000],
  fn n ->
    facts = for i <- 1..n, do: {:m, i}

    fan_in |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
  end,
  note:
    "one fact with n supports, so the rule below it fires n times — every one of those " <>
      "firings shares an insertion key, and none may cost more than the one before it"
)

Bench.scenario(
  "inserting n occurrences of one fact",
  [1_000, 2_000, 4_000],
  fn n ->
    facts = List.duplicate({:m, 1}, n)

    fan_in |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
  end,
  note: "every occurrence is a match of its own, and they all land in one bucket"
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
    "the same members through n calls, firing after each — the fire per member is what " <>
      "cannot be batched, not the call per member. The A/B below separates the two"
)

# An A/B rather than a shape, for the reason the concurrency and drip scenarios give: what
# matters is the ratio between the rows, not how either scales.
#
# This is the scenario `docs/dsl.md` and §13 send a reader to. It separates two things the
# docs used to treat as one. A collection re-emits its group once per **change**, and a
# change used to mean a call, because every call drained. From 0.5.0 a fire coalesces the
# queue, so a change means a fire.
#
# So the first row is the expensive shape, and the other two must sit level with each other.
# The caller who gets one event per call — the case the docs used to call unfixable —
# reaches the batched cost by deferring the fire, and changes nothing about how the events
# arrive. If row two drifts toward row one, `coalesce_queue/1` has stopped folding the
# members and the rule is firing once per call again. `Rete.EngineTest` pins the same
# property by counting activations rather than by timing them.
Bench.compare(
  "1,000 collection members, one per call, fired every call and fired once",
  [{"fire each call", :fire_each}, {"fire at the end", :fire_last}, {"one call", :batched}],
  fn kind ->
    orders = for i <- 1..1_000, do: {:order, 1, i}

    session =
      collection
      |> Bench.session()
      |> Rete.Session.insert({:cust, 1})
      |> Rete.Session.fire_rules()

    case kind do
      :fire_each ->
        Enum.reduce(orders, session, fn o, s ->
          s |> Rete.Session.insert(o) |> Rete.Session.fire_rules()
        end)

      :fire_last ->
        orders |> Enum.reduce(session, &Rete.Session.insert(&2, &1)) |> Rete.Session.fire_rules()

      :batched ->
        session |> Rete.Session.insert(orders) |> Rete.Session.fire_rules()
    end
  end,
  note: "the group changes once per fire, not once per call — the last two must be level"
)

# Compiled up front: the scenario times `Rete.Compiler.build/1`, not the macro
# expansion that defines the rules.
width_modules = for r <- [128, 256, 512, 1024], into: %{}, do: {r, Bench.Width.module(r)}

Bench.scenario(
  "compile r rules over one fact type",
  [128, 256, 512, 1024],
  fn r -> Rete.Compiler.build([width_modules[r]]) end,
  # `isolate: true`, because a build allocates a whole network. Five of them in the bench
  # process grow its heap with `r`, and collecting that heap then costs more at every later
  # size, which reads as a superlinear compiler. On a fresh heap this measures ~n^1.05. An
  # application builds its network once at start, so a fresh heap is the honest case too.
  isolate: true,
  note:
    "every rule hangs off the beta root, so sharing has to look past all the others — " <>
      "was O(r\u00B2) while that was a scan"
)

# Compiled up front, for the reason the width scenario gives: the scenario times firing,
# not the build that made the network.
rule_sizes = [128, 256, 512, 1024]

for r <- rule_sizes, do: Bench.Rules.put(r)

Bench.scenario(
  "activate one match of each of r rules",
  rule_sizes,
  fn r ->
    r
    |> Bench.Rules.get()
    |> Bench.session()
    |> Rete.Session.insert(Bench.Rules.facts(r))
    |> Rete.Session.fire_rules()
  end,
  # `isolate: true`, for the reason the compile scenario gives. This settles a whole session
  # of r rules per call. Five of them in the bench process grow its heap with `r`, and
  # collecting that heap then costs more at every later size. It read ~n^1.5 that way and
  # ~n^1.05 on a fresh heap, with the engine linear underneath both.
  isolate: true,
  note:
    "r rules pending at once, so the agenda holds r sort keys — every scenario above " <>
      "has one rule, and this is the dimension none of them varies"
)

# An A/B rather than a shape. Both directions activate the same r rules and settle to the
# same session, so the exponent would say the same thing twice. What separates them is
# where each new sort key lands, and that is a ratio.
#
# A sorted key list is asymmetric here. Activations arrive in compile order, so their keys
# arrive ascending and each insertion walks the whole list. Fed in reverse they arrive
# descending, and each one goes at the head. An ordered tree is flat both ways. So the two
# rows sitting level is the property, and a forward row that is a multiple of the reverse
# row means the agenda is back to a linear insertion.
Bench.compare(
  "1,024 rules activated in compile order and in reverse",
  [{"compile order", :forward}, {"reverse", :reverse}],
  fn direction ->
    facts = Bench.Rules.facts(1_024)
    facts = if direction == :reverse, do: Enum.reverse(facts), else: facts

    1_024
    |> Bench.Rules.get()
    |> Bench.session()
    |> Rete.Session.insert(facts)
    |> Rete.Session.fire_rules()
  end,
  note: "the same r activations, reaching the agenda from the two ends of its ordering"
)

# Compiled up front, for the reason the width scenario gives: the scenario times matching,
# not the build that made the network.
spread_sizes = [4, 8, 16, 32]

spread_networks =
  for k <- spread_sizes, into: %{}, do: {k, Rete.Compiler.build(Bench.Spread.modules(k))}

Bench.scenario(
  "match one condition written in k modules",
  spread_sizes,
  fn k ->
    facts = for i <- 1..200, do: {:ping, i}

    spread_networks[k] |> Bench.session() |> Rete.Session.insert(facts)
  end,
  note:
    "200 facts against the same condition in k modules, nothing firing — flat is the " <>
      "goal, since all k share one alpha and one root join"
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

# An A/B rather than a shape, for the same reason as the one above: batching does not
# change how insert scales, only how many times a node pays its per-call cost.
#
# This is where the 0.5.0 changelog sends a reader who wants the number. What matters is
# the relation, not the milliseconds: a fire coalesces the queue before it drains, so 1,000
# single-fact calls hand a node the same one batch that a single call carrying 1,000 facts
# does. The two rows sit on top of each other, and which one wins by a few percent is the
# machine talking. If the drip row grows to a multiple of the other, `coalesce_queue/1` has
# stopped running and every node is back to one dispatch per call. `Rete.EngineTest` pins
# the same property exactly, off the `:propagated` events. See `docs/design/engine.md` §2.
Bench.compare(
  "1,000 facts, in one insert call and in 1,000",
  [{"one call", :batched}, {"1,000 calls", :drip}],
  fn kind ->
    orders = for i <- 1..1_000, do: {:order, i, i}
    customers = for i <- 1..1_000, do: {:cust, i}
    session = many_keys |> Bench.session() |> Rete.Session.insert(customers)

    fed =
      case kind do
        :batched -> Rete.Session.insert(session, orders)
        :drip -> Enum.reduce(orders, session, &Rete.Session.insert(&2, &1))
      end

    Rete.Session.fire_rules(fed)
  end,
  note: "the queue is coalesced before it drains, so both must cost one settle"
)

IO.puts("")

# Scoped, and last. These need a loaded session per size alive at once, and a live heap
# that large distorts every measurement taken after it — the whole suite reads as
# superlinear. Inside a function the sessions become garbage when it returns, and the
# harness collects before it times anything.
(fn ->
   query = Bench.network(Bench.Query)
   keyed_query = Bench.network(Bench.KeyedQuery)

   query_sessions =
     for n <- [500, 1_000, 2_000, 4_000], into: %{} do
       facts = for i <- 1..n, do: {:rec, i, i}

       {n,
        %{
          plain:
            query |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules(),
          keyed:
            keyed_query
            |> Bench.session()
            |> Rete.Session.insert(facts)
            |> Rete.Session.fire_rules()
        }}
     end

   # Only the keyed shape gets a scaling scenario. To read a query with no head is linear
   # in the match count. `docs/design/engine.md` §13 measures that one session at a time.
   # A measurement here would show a step and then a flat line. That is an effect of the
   # heap, and not of the engine.
   Bench.scenario(
     "a query read by a parameter, selecting 1 of n",
     [500, 1_000, 2_000, 4_000],
     fn n -> for _ <- 1..200, do: Bench.KeyedQuery.rows(query_sessions[n].keyed, 1) end,
     note: "`defquery rows(cid)(...)`, so the read is one bucket and n stops mattering"
   )

   # This is the choice that a ruleset author now makes. A query with no head cannot be
   # read by `cid`. The correct comparison is thus against code that builds every row and
   # then filters the rows here.
   Bench.compare(
     "one row out of 4,000 matches, by parameter and by filtering in Elixir",
     [{"headless, filter after", :plain}, {"parameter cid", :keyed}],
     fn
       :plain ->
         session = query_sessions[4_000].plain

         for _ <- 1..200 do
           session |> Bench.Query.rows() |> Enum.filter(&(elem(&1, 0) == 1))
         end

       :keyed ->
         session = query_sessions[4_000].keyed

         for _ <- 1..200, do: Bench.KeyedQuery.rows(session, 1)
     end,
     note: "one row returned in each case. A head decreases this number."
   )

   :ok
 end).()

# What a head costs to maintain, by the cardinality of what it keys on. Scoped for the
# reason above: each variant loads 4,000 matches, and the memory column reads the live
# structure rather than timing it.
#
# The four rows are the four head shapes. A head keys the token store, so the store holds
# one bucket per distinct value of what the head names. That count is the cost, and the
# ruleset cannot decide it — the facts do. So `Bench.WideQuery` appears twice, once fed a
# field with 4 values and once fed a unique one.
(fn ->
   n = 4_000

   networks = %{
     headless: Bench.network(Bench.WideHeadlessQuery),
     wide: Bench.network(Bench.WideQuery),
     three: Bench.network(Bench.ThreeKeyQuery)
   }

   # `a` is what the one-parameter shapes key on, so it carries the cardinality. `b` and
   # `c` are unique throughout, so the three-parameter row keys on a unique tuple.
   facts = fn cardinality ->
     for i <- 1..n, do: {:rec, rem(i, cardinality), i, i}
   end

   load = fn network, facts ->
     network |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
   end

   shapes = [
     {"no parameters", :headless, Bench.WideHeadlessQuery, n},
     {"one parameter, 4 distinct values", :wide, Bench.WideQuery, 4},
     {"one parameter, all distinct", :wide, Bench.WideQuery, n},
     {"three parameters, all distinct", :three, Bench.ThreeKeyQuery, n}
   ]

   rows =
     Enum.map(shapes, fn {label, key, module, cardinality} ->
       network = networks[key]
       facts = facts.(cardinality)

       insert = Bench.time(fn -> load.(network, facts) end)

       loaded = load.(network, facts)

       retract =
         Bench.time(fn ->
           loaded |> Rete.Session.retract(facts) |> Rete.Session.fire_rules()
         end)

       {label,
        [
          Bench.sig(insert) <> " ms",
          Bench.sig(retract) <> " ms",
          "#{round(Bench.memory_kb(loaded))} KB",
          to_string(Bench.query_buckets(loaded, {module, :rows}))
        ]}
     end)

   Bench.table(
     "what a head costs: 4,000 matches inserted, then all of them retracted",
     ["insert", "retract", "memory", "buckets"],
     rows,
     note: "the cost of a head is the cardinality of what it names, not the head itself"
   )

   :ok
 end).()

# What a head saves, by the same cardinality. The read returns 4,000 / cardinality rows,
# so the two ends of the sweep are the two degenerate cases: a head that returns everything
# saves nothing, and a head that returns one row saves nearly the whole read.
#
# One cardinality at a time. Both sessions for a row become garbage before the next row
# builds its own, which is what keeps this out of the heap trap the scenarios above avoid
# by being scoped.
(fn ->
   n = 4_000
   headless = Bench.network(Bench.WideHeadlessQuery)
   keyed = Bench.network(Bench.WideQuery)

   rows =
     Enum.map([1, 4, 20, 200, 4_000], fn cardinality ->
       facts = for i <- 1..n, do: {:rec, rem(i, cardinality), i, i}

       load = fn network ->
         network |> Bench.session() |> Rete.Session.insert(facts) |> Rete.Session.fire_rules()
       end

       plain = load.(headless)
       keyed_session = load.(keyed)

       filtered =
         Bench.time(fn ->
           for _ <- 1..200 do
             plain |> Bench.WideHeadlessQuery.rows() |> Enum.filter(&(&1 == 0))
           end
         end)

       parameter =
         Bench.time(fn ->
           for _ <- 1..200, do: Bench.WideQuery.rows(keyed_session, a: 0)
         end)

       {to_string(cardinality),
        [
          to_string(div(n, cardinality)),
          Bench.sig(filtered / 200) <> " ms",
          Bench.sig(parameter / 200) <> " ms",
          "×" <> Bench.sig(filtered / parameter)
        ]}
     end)

   Bench.table(
     "what a head saves: one read of 4,000 matches, by distinct values",
     ["rows", "headless + filter", "parameter", "ratio"],
     rows,
     note: "per read, of 200. The left column is how many distinct values the head keys on"
   )

   :ok
 end).()

# The same comparison with a body that does work. The sweep above uses a body that returns
# what it already holds, which understates the difference: a filter on the result runs the
# body for every match and then discards most of the rows, and a head never runs it for a
# row it does not return. So the gap widens with the cost of the body, and this is the
# shape that shows it.
(fn ->
   n = 4_000
   facts = for i <- 1..n, do: {:rec, i, i, i}

   load = fn module ->
     module
     |> Bench.network()
     |> Bench.session()
     |> Rete.Session.insert(facts)
     |> Rete.Session.fire_rules()
   end

   plain = load.(Bench.FatQuery)
   keyed = load.(Bench.FatKeyedQuery)

   Bench.compare(
     "one row out of 4,000, with a body that builds a map and a string",
     [{"filter after", :plain}, {"parameter a", :keyed}],
     fn
       :plain ->
         for _ <- 1..50 do
           plain |> Bench.FatQuery.rows() |> Enum.filter(&(&1.id == 1))
         end

       :keyed ->
         for _ <- 1..50, do: Bench.FatKeyedQuery.rows(keyed, 1)
     end,
     note: "50 reads. The filter runs the body 4,000 times per read, and the head runs it once"
   )

   :ok
 end).()

# --- inspection -------------------------------------------------------------------------
#
# `Rete.Inspect.explain/1` and `why_not/1` walk every rule in the session, so both are
# shaped to go quadratic in the rule count. Two ways of doing so were found and fixed:
# resolving a rule's terminal node scans the beta graph, and `Rete.Memory.inserters/2` scans
# every insertion record when its index is not built. Neither shows at a size anybody writes
# by hand.

defmodule Bench.Explain do
  @moduledoc false

  # r rules in two layers. `a_i` concludes from an inserted fact, and `b_i` concludes from
  # what `a_i` concluded. So half the matched facts are derived, which is the path that
  # reads the provenance index. Each rule fires exactly once, so the work is linear in r and
  # any curve above that is the measurement finding a bug.
  def module(r) do
    name = Module.concat(Bench.Explain.Generated, "R#{r}")

    defs =
      for i <- 1..r do
        quote do
          defrule unquote(:"a#{i}")({:f, unquote(i), amt}) do
            {:mid, unquote(i), amt}
          end

          defrule unquote(:"b#{i}")({:mid, unquote(i), amt}) do
            {:out, unquote(i), amt}
          end
        end
      end

    Module.create(
      name,
      quote do
        use Rete.Ruleset
        unquote_splicing(defs)
      end,
      Macro.Env.location(__ENV__)
    )

    name
  end

  def session(r) do
    facts = for i <- 1..r, do: {:f, i, i}

    [module(r)]
    |> Rete.Session.new()
    |> Rete.Session.insert(facts)
    |> Rete.Session.fire_rules()
  end

  # Both scenarios take `isolate: true`, because each call allocates a whole answer and the
  # heap of the bench process would otherwise grow with `r`. Spawning copies the closure,
  # though, and a closure over a map of loaded sessions would copy every one of them at
  # every repeat. That is a fixed cost at each size, so it would flatten the curve and hide
  # the very shape the gate looks for.
  #
  # `:persistent_term` is read without copying, so the isolated process reads the session
  # and allocates nothing but its own answer. Written once here, and never updated, so the
  # global cost of an update is not paid.
  def put(r), do: :persistent_term.put({__MODULE__, r}, session(r))
  def get(r), do: :persistent_term.get({__MODULE__, r})
end

inspect_sizes = [64, 128, 256, 512]

for r <- inspect_sizes, do: Bench.Explain.put(r)

Bench.scenario(
  "explain every rule in a session of r rules",
  inspect_sizes,
  fn r -> r |> Bench.Explain.get() |> Rete.Inspect.explain() end,
  isolate: true,
  note:
    "2r rules, each firing once, half the matched facts derived — was O(r²) twice " <>
      "over: a beta graph scan per rule, and an unindexed provenance lookup per fact"
)

Bench.scenario(
  "why_not every rule in a session of r rules",
  inspect_sizes,
  fn r -> r |> Bench.Explain.get() |> Rete.Inspect.why_not() end,
  isolate: true,
  note: "one chain walk per rule — was a beta graph scan per rule to find its terminal"
)

# Last, because it sets the exit status of the run.
Bench.finish()
