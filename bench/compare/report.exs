# Joins the two result files and writes RESULTS.md. `elixir bench/compare/report.exs`
#
# Both sides write the number of matches their counting query holds. Two engines that
# report different counts for one scenario ran two different workloads, and a ratio between
# those is worse than no ratio at all. So a mismatch fails the run.

defmodule Report do
  @moduledoc false

  @results "bench/compare/results"
  @out "bench/compare/RESULTS.md"

  @variants ["clara-record", "clara-map"]

  def run do
    rows =
      Enum.flat_map(
        ["rete.tsv", "clara-record.tsv", "clara-map.tsv"],
        &read(Path.join(@results, &1))
      )

    by_scenario = Enum.group_by(rows, & &1.scenario)
    order = rows |> Enum.filter(&(&1.engine == "rete")) |> Enum.map(& &1.scenario)

    check_counts!(order, by_scenario)

    body = [
      preamble(),
      environment(),
      "\n## Medians\n\n",
      table(order, by_scenario, :median),
      "\n## Minimums\n\n",
      "The least noisy reading of the eleven. A JIT runtime is noisy upward and never\n" <>
        "downward, so the gap between a minimum and its median is how much of that median\n" <>
        "is noise.\n\n",
      table(order, by_scenario, :min),
      "\n",
      notes()
    ]

    File.write!(@out, IO.iodata_to_binary(body))
    IO.puts(IO.iodata_to_binary(table(order, by_scenario, :median)))
    IO.puts("wrote #{@out}")
  end

  defp read(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> tl()
    |> Enum.map(fn line ->
      [engine, scenario, n, count, median, min] = String.split(line, "\t")

      %{
        engine: engine,
        scenario: scenario,
        n: String.to_integer(n),
        count: String.to_integer(count),
        median: String.to_float(median),
        min: String.to_float(min)
      }
    end)
  end

  defp check_counts!(order, by_scenario) do
    mismatched =
      Enum.filter(order, fn scenario ->
        by_scenario |> Map.fetch!(scenario) |> Enum.map(& &1.count) |> Enum.uniq() |> length() > 1
      end)

    if mismatched != [] do
      IO.puts(:stderr, "the engines ran different workloads in: #{Enum.join(mismatched, ", ")}")

      Enum.each(mismatched, fn scenario ->
        Enum.each(Map.fetch!(by_scenario, scenario), fn row ->
          IO.puts(:stderr, "  #{scenario} #{row.engine} count=#{row.count}")
        end)
      end)

      System.halt(1)
    end
  end

  defp table(order, by_scenario, field) do
    header = ["scenario", "n", "matches", "rete", "clara-record", "×", "clara-map", "×"]
    rows = Enum.map(order, &row(&1, Map.fetch!(by_scenario, &1), field))
    widths = widths([header | rows])

    [
      line(header, widths),
      "|",
      Enum.map(widths, &(String.duplicate("-", &1 + 2) <> "|")),
      "\n",
      Enum.map(rows, &line(&1, widths))
    ]
  end

  defp row(scenario, entries, field) do
    of = fn engine -> entries |> Enum.find(&(&1.engine == engine)) |> Map.fetch!(field) end
    rete = of.("rete")
    [first, second] = Enum.map(@variants, of)
    sample = hd(entries)

    [
      scenario,
      to_string(sample.n),
      to_string(sample.count),
      ms(rete),
      ms(first),
      ratio(scenario, first, rete),
      ms(second),
      ratio(scenario, second, rete)
    ]
  end

  defp ratio(_scenario, _clara, rete) when rete == 0.0, do: "—"
  defp ratio(_scenario, clara, rete), do: :erlang.float_to_binary(clara / rete, decimals: 2)

  # Two decimals lose their meaning below a millisecond, where a build lands. Three more
  # would be noise on a reading of a hundred.
  defp ms(value) when value >= 1.0, do: :erlang.float_to_binary(value, decimals: 2)
  defp ms(value), do: :erlang.float_to_binary(value, decimals: 4)

  defp widths(rows) do
    rows
    |> Enum.zip_with(& &1)
    |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)
  end

  defp line(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map(fn {cell, width} -> "| " <> String.pad_trailing(cell, width) <> " " end)
    |> Enum.concat(["|\n"])
  end

  defp preamble do
    """
    # rete against clara-rules

    Written by `bench/compare/report.exs`. Read `bench/compare/README.md` first: it says
    what each scenario does and what the numbers do not mean.

    Every figure is milliseconds for one run of the whole scenario, so a smaller number is
    faster. The `×` columns are clara divided by rete, so above 1.00 means rete is ahead.
    The `matches` column is what each engine's counting query held after the scenario
    settled. The three engines agree on it, which is what makes the comparison a comparison.

    The `calibrate` row is not a result. It is an integer loop with no engine in it, and it
    reports how fast the process that ran the rest of the column was going. Its own `×` says
    nothing about either engine. Compare it against the same figure in an earlier run: a
    column whose `calibrate` has moved has moved everywhere, and that run is to be repeated
    rather than read.

    """
  end

  defp environment do
    """
    ## The machine

    | | |
    |---|---|
    | date | #{Date.utc_today()} |
    | model | #{hardware("Model Name")} (#{hardware("Model Identifier")}) |
    | chip | #{hardware("Chip")} |
    | cores | #{cores()} |
    | memory | #{hardware("Memory")} |
    | os | #{cmd("sw_vers", ["-productName"])} #{cmd("sw_vers", ["-productVersion"])} \
    (#{cmd("sw_vers", ["-buildVersion"])}) |

    ## What ran

    Each side asks its own runtime what it is and writes the answer next to its timings.
    A version read off the `PATH` instead would be the one installed, and not necessarily
    the one that ran.

    | | |
    |---|---|
    | rete | #{cmd("git", ["rev-parse", "--short", "HEAD"])} |
    #{env_rows("rete-env.tsv")}\
    | clara-rules | #{clara_version()} |
    #{env_rows("clara-env.tsv")}
    A table of milliseconds only means something next to the machine that produced it. A run
    on another machine overwrites this file, and that is correct.

    **Run it on a quiet machine.** The JVM side is far more sensitive to a busy one than the
    BEAM side, because its compiler and collector threads compete for the same cores. With
    another application holding half a core, clara read 70% slower while rete moved by 12%.
    A table taken then flatters rete. The `calibrate` row is how such a run is spotted.

    """
  end

  # The key-value file each side wrote about itself, as table rows.
  defp env_rows(file) do
    case File.read(Path.join(@results, file)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map_join(fn line ->
          [key, value] = String.split(line, "\t", parts: 2)
          "| #{key} | #{value} |\n"
        end)

      {:error, _reason} ->
        ""
    end
  end

  # `system_profiler` prints an indented `Key: value` block.
  defp hardware(key) do
    case Regex.run(~r/^\s*#{Regex.escape(key)}:\s*(.+)$/m, hardware_profile()) do
      [_match, value] -> String.trim(value)
      nil -> "unknown"
    end
  end

  defp hardware_profile do
    case Process.get(:hardware_profile) do
      nil ->
        profile = cmd_all("system_profiler", ["SPHardwareDataType"])
        Process.put(:hardware_profile, profile)
        profile

      profile ->
        profile
    end
  end

  # Apple silicon runs two kinds of core at two speeds, and which kind a thread lands on is
  # worth more to a reader than the total. `hw.perflevel0` is the faster of the two.
  defp cores do
    total = cmd("sysctl", ["-n", "hw.ncpu"])

    levels = Enum.map([0, 1], &perflevel/1)

    if Enum.member?(levels, "unknown") do
      total
    else
      "#{total} (#{Enum.join(levels, ", ")})"
    end
  end

  # `sysctl -n` with two names prints two lines. The count reads better before the name.
  defp perflevel(level) do
    case cmd_all("sysctl", ["-n", "hw.perflevel#{level}.name", "hw.perflevel#{level}.logicalcpu"]) do
      "unknown" -> "unknown"
      output -> output |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.join(" ")
    end
  end

  defp notes do
    """
    ## What this does not say

    **Two runtimes.** rete runs on the BEAM and clara runs on the JVM. Every ratio here
    mixes engine design with runtime design, and no column separates the two.

    **A steady state, not a start.** Each side warms up before it times anything, so these
    are the numbers a long-running process sees. Neither the JVM's start nor the BEAM's is
    measured.

    **No memory column.** `:erts_debug.size_shared/1` counts shared BEAM terms and a JVM
    heap reading counts reachable objects. The two numbers do not divide.

    **The build row is one ruleset, of four rules.** Both engines expand their rule macros
    ahead of it, so what it times is the same phase on both sides: rule data to a live
    session. The gap is runtime code generation. `mk-session` evaluates the condition and
    action forms of each rule, and rete has nothing to evaluate, because Elixir emitted
    those as functions when it compiled the ruleset module. A larger ruleset moves this row,
    and nothing here says how.

    **clara can go faster on one row.** The `collection` scenario uses
    `clara.rules.accumulators/all` and sums in the right hand side, because a rete collection
    is collect-all and has no other form. `acc/sum` is the faster clara answer, and it has no
    counterpart here.
    """
  end

  defp cmd(command, args) do
    case cmd_all(command, args) do
      "unknown" -> "unknown"
      output -> output |> String.split("\n", trim: true) |> List.first() |> String.trim()
    end
  end

  defp cmd_all(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  end

  # Which clara-rules the bench measured, read out of the dependency that names it. The
  # bench takes it either way: a released version off Clojars, or a checkout on disk. A
  # checkout has no version to print, so `git describe` names the commit instead.
  @clara_deps "bench/compare/clara/deps.edn"

  defp clara_version do
    deps = File.read!(@clara_deps)

    cond do
      captures = Regex.run(~r/:mvn\/version\s+"([^"]+)"/, deps) ->
        "#{Enum.at(captures, 1)} (Clojars)"

      captures = Regex.run(~r/:local\/root\s+"([^"]+)"/, deps) ->
        root = Enum.at(captures, 1)
        "#{cmd("git", ["-C", root, "describe", "--tags", "--always", "--dirty"])} (#{root})"

      true ->
        "unknown"
    end
  end
end

Report.run()
