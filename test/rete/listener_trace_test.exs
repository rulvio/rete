defmodule Rete.ListenerTraceTest do
  @moduledoc """
  `Rete.Listener.Trace` writes a line per event, and nothing used to run it.

  It is public and documented, and it was the one module in the project at zero coverage. A
  listener is folded over every event the engine emits, so a clause that raised would take
  the session down with it, and only a user who attached it would find out.

  One session reaches every branch of `describe/1`. The assertions are on the shape of a
  line rather than on its exact wording, so rewording a line does not fail the build, but
  losing one does.
  """

  use ExUnit.Case, async: true

  alias Rete.Listener.Trace
  alias Rete.Session

  defmodule Rules do
    use Rete.Ruleset

    defrule flag({:order, cid, amt} when amt > 100), do: {:flagged, cid}
    defrule escalate({:flagged, cid}), do: {:escalated, cid}
  end

  # Inserts a duplicate, retracts both occurrences so the conclusion cascades, then queues
  # an insert and its retraction so an activation is cancelled before it fires.
  defp traced(opts) do
    {:ok, io} = StringIO.open("")

    [Rules]
    |> Session.new()
    |> Session.with_listener(Trace, Keyword.put(opts, :device, io))
    |> Session.insert([{:order, 1, 250}, {:order, 1, 250}])
    |> Session.fire_rules()
    |> Session.retract([{:order, 1, 250}, {:order, 1, 250}])
    |> Session.fire_rules()
    |> Session.insert({:order, 2, 900})
    |> Session.retract({:order, 2, 900})
    |> Session.fire_rules()

    io |> StringIO.contents() |> elem(1) |> String.split("\n", trim: true)
  end

  describe "Trace" do
    test "writes a line for every kind of event it knows" do
      lines = traced(verbose: true)

      for {label, pattern} <- [
            {"fire started", ~r/^\[rete\] fire$/},
            {"fire finished", ~r/settled after \d+ activations/},
            {"asserted insert", ~r/^\[rete\]   \+ \{:order/},
            {"derived insert",
             ~r/^\[rete\]   \+ .* \(from Rete\.ListenerTraceTest\.Rules\.flag\)/},
            {"duplicate", ~r/\(already present\)/},
            {"asserted retract", ~r/^\[rete\]   - \{:order/},
            {"derived retract", ~r/\(support from .* gone\)/},
            {"activation added", ~r/^\[rete\]   ready  /},
            {"activation removed", ~r/^\[rete\]   cancel /},
            {"activation fired", ~r/^\[rete\]   fire   .* -> /},
            {"propagated", ~r/^\[rete\]     (left|right)\w* \d+ x\d+/}
          ] do
        assert Enum.any?(lines, &String.match?(&1, pattern)), "no line for #{label}"
      end
    end

    # The fallback exists so a new event kind cannot crash a listener. Reaching it means an
    # event has no line of its own, which is a gap rather than a failure.
    test "every event the engine emits has a line of its own" do
      unformatted = Enum.filter(traced(verbose: true), &String.match?(&1, ~r/^\[rete\] \{:/))

      assert [] == unformatted
    end

    test "propagation events are behind :verbose" do
      quiet = traced([])

      refute Enum.any?(quiet, &String.match?(&1, ~r/^\[rete\]     (left|right)/))
      assert Enum.any?(quiet, &String.match?(&1, ~r/^\[rete\]   fire   /))
    end

    test "every line is tagged, so trace output is greppable out of a mixed stream" do
      assert Enum.all?(traced(verbose: true), &String.starts_with?(&1, "[rete] "))
    end
  end
end
