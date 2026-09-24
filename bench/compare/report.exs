# Joins the result files and writes RESULTS.md. `elixir bench/compare/report.exs`
#
# Both sides write the number of matches their counting query holds. Two engines that
# report different counts for one scenario ran two different workloads, and a ratio between
# those is worse than no ratio at all. So a mismatch fails the run.
#
# With `--smoke` it checks the counts and prints the table, and writes nothing. A smoke run
# times nothing, so a RESULTS.md written from it would hold no result.

defmodule Report do
  @moduledoc false

  @results "bench/compare/results"
  @out "bench/compare/RESULTS.md"

  @variants ["clara-record", "clara-map"]

  def run(argv) do
    smoke? = "--smoke" in argv

    rows =
      Enum.flat_map(
        ["rete.tsv", "clara-record.tsv", "clara-map.tsv"],
        &read(Path.join(@results, &1))
      )

    by_scenario = Enum.group_by(rows, & &1.scenario)
    order = rows |> Enum.filter(&(&1.engine == "rete")) |> Enum.map(& &1.scenario)

    check_counts!(order, by_scenario)

    table = table(order, by_scenario, smoke?)

    if smoke? do
      IO.puts(IO.iodata_to_binary(table))
      IO.puts("counts agree")
    else
      File.write!(@out, IO.iodata_to_binary([preamble(), environment(), "## Results\n\n", table]))
      IO.puts(IO.iodata_to_binary(table))
      IO.puts("wrote #{@out}")
    end
  end

  defp read(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> tl()
    |> Enum.map(fn line ->
      [engine, scenario, n, count, mean, rsd] = String.split(line, "\t")

      %{
        engine: engine,
        scenario: scenario,
        n: String.to_integer(n),
        count: String.to_integer(count),
        mean: String.to_float(mean),
        rsd: String.to_float(rsd)
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

  defp table(order, by_scenario, smoke?) do
    header = ["scenario", "n", "matches", "rete", "clara-record", "×", "clara-map", "×"]
    rows = Enum.map(order, &row(&1, Map.fetch!(by_scenario, &1), smoke?))
    widths = widths([header | rows])

    [
      line(header, widths),
      "|",
      Enum.map(widths, &(String.duplicate("-", &1 + 2) <> "|")),
      "\n",
      Enum.map(rows, &line(&1, widths))
    ]
  end

  defp row(scenario, entries, smoke?) do
    of = fn engine -> Enum.find(entries, &(&1.engine == engine)) end
    rete = of.("rete")
    [first, second] = Enum.map(@variants, of)

    timings =
      if smoke? do
        List.duplicate("—", 5)
      else
        [
          timing(rete),
          timing(first),
          ratio(first.mean, rete.mean),
          timing(second),
          ratio(second.mean, rete.mean)
        ]
      end

    [scenario, to_string(rete.n), to_string(rete.count) | timings]
  end

  defp timing(entry), do: "#{ms(entry.mean)} ±#{round(entry.rsd * 100)}%"

  defp ratio(_clara, rete) when rete == 0.0, do: "—"
  defp ratio(clara, rete), do: :erlang.float_to_binary(clara / rete, decimals: 2)

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

    Written by `bench/compare/report.exs`. `bench/compare/README.md` says what each
    scenario does, how it is measured, and what the numbers do not mean.

    Each timing is the mean in milliseconds for one run of the whole scenario. The `±` is
    the relative standard deviation. The `×` columns are the clara mean divided by the rete
    mean. The `matches` column is the count that every engine's counting query held.

    """
  end

  defp environment do
    """
    ## The machine

    | | |
    |---|---|
    | date | #{Date.utc_today()} |
    #{machine_rows()}
    ## What ran

    | | |
    |---|---|
    | rete | #{cmd("git", ["rev-parse", "--short", "HEAD"])} |
    #{env_rows("rete-env.tsv")}#{env_rows("clara-env.tsv")}
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

  defp machine_rows do
    machine()
    |> Enum.map_join(fn {key, value} -> "| #{key} | #{value} |\n" end)
  end

  defp machine do
    case :os.type() do
      {:unix, :darwin} -> darwin_machine()
      {:unix, :linux} -> linux_machine()
      _other -> [{"os", "unknown"}]
    end
  end

  defp darwin_machine do
    [
      {"model", "#{hardware("Model Name")} (#{hardware("Model Identifier")})"},
      {"chip", hardware("Chip")},
      {"cores", darwin_cores()},
      {"memory", hardware("Memory")},
      {"os",
       "#{cmd("sw_vers", ["-productName"])} #{cmd("sw_vers", ["-productVersion"])} " <>
         "(#{cmd("sw_vers", ["-buildVersion"])})"}
    ]
  end

  # A cloud machine or a container often hides the DMI model or the CPU model. So every row
  # falls back to "unknown" on its own.
  defp linux_machine do
    [
      {"model", file_line("/sys/devices/virtual/dmi/id/product_name")},
      {"chip", field(cmd_all("lscpu", []), "Model name")},
      {"cores", cmd("nproc", [])},
      {"memory", linux_memory()},
      {"os",
       "#{"/etc/os-release" |> read_file() |> field("PRETTY_NAME", "=") |> String.trim("\"")} " <>
         "(#{cmd("uname", ["-r"])})"}
    ]
  end

  defp linux_memory do
    case "/proc/meminfo" |> read_file() |> field("MemTotal") |> Integer.parse() do
      {kb, _unit} -> "#{round(kb / 1024 / 1024)} GB"
      :error -> "unknown"
    end
  end

  defp file_line(path) do
    case read_file(path) do
      "unknown" -> "unknown"
      contents -> contents |> String.split("\n", trim: true) |> List.first("unknown")
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> "unknown"
    end
  end

  # One `Key: value` line out of a block of them. `system_profiler`, `lscpu` and
  # /proc/meminfo all print that shape. /etc/os-release uses `=` instead.
  defp field(text, key, separator \\ ":") do
    pattern = ~r/^\s*#{Regex.escape(key)}#{separator}\s*(.+)$/m

    # `lscpu` prints `-` for a model name that a virtual machine does not report.
    case Regex.run(pattern, text) do
      [_match, value] -> if String.trim(value) == "-", do: "unknown", else: String.trim(value)
      nil -> "unknown"
    end
  end

  defp hardware(key), do: field(hardware_profile(), key)

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
  defp darwin_cores do
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

  defp cmd(command, args) do
    case cmd_all(command, args) do
      "unknown" -> "unknown"
      output -> output |> String.split("\n", trim: true) |> List.first("unknown") |> String.trim()
    end
  end

  # `System.cmd/3` raises when the command does not exist. That is not an error here. It is
  # a machine that answers in another way, and its row reads "unknown".
  defp cmd_all(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  rescue
    ErlangError -> "unknown"
  end
end

Report.run(System.argv())
