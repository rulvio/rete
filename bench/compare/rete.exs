# The rete side of the clara comparison bench. `mix run bench/compare/rete.exs`
#
# Every scenario here has a counterpart in clara/src/bench/clara.clj, and the two must do
# the same work. A scenario reports how many matches its counting query holds, and
# report.exs refuses to print a ratio for a scenario whose counts disagree.
#
# This is not bench/run.exs. That one measures shape and gates CI on an exponent. This one
# measures milliseconds at one size, and asserts on nothing.

defmodule Cmp.Bench do
  @moduledoc false

  # Warm up for this long, or this many runs, whichever ends first. Then time this many
  # runs. clara/src/bench/clara.clj holds the same three numbers, because a comparison of
  # two measurements taken under different protocols is not a comparison.
  @warmup_ms 3_000
  @warmup_runs 50
  @repeats 11

  def measure(fun) do
    warm(fun, 0, System.monotonic_time(:millisecond) + @warmup_ms)

    times =
      for _ <- 1..@repeats do
        :erlang.garbage_collect()
        Process.sleep(5)
        {us, _} = :timer.tc(fun)
        us / 1000
      end
      |> Enum.sort()

    %{median: Enum.at(times, div(@repeats, 2)), min: hd(times)}
  end

  defp warm(fun, runs, deadline) do
    if runs < @warmup_runs and System.monotonic_time(:millisecond) < deadline do
      fun.()
      warm(fun, runs + 1, deadline)
    end
  end

  # The network is built once, and each run gets an empty session over it. Otherwise every
  # measurement would include compiling the ruleset. The clara side keeps its `build` call
  # outside the timed thunk for the same reason.
  def session(module) do
    [module] |> Rete.Compiler.build() |> Rete.Session.from_network()
  end

  def tally(session, module), do: length(Rete.Session.query(session, {module, :matches}))
end

# --- the rulesets ----------------------------------------------------------------------
#
# One module per scenario, for the reason bench/run.exs gives: a shared ruleset would put
# every scenario's facts through every other scenario's rules, and the measurement would be
# of the fixture. Each one carries a counting query, which is how the two engines are held
# to the same workload.

defmodule Cmp.Flag do
  @moduledoc false
  use Rete.Ruleset

  defrule flag({:order, cid, amt} when amt > 100), do: {:flagged, cid, amt}
  defquery matches({:flagged, _cid, _amt}), do: :ok
end

defmodule Cmp.Join do
  @moduledoc false
  use Rete.Ruleset

  defrule paired({:customer, cid, _name}, {:order, cid, amt}), do: {:paired, cid, amt}
  defquery matches({:paired, _cid, _amt}), do: :ok
end

defmodule Cmp.Collection do
  @moduledoc false
  use Rete.Ruleset

  defrule spend({:customer, cid, _name}, orders = [{:order, cid, _amt}]) do
    {:spend, cid, Enum.sum(for {_, _, amt} <- orders, do: amt)}
  end

  defquery matches({:spend, _cid, _total}), do: :ok
end

defmodule Cmp.Negation do
  @moduledoc false
  use Rete.Ruleset

  defrule dormant({:customer, cid, _name}, {:not, [{:order, cid, _amt}]}), do: {:dormant, cid}
  defquery matches({:dormant, _cid}), do: :ok
end

defmodule Cmp.Chain do
  @moduledoc false
  use Rete.Ruleset

  defrule b({:a, x}), do: {:b, x}
  defrule c({:b, x}), do: {:c, x}
  defrule d({:c, x}), do: {:d, x}
  defquery matches({:d, _x}), do: :ok
end

defmodule Cmp.Cascade do
  @moduledoc false
  use Rete.Ruleset

  defrule step({:limit, limit}, {:n, i} when i < limit), do: {:n, i + 1}
  defquery matches({:n, _i}), do: :ok
end

defmodule Cmp.Query do
  @moduledoc false
  use Rete.Ruleset

  defrule flag({:order, cid, amt} when amt > 100), do: {:flagged, cid, amt}
  defquery flagged_for(cid)({:flagged, cid, amt}), do: {cid, amt}
  defquery matches({:flagged, _cid, _amt}), do: :ok
end

# The four rules a reader would actually write together. Only the build scenario uses this
# one, because it is the only scenario that measures the rulebase rather than the firing.
defmodule Cmp.Full do
  @moduledoc false
  use Rete.Ruleset

  defrule flag({:order, cid, amt} when amt > 100), do: {:flagged, cid, amt}
  defrule paired({:customer, cid, _name}, {:order, cid, amt}), do: {:paired, cid, amt}

  defrule spend({:customer, cid, _name}, orders = [{:order, cid, _amt}]) do
    {:spend, cid, Enum.sum(for {_, _, amt} <- orders, do: amt)}
  end

  defrule dormant({:customer, cid, _name}, {:not, [{:order, cid, _amt}]}), do: {:dormant, cid}
  defquery matches({:flagged, _cid, _amt}), do: :ok
end

defmodule Cmp.Generated do
  @moduledoc false

  # One fact type per rule, so that a fact reaches one alpha and not all of them. 512 rules
  # are more than anybody writes out, so they are generated. The clara side evaluates 512
  # defrecord forms for the same reason.
  @rules 512

  def rules, do: @rules

  def module do
    defs =
      for i <- 1..@rules do
        quote do
          defrule unquote(:"r#{i}")({unquote(:"f#{i}"), x}) do
            {:out, unquote(i), x}
          end
        end
      end

    Module.create(
      Cmp.Generated.Ruleset,
      quote do
        use Rete.Ruleset
        unquote_splicing(defs)
        defquery matches({:out, _rule, _x}), do: :ok
      end,
      Macro.Env.location(__ENV__)
    )

    Cmp.Generated.Ruleset
  end

  def facts, do: for(i <- 1..@rules, do: {:"f#{i}", 1})
end

# --- the scenarios -----------------------------------------------------------------------
#
# `prepare` does everything that is not being measured and returns the thunk that is.
# `tally` reads what that thunk returned, and gives the number the two engines must agree
# on. Nothing inside a thunk may depend on a previous call of it, because it runs many
# times.

generated = Cmp.Generated.module()

scenarios = [
  # Not a rules engine at all. A tight integer loop, written the same way on both sides,
  # whose job is to say how fast the process it ran in was going.
  #
  # The cross-engine ratio of this row means nothing: it compares two runtimes at
  # arithmetic, not two engines. What it is for is the comparison of one engine against
  # itself between runs. A process that lands on slow cores, or whose heap is not resident
  # yet, reads high here and high on every other row, and the run is to be repeated rather
  # than read.
  %{
    id: "calibrate",
    n: 2_000_000,
    prepare: fn -> fn -> Enum.reduce(1..2_000_000, 0, &(&2 + rem(&1, 7))) end end,
    tally: fn total -> total end
  },
  %{
    id: "build",
    n: 0,
    prepare: fn -> fn -> Rete.Compiler.build([Cmp.Full]) end end,
    # A freshly built network holds no match, so the count is 0 on both engines. The
    # workload is the rulebase, and the report prints this row without a ratio.
    tally: fn _ -> 0 end
  },
  %{
    id: "insert-fire",
    n: 10_000,
    prepare: fn ->
      session = Cmp.Bench.session(Cmp.Flag)
      facts = for i <- 0..9_999, do: {:order, i, 250}

      fn -> session |> Rete.Session.insert(facts) |> Rete.Session.fire_rules() end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Flag)
  },
  %{
    id: "join-keyed",
    n: 5_000,
    prepare: fn ->
      session = Cmp.Bench.session(Cmp.Join)

      facts =
        for(i <- 0..4_999, do: {:customer, i, "c"}) ++ for(i <- 0..4_999, do: {:order, i, 250})

      fn -> session |> Rete.Session.insert(facts) |> Rete.Session.fire_rules() end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Join)
  },
  %{
    id: "join-one-key",
    n: 5_000,
    prepare: fn ->
      session = Cmp.Bench.session(Cmp.Join)
      facts = [{:customer, 1, "c"} | for(i <- 0..4_999, do: {:order, 1, i})]

      fn -> session |> Rete.Session.insert(facts) |> Rete.Session.fire_rules() end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Join)
  },
  %{
    id: "collection",
    n: 1_000,
    prepare: fn ->
      session = Cmp.Bench.session(Cmp.Collection)

      facts =
        for(i <- 0..999, do: {:customer, i, "c"}) ++
          for(i <- 0..999, k <- 0..3, do: {:order, i, 10 + k})

      fn -> session |> Rete.Session.insert(facts) |> Rete.Session.fire_rules() end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Collection)
  },
  %{
    id: "negation",
    n: 2_000,
    prepare: fn ->
      session = Cmp.Bench.session(Cmp.Negation)
      customers = for i <- 0..1_999, do: {:customer, i, "c"}
      orders = for i <- 0..1_999, do: {:order, i, 250}

      # n conclusions suppressed and then released, which is the cost a negation node
      # exists to pay.
      fn ->
        session
        |> Rete.Session.insert(customers)
        |> Rete.Session.fire_rules()
        |> Rete.Session.insert(orders)
        |> Rete.Session.fire_rules()
        |> Rete.Session.retract(orders)
        |> Rete.Session.fire_rules()
      end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Negation)
  },
  %{
    id: "tms-retract",
    n: 2_000,
    prepare: fn ->
      session = Cmp.Bench.session(Cmp.Chain)
      facts = for i <- 0..1_999, do: {:a, i}

      fn ->
        session
        |> Rete.Session.insert(facts)
        |> Rete.Session.fire_rules()
        |> Rete.Session.retract(facts)
        |> Rete.Session.fire_rules()
      end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Chain)
  },
  %{
    id: "cascade",
    n: 2_000,
    prepare: fn ->
      session = Cmp.Bench.session(Cmp.Cascade)

      fn ->
        session
        |> Rete.Session.insert([{:limit, 2_000}, {:n, 0}])
        |> Rete.Session.fire_rules()
      end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Cascade)
  },
  %{
    id: "query-param",
    n: 4_000,
    prepare: fn ->
      facts = for i <- 0..3_999, do: {:order, i, 250}

      loaded =
        Cmp.Query
        |> Cmp.Bench.session()
        |> Rete.Session.insert(facts)
        |> Rete.Session.fire_rules()

      # 20,000 reads, because one read of one row is too cheap to time on its own.
      fn ->
        Enum.reduce(1..20_000, 0, fn _, read ->
          read + length(Cmp.Query.flagged_for(loaded, 1))
        end)
      end
    end,
    # 20,000 reads of one row.
    tally: fn total -> total end
  },
  %{
    id: "rule-count",
    n: Cmp.Generated.rules(),
    prepare: fn ->
      session = Cmp.Bench.session(generated)
      facts = Cmp.Generated.facts()

      fn -> session |> Rete.Session.insert(facts) |> Rete.Session.fire_rules() end
    end,
    tally: &Cmp.Bench.tally(&1, Cmp.Generated.Ruleset)
  }
]

# --- running ------------------------------------------------------------------------------

argv = System.argv()
smoke? = "--smoke" in argv
out = Enum.find(argv, "bench/compare/results/rete.tsv", &(&1 != "--smoke"))

IO.puts(if smoke?, do: "rete: smoke", else: "rete: measuring")

rows =
  Enum.map(scenarios, fn %{id: id, n: n, prepare: prepare, tally: tally} ->
    thunk = prepare.()
    count = tally.(thunk.())

    IO.puts(
      "  #{String.pad_trailing(id, 14)} n=#{String.pad_trailing(to_string(n), 6)} count=#{count}"
    )

    timing = if smoke?, do: %{median: 0.0, min: 0.0}, else: Cmp.Bench.measure(thunk)

    [
      "rete",
      id,
      to_string(n),
      to_string(count),
      :erlang.float_to_binary(timing.median, decimals: 3),
      :erlang.float_to_binary(timing.min, decimals: 3)
    ]
    |> Enum.join("\t")
  end)

File.mkdir_p!(Path.dirname(out))
header = Enum.join(["engine", "scenario", "n", "count", "median_ms", "min_ms"], "\t")
File.write!(out, Enum.join([header | rows], "\n") <> "\n")
IO.puts("wrote #{out}")

# The runtime reports itself, rather than report.exs asking a shell what is installed. What
# ran is the only thing worth recording, and on a machine with more than one Erlang the two
# answers are not the same.
env = [
  {"elixir", System.version()},
  {"erlang", "OTP #{:erlang.system_info(:otp_release)}, erts #{:erlang.system_info(:version)}"},
  {"beam",
   "#{:erlang.system_info(:emu_flavor)}, #{:erlang.system_info(:wordsize) * 8}-bit, " <>
     "#{:erlang.system_info(:schedulers_online)} schedulers"}
]

env_out = Path.join(Path.dirname(out), "rete-env.tsv")
File.write!(env_out, Enum.map_join(env, "\n", fn {key, value} -> "#{key}\t#{value}" end) <> "\n")
