defmodule Rete.Doc.Orders do
  @moduledoc """
  The ruleset the doctests in `lib/` run against.

  Compiled in the test environment only. It is shown in `Rete.Session`'s moduledoc so
  that a reader of the generated docs can see what the examples match on.
  """

  use Rete.Ruleset

  derive :premium, :customer

  defrule large_order({:customer, cid}, {:order, cid, amt} when amt > 100) do
    {:flagged, cid, amt}
  end

  defquery flagged_for({:flagged, cid, amt}) do
    {cid, amt}
  end
end
