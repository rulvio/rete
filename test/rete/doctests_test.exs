defmodule Rete.DoctestsTest do
  @moduledoc """
  Doctests for modules that have no test file of their own.

  Every other module's `doctest` sits in its own test file.
  """

  use ExUnit.Case, async: true

  doctest Rete.Activation
  doctest Rete.Bucket
  doctest Rete.Element
  doctest Rete.Listener
  doctest Rete.Listener.Collect
  doctest Rete.Memory
  doctest Rete.Network.Node
  doctest Rete.Session
  doctest Rete.Token
end
